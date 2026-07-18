//! gist — the persisted-index loader, shared by every cold-query path.
//!
//! `ripgrep/index.zig`'s `run` (the `gist index` verb) serializes the trigram
//! `Index` + the doc→path table to disk; each later fresh process maps them back
//! **zero-copy** and validates only the compact directory up front. Posting
//! groups are checked when queried, avoiding a full body decode on every fresh
//! process. That cold-load path is shared by every shape the unified engine
//! serves — the index-accelerated read-elision walk (`commands/ripgrep/run.zig`)
//! and the `--rank` ranked view (`commands/ripgrep/rank.zig`) — so it lives
//! here, in the index layer, rather than in a command (a command importing
//! another command's internals is the coupling this split exists to kill).
//!
//! Publish is generation-atomic: both blobs land under `gens/<id>/` first, then
//! a single `pair.gen` rename publishes the pair. Readers bind to that id and
//! re-check it after mapping, so they never observe new `index.gist` with old
//! `paths.list` (or the reverse).

const std = @import("std");
const Index = @import("trigram.zig").Index;
const corpus_mod = @import("../corpus/corpus.zig");
const Dir = std.Io.Dir;

/// Stable aliases (status / bench size accounting). The query loader prefers the
/// generation published by `pair.gen` when present.
pub const index_file = corpus_mod.out_dir ++ "/index.gist";
pub const paths_file = corpus_mod.out_dir ++ "/paths.list";
pub const generation_file = corpus_mod.out_dir ++ "/pair.gen";
pub const gens_subdir = "gens";

/// A read-only, page-aligned file mapping (zero-copy view of the bytes on disk).
pub const Mapping = []align(std.heap.page_size_min) const u8;

/// mmap a whole file read-only. The mapping survives the fd close (POSIX), and
/// the OS faults in only the pages actually touched. The trusted local loader
/// scans the directory but not the much larger posting body; later queries
/// fault in and validate only their groups. A genuinely empty file is rejected
/// (`mmap` can't map zero length, and a 0-byte index is corruption anyway).
fn mmapFile(io: std.Io, path: []const u8) !Mapping {
    const file = try Dir.cwd().openFile(io, path, .{}); // .read_only default
    defer file.close(io);
    const len: usize = @intCast((try file.stat(io)).size);
    if (len == 0) return error.EmptyFile;
    return std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
}

/// Materialize `sub_path` with `data` via the temp-then-rename pattern (POSIX
/// `rename` is atomic on the same filesystem) instead of a plain truncate+write.
/// Up to ~10 agents cowork this repo and any of them can run `gist index` while
/// another is mid-`mmapFile` on the very same `index.gist`/`paths.list` — a
/// plain overwrite lets that reader observe a torn (truncated/zero-length or
/// half-written) file and silently return zero candidates. Atomic replace means
/// a concurrent reader always sees either the fully-old or fully-new bytes.
pub fn writeAtomic(io: std.Io, sub_path: []const u8, data: []const u8) !void {
    var af = try Dir.cwd().createFileAtomic(io, sub_path, .{ .make_path = true, .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, data);
    try af.replace(io);
}

/// The cold-loaded index + the doc→path table that maps candidate ids back to
/// files. Both are mmap'd: `idx`'s directory + body slices alias into `imap`
/// (borrowed, no copy) and every `paths` slice aliases into `pmap`, so all
/// lifetimes bind to the two mappings and `deinit` simply unmaps them.
pub const Persisted = struct {
    imap: Mapping,
    pmap: Mapping,
    idx: Index,
    paths: std.ArrayList([]const u8),
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Persisted) void {
        self.paths.deinit(self.gpa);
        self.idx.deinit(); // borrowed ⇒ frees nothing
        std.posix.munmap(self.pmap);
        std.posix.munmap(self.imap);
    }
};

/// Cold-load the persisted index + doc→path table by mmap (zero-copy). Returns
/// null (after printing guidance) when no index has been built yet — the one
/// expected miss. Paths are NUL-separated in doc-id order; the list is pre-sized
/// from the NUL count so the split is one allocation.
pub fn load(gpa: std.mem.Allocator, io: std.Io) !?Persisted {
    return loadAt(gpa, io, corpus_mod.out_dir, true);
}

/// `load`, but SILENT on a miss (no "run `gist index`" guidance). The bare
/// `gist <pattern>` front door probes for an index on every invocation to
/// accelerate its live walk (skip reading provable-non-candidate files —
/// `commands/ripgrep/run.zig`), and outside an indexed corpus that probe MUST
/// stay quiet: a missing index there is the normal case, not something to nag
/// about, and the walk falls back to reading every file exactly as before.
pub fn loadQuiet(gpa: std.mem.Allocator, io: std.Io) !?Persisted {
    return loadAt(gpa, io, corpus_mod.out_dir, false);
}

/// Doc→path table integrity: the index guarantees every candidate id < doc_count,
/// but that only prevents an out-of-bounds path lookup if the table holds EXACTLY
/// doc_count entries. Called by the loader; exposed for tests.
pub const PairError = error{ PathTableMismatch, GenerationMismatch };
pub fn validatePersistedPair(doc_count: u32, paths: []const []const u8) PairError!void {
    if (paths.len != doc_count) return PairError.PathTableMismatch;
}

pub fn validateGeneration(observed: []const u8, published: []const u8) PairError!void {
    if (!std.mem.eql(u8, observed, published)) return PairError.GenerationMismatch;
}

/// Split the mmap'd `paths.list` (NUL-separated, doc-id order) into borrowed
/// slices, dropping empties (a trailing NUL, or a coalesced double-NUL). The
/// slices alias `pmap`, which must outlive the returned list. Factored out of
/// `loadAt` so both the split and the count invariant above are unit-testable
/// without touching the filesystem.
pub fn parsePathTable(gpa: std.mem.Allocator, pmap: []const u8) !std.ArrayList([]const u8) {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(gpa);
    try paths.ensureTotalCapacity(gpa, std.mem.count(u8, pmap, &[_]u8{0}) + 1);
    var pit = std.mem.splitScalar(u8, pmap, 0);
    while (pit.next()) |p| if (p.len > 0) paths.appendAssumeCapacity(p);
    return paths;
}

fn join2(buf: []u8, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ a, b });
}

fn join3(buf: []u8, a: []const u8, b: []const u8, c: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ a, b, c });
}

fn join4(buf: []u8, a: []const u8, b: []const u8, c: []const u8, d: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}/{s}", .{ a, b, c, d });
}

fn readGenerationFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const buf = Dir.cwd().readFileAlloc(io, path, gpa, .limited(128)) catch return null;
    errdefer gpa.free(buf);
    const trimmed = std.mem.trimEnd(u8, buf, "\r\n");
    if (trimmed.len == 0) {
        gpa.free(buf);
        return null;
    }
    if (trimmed.len == buf.len) return buf;
    const out = try gpa.dupe(u8, trimmed);
    gpa.free(buf);
    return out;
}

fn loadMappedPair(
    gpa: std.mem.Allocator,
    io: std.Io,
    index_path: []const u8,
    paths_path: []const u8,
    comptime verbose: bool,
) !?Persisted {
    const imap = mmapFile(io, index_path) catch {
        if (verbose) std.debug.print("no index at {s} — run `gist index` first\n", .{index_path});
        return null;
    };
    errdefer std.posix.munmap(imap);
    var idx = try Index.fromTrustedMappedBytes(imap);
    errdefer idx.deinit();

    const pmap = mmapFile(io, paths_path) catch {
        if (verbose) std.debug.print("incomplete index — {s} missing; run `gist index` to rebuild\n", .{paths_path});
        std.posix.munmap(imap);
        return null;
    };
    errdefer std.posix.munmap(pmap);
    var paths = try parsePathTable(gpa, pmap);
    errdefer paths.deinit(gpa);
    validatePersistedPair(idx.doc_count, paths.items) catch {
        if (verbose) std.debug.print("index/paths mismatch ({d} paths != {d} docs) — run `gist index` to rebuild\n", .{ paths.items.len, idx.doc_count });
        paths.deinit(gpa);
        std.posix.munmap(pmap);
        std.posix.munmap(imap);
        return null;
    };
    return .{ .imap = imap, .pmap = pmap, .idx = idx, .paths = paths, .gpa = gpa };
}

/// Load from an arbitrary cache root (production uses `corpus.out_dir`; tests
/// inject a tempdir). When `pair.gen` is present, both blobs must come from
/// `gens/<id>/` and the generation must still match after the maps succeed.
pub fn loadAt(gpa: std.mem.Allocator, io: std.Io, out_dir: []const u8, comptime verbose: bool) !?Persisted {
    var gen_path_buf: [512]u8 = undefined;
    const gen_path = try join2(&gen_path_buf, out_dir, "pair.gen");
    if (try readGenerationFile(gpa, io, gen_path)) |gen| {
        defer gpa.free(gen);
        var index_buf: [512]u8 = undefined;
        var paths_buf: [512]u8 = undefined;
        const index_path = try join4(&index_buf, out_dir, gens_subdir, gen, "index.gist");
        const paths_path = try join4(&paths_buf, out_dir, gens_subdir, gen, "paths.list");
        const loaded = try loadMappedPair(gpa, io, index_path, paths_path, verbose) orelse return null;
        // Seqlock-style recheck: a concurrent publisher may have advanced
        // pair.gen after we started mapping. Reject rather than mix gens.
        const gen_after = try readGenerationFile(gpa, io, gen_path) orelse {
            var tmp = loaded;
            tmp.deinit();
            if (verbose) std.debug.print("index generation retracted mid-load — run `gist index` to rebuild\n", .{});
            return null;
        };
        defer gpa.free(gen_after);
        validateGeneration(gen, gen_after) catch {
            var tmp = loaded;
            tmp.deinit();
            if (verbose) std.debug.print("index generation changed mid-load — run `gist index` to rebuild\n", .{});
            return null;
        };
        return loaded;
    }

    // Legacy caches (pre-generation publish): stable paths only.
    var index_buf: [512]u8 = undefined;
    var paths_buf: [512]u8 = undefined;
    const index_path = try join2(&index_buf, out_dir, "index.gist");
    const paths_path = try join2(&paths_buf, out_dir, "paths.list");
    return loadMappedPair(gpa, io, index_path, paths_path, verbose);
}

/// Serialize + generation-publish the index/path pair under `out_dir`.
/// Returns the posting-blob byte length.
pub fn persistIndexAndPathsAt(
    gpa: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    idx: *const Index,
    paths: []const []const u8,
) !usize {
    try Dir.cwd().createDirPath(io, out_dir);

    var gen_buf: [32]u8 = undefined;
    const gen = try std.fmt.bufPrint(&gen_buf, "{x}", .{@as(u64, @truncate(@as(u128, @intCast(std.Io.Clock.now(.real, io).nanoseconds))))});

    var gen_dir_buf: [512]u8 = undefined;
    const gen_dir = try join3(&gen_dir_buf, out_dir, gens_subdir, gen);
    try Dir.cwd().createDirPath(io, gen_dir);

    const blob = try gpa.alloc(u8, idx.serializedSize());
    defer gpa.free(blob);
    _ = idx.writeInto(blob);

    var pl: std.ArrayList(u8) = .empty;
    defer pl.deinit(gpa);
    for (paths) |p| {
        try pl.appendSlice(gpa, p);
        try pl.append(gpa, 0);
    }

    var index_buf: [512]u8 = undefined;
    var paths_buf: [512]u8 = undefined;
    const gen_index = try join2(&index_buf, gen_dir, "index.gist");
    const gen_paths = try join2(&paths_buf, gen_dir, "paths.list");
    // Stage both blobs under the unpublished generation directory first.
    try writeAtomic(io, gen_index, blob);
    try writeAtomic(io, gen_paths, pl.items);

    // Single atomic publish of the pair.
    var gen_path_buf: [512]u8 = undefined;
    const gen_path = try join2(&gen_path_buf, out_dir, "pair.gen");
    try writeAtomic(io, gen_path, gen);

    // Stable aliases for status / bench tooling (after publish; load prefers gens/).
    var stable_index_buf: [512]u8 = undefined;
    var stable_paths_buf: [512]u8 = undefined;
    const stable_index = try join2(&stable_index_buf, out_dir, "index.gist");
    const stable_paths = try join2(&stable_paths_buf, out_dir, "paths.list");
    try writeAtomic(io, stable_index, blob);
    try writeAtomic(io, stable_paths, pl.items);

    return blob.len;
}

pub fn persistIndexAndPaths(
    gpa: std.mem.Allocator,
    io: std.Io,
    idx: *const Index,
    paths: []const []const u8,
) !usize {
    return persistIndexAndPathsAt(gpa, io, corpus_mod.out_dir, idx, paths);
}

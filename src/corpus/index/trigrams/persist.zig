//! gist — the persisted-index loader, shared by every cold-query path.
//!
//! `cli/gist/lifecycle/index.zig`'s `run` (the `gist index` verb) serializes the trigram
//! `Index` + the doc→path table to disk; each later fresh process maps them back
//! **zero-copy** and validates only the compact directory up front. Posting
//! groups are checked when queried, avoiding a full body decode on every fresh
//! process. That cold-load path is shared by every shape the unified engine
//! serves — the index-accelerated read-elision walk (`runtime/cold/engine/serial.zig`)
//! and the `--rank` ranked view (`runtime/cold/engine/ranked.zig`) — so it lives
//! here, in the index layer, rather than in a command (a command importing
//! another command's internals is the coupling this split exists to kill).
//!
//! Publish is generation-atomic: both blobs land under `gens/<id>/` first, then
//! a single `pair.gen` rename publishes the pair. Readers bind to that id and
//! re-check it after mapping, so they never observe new `index.gist` with old
//! `paths.list` (or the reverse).

const std = @import("std");
const Index = @import("trigram.zig").Index;
const corpus_mod = @import("../../tree/corpus.zig");
const crest = @import("../../../kernel/primitives/crest.zig");
const crest_sidecar = @import("../crest/sidecar.zig");
const frame = @import("../frame/frame.zig");
const Dir = std.Io.Dir;

/// Stable aliases (status / bench size accounting). The query loader prefers the
/// generation published by `pair.gen` when present.
const index_alias = corpus_mod.ArtifactPath("index.gist");
const paths_alias = corpus_mod.ArtifactPath("paths.list");
const generation_alias = corpus_mod.ArtifactPath("pair.gen");
pub fn indexFile() []const u8 {
    return index_alias.get();
}
pub fn pathsFile() []const u8 {
    return paths_alias.get();
}
pub fn generationFile() []const u8 {
    return generation_alias.get();
}

/// Published `pair.gen` contents (gpa-owned; "" when absent). A rebuilt index
/// changes this — both resident sessions probe it to decide `maybeReload`.
pub fn readPublishedGeneration(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const buf = Dir.cwd().readFileAlloc(io, generationFile(), gpa, .limited(128)) catch
        return gpa.alloc(u8, 0);
    const trimmed = std.mem.trimEnd(u8, buf, "\r\n");
    if (trimmed.len == buf.len) return buf;
    defer gpa.free(buf);
    return gpa.dupe(u8, trimmed);
}

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
    /// The crest-sieve sidecar (`index/crest/sidecar.zig`), mapped zero-copy —
    /// null for a legacy cache or any blob `decode` rejects. Purely additive:
    /// queries without it just lose the sieve, never correctness.
    cmap: ?Mapping = null,
    crest: ?[]const crest.Vector = null,
    paths: std.ArrayList([]const u8),
    /// Heap copy of `roots.list` — null for a legacy pre-roots cache.
    roots_blob: ?[]u8,
    /// The roots this index was BUILT over (NUL-separated in `roots_blob`,
    /// or `.` for a legacy cache — the sound superset). Query paths fold
    /// freshness over these, never a re-derived guess.
    roots: std.ArrayList([]const u8),
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Persisted) void {
        self.roots.deinit(self.gpa);
        if (self.roots_blob) |b| self.gpa.free(b);
        self.paths.deinit(self.gpa);
        self.idx.deinit(); // borrowed ⇒ frees nothing
        if (self.cmap) |m| std.posix.munmap(m);
        std.posix.munmap(self.pmap);
        std.posix.munmap(self.imap);
    }
};

/// Cold-load the persisted index + doc→path table by mmap (zero-copy). Returns
/// null (after printing guidance) when no index has been built yet — the one
/// expected miss. Paths are NUL-separated in doc-id order; the list is pre-sized
/// from the NUL count so the split is one allocation.
pub fn load(gpa: std.mem.Allocator, io: std.Io) !?Persisted {
    return loadAt(gpa, io, corpus_mod.outDir(), true);
}

/// `load`, but SILENT on a miss (no "run `gist index`" guidance). The bare
/// `gist <pattern>` front door probes for an index on every invocation to
/// accelerate its live walk (skip reading provable-non-candidate files —
/// `runtime/cold/engine/serial.zig`), and outside an indexed corpus that probe MUST
/// stay quiet: a missing index there is the normal case, not something to nag
/// about, and the walk falls back to reading every file exactly as before.
pub fn loadQuiet(gpa: std.mem.Allocator, io: std.Io) !?Persisted {
    return loadAt(gpa, io, corpus_mod.outDir(), false);
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

fn joinPath(buf: []u8, parts: anytype) ![]u8 {
    comptime var fmt: []const u8 = "{s}";
    inline for (1..parts.len) |_| fmt = fmt ++ "/{s}";
    return std.fmt.bufPrint(buf, fmt, parts);
}

/// The four per-pair blob paths (index / paths / roots / crest sidecar) under
/// one directory, formatted into caller-lifetime buffers.
const PairFiles = struct {
    bufs: [4][512]u8 = undefined,
    index: []const u8 = undefined,
    paths: []const u8 = undefined,
    roots: []const u8 = undefined,
    crest: []const u8 = undefined,

    fn init(self: *PairFiles, dir: []const u8) !void {
        self.index = try joinPath(&self.bufs[0], .{ dir, "index.gist" });
        self.paths = try joinPath(&self.bufs[1], .{ dir, "paths.list" });
        self.roots = try joinPath(&self.bufs[2], .{ dir, "roots.list" });
        self.crest = try joinPath(&self.bufs[3], .{ dir, crest_sidecar.file_name });
    }
};

fn readGenerationFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const buf = Dir.cwd().readFileAlloc(io, path, gpa, .limited(128)) catch return null;
    const trimmed = std.mem.trimEnd(u8, buf, "\r\n");
    if (trimmed.len == buf.len and buf.len > 0) return buf;
    defer gpa.free(buf);
    return if (trimmed.len == 0) null else try gpa.dupe(u8, trimmed);
}

fn loadMappedPair(gpa: std.mem.Allocator, io: std.Io, pf: *const PairFiles, comptime verbose: bool) !?Persisted {
    const imap = mmapFile(io, pf.index) catch {
        if (verbose) std.debug.print("no index at {s} — run `gist index` first\n", .{pf.index});
        return null;
    };
    errdefer std.posix.munmap(imap);
    var idx = try Index.fromTrustedMappedBytes(imap);
    errdefer idx.deinit();

    const pmap = mmapFile(io, pf.paths) catch {
        if (verbose) std.debug.print("incomplete index — {s} missing; run `gist index` to rebuild\n", .{pf.paths});
        std.posix.munmap(imap);
        return null;
    };
    errdefer std.posix.munmap(pmap);
    var paths = try frame.parsePathTable(gpa, pmap);
    errdefer paths.deinit(gpa);
    validatePersistedPair(idx.doc_count, paths.items) catch {
        if (verbose) std.debug.print("index/paths mismatch ({d} paths != {d} docs) — run `gist index` to rebuild\n", .{ paths.items.len, idx.doc_count });
        paths.deinit(gpa);
        std.posix.munmap(pmap);
        std.posix.munmap(imap);
        return null;
    };

    // Build roots (NUL-separated, tiny). A legacy cache predates roots.list
    // (and an empty file is corruption); either way fall back to `.` — the
    // whole tree is a sound superset of whatever the index was built over
    // (elision keys on the persisted path set, never on roots; a wider
    // freshness walk only re-reads more, it never wrongly skips).
    var roots_blob: ?[]u8 = Dir.cwd().readFileAlloc(io, pf.roots, gpa, .limited(1 << 16)) catch null;
    errdefer if (roots_blob) |b| gpa.free(b);
    var roots = if (roots_blob) |b| try frame.parsePathTable(gpa, b) else std.ArrayList([]const u8).empty;
    errdefer roots.deinit(gpa);
    if (roots.items.len == 0) {
        if (roots_blob) |b| gpa.free(b);
        roots_blob = null;
        roots.clearRetainingCapacity();
        try roots.append(gpa, ".");
    }

    // Crest sidecar: optional, fail-closed. A miss or a rejected blob costs
    // only the sieve (the query still answers exactly), so both read as null.
    var cmap: ?Mapping = mmapFile(io, pf.crest) catch null;
    const crest_view: ?[]const crest.Vector = if (cmap) |m| crest_sidecar.decode(m, idx.doc_count) else null;
    if (cmap != null and crest_view == null) {
        std.posix.munmap(cmap.?);
        cmap = null;
    }
    return .{ .imap = imap, .pmap = pmap, .idx = idx, .cmap = cmap, .crest = crest_view, .paths = paths, .roots_blob = roots_blob, .roots = roots, .gpa = gpa };
}

/// Load from an arbitrary cache root (production uses `corpus.outDir()`; tests
/// inject a tempdir). When `pair.gen` is present, both blobs must come from
/// `gens/<id>/` and the generation must still match after the maps succeed.
pub fn loadAt(gpa: std.mem.Allocator, io: std.Io, out_dir: []const u8, comptime verbose: bool) !?Persisted {
    var gen_path_buf: [512]u8 = undefined;
    const gen_path = try joinPath(&gen_path_buf, .{ out_dir, "pair.gen" });
    if (try readGenerationFile(gpa, io, gen_path)) |gen| {
        defer gpa.free(gen);
        var gen_dir_buf: [512]u8 = undefined;
        var pf: PairFiles = .{};
        try pf.init(try joinPath(&gen_dir_buf, .{ out_dir, gens_subdir, gen }));
        const loaded = try loadMappedPair(gpa, io, &pf, verbose) orelse return null;
        // Seqlock-style recheck: a concurrent publisher may have advanced
        // pair.gen after we started mapping. Reject rather than mix gens.
        const gen_after = try readGenerationFile(gpa, io, gen_path);
        defer if (gen_after) |g| gpa.free(g);
        if (gen_after == null or !std.mem.eql(u8, gen, gen_after.?)) {
            var tmp = loaded;
            tmp.deinit();
            const what: []const u8 = if (gen_after == null) "retracted" else "changed";
            if (verbose) std.debug.print("index generation {s} mid-load — run `gist index` to rebuild\n", .{what});
            return null;
        }
        return loaded;
    }

    // Legacy caches (pre-generation publish): stable paths only.
    var pf: PairFiles = .{};
    try pf.init(out_dir);
    return loadMappedPair(gpa, io, &pf, verbose);
}

/// Serialize + generation-publish the index/path/roots triple (plus the crest
/// sidecar when the builder computed one) under `out_dir`. Returns the
/// posting-blob byte length.
pub fn persistIndexAndPathsAt(
    gpa: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    idx: *const Index,
    paths: []const []const u8,
    roots: []const []const u8,
    crest_vectors: ?[]const crest.Vector,
) !usize {
    try Dir.cwd().createDirPath(io, out_dir);

    var gen_buf: [32]u8 = undefined;
    const gen = try std.fmt.bufPrint(&gen_buf, "{x}", .{@as(u64, @truncate(@as(u128, @intCast(std.Io.Clock.now(.real, io).nanoseconds))))});

    var gen_dir_buf: [512]u8 = undefined;
    const gen_dir = try joinPath(&gen_dir_buf, .{ out_dir, gens_subdir, gen });
    try Dir.cwd().createDirPath(io, gen_dir);

    const blob = try gpa.alloc(u8, idx.serializedSize());
    defer gpa.free(blob);
    _ = idx.writeInto(blob);

    var pl: std.ArrayList(u8) = .empty;
    defer pl.deinit(gpa);
    try frame.joinNul(gpa, &pl, paths);

    var rl: std.ArrayList(u8) = .empty;
    defer rl.deinit(gpa);
    try frame.joinNul(gpa, &rl, roots);

    // Crest sidecar bytes (empty when the builder skipped the pass).
    const cblob: []u8 = if (crest_vectors) |cv| blk: {
        const b = try gpa.alloc(u8, crest_sidecar.encodedSize(cv.len));
        _ = crest_sidecar.writeInto(cv, b);
        break :blk b;
    } else &.{};
    defer if (cblob.len > 0) gpa.free(cblob);

    // Stage all blobs under the unpublished generation directory first.
    try writePairBlobs(io, gen_dir, blob, pl.items, rl.items, cblob);

    // Single atomic publish of the pair.
    var gen_path_buf: [512]u8 = undefined;
    const gen_path = try joinPath(&gen_path_buf, .{ out_dir, "pair.gen" });
    try writeAtomic(io, gen_path, gen);

    // Stable aliases for status / bench tooling (after publish; load prefers gens/).
    try writePairBlobs(io, out_dir, blob, pl.items, rl.items, cblob);

    return blob.len;
}

/// Atomically write the index/paths/roots blobs (plus the crest sidecar when
/// non-empty) under `dir`.
fn writePairBlobs(io: std.Io, dir: []const u8, blob: []const u8, pl: []const u8, rl: []const u8, cblob: []const u8) !void {
    var pf: PairFiles = .{};
    try pf.init(dir);
    try writeAtomic(io, pf.index, blob);
    try writeAtomic(io, pf.paths, pl);
    try writeAtomic(io, pf.roots, rl);
    if (cblob.len > 0) try writeAtomic(io, pf.crest, cblob);
}

pub fn persistIndexAndPaths(
    gpa: std.mem.Allocator,
    io: std.Io,
    idx: *const Index,
    paths: []const []const u8,
    roots: []const []const u8,
    crest_vectors: ?[]const crest.Vector,
) !usize {
    return persistIndexAndPathsAt(gpa, io, corpus_mod.outDir(), idx, paths, roots, crest_vectors);
}

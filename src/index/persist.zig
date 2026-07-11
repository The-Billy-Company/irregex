//! gist — the persisted-index loader, shared by every cold-query path.
//!
//! `ripgrep/index.zig`'s `run` (the `gist index` verb) serializes the trigram
//! `Index` + the doc→path table to disk; each later fresh process maps them back
//! **zero-copy** and resolves candidates in RAM. That mmap-load is the
//! cold-query win (map ~0.4 ms vs a full read+alloc+memcpy of the 100+ MiB
//! table), and it is needed identically by every shape the unified engine
//! serves — the index-accelerated read-elision walk (`commands/ripgrep/run.zig`)
//! and the `--rank` ranked view (`commands/ripgrep/rank.zig`) — so it lives
//! here, in the index layer, rather than in a command (a command importing
//! another command's internals is the coupling this split exists to kill).

const std = @import("std");
const Index = @import("trigram.zig").Index;
const corpus_mod = @import("../corpus/corpus.zig");
const Dir = std.Io.Dir;

/// The on-disk artifacts `runIndex` writes and every query maps back.
pub const index_file = corpus_mod.out_dir ++ "/index.gist";
pub const paths_file = corpus_mod.out_dir ++ "/paths.list";

/// A read-only, page-aligned file mapping (zero-copy view of the bytes on disk).
pub const Mapping = []align(std.heap.page_size_min) const u8;

/// mmap a whole file read-only. The mapping survives the fd close (POSIX), and
/// the OS faults in only the pages actually touched — so "loading" a 100+ MiB
/// index is O(header) instead of a full read-into-heap + alloc + memcpy. This
/// is the cold-load win: the binary search probes a handful of pages (warm in
/// the page cache), not the whole table. A genuinely empty file is rejected
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

/// Serialize `idx` + its doc→path `paths` table to the two on-disk artifacts,
/// each via the atomic temp-then-rename above so a concurrent reader never sees
/// a torn pair. Returns the index blob size (for the caller's report). Does NOT
/// write the freshness anchor — that lives in `corpus/fresh.zig`, which imports
/// this module, so the caller stamps the anchor itself (`fresh.writeAnchor`)
/// after this returns. Shared by the full build (`commands/ripgrep/index.zig`)
/// and the incremental graft (`commands/ripgrep/graft.zig`) so both emit the
/// byte-identical artifact pair through one code path.
pub fn persistIndexAndPaths(gpa: std.mem.Allocator, io: std.Io, idx: *const Index, paths: []const []const u8) !usize {
    try Dir.cwd().createDirPath(io, corpus_mod.out_dir);
    const blob = try gpa.alloc(u8, idx.serializedSize());
    defer gpa.free(blob);
    _ = idx.writeInto(blob);
    try writeAtomic(io, index_file, blob);

    var pl: std.ArrayList(u8) = .empty;
    defer pl.deinit(gpa);
    for (paths) |p| {
        try pl.appendSlice(gpa, p);
        try pl.append(gpa, 0); // NUL-separated, doc-id order (`parsePathTable` splits on it)
    }
    try writeAtomic(io, paths_file, pl.items);
    return blob.len;
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
    return loadImpl(gpa, io, true);
}

/// `load`, but SILENT on a miss (no "run `gist index`" guidance). The bare
/// `gist <pattern>` front door probes for an index on every invocation to
/// accelerate its live walk (skip reading provable-non-candidate files —
/// `commands/ripgrep/run.zig`), and outside an indexed corpus that probe MUST
/// stay quiet: a missing index there is the normal case, not something to nag
/// about, and the walk falls back to reading every file exactly as before.
pub fn loadQuiet(gpa: std.mem.Allocator, io: std.Io) !?Persisted {
    return loadImpl(gpa, io, false);
}

/// Doc→path table integrity: the index guarantees every candidate id < doc_count,
/// but that only prevents an out-of-bounds path lookup if the table holds EXACTLY
/// doc_count entries. Called by the loader; exposed for tests.
pub const PairError = error{PathTableMismatch};
pub fn validatePersistedPair(doc_count: u32, paths: []const []const u8) PairError!void {
    if (paths.len != doc_count) return PairError.PathTableMismatch;
}

/// Split the mmap'd `paths.list` (NUL-separated, doc-id order) into borrowed
/// slices, dropping empties (a trailing NUL, or a coalesced double-NUL). The
/// slices alias `pmap`, which must outlive the returned list. Factored out of
/// `loadImpl` so both the split and the count invariant above are unit-testable
/// without touching the filesystem.
pub fn parsePathTable(gpa: std.mem.Allocator, pmap: []const u8) !std.ArrayList([]const u8) {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(gpa);
    try paths.ensureTotalCapacity(gpa, std.mem.count(u8, pmap, &[_]u8{0}) + 1);
    var pit = std.mem.splitScalar(u8, pmap, 0);
    while (pit.next()) |p| if (p.len > 0) paths.appendAssumeCapacity(p);
    return paths;
}

fn loadImpl(gpa: std.mem.Allocator, io: std.Io, comptime verbose: bool) !?Persisted {
    const imap = mmapFile(io, index_file) catch {
        if (verbose) std.debug.print("no index at {s} — run `gist index` first\n", .{index_file});
        return null;
    };
    errdefer std.posix.munmap(imap);
    var idx = try Index.fromMappedBytes(imap);
    errdefer idx.deinit();

    // The doc→path table is the second half of the same artifact pair; a missing
    // (or half-written) one is the same "no usable index" miss as above, not a
    // crash. `errdefer` won't fire on `return null`, so unmap `imap` by hand.
    const pmap = mmapFile(io, paths_file) catch {
        if (verbose) std.debug.print("incomplete index — {s} missing; run `gist index` to rebuild\n", .{paths_file});
        std.posix.munmap(imap);
        return null;
    };
    errdefer std.posix.munmap(pmap);
    var paths = try parsePathTable(gpa, pmap);
    errdefer paths.deinit(gpa);
    // The index bounds every candidate doc id < doc_count; that only protects the
    // path lookup if the table holds exactly doc_count entries. A mismatch (a torn
    // or stale paths.list) is treated as a no-usable-index miss — fall back to the
    // full walk rather than risk indexing past `paths.items`.
    validatePersistedPair(idx.doc_count, paths.items) catch {
        if (verbose) std.debug.print("index/paths mismatch ({d} paths != {d} docs) — run `gist index` to rebuild\n", .{ paths.items.len, idx.doc_count });
        paths.deinit(gpa);
        std.posix.munmap(pmap);
        std.posix.munmap(imap);
        return null;
    };
    return .{ .imap = imap, .pmap = pmap, .idx = idx, .paths = paths, .gpa = gpa };
}

//! gist `index` — build + persist the trigram index and freshness anchor.
//!
//! The one mutating lifecycle action behind the `gist index` verb. It scans the
//! corpus (every non-binary file under `corpus.default_roots`), builds the
//! trigram `Index`, and atomically persists it plus the doc→path table and the
//! freshness anchor (`corpus/fresh.zig`) that later queries map back zero-copy.
//! The persisted index is what the unified engine's read-elision path
//! (`run.zig` `IndexSkip`) and the ranked view (`rank.zig`) consume — building
//! it lives here, beside them, now that the engines have merged (hoisted out of
//! the former `commands/search/drivers.zig` when that module was deleted).

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");
const fresh = @import("../../corpus/fresh.zig");
const persist = @import("../../index/persist.zig");
const Index = @import("../../index/trigram.zig").Index;
const Dir = std.Io.Dir;

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}
fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// Build once, persist the index + the doc→path table (NUL-separated, doc-id
/// order) so a later fresh process can map candidate ids back to files.
pub fn run(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !void {
    const t0 = nowNs(io);
    // Wall-clock anchor captured BEFORE the read, so any file touched during the
    // build (after its own read) is mtime ≥ anchor ⇒ re-verified next query.
    const built_ns = std.Io.Clock.now(.real, io).nanoseconds;
    var corpus = try corpus_mod.load(gpa, io, roots);
    defer corpus.deinit();
    var idx = try Index.build(gpa, corpus.docs);
    defer idx.deinit();

    try Dir.cwd().createDirPath(io, corpus_mod.out_dir);
    const blob = try gpa.alloc(u8, idx.serializedSize());
    defer gpa.free(blob);
    _ = idx.writeInto(blob);
    // Atomic (temp-then-rename) writes: a concurrent `gist` query in another
    // coworking agent's process may be `mmapFile`-ing these exact paths right
    // now, and a plain truncate+write would let it observe a torn file (see
    // `persist.writeAtomic`).
    try persist.writeAtomic(io, persist.index_file, blob);

    var pl: std.ArrayList(u8) = .empty;
    defer pl.deinit(gpa);
    for (corpus.paths) |p| {
        try pl.appendSlice(gpa, p);
        try pl.append(gpa, 0);
    }
    try persist.writeAtomic(io, persist.paths_file, pl.items);
    try fresh.writeAnchor(io, built_ns); // T3 freshness anchor

    std.debug.print("indexed {d} files · {d:.1} MiB corpus · {d:.1} MiB index · {d:.0} ms → {s}\n", .{
        corpus.docs.len,
        @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20),
        @as(f64, @floatFromInt(blob.len)) / (1 << 20),
        ms(nowNs(io) - t0),
        corpus_mod.out_dir,
    });
}

//! gist status — read-only introspection of the persisted index.
//!
//! The question this answers, that no search verb should have to: *am I ready to
//! search fast, and how fresh is what I'd search?* Before an agent commits to a
//! query it can ask `gist status` and learn whether an index exists, how much it
//! covers (files, distinct trigrams, postings), what it costs on disk, how long
//! ago it was built (vs the freshness anchor the cold path reads), and which
//! roots it spans — all without running a single trigram query or reading a
//! candidate file. A missing index is reported as an actionable state (run
//! `index`), never an error, so this is safe to call blind.
//!
//! Everything here is derived from the same two mmap'd artifacts the query path
//! loads (`persist.load`) plus the freshness anchor (`fresh.readAnchor`); it maps
//! them zero-copy, tallies, and unmaps — no build, no scan, no mutation.

const std = @import("std");
const persist = @import("../../index/persist.zig");
const fresh = @import("../../corpus/fresh.zig");
const corpus_mod = @import("../../corpus/corpus.zig");
const Dir = std.Io.Dir;

/// The on-disk byte size of `path`, or 0 if it can't be stat'd (treated as
/// absent — this is a report, never a hard failure).
fn fileSize(io: std.Io, path: []const u8) u64 {
    const st = Dir.cwd().statFile(io, path, .{}) catch return 0;
    return @intCast(st.size);
}

fn mib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1 << 20);
}

/// Print the index report to stdout (the user asked for it — data on stdout, per
/// the corpus emit convention). No index yet ⇒ the actionable "run index" line.
pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    var p = (try persist.load(gpa, io)) orelse return; // load prints the "no index" guidance
    defer p.deinit();

    const files = p.paths.items.len;
    const postings = p.idx.posting_count;
    const trigrams = p.idx.dir_tri.len;
    const idx_bytes = fileSize(io, persist.index_file);
    const paths_bytes = fileSize(io, persist.paths_file);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const avg_per_file: f64 = if (files == 0) 0 else @as(f64, @floatFromInt(postings)) / @as(f64, @floatFromInt(files));
    try buf.print(gpa,
        \\gist index — {s}
        \\  files indexed     {d}
        \\  distinct trigrams {d}
        \\  postings          {d}  ({d:.0} trigram·doc pairs per file)
        \\  on disk           {d:.1} MiB index + {d:.1} MiB paths
        \\
    , .{
        persist.index_file,
        files,
        trigrams,
        postings,
        avg_per_file,
        mib(idx_bytes),
        mib(paths_bytes),
    });

    // Build age vs the freshness anchor (the same wall-clock instant the cold
    // path reads to widen candidates). No anchor ⇒ a pre-T3 index; still valid,
    // just with no freshness overlay.
    if (fresh.readAnchor(gpa, io)) |built_ns| {
        const now_ns = std.Io.Clock.now(.real, io).nanoseconds;
        const age_s = @as(f64, @floatFromInt(now_ns - built_ns)) / 1e9;
        try buf.print(gpa, "  built            {d:.0} s ago (freshness anchor set — new/edited files are folded in per query)\n", .{age_s});
        // Drift: files touched since the build — the live-scan tax a stale index
        // pays per query. `index --auto` folds these in (byte-identically) so
        // subsequent queries stop re-walking them.
        const drift = fresh.driftCount(gpa, io, &corpus_mod.default_roots, built_ns) catch 0;
        if (drift == 0)
            try buf.appendSlice(gpa, "  drift            0 files — index is current\n")
        else
            try buf.print(gpa, "  drift            {d} files changed since build (folded live per query; `gist index --auto` to persist)\n", .{drift});
    } else {
        try buf.appendSlice(gpa, "  built            (no freshness anchor — rebuild with `index` to enable the freshness overlay)\n");
    }

    try buf.appendSlice(gpa, "  roots           ");
    for (corpus_mod.default_roots) |r| try buf.print(gpa, " {s}", .{r});
    try buf.append(gpa, '\n');

    corpus_mod.emitStdout(buf.items);
}

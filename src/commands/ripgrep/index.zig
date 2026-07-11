//! gist `index` — build + persist the trigram index and freshness anchor.
//!
//! The one mutating lifecycle action behind the `gist index` verb. Three modes:
//!
//!   * `.full`        — scan every file under the roots, build the trigram
//!                      `Index` from scratch, persist it + the doc→path table +
//!                      the freshness anchor (the original, always-correct path).
//!   * `.incremental` — graft only the *changed* files onto the existing index
//!                      (`graft.zig`); byte-identical result, a fraction of the
//!                      work. Falls back to `.full` when there's no prior index.
//!   * `.auto`        — drift-gated + single-flight: fold only if something
//!                      changed since the anchor, and only if no other agent is
//!                      already folding. The safe thing to fire from a hook at
//!                      the end of an operation across ~10 coworking agents.
//!
//! The persisted index is what the unified engine's read-elision path
//! (`run.zig` `IndexSkip`) and the ranked view (`rank.zig`) consume. Writes go
//! through `persist.persistIndexAndPaths` (atomic temp-then-rename) so a
//! concurrent query mmap'ing the same files never observes a torn pair; the
//! advisory lock here is a *cost* guard (don't fold twice), not a *correctness*
//! one (the atomic writes already own that).

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");
const fresh = @import("../../corpus/fresh.zig");
const persist = @import("../../index/persist.zig");
const graft = @import("graft.zig");
const Index = @import("../../index/trigram.zig").Index;
const Dir = std.Io.Dir;

/// How `gist index` should (re)build. Parsed from the CLI flag in `cli/main.zig`.
pub const Mode = enum { full, incremental, auto };

/// Advisory single-flight lock — coordinates the ~10 agents that may each fire
/// `index --auto` at once. Lives beside the artifacts it guards.
const lock_file = corpus_mod.out_dir ++ "/index.lock";

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}
fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
fn mib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1 << 20);
}

/// Full from-scratch build: read + extract every file, fold, persist. The
/// always-correct baseline the incremental graft is proven byte-identical to.
fn buildFull(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, t0: i128) !void {
    // Wall-clock anchor captured BEFORE the read, so any file touched during the
    // build (after its own read) is mtime ≥ anchor ⇒ re-verified next query.
    const built_ns = std.Io.Clock.now(.real, io).nanoseconds;
    var corpus = try corpus_mod.load(gpa, io, roots);
    defer corpus.deinit();
    var idx = try Index.build(gpa, corpus.docs);
    defer idx.deinit();
    const index_bytes = try persist.persistIndexAndPaths(gpa, io, &idx, corpus.paths);
    try fresh.writeAnchor(io, built_ns);

    std.debug.print("indexed {d} files · {d:.1} MiB corpus · {d:.1} MiB index · {d:.0} ms → {s}\n", .{
        corpus.docs.len,
        mib(corpus.bytes),
        mib(index_bytes),
        ms(nowNs(io) - t0),
        corpus_mod.out_dir,
    });
}

fn reportGraft(io: std.Io, t0: i128, st: graft.Stats) void {
    std.debug.print("grafted {d} files · {d} reused + {d} re-read ({d:.1} MiB) · {d:.1} MiB index · {d:.0} ms → {s}\n", .{
        st.docs,
        st.reused,
        st.read,
        mib(st.new_bytes),
        mib(@intCast(st.index_bytes)),
        ms(nowNs(io) - t0),
        corpus_mod.out_dir,
    });
}

/// Build (or refresh) the persisted index per `mode`. See the file header.
pub fn run(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, mode: Mode) !void {
    Dir.cwd().createDirPath(io, corpus_mod.out_dir) catch {};
    // Acquire the advisory lock atomically with the open (Darwin/BSD). `.auto`
    // is non-blocking — a busy lock means another agent is already folding this
    // drift, so we bow out with zero work. Explicit builds block until it's
    // theirs. A lock we simply can't take (unsupported fs) degrades to
    // best-effort lockless — the atomic writes still keep readers safe.
    const held: ?std.Io.File = blk: {
        const f = Dir.cwd().createFile(io, lock_file, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = (mode == .auto),
        }) catch |e| switch (e) {
            error.WouldBlock => return, // auto + busy: single-flight no-op
            else => break :blk null,
        };
        break :blk f;
    };
    defer if (held) |f| {
        f.unlock(io);
        f.close(io);
    };

    const t0 = nowNs(io);
    switch (mode) {
        .full => try buildFull(gpa, io, roots, t0),
        .incremental => if (try graft.tryFold(gpa, io, roots)) |st|
            reportGraft(io, t0, st)
        else
            try buildFull(gpa, io, roots, t0),
        .auto => {
            // Drift gate: only pay the fold when the tree actually moved since
            // the anchor. No anchor yet ⇒ first run ⇒ full build (bootstrap).
            const anchor = fresh.readAnchor(gpa, io) orelse {
                try buildFull(gpa, io, roots, t0);
                return;
            };
            const drift = fresh.driftCount(gpa, io, roots, anchor) catch 0;
            if (drift == 0) return; // nothing new; deletions are rare + harmless (verify gates)
            if (try graft.tryFold(gpa, io, roots)) |st|
                reportGraft(io, t0, st)
            else
                try buildFull(gpa, io, roots, t0);
        },
    }
}

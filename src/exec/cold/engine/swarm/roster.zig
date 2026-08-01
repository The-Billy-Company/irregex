//! gist — the fused walk as a CALLABLE file-set enumerator.
//!
//! Everything `swarm.run` does up to the fan-out and join, without the per-file
//! search, the streaming sink, or the `noreturn` exit tail: it runs the identical
//! ignore-certified walk in `--files` mode and RETURNS the admitted set instead
//! of racing it to stdout. Membership is live ground truth — the phantom
//! snapshot and content shard are never consulted, because a file created since
//! the last index build must still appear. That is exactly what the resident
//! daemon's freshness reconcile needs, and it is the only caller.

const std = @import("std");
const portal = @import("../../../../portal.zig");
const args = @import("../../argv/args.zig");
const assay = @import("../../../../assay/assay.zig");
const crew = @import("crew.zig");
const descent = @import("descent.zig");
const ignore = @import("../../../../corpus/tree/ignore.zig");
const paths_mod = @import("../../../../corpus/scope/paths.zig");
const queue = @import("queue.zig");
const serial = @import("../../quarry/walk.zig");
const sink_mod = @import("sink.zig");
const treemap = @import("../../../../corpus/index/phantom/treemap.zig");

const Cfg = crew.Cfg;
const Worker = crew.Worker;
const DirTask = queue.DirTask;
const Opts = args.Opts;
const Queue = queue.Queue;
const Sink = sink_mod.Sink;
const defaultWorkerCount = crew.defaultWorkerCount;
const oom = @import("../../../../surface/cli/outcome.zig").oom;
const rootDepth = paths_mod.rootDepth;
const workerMain = descent.workerMain;

/// One admitted file plus its walk-time freshness clocks (from the same
/// `getattrlistbulk` listing that enumerated it — never a separate stat). Null
/// clocks mean the listing couldn't supply them (a `getattrlistbulk`-unsupported
/// fallback); the caller then re-stats that one path.
pub const FileEntry = struct { path: []const u8, mtime_ns: ?i128, ctime_ns: ?i128 };

/// The admitted rg-default file set under `roots`, plus whether the walk hit an
/// unreadable directory. The `-t`/`-g` un-hide/un-ignore extras a serial
/// `defaultFileSetExtras` walk gathers are deliberately NOT collected: a
/// files-only parallel walk drops every rejected entry silently. The one caller
/// (the resident daemon's `reconcileFull`) defers them — it marks its extras
/// stale so the next `-t`/`-g` query refreshes on demand, the identical contract
/// the scoped reconcile path already uses.
pub const FileSet = struct { entries: []const FileEntry, walk_error: bool };

fn hasNonDirectoryRoot(io: std.Io, roots: []const []const u8) bool {
    for (roots) |root| {
        if (std.Io.Dir.cwd().openDir(io, root, .{})) |dir_const| {
            var dir = dir_const;
            dir.close(io);
        } else |_| return true;
    }
    return false;
}

/// The fused work-stealing walk as a CALLABLE — everything `run` does up to the
/// fan-out/join, WITHOUT the per-file search, the streaming sink, or the
/// `noreturn` exit tail. It runs the identical ignore-certified directory walk
/// `run` runs in `--files` mode (same `Ignore`/`Cfg`/`Worker`/`Queue`/
/// `processDir`/`handleEntry`, so admission is parity-identical to the serial
/// `defaultFileSet` by construction), but COLLECTS each admitted path into `a`
/// and RETURNS the set instead of racing it to stdout and exiting. Membership is
/// live ground truth: the phantom snapshot and content shard are never consulted
/// (a file created since the last index build must still appear), which is
/// exactly what the daemon's freshness reconcile needs. `roots` empty ⇒ the CWD
/// walked with rootless corpus keys. Caller owns `a`; every internal scratch
/// allocation is released before return.
///
/// Allocation failure RETURNS rather than exiting: the resident daemon calls
/// this from `irregex_search`'s reconcile, where `exit(2)` would kill the
/// embedding host instead of yielding `IRREGEX_OOM` (fault-channel law 1). Only this
/// enumerator's OWN allocations — the ones on the calling thread — are covered;
/// the shared per-worker descent (`descent.zig`) still exits, since an error
/// cannot cross the fan-out and its `catch oom()` sites sit in the per-entry
/// inner loop.
pub fn collectFileSet(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, a: std.mem.Allocator) std.mem.Allocator.Error!FileSet {
    // The fused queue carries directory tasks. Explicit file roots use the
    // authoritative serial selector so reconciliation does not mistake the
    // file for an unreadable directory and decline every warm query.
    if (roots.len != 0 and hasNonDirectoryRoot(io, roots)) {
        const files = try serial.defaultFileSetExtras(a, io, roots, null);
        const entries = try a.alloc(FileEntry, files.paths.len);
        for (files.paths, entries) |path, *entry|
            entry.* = .{ .path = path, .mtime_ns = null, .ctime_ns = null };
        return .{ .entries = entries, .walk_error = files.path_error };
    }

    // `files_list` gates only `files_mode`/worker topology; `ignore.Options.from`
    // reads none of it, so the admission layer is byte-identical to serial
    // `defaultFileSet`'s default `Opts{}`.
    const o: Opts = .{ .mode = .files };
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var ig = try ignore.Ignore.init(sa, io, ignore.Options.from(o), roots);
    const compiled = try ignore.Compiled.build(sa, &ig);
    var q: Queue = .{ .gpa = gpa, .io = io };
    defer q.items.deinit(gpa);
    // Never streamed to: files+`collect_sorted` route every path into the
    // worker's `recs` (see `bufferPath`), so the sink exists only to satisfy
    // `Cfg`. Its `heading`/`join_groups` are inert in files mode.
    var sink: Sink = .{ .q = &q, .io = io, .heading = false, .join_groups = false };
    const cfg: Cfg = .{
        .o = o,
        .re = null,
        .ig = &ig,
        .compiled = if (compiled) |*c| c else null,
        .lazy = null,
        .file_needle = null,
        .file_alts = &.{},
        .lits_equiv = false,
        .gate_len = 0,
        .line_needle = null,
        .fast_l = false,
        .use_color = false,
        .show_name = true,
        .heading = false,
        .join_groups = false,
        .binary_detect = false,
        .files_mode = true,
        .ingest = null,
        .snap = null, // live ground truth — no phantom membership
        .shard = null, // no bytes read in files mode
        .sink = &sink,
        .collect_sorted = true, // route `bufferPath` into each worker's `recs`
        .freshness_meta = true, // clock-bearing listing; carry mtime/ctime in `recs`
    };
    {
        const eff_roots: []const []const u8 = if (roots.len > 0) roots else &.{"."};
        var seed: std.ArrayList(DirTask) = .empty;
        defer seed.deinit(gpa);
        for (eff_roots) |r| {
            const prefix = if (std.mem.eql(u8, r, ".") and roots.len == 0) "" else std.mem.trimEnd(u8, r, "/");
            try seed.append(gpa, .{
                .disk = r,
                .rel = prefix,
                .scope = paths_mod.cwdRelative(sa, io, prefix),
                .depth = 0,
                .root_depth = rootDepth(prefix),
                .chain = null,
                .snap_ix = treemap.not_walked,
            });
        }
        q.push(seed.items);
    }
    const ncpu = portal.cpuCount() catch 6;
    var nworkers = defaultWorkerCount(ncpu, true);
    if (assay.knob("WORKERS")) |s| if (std.fmt.parseInt(usize, s, 10) catch null) |n| {
        nworkers = @max(1, n);
    };
    const workers = try gpa.alloc(Worker, nworkers);
    defer gpa.free(workers);
    // Fixed width, deliberately: this walk reads no file bytes (it collects the
    // daemon's path set), so it is the namei-bound traversal `defaultWorkerCount`
    // was tuned on — there is no I/O latency for extra hands to hide, and
    // `Worker.crew` stays null so nothing even looks.
    var pool: crew.Crew = .{ .workers = workers, .gpa = gpa, .io = io, .body = workerMain, .ceiling = nworkers };
    for (workers) |*w| w.* = .{ .q = &q, .io = io, .gpa = gpa, .cfg = &cfg, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer for (workers) |*w| {
        w.arena.deinit();
        w.out.deinit(gpa);
        w.recs.deinit(gpa);
    };
    try pool.muster(nworkers);

    // Each worker held its admitted paths in its own arena (torn down by the
    // defer above); dupe them into the caller's allocator before that fires.
    var total: usize = 0;
    for (workers) |*w| total += w.recs.items.len;
    const entries = try a.alloc(FileEntry, total);
    var k: usize = 0;
    for (workers) |*w| for (w.recs.items) |r| {
        entries[k] = .{ .path = try a.dupe(u8, r.path), .mtime_ns = r.mtime_ns, .ctime_ns = r.ctime_ns };
        k += 1;
    };
    return .{ .entries = entries, .walk_error = q.walk_error.load(.acquire) };
}

//! gist — the crew: run-wide immutable `Cfg`, per-worker mutable state, the
//! pool topology, and the ordered `--sort` replay over what the crew held back.
//!
//! `Cfg` is frozen before fan-out and shared by const pointer; everything a
//! worker mutates lives in its own `Worker` (arena, reusable match scratch,
//! coalesced path-list buffer, per-worker `--json`/`--stats` tallies). That
//! split is the whole thread-safety argument: no locks beyond the queue and the
//! sink, because there is nothing else two workers can both write.

const std = @import("std");
const builtin = @import("builtin");
const args = @import("../../argv/args.zig");
const elide = @import("../../quarry/elide.zig");
const grepfile = @import("../../read/grepfile.zig");
const ignore = @import("../../../../../corpus/tree/ignore.zig");
const ingest = @import("../../read/ingest.zig");
const json = @import("../../emit/json.zig");
const queue = @import("queue.zig");
const serial = @import("../serial.zig");
const shard_mod = @import("../../../../../corpus/index/content/shard.zig");
const simd = @import("../../../../../kernel/match/scan/simd.zig");
const sink_mod = @import("sink.zig");
const treemap = @import("../../../../../corpus/index/phantom/treemap.zig");

const FragKind = sink_mod.FragKind;
const Matcher = @import("../../../../../kernel/match/regex/linear/ladder/matcher.zig").Matcher;
const Opts = args.Opts;
const Queue = queue.Queue;
const Sink = sink_mod.Sink;
const oom = args.oom;

/// Run-wide immutable configuration every worker shares.
pub const Cfg = struct {
    o: Opts,
    re: ?*const Matcher, // null only in --files mode
    ig: *const ignore.Ignore,
    compiled: ?*const ignore.Compiled, // rank-based base tier (null → decideAt)
    lazy: ?*elide.Lazy, // concurrent elide loader (null → no elision this run)
    file_needle: ?simd.Gate, // whole-file SIMD gate; null for passthru / invert modes
    // Multi-literal whole-file SIMD gate for pure alternations (`panic|0x`):
    // the union of these literals covers every match, so a body containing none
    // of them is dropped without a regex run. Non-empty only when `file_needle`
    // is null (a single required literal is the stronger gate) and the mode may
    // drop whole files. Because the set is a match EQUIVALENCE (see
    // `Regex.lits`), the `-l` fast path may also EMIT on a gate hit alone.
    file_alts: []const []const u8,
    // The whole-file literal gate that ran (`file_needle` or `file_alts`) is a
    // match EQUIVALENCE (`Regex.lits`): a gate hit PROVES some line matches, so
    // the `-l` fast path may emit without any engine run at all.
    lits_equiv: bool,
    // Longest gate literal (`file_needle`/`file_alts`), or 0 when no gate runs.
    // Sizes the straddle window when a stage-1-cleared prefix lets the gate
    // rescan only the tail: a literal crossing the prefix/tail seam can start
    // at most `gate_len-1` bytes before the seam.
    gate_len: usize,
    line_needle: ?simd.Gate, // required literal before each regex engine run
    // `-l` fused fast path is sound for this invocation: no flag reshapes the
    // per-line match decision away from "does any line match?" — so one fused
    // whole-buffer `docMatch` (early-exit, no line split, no per-line dispatch)
    // answers the file.
    fast_l: bool,
    use_color: bool,
    show_name: bool,
    heading: bool,
    join_groups: bool,
    binary_detect: bool,
    files_mode: bool,
    // Non-null ⇒ a `-z`/`-E` run: each worker rewrites a file's bytes
    // (decompress/transcode) before matching. Immutable + shared; every
    // `ingest.apply` call is thread-confined to the calling worker's arena.
    ingest: ?*const ingest.Config,
    // The phantom `tree.map` snapshot (rootless whole-CWD walks only; null
    // otherwise). Membership-only: admission (ignore/hidden/glob) is always
    // decided live, and a never-descended or clock-stale directory falls back
    // to the ordinary live listing — see `corpus/index/phantom/treemap.zig`.
    snap: ?*const treemap.View,
    // The content shard (`content.shard`): concatenated corpus bodies mmap'd
    // once, so a file the walk would open is instead served from the mapping
    // when the T3 clock rule proves it unchanged. Null when disabled, absent,
    // or not worth loading (narrow scope, `--files`, a transform run). Membership
    // + freshness only — a miss or a changed file reads live, byte-identically.
    shard: ?*const shard_mod.View,
    sink: *Sink,
    // `--sort`/`--sortr path`: hold each rendered fragment in the worker's arena
    // keyed by path (`Worker.recs`) rather than streaming it, so `run` can order
    // the whole result once (`emitSorted`). False ⇒ the streaming sink path.
    collect_sorted: bool = false,
    // `collectFileSet` only: force the clock-bearing `listOneLevel` listing and
    // carry each admitted file's walk-time mtime/ctime into its `recs` entry, so
    // the resident daemon's `reconcileOne` reads freshness straight off the walk
    // instead of re-`statFile`ing every path from CWD. Inert for search runs.
    freshness_meta: bool = false,
};

/// One rendered file fragment held for the ordered `--sort`/`--sortr` emit. The
/// fused walk renders every file in parallel exactly as the streaming path does;
/// the only difference is the bytes stay in this worker's arena (which outlives
/// the walk) keyed by `path`, so `run` orders the whole result once. `buf` is the
/// rendered block for a content mode; in `-l`/`--files` mode `buf` is unused (the
/// path IS the output) and `kind` is immaterial — `emitSorted` writes path+term.
// `mtime_ns`/`ctime_ns` are populated only on the `collectFileSet` freshness
// path (`Cfg.freshness_meta`); every other producer leaves them null.
const SortedRec = struct { path: []const u8, kind: FragKind, buf: []const u8, mtime_ns: ?i128 = null, ctime_ns: ?i128 = null };

/// A file discovered before the elide oracle finished loading — held back so
/// it can still be elided (or searched) once `elide.Lazy.ready` flips.
const Deferred = struct {
    disk: []const u8,
    rel: []const u8,
    mtime_ns: ?i128,
    ctime_ns: ?i128,
};

pub const Worker = struct {
    q: *Queue,
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const Cfg,
    arena: std.heap.ArenaAllocator,
    pending: std.ArrayList(Deferred) = .empty,
    // Coalesced path-list output (`-l`/`--files`): a per-file lock+`write(2)`
    // under the shared sink mutex serialized every worker on a high-hit scan
    // (`\w{3,8} -l` matches ~every file — 20k locked syscalls), which capped
    // parallel scaling at ~1.4x. Batching each worker's paths into ~64 KiB
    // chunks (order-free by the files-list contract) makes the lock+syscall a
    // per-chunk cost. `out` is gpa-owned so it outlives per-file arena churn.
    out: std.ArrayList(u8) = .empty,
    out_files: usize = 0, // paths buffered in `out` since the last flush
    // `--sort`/`--sortr path` only (`Cfg.collect_sorted`): the worker's rendered
    // fragments held for the ordered final emit, keyed by path. Each `buf`/`path`
    // already lives in this worker's arena (no copy) — this list just references
    // them; `gpa`-owned so it survives per-file arena churn and `run` reads it
    // after join. Empty in the streaming (non-sorted) path.
    recs: std.ArrayList(SortedRec) = .empty,
    // Reusable boolean-match scratch (`Matcher.Sim` is per-thread by design):
    // lazily built once on first use, then reused for every file this worker
    // searches — the Pike generation counter self-invalidates between calls,
    // so no reset is needed and no per-file alloc/free is paid.
    sim: ?Matcher.Sim = null,
    // `--json` per-worker span scratch + running tally (both null/zero until the
    // first JSON file this worker renders). `run` sums every worker's `jstats`
    // for the single trailing `summary` record.
    jss: ?Matcher.SpanSim = null,
    jstats: json.Stats = .{},
    // `--stats` per-worker tally (`files_with_match` is filled once in `run`
    // from `sink.matched_files`; `bytes_printed` from `sink.bytes_printed`).
    // Summed across workers into the trailing stats block after the walk.
    stats: grepfile.Stats = .{},
    /// Flush a worker's coalesced path-list buffer once it reaches this size — big
    /// enough that the lock+`write(2)` amortizes over hundreds of paths, small
    /// enough to stream (and to keep the soft output budget's cut at a whole-line
    /// chunk boundary).
    const files_flush_cap: usize = 64 * 1024;

    /// Append one path-list record (`path` + its terminator) to the worker's
    /// private buffer, flushing in a single locked write once it fills. Replaces a
    /// per-file `Sink.emit` (lock + raw syscall) on the `-l`/`--files` hot paths.
    pub fn bufferPath(w: *Worker, path: []const u8, term: []const u8) void {
        if (w.cfg.collect_sorted) {
            // `--sort`/`--sortr`: hold the path for the ordered emit (`emitSorted`
            // rewrites the terminator in sorted order); `path` lives in the arena.
            w.recs.append(w.gpa, .{ .path = path, .kind = .text_hit, .buf = "" }) catch oom();
            return;
        }
        w.out.appendSlice(w.gpa, path) catch oom();
        w.out.appendSlice(w.gpa, term) catch oom();
        w.out_files += 1;
        if (w.out.items.len >= files_flush_cap) w.flushFiles();
    }

    /// Stream one rendered fragment to the sink, or — under `--sort`/`--sortr` —
    /// hold it in this worker's arena keyed by `dpath` for the ordered final emit.
    /// The rendered bytes already live in the worker arena (which outlives the
    /// walk), so holding a reference costs one record, never a copy.
    pub fn deliver(w: *Worker, kind: FragKind, dpath: []const u8, buf: []const u8) void {
        if (w.cfg.collect_sorted) {
            w.recs.append(w.gpa, .{ .path = dpath, .kind = kind, .buf = buf }) catch oom();
            return;
        }
        w.cfg.sink.emit(kind, buf);
    }

    /// Drain the worker's buffered path list into the sink as one chunk.
    pub fn flushFiles(w: *Worker) void {
        if (w.out_files == 0) return;
        w.cfg.sink.emitFilesChunk(w.out.items, w.out_files);
        w.out.clearRetainingCapacity();
        w.out_files = 0;
    }

    /// The worker's lazily-built reusable match scratch (null only on OOM, where
    /// the caller degrades to "no match proven" — never an invented match).
    pub fn matchSim(w: *Worker) ?*Matcher.Sim {
        if (w.sim == null) w.sim = Matcher.Sim.init(w.arena.allocator(), w.cfg.re.?) catch return null;
        return &w.sim.?;
    }

    /// The worker's lazily-built reusable span scratch for the `--json` encoder
    /// (`Matcher.SpanSim` is per-thread, mirroring `matchSim`).
    pub fn spanSim(w: *Worker) ?*Matcher.SpanSim {
        if (w.jss == null) w.jss = Matcher.SpanSim.init(w.arena.allocator(), w.cfg.re.?) catch return null;
        return &w.jss.?;
    }
};

/// Worker pool size for a plaintext walk. macOS serializes the walk in the
/// kernel — the `vm_map` fault lock on the mmap'd content shard and syspolicyd/
/// vnode locks on open+namei — so past a small pool more threads only add
/// contention (measured flat 6→16 on the shard path, and slower on the open
/// path); the tuned six-worker ceiling stays, halved further for traversal-only
/// / narrow / index-selective runs that do less work per file. Every other OS
/// has a scalable fault + open path — ripgrep saturates all logical CPUs there —
/// so the ceiling would just idle cores: scale to `ncpu`. `GIST_WORKERS` and
/// `-j` still override.
pub fn defaultWorkerCount(ncpu_raw: usize, selective: bool) usize {
    const ncpu = @max(1, ncpu_raw);
    if (builtin.os.tag != .macos) return ncpu;
    const full = @min(ncpu, 6);
    if (!selective or ncpu <= 4) return full;
    return @min(full, @max(4, (ncpu + 1) / 2));
}

/// Run a built pool to completion: a thread per worker after the first, the
/// caller's thread as worker 0, then join. Both walks (search and file-set) enter
/// here, so the pool's shape is written once.
///
/// A mid-spawn failure is not fatal and not retried — the walk simply proceeds at
/// the width the OS granted, down to one worker on the caller's thread. Work is
/// never lost by a thread that failed to start: the queue is work-stealing, so a
/// missing worker's tasks are taken by the ones that did start, and its per-worker
/// state stays empty and folds in as a no-op.
///
/// Deliberately not `kernel/primitives/parallel.zig::fanOut`: that combinator
/// runs its un-spawned tail inline *after* spawning and joins around it, which is
/// right for fixed shards. Here worker 0 must walk on the caller's thread
/// concurrently with the others — the caller's thread is a first-class worker for
/// the whole walk, not a fallback for a shard nobody took.
///
/// The thread array's allocation failure RETURNS: this sits on the calling
/// thread, so the daemon-facing `roster.collectFileSet` can honor its own
/// `Oom!` contract instead of taking the embedding host down with `exit(2)`
/// (ADR-373 law 1). The `noreturn` CLI path converts it back at its call site.
pub fn muster(gpa: std.mem.Allocator, workers: []Worker, comptime body: fn (*Worker) void) std.mem.Allocator.Error!void {
    const threads = try gpa.alloc(std.Thread, workers.len);
    defer gpa.free(threads);
    var spawned: usize = 0;
    for (workers[1..]) |*w| {
        threads[spawned] = std.Thread.spawn(.{}, body, .{w}) catch break;
        spawned += 1;
    }
    body(&workers[0]); // the caller's thread is a worker too
    for (threads[0..spawned]) |t| t.join();
}

// ─────────────────────────── sorted emit ───────────────────────────

/// `--sort`/`--sortr path` order over the collected fragments. Ascending is
/// `serial.pathLess` (rg's `Path::cmp`, `/` ranked below every byte); this
/// engine only takes ascending path for a single/implicit root, where rg's
/// per-argv-root walker order (`lessAscPathWalk`) collapses to exactly that.
/// Descending is the global mirror (`--sortr`'s `ordering.reverse()`), valid for
/// any root count — swapping the operands flips the tiebreak too.
fn recLess(reverse: bool, x: SortedRec, y: SortedRec) bool {
    return if (reverse) serial.pathLess(y.path, x.path) else serial.pathLess(x.path, y.path);
}

/// Gather every worker's held fragments, order them once, and replay them
/// through the SAME `Sink` the streaming path uses — so heading/context
/// separators (`emit`'s `first`/`join_groups` logic, now driven in sorted
/// order) and the `matched_files` exit-code tally stay byte-identical to the
/// serial sort oracle. `-l`/`--files` records carry only a path: rewrite the
/// terminator here and emit them as one coalesced chunk.
pub fn emitSorted(gpa: std.mem.Allocator, sink: *Sink, workers: []Worker, o: Opts) void {
    var total: usize = 0;
    for (workers) |*w| total += w.recs.items.len;
    if (total == 0) return;
    const recs = gpa.alloc(SortedRec, total) catch oom();
    defer gpa.free(recs);
    var k: usize = 0;
    for (workers) |*w| for (w.recs.items) |r| {
        recs[k] = r;
        k += 1;
    };
    std.mem.sort(SortedRec, recs, o.sort_reverse, recLess);
    if (o.files_list or o.files_only) {
        const term: []const u8 = if (o.null_sep) "\x00" else o.outTerm();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        for (recs) |r| {
            out.appendSlice(gpa, r.path) catch oom();
            out.appendSlice(gpa, term) catch oom();
        }
        sink.emitFilesChunk(out.items, recs.len);
    } else for (recs) |r| sink.emit(r.kind, r.buf);
}
test "sorted-emit order matches the serial --sort path oracle" {
    const t = std.testing;
    const mk = struct {
        fn r(p: []const u8) SortedRec {
            return .{ .path = p, .kind = .text_hit, .buf = "" };
        }
    }.r;
    // Ascending rides `serial.pathLess` (rg's `Path::cmp`): `/` ranks below every
    // other byte, so a directory sorts before a sibling file sharing its stem —
    // a raw byte compare (`.`=0x2e < `/`=0x2f) would flip these.
    try t.expect(recLess(false, mk("warroom/service.go"), mk("warroom.go")));
    try t.expect(!recLess(false, mk("warroom.go"), mk("warroom/service.go")));
    try t.expect(recLess(false, mk("a.zig"), mk("b.zig")));
    // `--sortr` is the exact mirror (operands swapped), matching rg's `.reverse()`.
    try t.expect(recLess(true, mk("b.zig"), mk("a.zig")));
    try t.expect(recLess(true, mk("warroom.go"), mk("warroom/service.go")));
    // Equal paths compare false either way — a stable, no-adjacent-reorder sort.
    try t.expect(!recLess(false, mk("x"), mk("x")));
    try t.expect(!recLess(true, mk("x"), mk("x")));
}
test "worker topology keeps scans wide and selective walks lean" {
    const t = std.testing;
    if (builtin.os.tag == .macos) {
        // macOS keeps the kernel-serialized ceiling, halved for selective walks.
        try t.expectEqual(4, defaultWorkerCount(8, true));
        try t.expectEqual(6, defaultWorkerCount(8, false));
        try t.expectEqual(4, defaultWorkerCount(4, true));
        try t.expectEqual(6, defaultWorkerCount(12, true));
    } else {
        // Every other OS scales to all logical CPUs (ripgrep's model).
        try t.expectEqual(8, defaultWorkerCount(8, true));
        try t.expectEqual(8, defaultWorkerCount(8, false));
        try t.expectEqual(12, defaultWorkerCount(12, true));
    }
}

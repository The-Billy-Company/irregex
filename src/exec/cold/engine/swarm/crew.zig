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
const assay = @import("../../../../assay/assay.zig");
const elide = @import("../../quarry/elide.zig");
const fresh = @import("../../../../corpus/fresh/fresh.zig");
const Stats = @import("../../read/stats.zig").Stats;
const ignore = @import("../../../../corpus/tree/ignore.zig");
const ingest = @import("../../read/ingest.zig");
const json = @import("../../emit/json.zig");
const beacon = @import("../../../../surface/cli/beacon.zig");
const palette = @import("../../emit/color.zig");
const portal = @import("../../../../portal.zig");
const queue = @import("queue.zig");
const serial = @import("../serial.zig");
const shard_mod = @import("../../../../corpus/index/content/shard.zig");
const simd = @import("../../../../kernel/scan/simd.zig");
const sink_mod = @import("sink.zig");
const treemap = @import("../../../../corpus/index/phantom/treemap.zig");

const FragKind = sink_mod.FragKind;
const Matcher = @import("../../../../kernel/regex/regex.zig").Matcher;
const Opts = args.Opts;
const Queue = queue.Queue;
const Sink = sink_mod.Sink;
const oom = @import("../../../../surface/cli/outcome.zig").oom;

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
    // The corpus-wide freshness anchor the filesystem journal proved before this
    // walk started (`fresh.Certificate.settle`), or null when the run never asked
    // or the proof was refused. A latched VALUE rather than a live handle: the
    // whole walk lists directories one way or the other, never both. Under an
    // anchor every corpus file is known to predate the build, so the walk drops
    // per-file clocks entirely and the phantom snapshot serves membership outright.
    cert: ?i128 = null,
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
const SortedRec = struct { path: []const u8, kind: FragKind, buf: []const u8, chrome: usize = 0, mtime_ns: ?i128 = null, ctime_ns: ?i128 = null };

/// A file discovered before the elide oracle finished loading — held back so
/// it can still be elided (or searched) once `elide.Lazy.ready` flips.
pub const Deferred = struct {
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
    /// The pool this worker belongs to, so a worker that finishes a directory can
    /// notice the crew is undersized for the walk it turned out to be and hire
    /// (`Crew.consider`). Shared and mutable like `q` — and, like `q`, guarded:
    /// every field a peer reads is an atomic or sits under `Crew.mu`. Null for a
    /// pool that cannot grow (a fixed-width `Crew` never reads it).
    crew: ?*Crew = null,
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
    out_chrome: usize = 0, // of `out`'s bytes, the OSC-8 frames around those paths
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
    stats: Stats = .{},
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
        w.out_chrome += pathRow(w.gpa, &w.out, w.cfg.o, w.cfg.use_color, path, term);
        w.out_files += 1;
        if (w.out.items.len >= files_flush_cap) w.flushFiles();
    }

    /// Stream one rendered fragment to the sink, or — under `--sort`/`--sortr` —
    /// hold it in this worker's arena keyed by `dpath` for the ordered final emit.
    /// The rendered bytes already live in the worker arena (which outlives the
    /// walk), so holding a reference costs one record, never a copy.
    pub fn deliver(w: *Worker, kind: FragKind, dpath: []const u8, buf: []const u8, chrome: usize) void {
        if (w.cfg.collect_sorted) {
            w.recs.append(w.gpa, .{ .path = dpath, .kind = kind, .buf = buf, .chrome = chrome }) catch oom();
            return;
        }
        w.cfg.sink.emit(kind, buf, chrome);
    }

    /// Drain the worker's buffered path list into the sink as one chunk.
    pub fn flushFiles(w: *Worker) void {
        if (w.out_files == 0) return;
        w.cfg.sink.emitFilesChunk(w.out.items, w.out_files, w.out_chrome);
        w.out.clearRetainingCapacity();
        w.out_files = 0;
        w.out_chrome = 0;
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

/// Worker pool size for a plaintext walk — the width a walk STARTS at. macOS
/// serializes the walk in the kernel — the `vm_map` fault lock on the mmap'd
/// content shard and syspolicyd/vnode locks on open+namei — so past a small pool
/// more threads only add contention (measured flat 6→16 on the shard path, and
/// slower on the open path); the tuned six-worker ceiling stays, halved further
/// for traversal-only / narrow / index-selective runs that do less work per file.
/// Every other OS has a scalable fault + open path — ripgrep saturates all
/// logical CPUs there — so the ceiling would just idle cores: scale to `ncpu`.
/// `GIST_WORKERS` and `-j` still override.
///
/// It is a STARTING width because the numbers above were all measured on walks
/// that respect `.gitignore` and hit the index — the fast ones. A walk that turns
/// out to be neither (`-uu` over gigabytes of ignored build artifacts, an
/// unindexed external root) is I/O-bound rather than namei-bound, and there six
/// workers idle the machine: see `Crew.consider`, which hires up to
/// `maxWorkerCount` once a walk has proven it is that kind of walk.
pub fn defaultWorkerCount(ncpu_raw: usize, selective: bool) usize {
    const ncpu = @max(1, ncpu_raw);
    if (builtin.os.tag != .macos) return ncpu;
    const full = @min(ncpu, 6);
    if (!selective or ncpu <= 4) return full;
    return @min(full, @max(4, (ncpu + 1) / 2));
}

/// The widest a walk may ever be reinforced to: every logical CPU, except on an
/// asymmetric machine, where it is the count of the FAST ones. Beyond that a
/// worker lands on an efficiency core and runs the same syscall-heavy loop
/// several times slower while still taking the same kernel locks — on an M4 Max
/// (12 P + 4 E) the full-16 pool bought 2 % wall time for 62 % more system time
/// on a 54 GiB `-uu` sweep, which on a laptop shared with other work is a loss,
/// not a win. A symmetric machine (`performanceCores` null) keeps ripgrep's
/// model and scales to `ncpu`.
pub fn maxWorkerCount(ncpu_raw: usize) usize {
    const ncpu = @max(1, ncpu_raw);
    return @min(ncpu, portal.performanceCores() orelse ncpu);
}

/// A walk must be at least this old before it may widen. The topology
/// `defaultWorkerCount` picks is right for the walks it was tuned on, and those
/// answer in 18–310 ms on this corpus; the walk that needs more hands runs for
/// 80 s. So elapsed time — not queue depth, which is deep on ANY wide tree —
/// is what separates them, and half a second is comfortably past every
/// interactive walk while costing the long one 0.6 % of its runtime at the
/// starting width.
const patience_ns: i128 = 500 * std.time.ns_per_ms;

/// Outstanding directories required per hired worker before hiring another. A
/// walk whose remaining front is one enormous file cannot use a second thread on
/// it, and the front is exactly what says so.
const front_per_worker: usize = 2;

/// The worker pool, and the one thing about it that is not decided up front: how
/// wide it should be.
///
/// A walk's shape is not knowable when its crew is mustered. Flags and roots hint
/// at it — that is what `defaultWorkerCount`'s `selective` argument is — but they
/// cannot distinguish the 20 ms indexed scan the small pool was tuned for from a
/// sweep of tens of gigabytes of unindexed artifacts, where the same pool leaves
/// most of the machine idle waiting on reads. So the crew starts at the tuned
/// width and REINFORCES: any worker that finishes a directory checks whether the
/// walk has run long enough, and left enough of a front, to be worth more hands
/// (`consider`), and hires them itself.
///
/// One-way and bounded by construction: the roster only grows, never past
/// `ceiling`, and closes for good the moment the walk's own thread returns —
/// which is what makes joining safe without a second synchronization protocol.
/// A worker mid-file when the crew widens is unaffected; new hands take work
/// from the shared queue exactly as a starving peer would, because that is the
/// same protocol (`Queue.pop` bumps `starving`, and its peers donate).
pub const Crew = struct {
    /// Every seat, `ceiling` of them; only `[0..roster)` ever run. Initialized by
    /// the caller before `muster`, so a hire is a spawn and nothing else.
    workers: []Worker,
    gpa: std.mem.Allocator,
    io: std.Io,
    /// What a late hire runs. A pointer rather than a comptime parameter because
    /// the hiring worker is not the mustering frame; both walk bodies
    /// (`descent.workerMain`, `roster.workerMain`) fit through it unchanged.
    body: *const fn (*Worker) void,
    ceiling: usize,
    /// Opened by `muster`. The awake-monotonic house clock (`assay.Span`), so a
    /// suspend or an NTP step can never make a walk look old enough to widen.
    walk: assay.Span = .{ .start = 0 },
    /// Seats filled, worker 0 included. Written under `mu`, read lock-free by
    /// `consider` on the hot path.
    hired: std.atomic.Value(usize) = .init(1),
    threads: []std.Thread = &.{},
    running: usize = 0, // live threads in `threads[0..running]` (under `mu`)
    closed: bool = false, // the roster is final — the walk's own thread has returned
    mu: std.Io.Mutex = .init,

    /// Run the pool to completion: a thread per starting seat after the first, the
    /// caller's thread as worker 0, then close the roster and join every thread —
    /// the ones mustered here and any hired mid-walk.
    ///
    /// A mid-spawn failure is not fatal and not retried — the walk simply proceeds
    /// at the width the OS granted, down to one worker on the caller's thread.
    /// Work is never lost by a thread that failed to start: the queue is
    /// work-stealing, so a missing worker's tasks are taken by the ones that did
    /// start, and its per-worker state stays empty and folds in as a no-op.
    ///
    /// Deliberately not `kernel/math/parallel.zig::fanOut`: that combinator runs
    /// its un-spawned tail inline *after* spawning and joins around it, which is
    /// right for fixed shards. Here worker 0 must walk on the caller's thread
    /// concurrently with the others — the caller's thread is a first-class worker
    /// for the whole walk, not a fallback for a shard nobody took.
    ///
    /// The thread array's allocation failure RETURNS: this sits on the calling
    /// thread, so the daemon-facing `roster.collectFileSet` can honor its own
    /// `Oom!` contract instead of taking the embedding host down with `exit(2)`
    /// (fault-channel law 1). The `noreturn` CLI path converts it back at its call site.
    pub fn muster(c: *Crew, start: usize) std.mem.Allocator.Error!void {
        const seats = @max(1, @min(start, c.workers.len));
        c.threads = try c.gpa.alloc(std.Thread, c.workers.len -| 1);
        defer c.gpa.free(c.threads);
        c.walk = .open(c.io);
        for (c.workers[1..seats]) |*w| {
            c.threads[c.running] = std.Thread.spawn(.{}, enlist, .{ c, w }) catch break;
            c.running += 1;
        }
        c.hired.store(c.running + 1, .release);
        c.body(&c.workers[0]); // the caller's thread is a worker too
        // The walk is over, so nobody may join it: close the roster under the same
        // lock `hire` takes, after which `running` is final and safe to read here.
        c.mu.lockUncancelable(c.io);
        c.closed = true;
        const live = c.running;
        c.mu.unlock(c.io);
        for (c.threads[0..live]) |t| t.join();
    }

    /// One worker's per-directory look at whether the crew is the bottleneck.
    /// Ordered cheapest-first, and free once the crew is at its ceiling (a single
    /// relaxed load): a walk that never widens pays one load per directory, and a
    /// clock is read only by a walk that already has a front worth widening for.
    pub fn consider(c: *Crew, q: *Queue) void {
        const hired = c.hired.load(.monotonic);
        if (hired >= c.ceiling) return;
        const front = q.live.load(.monotonic);
        if (front < hired * front_per_worker) return;
        if (c.walk.read(c.io).ns() < patience_ns) return;
        // The front says how many hands it can actually keep busy; the ceiling
        // says how many the machine can. Hire the smaller in one step, so a walk
        // that has been starving for half a second does not ramp a seat per
        // directory.
        c.hire(@min(c.ceiling, front / front_per_worker));
    }

    /// Fill seats up to `want`. Serialized on `mu`, which is also what makes the
    /// race with `muster`'s close benign: a hire either lands before the roster
    /// closes (and is joined) or sees it closed and does nothing.
    fn hire(c: *Crew, want: usize) void {
        c.mu.lockUncancelable(c.io);
        defer c.mu.unlock(c.io);
        if (c.closed) return;
        while (c.running + 1 < @min(want, c.workers.len)) {
            const w = &c.workers[c.running + 1];
            c.threads[c.running] = std.Thread.spawn(.{}, enlist, .{ c, w }) catch break;
            c.running += 1;
            c.hired.store(c.running + 1, .release);
        }
    }
};

/// A spawned worker's entry point. The indirection exists because `Crew.body` is a
/// runtime pointer (see the field) while `std.Thread.spawn` wants a comptime
/// function; every seat — mustered or hired — enters through the same door.
fn enlist(c: *Crew, w: *Worker) void {
    c.body(w);
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
pub fn emitSorted(gpa: std.mem.Allocator, sink: *Sink, workers: []Worker, o: Opts, use_color: bool) void {
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
    // Every mode whose record IS a bare path — `Mode.pathPerFile` (the two
    // yes/no verdict modes) plus `--files`, which prints paths without asking
    // the pattern anything. Spelling the membership by hand is what dropped
    // `--files-without-match` into the fragment branch, where its empty `buf`
    // rendered as nothing at all.
    if (o.mode == .files or o.mode.pathPerFile()) {
        const term: []const u8 = if (o.null_sep) "\x00" else o.outTerm();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var chrome: usize = 0;
        for (recs) |r| chrome += pathRow(gpa, &out, o, use_color, r.path, term);
        sink.emitFilesChunk(out.items, recs.len, chrome);
    } else for (recs) |r| sink.emit(r.kind, r.buf, r.chrome);
}

/// One path-list row: the path framed as a click target, painted with the
/// `path` element, then terminated. Returns the chrome (link + escape) bytes
/// the output budget discounts, so a colored listing is not charged for its
/// own escapes.
///
/// A free function because the parallel workers write their `-l` lists into an
/// arena buffer with no `Emitter` in hand, and this has to render what
/// `Emitter.heading` renders — a listing that changed color depending on
/// whether the run happened to shard is a worse answer than an uncolored one.
/// `beacon.anchor` borrows the path unchanged when the run resolved no beacon,
/// and `paint` is a plain append when color is off, so a piped run still pays
/// nothing and writes ripgrep's bytes.
fn pathRow(gpa: std.mem.Allocator, out: *std.ArrayList(u8), o: Opts, use_color: bool, path: []const u8, term: []const u8) usize {
    const shown = beacon.anchor(gpa, path);
    const tint = use_color and o.palette.path.len > 0;
    if (tint) out.appendSlice(gpa, o.palette.path) catch oom();
    out.appendSlice(gpa, shown) catch oom();
    if (tint) out.appendSlice(gpa, palette.reset) catch oom();
    out.appendSlice(gpa, term) catch oom();
    return shown.len - path.len + if (tint) o.palette.path.len + palette.reset.len else 0;
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
test "a walk may only ever be reinforced toward the machine's fast cores" {
    const t = std.testing;
    // The ceiling is a property of the machine, so it is asserted as a relation to
    // what the machine says rather than as a number: never above `ncpu` (a pool
    // wider than the CPU only adds contention), never below the starting width
    // (reinforcement must not be able to shrink a pool), and on an asymmetric
    // package never above the count of fast cores.
    for ([_]usize{ 1, 2, 4, 8, 12, 16, 64 }) |ncpu| {
        const ceiling = maxWorkerCount(ncpu);
        try t.expect(ceiling >= 1);
        try t.expect(ceiling <= ncpu);
        if (portal.performanceCores()) |fast| try t.expect(ceiling <= @max(1, fast));
    }
    // A machine that reports nothing is symmetric by assumption — ripgrep's model.
    if (portal.performanceCores() == null) try t.expectEqual(@as(usize, 8), maxWorkerCount(8));
    // Zero CPUs is a refused query, not a zero-worker pool.
    try t.expectEqual(@as(usize, 1), maxWorkerCount(0));
}
test "hiring is gated on a front the crew cannot already absorb" {
    const t = std.testing;
    // The front test alone, over the exact arithmetic `consider` runs, so the
    // policy is pinned without spawning threads: a crew at its ceiling is done,
    // and a walk whose remaining front is thinner than two directories per worker
    // has nothing a new hand could take.
    const wants = struct {
        fn f(hired: usize, ceiling: usize, front: usize) bool {
            return hired < ceiling and front >= hired * front_per_worker;
        }
    }.f;
    try t.expect(!wants(12, 12, 10_000)); // at the ceiling: no clock is even read
    try t.expect(!wants(6, 12, 11)); // one enormous file left — another thread cannot help
    try t.expect(wants(6, 12, 12)); // two directories per worker: hire
    try t.expect(wants(6, 12, 4_000));
    // And the width a deep front asks for is bounded by the ceiling, never by it.
    try t.expectEqual(@as(usize, 12), @min(@as(usize, 12), @as(usize, 4_000) / front_per_worker));
    try t.expectEqual(@as(usize, 8), @min(@as(usize, 12), @as(usize, 16) / front_per_worker));
}

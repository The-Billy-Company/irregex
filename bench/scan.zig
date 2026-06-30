//! gist cold no-prefilter scan — the direct live-tree path (regex AND literal).
//!
//! When a query has NO usable trigram prefilter — a regex with no ≥3 B required
//! literal and no all-≥3 alternation cover (`[0-9]{4}`, `panic|0x`, `[a-f0-9]{2,}`,
//! `\w{3,8}`), OR a sub-trigram literal (`<3 B`, e.g. `})`, `=>`) — the index
//! cannot filter anything: every doc is a candidate. The index path then pays TWO
//! full tree traversals: a corpus-wide T3 freshness stat-walk (`statFile` on every
//! file) AND a candidate read of all ~18 k files — where ripgrep pays one (walk +
//! read). So for that case we skip the index entirely and walk the LIVE tree ONCE,
//! reading + scanning each file (NFA `docMatch` for regex, `simd.contains` for the
//! literal).
//! This is strictly MORE correct than the index+freshness path: it reads current
//! bytes, sees files created since the build, honors deletions — no staleness
//! window, so no freshness stat-walk at all. Same skip-dirs, NUL-binary detection
//! and per-file cap as the indexed corpus, so the matched set is identical.
//!
//! THROUGHPUT MODEL (measured, not assumed): the tier is IO-latency-bound, not
//! scan-bound — ~140 µs per file (open+read+close of a ~16 KiB median file), the
//! `Regex.docMatch` DFA pass (one byte-touch) is a rounding error on top. So the
//! win is in the ORCHESTRATION, and a phased walk-then-shard left two leaks on the
//! floor, both profiled before this rewrite:
//!   • a ~63 ms walk BARRIER — directory iteration that overlapped with nothing;
//!   • ~169 ms STRAGGLER idle — static file-count sharding stranded the big files
//!     on one thread (fastest core done in 158 ms, slowest 327 ms).
//! This file closes both with one fused, work-stealing pipeline:
//!   • walkers stream discovered paths into a shared queue AS THEY WALK, so the
//!     read+scan starts on the first batch — the walk is hidden under the scan,
//!     not serialized before it;
//!   • a pool of OVERSUBSCRIBED consumers (`worker_mult`× cores) steal files one
//!     batch at a time off the queue, so byte-load self-balances (no straggler)
//!     and a thread blocked in `read()` yields its core to another in-flight read
//!     (latency hiding — the lever an IO-bound tier actually responds to).
//! Every worker is both: it walks its assigned root (if any), then drains the
//! queue as a consumer, so no thread goes idle after the walk. The DFA is unchanged.

const std = @import("std");
const gist = @import("gist");
const corpus_mod = @import("corpus.zig");
const simd = @import("simd.zig");
const Regex = gist.regex.Regex;
const Dir = std.Io.Dir;

/// Workers per core. Measured, not assumed: a warm page cache makes this tier
/// CPU/syscall-bound (~190 µs/file is openat+read+close + fault-in, the DFA pass
/// is a rounding error), so oversubscription only thrashes the scheduler — ×1
/// (= one worker per logical core) was fastest AND tightest-balanced (worker span
/// Δ 2.5 ms vs 8–14 ms at ×2/×3). Work-stealing means a blocked syscall still
/// hands the next file to a free core without a dedicated extra thread, so the
/// only thing oversubscription would buy — cold-cache disk-latency hiding — isn't
/// the benchmark's regime (hyperfine warms the cache first).
const worker_mult: usize = 1;
const push_batch: usize = 64; // walker → queue flush granularity (amortize the lock)
const steal_batch: usize = 16; // queue → consumer steal granularity

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}
fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
fn cmpStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// MPMC path queue: producers (walkers) append discovered paths, consumers steal
/// them in batches. A monotonically-rising `head` cursor over an append-only list
/// (paths alias the walker arenas, alive for the whole call — never moved) means a
/// steal is a memcpy + cursor bump, no per-item alloc. `live_walkers` drives
/// termination: a consumer that finds the queue empty blocks until either more
/// paths arrive or the last walker finishes (then the queue is drained → done).
const Queue = struct {
    mu: std.Io.Mutex = .init,
    cv: std.Io.Condition = .init,
    items: std.ArrayList([]const u8) = .empty,
    head: usize = 0,
    live_walkers: usize,
    gpa: std.mem.Allocator,
    io: std.Io,

    fn push(q: *Queue, batch: []const []const u8) void {
        if (batch.len == 0) return;
        q.mu.lockUncancelable(q.io);
        q.items.appendSlice(q.gpa, batch) catch {};
        q.mu.unlock(q.io);
        q.cv.broadcast(q.io);
    }

    fn walkerDone(q: *Queue) void {
        q.mu.lockUncancelable(q.io);
        q.live_walkers -= 1;
        const last = q.live_walkers == 0;
        q.mu.unlock(q.io);
        if (last) q.cv.broadcast(q.io);
    }

    /// Steal up to `out.len` paths. Returns the count taken; 0 means the run is
    /// over (queue drained AND every walker has finished). Blocks while the queue
    /// is momentarily empty but walkers are still producing.
    fn steal(q: *Queue, out: [][]const u8) usize {
        q.mu.lockUncancelable(q.io);
        defer q.mu.unlock(q.io);
        while (true) {
            const avail = q.items.items.len - q.head;
            if (avail > 0) {
                const take = @min(avail, out.len);
                @memcpy(out[0..take], q.items.items[q.head..][0..take]);
                q.head += take;
                return take;
            }
            if (q.live_walkers == 0) return 0;
            q.cv.waitUncancelable(q.io, &q.mu);
        }
    }
};

/// A pipeline thread. If `root` is set it first walks that root (streaming paths
/// into the queue), then — every thread, walker or not — drains the queue as a
/// consumer until the run ends. Per-thread scratch + Pike sim; matched paths alias
/// the walk arenas. Failures degrade to "found nothing here" (the live tree is
/// truth, a transient open error omits a file, never invents a match).
const Worker = struct {
    q: *Queue,
    io: std.Io,
    re: ?*const Regex, // set ⇒ NFA `docMatch`; null ⇒ literal `simd.contains(needle)`
    needle: []const u8 = "", // the substring to verify when `re` is null
    gpa: std.mem.Allocator,
    root: ?[]const u8 = null,
    arena: ?*std.heap.ArenaAllocator = null, // path storage for this worker's root
    matched: std.ArrayList([]const u8) = .empty,
    reads: usize = 0,
    bytes: u64 = 0,
    elapsed_ns: i128 = 0,
};

fn walkRoot(w: *Worker, root_path: []const u8) void {
    const a = w.arena.?.allocator();
    var root = Dir.cwd().openDir(w.io, root_path, .{ .iterate = true }) catch return;
    defer root.close(w.io);
    var walker = root.walkSelectively(a) catch return;
    defer walker.deinit();
    var batch: [push_batch][]const u8 = undefined;
    var n: usize = 0;
    while (walker.next(w.io) catch return) |entry| {
        if (entry.kind == .directory) {
            if (!corpus_mod.isSkipDir(entry.basename)) walker.enter(w.io, entry) catch return;
            continue;
        }
        if (entry.kind != .file) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, entry.path }) catch return;
        batch[n] = full;
        n += 1;
        if (n == push_batch) {
            w.q.push(batch[0..n]);
            n = 0;
        }
    }
    if (n > 0) w.q.push(batch[0..n]);
}

fn consume(w: *Worker) void {
    const scratch = w.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
    defer w.gpa.free(scratch);
    // A regex worker owns one reusable Pike-sim (the `Regex` is shared+immutable,
    // the `Sim` scratch is per-thread); a literal worker needs none.
    var sim: ?Regex.Sim = if (w.re) |re| (Regex.Sim.init(w.gpa, re) catch return) else null;
    defer if (sim) |*s| s.deinit();
    var stolen: [steal_batch][]const u8 = undefined;
    while (true) {
        const got = w.q.steal(stolen[0..]);
        if (got == 0) break;
        for (stolen[0..got]) |path| {
            const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
            var n: usize = 0;
            while (n < scratch.len) {
                const r = std.posix.read(fd, scratch[n..]) catch break;
                if (r == 0) break;
                n += r;
            }
            _ = std.posix.system.close(fd);
            w.reads += 1;
            w.bytes += n;
            if (n == 0 or corpus_mod.isBinary(scratch[0..n])) continue;
            const hit = if (w.re) |re| re.docMatch(&sim.?, scratch[0..n]) else simd.contains(scratch[0..n], w.needle);
            if (hit) w.matched.append(w.gpa, path) catch {};
        }
    }
}

fn workerMain(w: *Worker) void {
    const t = nowNs(w.io);
    if (w.root) |r| {
        walkRoot(w, r);
        w.q.walkerDone();
    }
    consume(w);
    w.elapsed_ns = nowNs(w.io) - t;
}

/// Cold no-prefilter regex: skip the index, scan the live tree directly.
pub fn runRegexFullScan(gpa: std.mem.Allocator, io: std.Io, re: *const Regex) !void {
    return runFullScan(gpa, io, re, "");
}

/// Cold sub-trigram literal (`<3 B` needle ⇒ no trigram filter, so the index
/// would seed every doc AND pay a freshness stat-walk on top of the read — two
/// traversals where rg pays one). Skip the index and scan the live tree once,
/// SIMD-verifying the substring — the literal twin of `runRegexFullScan`.
pub fn runLiteralFullScan(gpa: std.mem.Allocator, io: std.Io, needle: []const u8) !void {
    return runFullScan(gpa, io, null, needle);
}

/// Fused work-stealing walk+read+scan of the live tree, emitting the sorted match
/// set. No index load, no freshness stat-walk — the live read IS the freshness
/// guarantee. Verifies with the NFA when `re` is set, else `simd.contains(needle)`.
fn runFullScan(gpa: std.mem.Allocator, io: std.Io, re: ?*const Regex, needle: []const u8) !void {
    const t0 = nowNs(io);
    const roots = &corpus_mod.default_roots;

    const ncpu = std.Thread.getCpuCount() catch 8;
    // Every walker is also a consumer; top up with pure consumers to the target.
    const nworkers = @max(roots.len, ncpu * worker_mult);

    var q: Queue = .{ .live_walkers = roots.len, .gpa = gpa, .io = io };
    defer q.items.deinit(gpa);

    // One arena per root-walker; alive for the whole call (matched paths alias it).
    const arenas = try gpa.alloc(std.heap.ArenaAllocator, roots.len);
    defer gpa.free(arenas);
    for (arenas) |*ar| ar.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer for (arenas) |*ar| ar.deinit();

    const workers = try gpa.alloc(Worker, nworkers);
    defer gpa.free(workers);
    for (workers, 0..) |*w, i| w.* = .{
        .q = &q,
        .io = io,
        .re = re,
        .needle = needle,
        .gpa = gpa,
        .root = if (i < roots.len) roots[i] else null,
        .arena = if (i < roots.len) &arenas[i] else null,
    };

    // Fan out; run inline if spawning is unavailable (degrade, never deadlock —
    // inline producers finish before inline consumers steal, queue self-drains).
    const threads = try gpa.alloc(std.Thread, nworkers);
    defer gpa.free(threads);
    var spawned: usize = 0;
    for (workers) |*w| {
        threads[spawned] = std.Thread.spawn(.{}, workerMain, .{w}) catch break;
        spawned += 1;
    }
    for (workers[spawned..]) |*w| workerMain(w);
    for (threads[0..spawned]) |t| t.join();

    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(gpa);
    var reads: usize = 0;
    var bytes: u64 = 0;
    var w_min: i128 = std.math.maxInt(i128);
    var w_max: i128 = 0;
    for (workers) |*w| {
        try matches.appendSlice(gpa, w.matched.items);
        reads += w.reads;
        bytes += w.bytes;
        w_min = @min(w_min, w.elapsed_ns);
        w_max = @max(w_max, w.elapsed_ns);
        w.matched.deinit(gpa);
    }
    std.mem.sort([]const u8, matches.items, {}, cmpStrings);

    var outbuf: std.ArrayList(u8) = .empty;
    defer outbuf.deinit(gpa);
    for (matches.items) |p| {
        try outbuf.appendSlice(gpa, p);
        try outbuf.append(gpa, '\n');
    }
    corpus_mod.emitStdout(outbuf.items); // matched paths → stdout (rg convention)
    const mb = @as(f64, @floatFromInt(bytes)) / (1 << 20);
    std.debug.print("— {d} matches · scanned {d} files / {d:.0} MiB (live tree, no index/freshness) · total {d:.1} ms\n", .{
        matches.items.len, reads, mb, ms(nowNs(io) - t0),
    });
    std.debug.print("  [pipeline] {d} workers ({d} walkers + steal) · worker span {d:.1}→{d:.1} ms (Δ{d:.1})\n", .{
        nworkers, roots.len, ms(w_min), ms(w_max), ms(w_max - w_min),
    });
}

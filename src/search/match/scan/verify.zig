//! gist — data-parallel candidate verify (the half of the head-to-head that has
//! to out-throughput ripgrep's multi-core scan). The trigram filter is cheap and
//! single-threaded; the *bytes* are in the candidate verify (and the <3-byte
//! full-scan fallback), so that is what fans out across cores. The corpus-aware
//! matcher wrappers that drive this live in the callers (the CLI drivers and the
//! bench harness); this module is the pure parallel verify kernel + SIMD scan.

const std = @import("std");
const simd = @import("simd.zig");

pub const par_threshold = 512; // below this candidate count, threading isn't worth it

/// SIMD first+last-byte scan — ~18x std's naive 2–4 byte path (see `simd.zig`).
pub inline fn contains(hay: []const u8, needle: []const u8) bool {
    return simd.contains(hay, needle);
}

/// One buffer this large stops being "a file" and becomes "a corpus": fan its
/// presence gate across cores. Below it, the single-thread kernel's early exit
/// and zero spawn cost win. 16 MiB ≈ 1 ms of single-thread scan — the smallest
/// buffer where ~30 µs/thread of spawn+join noise is decisively amortized.
pub const wide_threshold: usize = 16 << 20;

/// Slab granularity for the cooperative early-exit poll inside a shard: one
/// atomic load per MiB scanned (~40 µs), so a hit anywhere stops every shard
/// within a millisecond while the no-hit case pays ~0.003% overhead.
const wide_slab: usize = 1 << 20;

const WideShard = struct {
    hay: []const u8,
    needles: []const []const u8,
    overlap: usize,
    hit: *std.atomic.Value(bool),

    /// Scan this shard slab-by-slab through the proven single-thread kernels,
    /// each slab extended `overlap` bytes so an occurrence straddling a slab
    /// seam is seen whole; shards themselves overlap the same way, so the
    /// union of shards sees every occurrence exactly as one contiguous scan
    /// would. Polls `hit` between slabs and stops early on any shard's find.
    fn run(sh: *const WideShard) void {
        var i: usize = 0;
        while (i < sh.hay.len) : (i += wide_slab) {
            if (sh.hit.load(.monotonic)) return;
            const end = @min(sh.hay.len, i + wide_slab + sh.overlap);
            if (simd.containsAny(sh.hay[i..end], sh.needles)) {
                sh.hit.store(true, .monotonic);
                return;
            }
        }
    }
};

/// Whole-buffer any-of presence for a HUGE body (an mmap'd multi-GiB blob the
/// rg-parity walk legitimately admits): chunk it across cores with a
/// `max(len)-1` overlap so no straddling occurrence can hide, and let any hit
/// cancel the remaining shards. Byte-equivalent to `simd.containsAny` (proven
/// by the differential test in `simd_test.zig`); ~4× faster on a 2.1 GiB
/// page-cached blob (160 ms single-thread faulting → ~40 ms fanned). Falls
/// back to the single-thread kernel below `wide_threshold`, for degenerate
/// needle sets, or if a thread can't spawn — never a behavior change.
pub fn containsAnyWide(gpa: std.mem.Allocator, hay: []const u8, needles: []const []const u8) bool {
    // Sub-threshold bodies (the overwhelmingly common case) branch out here
    // on one comparison — no cpu-count syscall, no allocation, no spawn.
    // (`simd.containsAny` itself takes the single-needle kernel for len 1.)
    if (hay.len < wide_threshold) return simd.containsAny(hay, needles);
    var overlap: usize = 0;
    for (needles) |n| {
        if (n.len == 0) return true;
        overlap = @max(overlap, n.len - 1);
    }
    const ncpu = std.Thread.getCpuCount() catch 1;
    const nthr = @min(hay.len / wide_threshold + 1, ncpu);
    if (nthr < 2) return simd.containsAny(hay, needles);

    var hit = std.atomic.Value(bool).init(false);
    const shards = gpa.alloc(WideShard, nthr) catch
        return simd.containsAny(hay, needles);
    defer gpa.free(shards);
    const threads = gpa.alloc(std.Thread, nthr) catch
        return simd.containsAny(hay, needles);
    defer gpa.free(threads);

    const chunk = hay.len / nthr;
    for (0..nthr) |k| {
        const start = k * chunk;
        const end = if (k == nthr - 1) hay.len else @min(hay.len, (k + 1) * chunk + overlap);
        shards[k] = .{ .hay = hay[start..end], .needles = needles, .overlap = overlap, .hit = &hit };
    }
    fanOut(WideShard, shards, threads, WideShard.run);
    return hit.load(.monotonic);
}

/// Single-needle sugar over `containsAnyWide` — the shape the file-level
/// required-literal gate calls with.
pub fn containsWide(gpa: std.mem.Allocator, hay: []const u8, needle: []const u8) bool {
    return containsAnyWide(gpa, hay, &.{needle});
}

/// Byte-greedy shard boundaries over `items` (`bounds.len − 1` shards): each
/// shard takes ~equal total `weight`, not equal item count, so a few large
/// files can't stall one thread while the rest idle — the load-imbalance that
/// capped the earlier speedup. Shared by the candidate verify below and the
/// relate sketch build (`cli/relate/kinship.zig`).
pub fn greedyBounds(
    comptime T: type,
    items: []const T,
    ctx: anytype,
    comptime weight: fn (@TypeOf(ctx), T) usize,
    total: usize,
    bounds: []usize,
) void {
    const nthr = bounds.len - 1;
    const target = total / nthr;
    bounds[0] = 0;
    var b: usize = 1;
    var acc: usize = 0;
    for (items, 0..) |item, i| {
        acc += weight(ctx, item);
        if (b < nthr and acc >= target * b) {
            bounds[b] = i + 1;
            b += 1;
        }
    }
    while (b <= nthr) : (b += 1) bounds[b] = items.len;
}

/// The byte-length weight most callers shard by (`items` are the docs themselves).
pub fn sliceLen(_: void, d: []const u8) usize {
    return d.len;
}

/// Spawn one thread per shard and join them — with the partial-spawn fallback
/// every fan-out here shares: a mid-fan-out spawn failure must not return with
/// live threads still scanning buffers the caller's defers would free. The
/// unspawned tail runs inline on the calling thread — exactness preserved,
/// just less parallelism — then the spawned shards are joined as usual.
pub fn fanOut(comptime S: type, shards: []S, threads: []std.Thread, comptime runFn: anytype) void {
    var spawned: usize = 0;
    for (shards) |*sh| {
        threads[spawned] = std.Thread.spawn(.{}, runFn, .{sh}) catch break;
        spawned += 1;
    }
    for (shards[spawned..]) |*sh| runFn(sh);
    for (threads[0..spawned]) |t| t.join();
}

const VerifyShard = struct {
    docs: []const []const u8,
    ids: []const u32,
    needle: []const u8,
    out: []u32, // private region (≤ ids.len), no contention
    n: usize = 0,
};

fn verifyShard(sh: *VerifyShard) void {
    var w: usize = 0;
    for (sh.ids) |d| if (contains(sh.docs[d], sh.needle)) {
        sh.out[w] = d;
        w += 1;
    };
    sh.n = w;
}

fn docWeight(docs: []const []const u8, d: u32) usize {
    return docs[d].len;
}

/// Verify `ids` against `needle`, fanning out across cores when the candidate
/// set is large. Sharding is **byte-balanced** (each thread gets ~equal total
/// bytes, not equal file count) so a few large files can't stall one thread
/// while the rest idle — the load-imbalance that capped the earlier speedup.
/// Thread count scales with total bytes (~one per 512 KiB). Results are
/// appended unordered (callers that need a set sort afterward).
pub fn parallelVerify(gpa: std.mem.Allocator, docs: []const []const u8, ids: []const u32, needle: []const u8, out: *std.ArrayList(u32)) !void {
    var total: usize = 0;
    for (ids) |d| total += docs[d].len;

    const ncpu = std.Thread.getCpuCount() catch 1;
    var nthr = @max(@as(usize, 1), total / (512 * 1024));
    nthr = @min(nthr, ncpu);
    if (ids.len < par_threshold or nthr <= 1) {
        for (ids) |d| if (contains(docs[d], needle)) try out.append(gpa, d);
        return;
    }

    // Byte-greedy boundaries over the (arbitrary-order) candidate list.
    const bounds = try gpa.alloc(usize, nthr + 1);
    defer gpa.free(bounds);
    greedyBounds(u32, ids, docs, docWeight, total, bounds);

    const shards = try gpa.alloc(VerifyShard, nthr);
    defer gpa.free(shards);
    const threads = try gpa.alloc(std.Thread, nthr);
    defer gpa.free(threads);
    const outbuf = try gpa.alloc(u32, ids.len);
    defer gpa.free(outbuf);

    for (0..nthr) |t| {
        const lo = bounds[t];
        const hi = bounds[t + 1];
        shards[t] = .{ .docs = docs, .ids = ids[lo..hi], .needle = needle, .out = outbuf[lo..hi] };
    }
    fanOut(VerifyShard, shards, threads, verifyShard);
    for (0..nthr) |t| try out.appendSlice(gpa, shards[t].out[0..shards[t].n]);
}

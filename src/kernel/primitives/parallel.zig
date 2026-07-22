//! gist — the shared data-parallel sharding floor: byte-balanced work division
//! and the partial-spawn-safe fan-out both engines ride. Pure `std.Thread`
//! plumbing with no search, index, or corpus knowledge — the candidate verify
//! (`search/match/scan/verify.zig`), the trigram index build
//! (`index/trigrams/trigram.zig`), the relate sketch build, and the relate
//! attribution pass all divide their work through these three primitives
//! instead of five hand-rolled copies.

const std = @import("std");

/// Below this many total bytes of candidate work a sharded face stays SERIAL:
/// thread spawn + per-shard scratch (a recompiled engine, a span VM, an arena)
/// only amortizes once the scan itself dominates. One floor for every parallel
/// face — the warm fold/render/stream AND the cold match/emit — so small-corpus
/// answers never regress and the crossover lives in exactly one place.
pub const min_bytes: usize = 256 << 10;

/// Hard cap on shards — the realistic core ceiling, so a giant corpus doesn't
/// spawn hundreds of scheduler-thrashing threads.
pub const max_shards: usize = 16;

/// Byte-greedy shard boundaries over `items` (`bounds.len − 1` shards): each
/// shard takes ~equal total `weight`, not equal item count, so a few large
/// files can't stall one thread while the rest idle — the load-imbalance that
/// caps naive count-splitting. `total` is the summed weight of `items`.
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

/// The per-face parallel gate: byte-balanced shard boundaries for `items`
/// (`greedyBounds` into an arena-owned slice), or null when the work should stay
/// SERIAL — total `weight` below `min_bytes`, a single usable core, fewer than
/// two shards, or the bounds allocation failed (serial is always a correct
/// fallback). Every warm search face crosses into parallelism through this one
/// gate — the render emit, the `-l`/`-c` fold, and the FFI record stream — so the
/// floor discipline (thread-spawn + per-shard scratch only pays once the scan
/// dominates) lives in exactly one place instead of three inlined copies.
pub fn shardBounds(
    comptime T: type,
    items: []const T,
    ctx: anytype,
    comptime weight: fn (@TypeOf(ctx), T) usize,
    floor: usize,
    cap: usize,
    a: std.mem.Allocator,
) ?[]usize {
    var total: usize = 0;
    for (items) |item| total += weight(ctx, item);
    if (total < floor) return null;
    const cores = std.Thread.getCpuCount() catch 1;
    const nthr = @min(@min(cores, items.len), cap);
    if (nthr < 2) return null;
    const bounds = a.alloc(usize, nthr + 1) catch return null;
    greedyBounds(T, items, ctx, weight, total, bounds);
    return bounds;
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

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "greedyBounds: byte-balanced split isolates a heavy item" {
    // Byte-greedy (not count-greedy): the forward pass closes a shard once its
    // cumulative weight crosses the per-shard target, so a leading giant lands
    // alone while the light tail shares the next shard.
    const docs = [_][]const u8{ "x" ** 1000, "x", "x" };
    var bounds: [3]usize = undefined; // 2 shards
    greedyBounds([]const u8, &docs, {}, sliceLen, 1002, bounds[0..3]);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, &bounds);
    // Boundaries are always monotonic non-decreasing and cover every item.
    try testing.expectEqual(@as(usize, 0), bounds[0]);
    try testing.expectEqual(docs.len, bounds[2]);
    try testing.expect(bounds[0] <= bounds[1] and bounds[1] <= bounds[2]);
}

test "shardBounds: gates on the byte floor and returns balanced ranges" {
    const docs = [_][]const u8{ "x" ** 1000, "x", "x" };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Below the floor: serial (null), no allocation, no spawn.
    try testing.expect(shardBounds([]const u8, &docs, {}, sliceLen, 1 << 20, 16, a) == null);
    // Above the floor with ≥2 usable shards: balanced boundaries, heavy item alone.
    const cores = std.Thread.getCpuCount() catch 1;
    if (cores >= 2) {
        const bounds = shardBounds([]const u8, &docs, {}, sliceLen, 512, 2, a).?;
        try testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, bounds);
    }
}

test "fanOut: every shard runs even when no thread can spawn" {
    const Shard = struct {
        seen: bool = false,
        fn run(sh: *@This()) void {
            sh.seen = true;
        }
    };
    var shards = [_]Shard{ .{}, .{}, .{} };
    var threads: [3]std.Thread = undefined;
    fanOut(Shard, &shards, &threads, Shard.run);
    for (shards) |sh| try testing.expect(sh.seen);
}

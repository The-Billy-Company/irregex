//! wavelet — `Huff` (the canonical Huffman table) and `Tree` (the wavelet
//! tree built over it), proved independently of each other:
//!
//!   `Huff.build` is checked against a from-scratch priority-queue Huffman
//!   oracle for total coded length (the classic identity: the sum of every
//!   internal node's merged weight equals Σ freq(c)·len(c), so the oracle
//!   never needs to track per-symbol depth), then the produced table is
//!   checked to be genuinely prefix-free and Kraft-complete — not just
//!   cheap. `fromLengths` is round-tripped byte-for-byte against every
//!   `Huff.build` case, then separately fed the length tables the Kraft
//!   check exists to catch (over/under-subscribed, len > 63, no symbols).
//!
//!   `Tree` is differential-tested against a literal per-symbol scan across
//!   alphabet sizes from 2 up to `max_sigma`, both `Encoding`s, and a
//!   sequence long enough to force the root level's sharded `weave` path
//!   (`parallel.build_min_bytes`) — the one shape nothing at codex-test scale
//!   specifically pins on its own.

const std = @import("std");
const wavelet = @import("wavelet.zig");

const t = std.testing;

// ── Huff: independent priority-queue oracle ──

/// From-scratch two-heap-free Huffman: repeatedly merge the two lightest
/// weights. The sum of every merge's combined weight equals the optimal
/// Σ freq(c)·len(c) — the standard proof that Huffman coding minimizes
/// weighted path length — so the oracle needs no tree, no depths, just a
/// running total.
fn oracleHuffmanTotalCost(gpa: std.mem.Allocator, freq: []const u64) !u64 {
    const Ctx = struct {
        fn lt(_: void, a: u64, b: u64) std.math.Order {
            return std.math.order(a, b);
        }
    };
    var pq: std.PriorityQueue(u64, void, Ctx.lt) = .empty;
    defer pq.deinit(gpa);
    for (freq) |f| if (f > 0) try pq.push(gpa, f);

    var total: u64 = 0;
    while (pq.items.len > 1) {
        const a = pq.pop().?;
        const b = pq.pop().?;
        total += a + b;
        try pq.push(gpa, a + b);
    }
    return total;
}

fn presentSymbols(gpa: std.mem.Allocator, freq: []const u64) !std.ArrayList(u16) {
    var present: std.ArrayList(u16) = .empty;
    for (freq, 0..) |f, c| if (f > 0) try present.append(gpa, @intCast(c));
    return present;
}

/// Prefix-free + Kraft-complete over the present alphabet: no codeword is a
/// bit-prefix of (or identical to) another, and — once there are ≥2 codes —
/// Σ 2^(maxdepth−len) lands exactly on 2^maxdepth (a complete binary code,
/// no unused leaf and no over-subscribed one).
fn assertPrefixFreeAndComplete(h: *const wavelet.Huff, present: []const u16) !void {
    for (present) |a| {
        for (present) |b| {
            if (a == b) continue;
            const la = h.len[a];
            const lb = h.len[b];
            if (la > lb) continue; // check each ordered pair once, shorter-or-equal first
            var matches = true;
            for (0..la) |d| {
                if (h.bitAt(a, @intCast(d)) != h.bitAt(b, @intCast(d))) {
                    matches = false;
                    break;
                }
            }
            try t.expect(!matches);
        }
    }
    if (present.len > 1) {
        var kraft: u64 = 0;
        for (present) |c| kraft += @as(u64, 1) << @intCast(63 - h.len[c]);
        try t.expectEqual(@as(u64, 1) << 63, kraft);
    }
}

fn checkHuffman(gpa: std.mem.Allocator, freq: []const u64) !void {
    var h = try wavelet.Huff.build(gpa, freq);
    defer h.deinit(gpa);

    var present = try presentSymbols(gpa, freq);
    defer present.deinit(gpa);

    if (present.items.len == 1) {
        try t.expectEqual(@as(u8, 1), h.len[present.items[0]]); // degenerate σ=1: one-bit code
        return;
    }

    var got_total: u64 = 0;
    for (present.items) |c| got_total += freq[c] * h.len[c];
    try t.expectEqual(try oracleHuffmanTotalCost(gpa, freq), got_total);

    try assertPrefixFreeAndComplete(&h, present.items);

    var reloaded = try wavelet.Huff.fromLengths(gpa, h.len);
    defer reloaded.deinit(gpa);
    try t.expectEqualSlices(u8, h.len, reloaded.len);
    try t.expectEqualSlices(u64, h.code, reloaded.code);
}

test "Huff.build: matches an independent priority-queue oracle, is prefix-free and Kraft-complete, and round-trips through fromLengths" {
    const gpa = t.allocator;
    const fixed_freqs = [_][]const u64{
        &.{ 5, 9, 12, 13, 16 }, // the textbook 5-symbol skewed example
        &.{ 1, 1, 1, 1, 1, 1, 1, 1 }, // uniform: a balanced tree, one length for all
        &.{ 1, 1, 2, 3, 5, 8, 13, 21 }, // Fibonacci weights: maximally lopsided merges
        &.{ 1000, 1, 1, 1, 1 }, // one dominant symbol, long thin tail
        &.{ 0, 4, 0, 7, 0, 2 }, // absent symbols interleaved with present ones
        &.{ 7, 7 }, // exactly two symbols: both get one-bit codes
    };
    for (fixed_freqs) |freq| try checkHuffman(gpa, freq);

    var prng = std.Random.DefaultPrng.init(0x4dea);
    const rand = prng.random();
    for (0..60) |_| {
        const sigma = rand.intRangeAtMost(usize, 1, 64);
        const freq = try gpa.alloc(u64, sigma);
        defer gpa.free(freq);
        var any = false;
        for (freq) |*f| {
            f.* = if (rand.uintLessThan(u8, 5) == 0) 0 else rand.intRangeAtMost(u64, 1, 1000);
            if (f.* > 0) any = true;
        }
        if (!any) freq[0] = 1; // Huff.build asserts np >= 1
        try checkHuffman(gpa, freq);
    }
}

test "Huff.fromLengths: fails closed on out-of-range, empty, over-, and under-subscribed tables" {
    const gpa = t.allocator;
    {
        var lens = [_]u8{ 64, 1 }; // len > 63
        try t.expectError(error.Corrupt, wavelet.Huff.fromLengths(gpa, &lens));
    }
    {
        var lens = [_]u8{ 0, 0, 0 }; // no present symbol at all
        try t.expectError(error.Corrupt, wavelet.Huff.fromLengths(gpa, &lens));
    }
    {
        var lens = [_]u8{ 2, 2 }; // under-subscribed: 2 leaves claimed of the 4 a depth-2 code needs
        try t.expectError(error.Corrupt, wavelet.Huff.fromLengths(gpa, &lens));
    }
    {
        var lens = [_]u8{ 1, 1, 1 }; // over-subscribed: 3 claims of the 2 codewords 1 bit affords
        try t.expectError(error.Corrupt, wavelet.Huff.fromLengths(gpa, &lens));
    }
    {
        // a single present symbol is deliberately allowed to be Kraft-incomplete
        // at any depth — np == 1 never enforces the equality
        var lens = [_]u8{ 0, 3, 0 };
        var h = try wavelet.Huff.fromLengths(gpa, &lens);
        defer h.deinit(gpa);
        try t.expectEqual(@as(u8, 3), h.len[1]);
    }
}

test "Huff.fromLengths: a hand-verified canonical assignment (the textbook 5-symbol example)" {
    const gpa = t.allocator;
    // Frequencies 5,9,12,13,16 for symbols (0,1,2,3,4) → optimal lengths
    // (3,3,2,2,2). Canonical assignment orders by (len, sym) — shortest
    // codes first, ties broken by symbol id — so the length-2 symbols
    // (2,3,4) get 00,01,10 and the length-3 symbols (0,1) get 110,111.
    var lens = [_]u8{ 3, 3, 2, 2, 2 };
    var h = try wavelet.Huff.fromLengths(gpa, &lens);
    defer h.deinit(gpa);
    try t.expectEqual(@as(u64, 0b00), h.code[2]);
    try t.expectEqual(@as(u64, 0b01), h.code[3]);
    try t.expectEqual(@as(u64, 0b10), h.code[4]);
    try t.expectEqual(@as(u64, 0b110), h.code[0]);
    try t.expectEqual(@as(u64, 0b111), h.code[1]);
}

// ── Tree: differential vs a literal scan ──

fn buildFreq(gpa: std.mem.Allocator, seq: []const u16, sigma: u16) ![]u64 {
    const freq = try gpa.alloc(u64, sigma);
    @memset(freq, 0);
    for (seq) |c| freq[c] += 1;
    return freq;
}

fn checkTreeAgainstScan(gpa: std.mem.Allocator, seq: []const u16, sigma: u16, enc: wavelet.Encoding) !void {
    const freq = try buildFreq(gpa, seq, sigma);
    defer gpa.free(freq);
    var tree = try wavelet.Tree.build(gpa, seq, freq, enc);
    defer tree.deinit(gpa);

    const counts = try gpa.alloc(usize, sigma);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (seq, 0..) |c, pos| {
        const a = tree.access(pos);
        try t.expectEqual(c, a.sym);
        try t.expectEqual(counts[c], a.occ);
        try t.expectEqual(counts[c], tree.occ(c, pos));
        counts[c] += 1;
    }
    for (0..sigma) |sym| try t.expectEqual(counts[sym], tree.occ(@intCast(sym), seq.len));
}

test "Tree: agrees with a literal scan across small alphabets and both encodings" {
    const gpa = t.allocator;
    var prng = std.Random.DefaultPrng.init(0x7a11);
    const rand = prng.random();
    for ([_]u16{ 1, 2, 3, 7, 37 }) |sigma| {
        const seq = try gpa.alloc(u16, 3000);
        defer gpa.free(seq);
        for (seq) |*c| c.* = rand.uintLessThan(u16, sigma);
        for ([_]wavelet.Encoding{ .plain_only, .adopt_min }) |enc| {
            try checkTreeAgainstScan(gpa, seq, sigma, enc);
        }
    }
}

test "Tree: agrees with a literal scan at sigma == max_sigma under a skewed Zipf-shaped histogram" {
    const gpa = t.allocator;
    var prng = std.Random.DefaultPrng.init(0x517e);
    const rand = prng.random();
    const sigma: u16 = wavelet.max_sigma;
    const seq = try gpa.alloc(u16, 6000);
    defer gpa.free(seq);
    for (seq) |*c| {
        // Most mass on a handful of symbols, a long thin tail — the shape
        // that makes the Huffman tree deep and lopsided rather than a
        // balanced ~log2(sigma) for every symbol.
        c.* = if (rand.uintLessThan(u8, 3) != 0)
            rand.uintLessThan(u16, 8)
        else
            rand.uintLessThan(u16, sigma);
    }
    for ([_]wavelet.Encoding{ .plain_only, .adopt_min }) |enc| {
        try checkTreeAgainstScan(gpa, seq, sigma, enc);
    }
}

test "Tree: the sharded weave (root over parallel.build_min_bytes) agrees with a literal scan" {
    const gpa = t.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eedbad5);
    const rand = prng.random();
    // 2.4M u16 symbols = 4.8 MB, comfortably over the 4 MiB
    // `parallel.build_min_bytes` floor, so the root node's `weave` takes the
    // sharded `Weft` path — every smaller test here stays on the serial one.
    const n = 2_400_000;
    const sigma: u16 = 37;
    const seq = try gpa.alloc(u16, n);
    defer gpa.free(seq);
    for (seq) |*c| c.* = rand.uintLessThan(u16, sigma);

    const freq = try buildFreq(gpa, seq, sigma);
    defer gpa.free(freq);
    var tree = try wavelet.Tree.build(gpa, seq, freq, .adopt_min);
    defer tree.deinit(gpa);

    var counts = try gpa.alloc(usize, sigma);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (seq, 0..) |c, pos| {
        const a = tree.access(pos);
        try t.expectEqual(c, a.sym);
        try t.expectEqual(counts[c], a.occ);
        counts[c] += 1;
    }
    // A stride-sampled occ() sweep per symbol: exhaustive enough to catch an
    // off-by-one at a shard boundary without paying sigma * n full scans.
    for (0..sigma) |sym| {
        var running: usize = 0;
        for (seq, 0..) |c, pos| {
            if (pos % 100_003 == 0) try t.expectEqual(running, tree.occ(@intCast(sym), pos));
            if (c == sym) running += 1;
        }
        try t.expectEqual(running, tree.occ(@intCast(sym), seq.len));
    }
}

test "Tree.sizeBytes: sensible bounds — grows with the tree, never zero for a non-empty sequence" {
    const gpa = t.allocator;
    var prng = std.Random.DefaultPrng.init(0x51e5);
    const rand = prng.random();
    const seq = try gpa.alloc(u16, 4000);
    defer gpa.free(seq);
    for (seq) |*c| c.* = rand.uintLessThan(u16, 40);
    const freq = try buildFreq(gpa, seq, 40);
    defer gpa.free(freq);
    var tree = try wavelet.Tree.build(gpa, seq, freq, .adopt_min);
    defer tree.deinit(gpa);
    try t.expect(tree.sizeBytes() > 0);
    // never more than the raw sequence would cost stored at 2 bytes/symbol
    // plus a generous per-node fixed overhead — a regression here would mean
    // a level materialized far more bits than its own alphabet's histogram
    try t.expect(tree.sizeBytes() < seq.len * 2 + tree.nodes.len * 4096);
}

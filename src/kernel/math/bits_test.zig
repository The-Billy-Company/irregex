//! bits — differential proof of the two's-complement identities.
//!
//! Every operation is checked against a naive bit-at-a-time oracle over
//! random and adversarial words/sets (empty, full, single-bit, alternating,
//! word-boundary straddlers), at BOTH deployed widths (u64 engine masks,
//! u8 sais type maps), so the packed fast path can never drift from the
//! semantics a plain `[]bool` would have.

const std = @import("std");
const bits = @import("bits.zig");

const B64 = bits.Field(u64);
const B8 = bits.Field(u8);

test "ones: single-word iterator vs naive shift walk" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    const cases = [_]u64{ 0, 1, 1 << 63, std.math.maxInt(u64), 0xAAAA_AAAA_AAAA_AAAA, 0x8000_0000_0000_0001 };
    for (0..200) |round| {
        const x = if (round < cases.len) cases[round] else rand.int(u64);
        var it = bits.ones(x);
        for (0..64) |i| {
            if ((x >> @intCast(i)) & 1 == 1)
                try std.testing.expectEqual(@as(?u6, @intCast(i)), it.next());
        }
        try std.testing.expectEqual(@as(?u6, null), it.next());
    }
}

test "ones: u16 width (the SIMD mask shape)" {
    var it = bits.ones(@as(u16, 0b1000_0000_0000_0101));
    try std.testing.expectEqual(@as(?u4, 0), it.next());
    try std.testing.expectEqual(@as(?u4, 2), it.next());
    try std.testing.expectEqual(@as(?u4, 15), it.next());
    try std.testing.expectEqual(@as(?u4, null), it.next());
}

fn fieldDifferential(comptime Word: type, gpa: std.mem.Allocator, nbits: usize, seed: u64) !void {
    const F = bits.Field(Word);
    const oracle = try gpa.alloc(bool, nbits);
    defer gpa.free(oracle);
    @memset(oracle, false);
    const packed_bits = try gpa.alloc(Word, F.words(nbits));
    defer gpa.free(packed_bits);
    @memset(packed_bits, 0);

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    for (0..nbits * 4) |_| {
        const i = rand.uintLessThan(usize, nbits);
        if (rand.boolean()) {
            F.set(packed_bits, i);
            oracle[i] = true;
        } else {
            F.clear(packed_bits, i);
            oracle[i] = false;
        }
        // point query
        const j = rand.uintLessThan(usize, nbits);
        try std.testing.expectEqual(oracle[j], F.get(packed_bits, j));
    }
    // whole-set queries vs the oracle
    var want_count: usize = 0;
    var want_first: ?usize = null;
    for (oracle, 0..) |v, i| {
        if (v) {
            want_count += 1;
            if (want_first == null) want_first = i;
        }
    }
    try std.testing.expectEqual(want_count, F.count(packed_bits));
    try std.testing.expectEqual(want_first == null, F.none(packed_bits));
    try std.testing.expectEqual(want_first, F.first(packed_bits));
    // full iteration order
    var it = F.ones(packed_bits);
    for (oracle, 0..) |v, i| {
        if (v) try std.testing.expectEqual(@as(?usize, i), it.next());
    }
    try std.testing.expectEqual(@as(?usize, null), it.next());
}

test "Field(u64): differential vs bool-slice oracle across sizes" {
    const gpa = std.testing.allocator;
    // straddle word boundaries: sub-word, exact word, word+1, multi-word
    for ([_]usize{ 1, 7, 63, 64, 65, 200, 511 }) |n| {
        try fieldDifferential(u64, gpa, n, 0xF00D + n);
    }
}

test "Field(u8): differential at the sais Types width" {
    const gpa = std.testing.allocator;
    for ([_]usize{ 1, 8, 9, 100 }) |n| {
        try fieldDifferential(u8, gpa, n, 0xBEEF + n);
    }
}

test "Field: words() sizing exactly covers the index range" {
    try std.testing.expectEqual(@as(usize, 0), B64.words(0));
    try std.testing.expectEqual(@as(usize, 1), B64.words(1));
    try std.testing.expectEqual(@as(usize, 1), B64.words(64));
    try std.testing.expectEqual(@as(usize, 2), B64.words(65));
    try std.testing.expectEqual(@as(usize, 1), B8.words(8));
    try std.testing.expectEqual(@as(usize, 2), B8.words(9));
}

test "Field: empty slice is none, iterates nothing" {
    const empty: []const u64 = &.{};
    try std.testing.expect(B64.none(empty));
    try std.testing.expectEqual(@as(usize, 0), B64.count(empty));
    try std.testing.expectEqual(@as(?usize, null), B64.first(empty));
    var it = B64.ones(empty);
    try std.testing.expectEqual(@as(?usize, null), it.next());
}

test "prefixMask: every k including both UB-prone edges" {
    // oracle: k ones built one bit at a time
    var want: u64 = 0;
    try std.testing.expectEqual(want, bits.prefixMask(u64, 0));
    for (1..65) |k| {
        want = (want << 1) | 1;
        try std.testing.expectEqual(want, bits.prefixMask(u64, k));
    }
    try std.testing.expectEqual(@as(u8, 0), bits.prefixMask(u8, 0));
    try std.testing.expectEqual(@as(u8, 0xFF), bits.prefixMask(u8, 8));
    try std.testing.expectEqual(@as(u8, 0x07), bits.prefixMask(u8, 3));
}

test "rank: in-word rank1 vs naive bit walk" {
    var prng = std.Random.DefaultPrng.init(0xCAFE);
    const rand = prng.random();
    for (0..200) |_| {
        const w = rand.int(u64);
        var naive: usize = 0;
        for (0..65) |k| {
            try std.testing.expectEqual(naive, bits.rank(w, k));
            if (k < 64 and (w >> @intCast(k)) & 1 == 1) naive += 1;
        }
    }
}

fn setRangeDifferential(comptime Word: type, gpa: std.mem.Allocator, nbits: usize, seed: u64) !void {
    const F = bits.Field(Word);
    const oracle = try gpa.alloc(bool, nbits);
    defer gpa.free(oracle);
    const packed_bits = try gpa.alloc(Word, F.words(nbits));
    defer gpa.free(packed_bits);

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    for (0..300) |_| {
        @memset(oracle, false);
        @memset(packed_bits, 0);
        // several overlapping ranges per round, then compare every bit
        for (0..3) |_| {
            const a = rand.uintLessThan(usize, nbits);
            const b = rand.uintLessThan(usize, nbits);
            const lo = @min(a, b);
            const hi = @max(a, b);
            F.setRange(packed_bits, lo, hi);
            for (lo..hi + 1) |i| oracle[i] = true;
        }
        for (oracle, 0..) |v, i| try std.testing.expectEqual(v, F.get(packed_bits, i));
    }
    // degenerate + full-span edges
    @memset(packed_bits, 0);
    F.setRange(packed_bits, 0, nbits - 1);
    try std.testing.expectEqual(nbits, F.count(packed_bits));
    @memset(packed_bits, 0);
    F.setRange(packed_bits, nbits - 1, nbits - 1);
    try std.testing.expectEqual(@as(usize, 1), F.count(packed_bits));
    try std.testing.expectEqual(@as(?usize, nbits - 1), F.first(packed_bits));
}

test "Field.setRange: differential vs per-bit oracle at both widths" {
    const gpa = std.testing.allocator;
    for ([_]usize{ 1, 63, 64, 65, 256, 300 }) |n| {
        try setRangeDifferential(u64, gpa, n, 0xAB + n);
    }
    for ([_]usize{ 1, 8, 9, 100 }) |n| {
        try setRangeDifferential(u8, gpa, n, 0xCD + n);
    }
}

test "Stream: cursor decodes exactly what positioned reads see" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xF1E1D5);
    const rand = prng.random();
    inline for ([_]u7{ 3, 6, 7, 13 }) |f| {
        const n_fields = 200;
        // pack n_fields random f-bit values densely, +1 pad word (the stream
        // contract Stream documents)
        const total_bits = n_fields * @as(usize, f);
        const words = try gpa.alloc(u64, (total_bits + 63) / 64 + 1);
        defer gpa.free(words);
        @memset(words, 0);
        var want: [n_fields]u64 = undefined;
        for (&want, 0..) |*v, i| {
            v.* = rand.int(u64) & bits.prefixMask(u64, f);
            const pos = i * f;
            words[pos / 64] |= v.* << @intCast(pos % 64);
            if (pos % 64 + f > 64) words[pos / 64 + 1] |= v.* >> @intCast(64 - pos % 64);
        }
        // from the head, and from every possible start alignment
        for ([_]usize{ 0, 1, 2, 9, 10, 11, 63, 64, 100 }) |start| {
            if (start >= n_fields) continue;
            var cur = bits.Stream.init(words, start * f);
            for (want[start..]) |v| try std.testing.expectEqual(v, cur.take(f));
        }
    }
}

test "Stream: mixed-width takes fuse adjacent fields (the pair-gulp shape)" {
    // 8 six-bit fields; read them as 12-bit pairs and check v = lo | hi<<6.
    var words = [_]u64{ 0, 0 };
    const vals = [_]u64{ 5, 63, 0, 42, 17, 1, 60, 33 };
    for (vals, 0..) |v, i| {
        const pos = i * 6;
        words[pos / 64] |= v << @intCast(pos % 64);
        if (pos % 64 + 6 > 64) words[pos / 64 + 1] |= v >> @intCast(64 - pos % 64);
    }
    var cur = bits.Stream.init(&words, 0);
    var i: usize = 0;
    while (i < vals.len) : (i += 2) {
        try std.testing.expectEqual(vals[i] | (vals[i + 1] << 6), cur.take(12));
    }
    // and a fresh cursor mixing widths: one pair, one single, one pair
    var cur2 = bits.Stream.init(&words, 0);
    try std.testing.expectEqual(vals[0] | (vals[1] << 6), cur2.take(12));
    try std.testing.expectEqual(vals[2], cur2.take(6));
    try std.testing.expectEqual(vals[3] | (vals[4] << 6), cur2.take(12));
}

/// The inverse of `blockMask`: spread a 64-bit mask back over four 16-lane
/// boolean vectors, so a case can state the mask it expects and the input that
/// should produce it in one breath. Built through an array because a vector
/// lane cannot be indexed with a runtime value.
fn spreadLanes(m: u64) [4]@Vector(16, bool) {
    var out: [4]@Vector(16, bool) = undefined;
    for (&out, 0..) |*v, k| {
        var lane: [16]bool = undefined;
        for (&lane, 0..) |*b, i| b.* = m >> @intCast(k * 16 + i) & 1 != 0;
        v.* = lane;
    }
    return out;
}

test "blockMask: lane i of the block is bit i, on every arch" {
    // One lane at a time, so a per-chunk shift cannot be off by a chunk and a
    // reversed lane order cannot hide behind a symmetric pattern.
    for (0..64) |i| {
        const want = @as(u64, 1) << @intCast(i);
        try std.testing.expectEqual(want, bits.blockMask(spreadLanes(want)));
    }
    try std.testing.expectEqual(@as(u64, 0), bits.blockMask(spreadLanes(0)));
    try std.testing.expectEqual(std.math.maxInt(u64), bits.blockMask(spreadLanes(std.math.maxInt(u64))));

    var prng = std.Random.DefaultPrng.init(0xB10C_4A5C);
    const rng = prng.random();
    for (0..4096) |_| {
        const want = rng.int(u64);
        try std.testing.expectEqual(want, bits.blockMask(spreadLanes(want)));
    }
}

//! gist — adverse suite for the calibrating anchor selector.
//!
//! Every expectation here is derived from the CONTRACT, not from the module's
//! arithmetic: the survivor count a pair costs is recomputed by a scalar sliding
//! reference (`survivors` below), so a test can disagree with the kernel's
//! bitvector algebra rather than merely echo it. The three checks that carry
//! weight are the ones that could go the other way:
//!
//!   · a PLANTED oracle — a buffer built so that exactly one pair is
//!     structurally impossible to satisfy, so the right answer is known before
//!     the calibrator runs and there is no tie to hide behind;
//!   · the STRATIFICATION contrast — the same calibrator pointed at a
//!     heterogeneous buffer and at that buffer's own prefix, priced over the
//!     whole buffer. If prefix sampling were good enough, this test would fail;
//!   · the SIZE GATE at its exact boundary, in both directions, so "costs
//!     nothing below the threshold" is a property of the code and not of the
//!     prose.
//!
//! The anchor pair changes only WHICH filter runs — `simd.zig` always
//! `eql`-verifies survivors — so no assertion here is about match sets. An
//! out-of-bounds offset, on the other hand, is a read past the end of `hay` in
//! the block loop, which is why the invariant fuzz runs over deliberately
//! awkward needle lengths (past the offset cap) and buffer sizes.

const std = @import("std");
const calibrate = @import("calibrate.zig");

/// The block stride the kernel really uses. Passed in rather than re-derived
/// for the reason `calibrate.zig`'s doc records; the tests honour that too.
const block_bytes: usize = 64;

/// A sampling budget small enough that a test buffer stays in the hundreds of
/// kilobytes. Same window grain and cap as `calibrate.shipped`, so what is
/// under test is the geometry and the objective, not a different selector.
const small: calibrate.Config = .{
    .budget_bytes = 4 << 10,
    .window_bytes = calibrate.shipped.window_bytes,
    .max_offsets = calibrate.shipped.max_offsets,
};

/// Exact survivors for the pair `(i, j)`: candidate starts where both anchor
/// bytes match. The obvious scalar definition of the thing the kernel's
/// `popCount(B_i & B_j)` computes — an independent oracle, not a mirror.
fn survivors(hay: []const u8, needle: []const u8, i: usize, j: usize) usize {
    var n: usize = 0;
    var p: usize = 0;
    while (p + needle.len <= hay.len) : (p += 1)
        n += @intFromBool(hay[p + i] == needle[i] and hay[p + j] == needle[j]);
    return n;
}

const Cheapest = struct { pair: [2]usize, cost: usize, runner_up: usize };

/// The best pair that exists on this buffer, by exhaustive scalar search, plus
/// the second-best cost so a test can assert the answer is UNIQUE and therefore
/// independent of any tie-break policy.
fn cheapest(hay: []const u8, needle: []const u8) Cheapest {
    var out = Cheapest{ .pair = .{ 0, needle.len - 1 }, .cost = std.math.maxInt(usize), .runner_up = std.math.maxInt(usize) };
    for (0..needle.len) |i| for (i + 1..needle.len) |j| {
        const c = survivors(hay, needle, i, j);
        if (c < out.cost) {
            out.runner_up = out.cost;
            out.cost = c;
            out.pair = .{ i, j };
        } else if (c < out.runner_up) out.runner_up = c;
    };
    return out;
}

test "a returned pair is always in-bounds, ordered and distinct (randomised)" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xCA11B);
    const rng = prng.random();

    // Sized so the gate admits needles up to the offset cap: 16 x 16 x 4 KB.
    const hay = try gpa.alloc(u8, 16 * small.max_offsets * small.budget_bytes);
    defer gpa.free(hay);

    var ndl: [40]u8 = undefined;
    for (0..400) |t| {
        // Alternate a tiny alphabet (dense survivors, many ties at every pair)
        // with the full byte range (sparse, most pairs sample zero) — the two
        // ends of the signal spectrum the argmin has to survive.
        const narrow = t % 2 == 0;
        for (hay) |*b| b.* = if (narrow) 'a' + rng.uintLessThan(u8, 3) else rng.int(u8);
        // Lengths past `max_offsets` exercise the even-spaced preselection, and
        // 2 exercises the "nothing to decide" decline.
        const n = 2 + rng.uintLessThan(usize, ndl.len - 1);
        for (ndl[0..n]) |*b| b.* = if (narrow) 'a' + rng.uintLessThan(u8, 3) else rng.int(u8);
        const needle = ndl[0..n];
        // Buffer lengths straddling the gate, including the degenerate tails.
        const len = switch (t % 4) {
            0 => hay.len,
            1 => hay.len / 2 + rng.uintLessThan(usize, hay.len / 2),
            2 => rng.uintLessThan(usize, 4096),
            else => rng.uintLessThan(usize, hay.len),
        };
        const got = calibrate.tuned(small, hay[0..len], needle, block_bytes) orelse continue;
        try std.testing.expect(got[0] < got[1]);
        try std.testing.expect(got[1] < n);
        // Determinism: the same buffer and needle must price identically.
        try std.testing.expectEqual(got, calibrate.tuned(small, hay[0..len], needle, block_bytes).?);
    }
}

test "a 2-byte needle is declined — one pair is not a decision" {
    const gpa = std.testing.allocator;
    const hay = try gpa.alloc(u8, 8 << 20);
    defer gpa.free(hay);
    @memset(hay, 'x');
    try std.testing.expectEqual(@as(?[2]usize, null), calibrate.best(hay, "ab", block_bytes));
    try std.testing.expectEqual(@as(?[2]usize, null), calibrate.tuned(small, hay, "ab", block_bytes));
    // Three bytes is the shortest needle with a choice to make, and on a buffer
    // this size the shipped tuning does make it.
    try std.testing.expect(calibrate.best(hay, "abc", block_bytes) != null);
}

test "the size gate is structural: null below it, a pair at it" {
    const gpa = std.testing.allocator;
    // `k x budget x 16` for the shipped 64 KB budget at the shortest needle
    // that has a choice (k = 3) — the exact boundary, not a round number.
    const gate = 16 * 3 * calibrate.shipped.budget_bytes;
    const hay = try gpa.alloc(u8, gate);
    defer gpa.free(hay);
    var prng = std.Random.DefaultPrng.init(0x5A1E);
    for (hay) |*b| b.* = prng.random().int(u8);

    try std.testing.expectEqual(@as(?[2]usize, null), calibrate.best(hay[0 .. gate - 1], "abc", block_bytes));
    try std.testing.expect(calibrate.best(hay, "abc", block_bytes) != null);

    // The gate scales with the candidate count, so a longer needle needs a
    // proportionally larger buffer for the same budget — the 3-byte-needle
    // buffer above must be refused for a 6-byte one.
    try std.testing.expectEqual(@as(?[2]usize, null), calibrate.best(hay, "abcdef", block_bytes));

    // Same property at the small tuning, swept across every candidate count so
    // the boundary is a formula rather than one lucky point.
    inline for (.{ "abc", "abcd", "abcde", "abcdefgh" }) |needle| {
        const k = needle.len;
        const g = 16 * k * small.budget_bytes;
        try std.testing.expectEqual(@as(?[2]usize, null), calibrate.tuned(small, hay[0 .. g - 1], needle, block_bytes));
        try std.testing.expect(calibrate.tuned(small, hay[0..g], needle, block_bytes) != null);
    }
}

test "planted oracle: the calibrator finds the pair that cannot co-occur" {
    const gpa = std.testing.allocator;
    const needle = "abcd";
    const hay = try gpa.alloc(u8, 16 * needle.len * small.budget_bytes);
    defer gpa.free(hay);

    // Construction. `c` lands only on multiples of 16 and `d` only on 16k + 8,
    // so `hay[p+2] == 'c'` forces `p % 16 == 14`, which forces
    // `hay[p+3] == hay[16k+1] != 'd'`: the pair (2,3) has ZERO survivors by
    // arithmetic, not by luck. `b` is spaced 5 apart — coprime with 16 — so
    // every OTHER pair keeps a strictly positive count and the argmin is
    // unique. Without the coprime spacing the modular coincidences produce a
    // pile of zero-cost pairs and the test would only be exercising the
    // tie-break.
    for (hay, 0..) |*byte, i| byte.* = if (i % 16 == 0)
        'c'
    else if (i % 16 == 8)
        'd'
    else if (i % 5 == 1)
        'b'
    else
        'a';

    const truth = cheapest(hay, needle);
    try std.testing.expectEqual(@as(usize, 0), truth.cost); // the plant landed
    try std.testing.expect(truth.runner_up > 0); // and it is unique
    try std.testing.expectEqual([2]usize{ 2, 3 }, truth.pair);
    try std.testing.expectEqual(truth.pair, calibrate.tuned(small, hay, needle, block_bytes).?);

    // Second plant, the marginal shape: one needle byte never occurs at all, so
    // every pair touching its offset is globally free and the widest of those
    // is the answer the tie-break must produce.
    const absent = "abcQ";
    const got = calibrate.tuned(small, hay, absent, block_bytes).?;
    try std.testing.expectEqual(@as(usize, 0), survivors(hay, absent, got[0], got[1]));
    try std.testing.expectEqual([2]usize{ 0, 3 }, got);
}

test "stratified sampling survives a prefix that misdescribes the buffer" {
    const gpa = std.testing.allocator;
    const needle = "ABC";
    // The prefix the biased sampler sees must itself clear the gate, else the
    // comparison is against a decline rather than against a bad decision. One
    // gate's worth of head, twice that of tail.
    const head = 16 * needle.len * small.budget_bytes;
    const hay = try gpa.alloc(u8, head * 3);
    defer gpa.free(hay);

    var prng = std.Random.DefaultPrng.init(0xB1A5);
    const rng = prng.random();
    // Two regions whose orderings over the pairs are INVERTED. Head: 'C' is
    // half the bytes while 'A' and 'B' are 2% each, so (0,1) is by far the
    // cheapest pair here. Tail: no 'C' at all and 'A'/'B' at 45% each, so (0,1)
    // is by far the most expensive and both pairs touching offset 2 are free.
    // This is the mechanism of the measured heterogeneous result, not a
    // caricature of it — a base64 blob followed by code inverts exactly this
    // way (underscore absent from one, dominant in the other), and a prefix
    // sampler cannot see the inversion by construction.
    for (hay[0..head]) |*b| b.* = switch (rng.uintLessThan(u8, 100)) {
        0...49 => 'C',
        50 => 'A',
        51 => 'B',
        else => 'Z',
    };
    for (hay[head..]) |*b| b.* = switch (rng.uintLessThan(u8, 100)) {
        0...44 => 'A',
        45...89 => 'B',
        else => 'Z',
    };

    const strat = calibrate.tuned(small, hay, needle, block_bytes).?;
    const prefix = calibrate.tuned(small, hay[0..head], needle, block_bytes).?;

    // The premise: the head alone really does reach a different decision, and
    // that decision is locally CORRECT — the prefix sampler is not broken, it is
    // answering the wrong question. If either stops holding, the conclusion
    // below is vacuous and this test would be passing by accident.
    try std.testing.expect(!std.mem.eql(usize, &strat, &prefix));
    try std.testing.expect(survivors(hay[0..head], needle, prefix[0], prefix[1]) <
        survivors(hay[0..head], needle, strat[0], strat[1]));

    // The conclusion, priced over the WHOLE buffer — the only place the two
    // decisions can be compared honestly. Measured over 12 seeds the margin is
    // 77-85x and the stratified pick alternates between the two equally optimal
    // pairs, which is why the assertion is on COST and not on a pair: asserting
    // `0:2` would be asserting a tie-break, and would fail on half the seeds.
    const cost_strat = survivors(hay, needle, strat[0], strat[1]);
    const cost_prefix = survivors(hay, needle, prefix[0], prefix[1]);
    try std.testing.expect(cost_strat * 10 < cost_prefix);

    // And the stratified pick is the best pair that exists, or within reach.
    const truth = cheapest(hay, needle);
    try std.testing.expect(cost_strat <= truth.cost * 2);
}

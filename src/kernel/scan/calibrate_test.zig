//! irregex — adverse suite for the calibrating anchor selector.
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
/// for the reason `calibrate.zig`'s doc records; the tests honor that too.
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

test "a returned pair is always in-bounds, ordered and distinct (randomized)" {
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

// ---------------------------------------------------------------------------
// `refine` — calibration as an improvement test rather than an override.
//
// These are the tests the first wiring did not have, and the reason it shipped a
// tax: a survivor-count sweep asks "is the calibrated pair good?", which is the
// wrong question. The question is "is it enough BETTER than what the caller
// already holds to be worth swapping to?", and the answer is usually no.
// ---------------------------------------------------------------------------

test "refine: the incumbent is kept when nothing beats it" {
    const gpa = std.testing.allocator;
    const needle = "abcd";
    const hay = try gpa.alloc(u8, 16 * needle.len * small.budget_bytes);
    defer gpa.free(hay);

    // The planted oracle again: (2,3) has zero survivors by arithmetic.
    for (hay, 0..) |*byte, i| byte.* = if (i % 16 == 0)
        'c'
    else if (i % 16 == 8)
        'd'
    else if (i % 5 == 1)
        'b'
    else
        'a';

    // Holding the unbeatable pair, there is nothing to swap to. `best` still
    // names it, so this is a DECISION to decline and not a gate refusal — that
    // distinction is the whole point, and without the `best` line below this
    // assertion would pass just as happily on a buffer too small to sample.
    try std.testing.expectEqual([2]usize{ 2, 3 }, calibrate.tuned(small, hay, needle, block_bytes).?);
    try std.testing.expectEqual(
        @as(?[2]usize, null),
        calibrate.refineTuned(small, hay, needle, block_bytes, .{ 2, 3 }),
    );

    // Holding a bad pair, the swap is worth it — and the winner is the planted
    // one, priced by the scalar oracle rather than taken on the module's word.
    const got = calibrate.refineTuned(small, hay, needle, block_bytes, .{ 0, 1 }).?;
    try std.testing.expectEqual(@as(usize, 0), survivors(hay, needle, got[0], got[1]));
    try std.testing.expect(survivors(hay, needle, 0, 1) > 0);
}

test "refine: a buffer where no pair is better keeps the incumbent" {
    const gpa = std.testing.allocator;
    const needle = "abcd";
    // THE PRODUCTION REGIME, and the one the first wiring lost 0.5-1.1% CPU on.
    // Bytes drawn uniformly from exactly the needle's own alphabet, so every
    // pair's true survivor density is identical (1/16) and the only differences
    // in the sample are variance. A calibrator that swaps here is swapping on
    // noise, paying the sampling and forfeiting the single-probe shape for a
    // pair that is not better.
    //
    // Sized for the SHIPPED budget on purpose: at 65,536 sampled positions the
    // per-pair standard deviation is ~62 against a mean of 4,096 (1.5%), so the
    // spread across six pairs sits far inside the 12.5% margin. At the 4 KB test
    // budget it would be ~6% and this test would be a coin flip — the margin is
    // calibrated against the shipped sample size, so it must be tested there.
    const hay = try gpa.alloc(u8, 16 * needle.len * calibrate.shipped.budget_bytes);
    defer gpa.free(hay);
    var prng = std.Random.DefaultPrng.init(0xF1A7);
    for (hay) |*b| b.* = needle[prng.random().uintLessThan(usize, needle.len)];

    // The premise: the gate admits this buffer, so every decline below is a
    // judgment about the pairs and not a refusal to look at them.
    try std.testing.expect(calibrate.best(hay, needle, block_bytes) != null);

    // Every pair, as an incumbent, survives contact with the calibrator.
    for (0..needle.len) |i| for (i + 1..needle.len) |j| {
        try std.testing.expectEqual(
            @as(?[2]usize, null),
            calibrate.refine(hay, needle, block_bytes, .{ i, j }),
        );
    };
}

test "refine: an incumbent past the offset cap is priced, not ignored" {
    const gpa = std.testing.allocator;
    // 20 bytes, so `candidates` spreads 16 offsets over 20 and offsets 4, 9, 14
    // and 18 are NOT candidates. An incumbent there has to be PINNED into the
    // set or it cannot be priced at all — and a `refine` that silently declined
    // instead would look identical to one that judged the incumbent good.
    var needle: [20]u8 = @splat('a');
    needle[0] = 'c';
    needle[19] = 'd';
    const hay = try gpa.alloc(u8, 16 * calibrate.shipped.max_offsets * small.budget_bytes);
    defer gpa.free(hay);

    // `c` only on multiples of 16, `d` only on 16k+8. `hay[p] == 'c'` forces
    // `p % 16 == 0`, hence `(p + 19) % 16 == 3 != 8`, so the pair (0,19) has
    // ZERO survivors by arithmetic. Both its offsets are also pin-proof: the
    // nearest evictable neighbor of 4 is 3 and of 18 is 17.
    for (hay, 0..) |*byte, i| byte.* = if (i % 16 == 0)
        'c'
    else if (i % 16 == 8)
        'd'
    else if (i % 5 == 1)
        'b'
    else
        'a';

    // The premise: the incumbent really is expensive, so declining would be wrong.
    try std.testing.expect(survivors(hay, &needle, 4, 18) > 0);

    const got = calibrate.refineTuned(small, hay, &needle, block_bytes, .{ 4, 18 }).?;
    try std.testing.expectEqual(@as(usize, 0), survivors(hay, &needle, got[0], got[1]));
    try std.testing.expect(got[0] < got[1] and got[1] < needle.len);

    // And the same incumbent when it is the free pair: nothing beats zero.
    try std.testing.expectEqual(
        @as(?[2]usize, null),
        calibrate.refineTuned(small, hay, &needle, block_bytes, .{ 0, 19 }),
    );
}

test "refine: every swap is in-bounds, bounded in loss, and wins in aggregate" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x8E77E5);
    const rng = prng.random();

    // Sized for the largest candidate count at the small tuning, so needles both
    // under and over the cap clear the gate from one buffer.
    const hay = try gpa.alloc(u8, 16 * calibrate.shipped.max_offsets * small.budget_bytes);
    defer gpa.free(hay);

    // What a SAMPLED selector can and cannot promise, stated as the module head
    // states it: not "never loses" — an estimator that read the whole buffer to
    // guarantee that would cost more than the scan it is optimizing — but
    // "losses are immaterial and the aggregate improves". This suite is what
    // holds the margin to that, and it is where the winner's-curse defect
    // recorded at `noise_sigmas` was caught: with a purely relative margin the
    // per-trial bound below failed on the second trial.
    var total_before: usize = 0;
    var total_after: usize = 0;
    var swaps: usize = 0;

    for (0..24) |trial| {
        // A SKEWED alphabet, so pairs genuinely differ and there is a real win to
        // find — the aggregate assertion is vacuous on a uniform buffer where
        // every pair is equally good. Skew is also the realistic case: no text
        // has a flat byte distribution, which is the whole premise of the module.
        for (hay) |*b| b.* = 'a' + switch (rng.uintLessThan(u8, 16)) {
            0...7 => @as(u8, 0), // half the buffer is one byte
            8...11 => 1,
            12...13 => 2,
            14 => 3,
            else => 4 + rng.uintLessThan(u8, 4),
        };

        var buf: [40]u8 = undefined;
        const len = 3 + rng.uintLessThan(usize, buf.len - 2);
        const n = buf[0..len];
        for (n) |*b| b.* = 'a' + rng.uintLessThan(u8, 8);

        // An arbitrary incumbent, including deliberately awkward ones: adjacent
        // offsets, the extremes, and offsets the candidate spread omits.
        const i = rng.uintLessThan(usize, len - 1);
        const j = i + 1 + rng.uintLessThan(usize, len - i - 1);

        const got = calibrate.refineTuned(small, hay, n, block_bytes, .{ i, j }) orelse continue;
        try std.testing.expect(got[0] < got[1]);
        try std.testing.expect(got[1] < len);

        const before = survivors(hay, n, i, j);
        const after = survivors(hay, n, got[0], got[1]);
        swaps += 1;
        total_before += before;
        total_after += after;

        // Per trial: a loss is allowed, an ARBITRARY loss is not. 5% bounds the
        // sampling variance that survives the margin; a systematically inverted
        // objective would blow straight through it.
        std.testing.expect(after <= before + before / 20) catch |e| {
            std.debug.print("trial {d}: needle {s} incumbent {d}:{d} ({d}) -> {d}:{d} ({d})\n", .{ trial, n, i, j, before, got[0], got[1], after });
            return e;
        };
    }

    // The premise: the margin did not simply refuse everything, which would make
    // both assertions above free.
    try std.testing.expect(swaps > 0);
    // And the aggregate — the thing the scan actually pays — improves.
    try std.testing.expect(total_after < total_before);
}

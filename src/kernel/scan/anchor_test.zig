//! irregex — the anchor decision's regression guards.
//!
//! These exist because the defect they cover was invisible to every benchmark
//! that could have caught it (`research/pincer/`, PROOF.md §10.2). The two
//! repairs — a density table with real dynamic range, and a tie-break that
//! resolves toward separation — are REDUNDANT: either alone holds most of the
//! win. So losing one of them does not produce a throughput cliff; the survivor
//! absorbs it and the trap/control ratio stays plausible. A perf number
//! structurally cannot distinguish one repair from two, which is why both are
//! asserted here as STRUCTURE instead.

const std = @import("std");
const anchor = @import("anchor.zig");
const rarity = @import("rarity.zig");
const simd = @import("simd.zig");
const t = std.testing;

// ── guard 1: the tie-break ────────────────────────────────────────────────────

test "anchor: the separation tie-break displaces its initialisers" {
    // The half of the collapse that lived in the COMPARISON. Under a strict `<`
    // the first pair `select` prices is (0,1), and an equal-cost pair can never
    // displace it — so every all-tied needle returned the adjacent pair, the
    // maximally correlated choice and the one case where a two-byte conjunction
    // buys almost nothing over a single byte.
    //
    // `QQQQQQQQ` is the witness, and the choice of byte is load-bearing. Every
    // offset ties on the marginal, AND the fitted digraph term for `QQ` is flat
    // across gaps, so every candidate pair genuinely costs the same and the
    // tie-break is the ONLY key left. `candidates` offsets are held (ties keeping
    // the earlier), so the widest available pair is (0, candidates-1).
    //
    // A repeated LOWERCASE byte does not qualify, and that is not a defect:
    // measured, `select("aaaaaaaa")` returns gap 1 on purpose, because `aa` is
    // rarer in this corpus than P(a)² predicts and the lift term says so. Pinning
    // "gap > 1" for those would encode the pre-lift contract and fight the model.
    const p = anchor.select("QQQQQQQQ");
    try t.expectEqual(@as(usize, 0), @min(p.probe, p.confirm));
    try t.expect(@max(p.probe, p.confirm) - @min(p.probe, p.confirm) > 1);
}

test "anchor: needles with a genuinely separated best pair keep it" {
    // The population symptom, pinned on named cases. Under the defect these all
    // returned (0,1); measured today they separate widely. Over the 177-needle
    // code slate the adjacent-pair rate is 34% — it is not zero, because an
    // adjacent pair is sometimes correct — so this asserts specific needles the
    // model has a strong opinion about rather than a corpus-wide rate that would
    // drift with any honest re-fit.
    const expect_wide = [_]struct { needle: []const u8, min_gap: usize }{
        .{ .needle = "_context", .min_gap = 4 },
        .{ .needle = "bot_id", .min_gap = 4 },
        .{ .needle = "FileSummary", .min_gap = 4 },
        .{ .needle = "METRIC_UNITS", .min_gap = 5 },
        .{ .needle = "ListTracesReques", .min_gap = 8 },
        .{ .needle = "circuit_breaker", .min_gap = 6 },
    };
    for (expect_wide) |c| {
        const p = anchor.select(c.needle);
        const gap = @max(p.probe, p.confirm) - @min(p.probe, p.confirm);
        try t.expect(gap >= c.min_gap);
    }
}

// ── guard 2: the table's dynamic range ───────────────────────────────────────

test "rarity: the density table is not saturated" {
    // The clamp's signature: many cells pinned to the type's ceiling, which makes
    // distinct byte frequencies indistinguishable and hands the decision to
    // whatever the tie-break happens to do. At `u8`/x32768 THIRTY printable cells
    // sat at 255, twenty of them lowercase letters.
    //
    // The space is legitimately the densest byte in any text corpus, so exactly
    // one cell is allowed at the ceiling. More than that is a re-clamped table.
    const ceiling = std.math.maxInt(@TypeOf(rarity.density[0]));
    var at_ceiling: usize = 0;
    for (rarity.density) |d| if (d == ceiling) {
        at_ceiling += 1;
    };
    try t.expect(at_ceiling <= 1);
}

test "rarity: lowercase letters are mutually distinguishable" {
    // The specific loss that caused the collapse: 20 of 26 lowercase letters
    // shared one value, so `select` could not prefer any letter over any other.
    // A code corpus separates them comfortably, so near-total distinctness is
    // the honest bar — this asserts the SIGNAL exists, not an exact census.
    var seen: [26]u16 = undefined;
    for ('a'..'z' + 1, 0..) |c, i| seen[i] = rarity.density[c];
    var collisions: usize = 0;
    for (0..26) |i| for (i + 1..26) |j| {
        if (seen[i] == seen[j]) collisions += 1;
    };
    try t.expect(collisions <= 2);
}

test "rarity: ordering separates the ranks the clamp flattened" {
    // Three ranks that MUST stay ordered: the space (densest), `_` (common in
    // code identifiers, and the trap — it sat at the same 255 as the space), and
    // `Q` (genuinely rare). Under the clamp the first two were equal.
    try t.expect(rarity.density['_'] < rarity.density[' ']);
    try t.expect(rarity.density['Q'] < rarity.density['_']);
    // The single-probe bar must sit inside the range, not above it: a threshold
    // above every cell admits everything, below every cell admits nothing.
    try t.expect(rarity.single_probe_max > rarity.density['Q']);
    try t.expect(rarity.single_probe_max < rarity.density[' ']);
}

// ── guard 3: the pair's own invariant ────────────────────────────────────────

test "anchor: the probe slot carries the rarer byte" {
    // `indexOfPos` enters the single-load shape on `probe`'s density alone, so a
    // pair sorted by OFFSET instead of by rarity silently prices the fast path on
    // the wrong byte. That regression was introduced and caught once already
    // (`anchor.zig`: "Never sort this pair").
    for ([_][]const u8{
        "AcmeStore", "acmepool", "context.Context", "SELECT", "buf.validate",
        "Zq9_x",     "aaaaaaaa", "})",              "impl",   "acmekernel",
    }) |needle| {
        const p = anchor.select(needle);
        try t.expect(p.probe != p.confirm);
        try t.expect(p.probe < needle.len and p.confirm < needle.len);
        try t.expect(anchor.score(needle[p.probe]) <= anchor.score(needle[p.confirm]));
    }
}

test "anchor: selection is a pure function of the bytes" {
    // A pair that depends on iteration incident rather than on the needle makes
    // every measurement above unreproducible.
    for ([_][]const u8{ "acmekernel", "aaaaaaaa", "Zq9_x", "the " }) |needle| {
        const a = anchor.select(needle);
        for (0..8) |_| {
            const b = anchor.select(needle);
            try t.expectEqual(a.probe, b.probe);
            try t.expectEqual(a.confirm, b.confirm);
        }
    }
}

// ── guard 4: the plan seam is a cost seam, never a semantic one ───────────────

test "plan: containsWith ≡ contains ≡ std.mem.indexOf" {
    // The plan hoist (`query.zig` prices the pair once per query instead of once
    // per line) is only sound if the pair cannot change the VERDICT — it selects
    // which two offsets the block filter compares, and `eql` decides the match.
    // Checked against std as the third opinion so a shared bug in both of this
    // package's paths still fails.
    const needles = [_][]const u8{ "ab", "ctx", "func", "acmepool", "AcmeStore", "aaaa", "})", "Zq9_x" };
    var prng: std.Random.DefaultPrng = .init(0x9E3779B97F4A7C15);
    const rnd = prng.random();

    var buf: [4096]u8 = undefined;
    for (0..64) |_| {
        // A tiny alphabet makes hits dense, which exercises the survivor-verify
        // path rather than the all-miss fast path.
        for (&buf) |*b| b.* = "abcZq9_ \n"[rnd.uintLessThan(usize, 9)];
        for (needles) |needle| {
            const plan = simd.planOf(needle);
            for ([_]usize{ 0, 1, 63, 64, 65, 500, 4000 }) |len| {
                if (len > buf.len) continue;
                const hay = buf[0..len];
                const want = std.mem.indexOf(u8, hay, needle);
                try t.expectEqual(want, simd.indexOfPos(hay, 0, needle));
                try t.expectEqual(want, simd.indexOfPosWith(hay, 0, needle, plan));
                try t.expectEqual(want != null, simd.containsWith(hay, needle, plan));
            }
        }
    }
}

test "plan: indexOfPosWith ≡ indexOfPos at every resume point" {
    // `collectSpans` walks a line by resuming at `from` after each match, so the
    // planned path has to agree with the unplanned one for EVERY `from`, not just
    // zero — an off-by-one in the wide-tier guard would only show up here.
    const hay = "ctx ctxctx  a ctx" ** 24;
    for ([_][]const u8{ "ctx", "ctxctx", "a ", "zz" }) |needle| {
        const plan = simd.planOf(needle);
        for (0..hay.len + 2) |from| {
            const want = if (from <= hay.len) std.mem.indexOfPos(u8, hay, from, needle) else null;
            try t.expectEqual(want, simd.indexOfPos(hay, from, needle));
            try t.expectEqual(want, simd.indexOfPosWith(hay, from, needle, plan));
        }
    }
}

test "plan: a Gate answers the same planned or unplanned" {
    // The plan lives IN the gate, so the gate is the seam that has to be proven a
    // cost decision and not a semantic one: `Gate.of` mints a plan, and a gate
    // built without one (what `<prefix>NO_PLAN` produces, and what a caseless or
    // 1-byte gate is) must give the identical verdict and the identical position.
    const needles = [_][]const u8{ "x", "ab", "ctx", "acmepool", "context.Context", "aaaa", "})" };
    var prng: std.Random.DefaultPrng = .init(0x5DEECE66D);
    const rnd = prng.random();
    var buf: [2048]u8 = undefined;
    for (0..48) |_| {
        for (&buf) |*b| b.* = "abcxt.C})\n "[rnd.uintLessThan(usize, 11)];
        for (needles) |needle| {
            const planned = simd.Gate.of(needle);
            const bare: simd.Gate = .{ .bytes = needle, .plan = null };
            for ([_]usize{ 0, 1, 17, 64, 65, 300, 2048 }) |len| {
                const hay = buf[0..len];
                const want = std.mem.indexOf(u8, hay, needle);
                try t.expectEqual(want != null, planned.in(hay));
                try t.expectEqual(want != null, bare.in(hay));
                try t.expectEqual(want, planned.find(hay, 0));
                try t.expectEqual(want, bare.find(hay, 0));
            }
        }
    }
}

test "plan: a degenerate needle survives the hoist" {
    // The needle class the anchor model has the least to say about: every byte
    // identical, so all fifteen candidate pairs tie and the separation tie-break
    // is what picks one. A hoisted plan reuses that ONE decision across every
    // haystack, so if the tie-break ever returned a pair the loop mishandled, the
    // per-call path could hide it while the hoisted path failed everywhere. Both
    // arms are checked against std over haystacks that are themselves degenerate.
    const needles = [_][]const u8{ "aa", "aaa", "aaaaaaaa", "QQQQQQQQ", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
    var buf: [512]u8 = undefined;
    for (needles) |needle| {
        const plan = simd.planOf(needle);
        for ([_]u8{ 'a', 'Q', 'b' }) |fill| {
            @memset(&buf, fill);
            // Plus the boundary shapes: a lone mismatch at the front, middle, end.
            for ([_]?usize{ null, 0, buf.len / 2, buf.len - 1 }) |spoil| {
                @memset(&buf, fill);
                if (spoil) |s| buf[s] = '~';
                for ([_]usize{ 0, 1, 2, 63, 64, 65, 127, 128, 511, 512 }) |len| {
                    const hay = buf[0..len];
                    const want = std.mem.indexOf(u8, hay, needle);
                    try t.expectEqual(want, simd.indexOfPos(hay, 0, needle));
                    try t.expectEqual(want, simd.indexOfPosWith(hay, 0, needle, plan));
                }
            }
        }
    }
}

test "plan: a needle the wide tier can never reach still agrees" {
    // The lazy guard added with the plan seam skips the anchor decision when
    // `hay.len < needle.len - 1 + block_bytes`. Every haystack here is inside
    // that region, so this is the path where the pair is never computed at all.
    var buf: [200]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0xDEADBEEF);
    const rnd = prng.random();
    for (0..256) |_| {
        for (&buf) |*b| b.* = "ab"[rnd.uintLessThan(usize, 2)];
        const len = rnd.uintLessThan(usize, 100) + 1;
        const hay = buf[0..len];
        for ([_][]const u8{ "ab", "aab", "abab" }) |needle| {
            const want = std.mem.indexOf(u8, hay, needle);
            try t.expectEqual(want, simd.indexOfPos(hay, 0, needle));
            try t.expectEqual(want, simd.indexOfPosWith(hay, 0, needle, simd.planOf(needle)));
        }
    }
}

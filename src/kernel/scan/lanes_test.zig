//! gist — the shuffle primitive's own differential: hardware against the
//! portable statement of it, on whichever architecture is running.
//!
//! Every other differential in this package holds a vector kernel to a scalar
//! oracle *through* `lanes.shuffle`, which proves whichever of the three arms
//! the host compiled and says nothing about the other two. A build takes
//! exactly one — NEON `tbl`, SSSE3 `pshufb`, or the portable gather — and
//! comptime-prunes the rest, so before this file the portable arm was reachable
//! from no test on no machine: CI runs macOS/aarch64 (NEON) and Linux/x86_64
//! native (SSSE3), and every shipped artifact declares a floor (`aarch64`
//! baseline, `x86_64_v2`) carrying one of the two instructions. The arm that a
//! from-source `-Dcpu=baseline`, a distro rebuild, or any target that is
//! neither NEON nor SSSE3 actually executes had never run.
//!
//! `shufflePortable` is compiled on every target, so holding the host's real
//! instruction to it pins all three arms to ONE statement with two CI hosts:
//! each asm arm is proved against the same shared reference.
//!
//! Three layers, and none is implied by another:
//!   1. **hardware ≡ portable** over the in-range domain — the differential
//!      proper, and the layer that catches a real arm bug.
//!   2. **an independent restatement ≡ both** — `model` below is a third
//!      implementation written here, not imported, and the three arms of it
//!      agree in range. That is the premise `shuffle`'s assert rests on,
//!      machine-checked rather than argued in a comment.
//!   3. **and they disagree above 15, exactly where documented** — so "these
//!      all do the same thing, drop the check" cannot pass review by being
//!      plausible.
//!
//! Layer 2 exists because layer 1 alone would repeat the mistake this file is
//! about. On a target that is neither NEON nor SSSE3, `shuffle` *is*
//! `shufflePortable`, so layer 1 degenerates to comparing a function with
//! itself — precisely the tautology the compose rung's own kernel differential
//! was running on every Linux CI job. `model` is the independent statement that
//! keeps every build honest about whichever arm it compiled.

const std = @import("std");
const lanes = @import("lanes.zig");

const Vec = lanes.Vec;

/// Each arm's index handling, written as data. Nothing ships against this — the
/// assert in `shuffle` forbids the domain where they differ — so it lives here
/// rather than in the module it describes.
///
/// Keyed on the permute class, which has four members against three behaviors:
/// `vpshufb` is `pshufb` in a VEX encoding and handles an index identically, so
/// the two share an arm here. They are separate classes because their COST
/// differs, which is a question for `ladder/price.zig` and not for semantics.
fn model(comptime isa: lanes.Isa, t: Vec, idx: Vec) Vec {
    var out: [16]u8 = undefined;
    const tt: [16]u8 = t;
    const ii: [16]u8 = idx;
    for (&out, ii) |*o, k| o.* = switch (isa) {
        .neon => if (k < 16) tt[k] else 0, // `tbl` zeroes every index ≥ 16
        .ssse3, .avx => if (k & 0x80 != 0) 0 else tt[k & 0x0F], // `pshufb` zeroes on bit 7
        .portable => tt[k & 0x0F], // masks, and never zeroes
    };
    return out;
}

/// Sixteen distinct bytes in a random order: distinct so that reading the wrong
/// lane cannot coincidentally produce the right byte, and permuted so the table
/// is not itself the identity the shuffle is being asked to compute.
fn distinctTable(r: std.Random) Vec {
    var t: [16]u8 = undefined;
    for (&t, 0..) |*c, i| c.* = @as(u8, @intCast(i)) *% 17 +% 3;
    r.shuffle(u8, &t);
    return t;
}

test "lanes: the host's shuffle instruction equals the portable statement of it" {
    var prng = std.Random.DefaultPrng.init(0x5A17_ED9E);
    const r = prng.random();
    var checked: usize = 0;

    // Pairwise-exhaustive placement: lane `p` takes value `v` against a fixed
    // in-range filler, for all 256 (p, v) pairs. A lane-indexing bug is a
    // permutation error, and a permutation error shows up here for certain.
    for (0..64) |trial| {
        const t = distinctTable(r);
        const filler: u8 = @intCast(trial % 16);
        for (0..16) |p| {
            for (0..16) |v| {
                var ix: [16]u8 = @splat(filler);
                ix[p] = @intCast(v);
                const idx: Vec = ix;
                try std.testing.expectEqual(lanes.shufflePortable(t, idx), lanes.shuffle(t, idx));
                checked += 1;
            }
        }
    }

    // …then whole random vectors, where every lane moves at once — the shape
    // pairwise placement cannot reach.
    for (0..20_000) |_| {
        const t = distinctTable(r);
        var ix: [16]u8 = undefined;
        for (&ix) |*k| k.* = r.uintLessThan(u8, 16);
        const idx: Vec = ix;
        try std.testing.expectEqual(lanes.shufflePortable(t, idx), lanes.shuffle(t, idx));
        checked += 1;
    }

    // The identity table states the whole contract in one line: shuffling by
    // `idx` through `t[i] = i` returns `idx` on any arm.
    var ident: [16]u8 = undefined;
    for (&ident, 0..) |*c, i| c.* = @intCast(i);
    for (0..16) |v| {
        const idx: Vec = @as([16]u8, @splat(@as(u8, @intCast(v))));
        try std.testing.expectEqual(idx, lanes.shuffle(ident, idx));
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 64 * 256 + 20_000 + 16), checked);
}

test "lanes: the three arms agree on every in-range index — the assert's premise" {
    // Why `shuffle` may assert `idx < 16` and then let the target pick any arm:
    // below 16 the three are one function. If this fails, the primitive has
    // stopped being portable and no amount of caller discipline rescues it.
    var prng = std.Random.DefaultPrng.init(0x3A_9C0FFE);
    const r = prng.random();
    for (0..50_000) |_| {
        const t = distinctTable(r);
        var ix: [16]u8 = undefined;
        for (&ix) |*k| k.* = r.uintLessThan(u8, 16);
        const idx: Vec = ix;
        const neon = model(.neon, t, idx);
        try std.testing.expectEqual(neon, model(.ssse3, t, idx));
        try std.testing.expectEqual(neon, model(.portable, t, idx));
        // Both production entrances against the independent statement, so this
        // layer stays a real differential on a build where they are one
        // function.
        try std.testing.expectEqual(neon, lanes.shuffle(t, idx));
        try std.testing.expectEqual(neon, lanes.shufflePortable(t, idx));
    }
}

test "lanes: the three arms disagree above 15, and exactly where documented" {
    // Both disagreements must be witnessed. A run that found neither would mean
    // the domain had been narrowed, not that the arms had converged.
    //
    // The table holds no zero byte, so a zeroed output lane is unambiguously the
    // instruction zeroing rather than a table read that landed on 0.
    var t: [16]u8 = undefined;
    for (&t, 0..) |*c, i| c.* = @as(u8, @intCast(i)) +% 1;
    const table: Vec = t;

    var tbl_zeroes_where_others_mask: usize = 0; // 0x10..0x7F
    var portable_reads_where_others_zero: usize = 0; // 0x80..0xFF

    var v: usize = 16;
    while (v < 256) : (v += 1) {
        const idx: Vec = @as([16]u8, @splat(@as(u8, @intCast(v))));
        const neon = model(.neon, table, idx);
        const ssse3 = model(.ssse3, table, idx);
        const portable = model(.portable, table, idx);

        try std.testing.expectEqual(@as(Vec, @splat(0)), neon);
        try std.testing.expectEqual(t[v & 0x0F], portable[0]);
        if (v < 0x80) {
            try std.testing.expectEqual(portable, ssse3);
            tbl_zeroes_where_others_mask += 1;
        } else {
            try std.testing.expectEqual(neon, ssse3);
            portable_reads_where_others_zero += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0x80 - 0x10), tbl_zeroes_where_others_mask);
    try std.testing.expectEqual(@as(usize, 0x100 - 0x80), portable_reads_where_others_zero);
}

test "lanes: the 32-lane pair shuffle equals the portable statement of it" {
    // NEON-only by construction — `shufflePair` is a compile error off it — so
    // this is the one layer a Linux run cannot check. It skips rather than
    // passing vacuously, and the guard is comptime so the asm stays out of an
    // x86 build's sight.
    if (comptime !lanes.armed(.lanes32)) return error.SkipZigTest;

    var prng = std.Random.DefaultPrng.init(0x32_1A4E5);
    const r = prng.random();
    for (0..20_000) |_| {
        var lo: [16]u8 = undefined;
        var hi: [16]u8 = undefined;
        for (&lo) |*c| c.* = r.int(u8);
        for (&hi) |*c| c.* = r.int(u8);
        var ix: [16]u8 = undefined;
        for (&ix) |*k| k.* = r.uintLessThan(u8, 32);
        const idx: Vec = ix;

        var want: [16]u8 = undefined;
        for (&want, ix) |*o, k| o.* = if (k < 16) lo[k] else hi[k - 16];
        try std.testing.expectEqual(@as(Vec, want), lanes.shufflePair(lo, hi, idx));
    }
}

test "lanes: the arming claim is exactly the instruction the shuffle compiled to" {
    // `widest` promises a width can run as a REAL vector kernel, and `isa` is
    // the independent record of what `shuffle` actually resolved to. Deriving
    // them separately and pinning them together is what stops a future arm from
    // claiming a width its instruction cannot serve — an AVX2 entry in `widest`
    // with no AVX2 arm in `shuffle` would arm the rung onto the scalar gather,
    // which is slower than the DFA the rung exists to beat and would show up as
    // a throughput regression rather than a failure.
    //
    // The 32-lane form is the asymmetry worth stating: neither `pshufb` nor its
    // VEX spelling has register-pair addressing at all, so both x86 classes top
    // out at sixteen. Reading that off the permute rather than off the
    // architecture is the whole repair — the predicate used to be one NEON bool,
    // and an SSE machine with `pshufb` in hand ran the 16-lane composition
    // through the oracle.
    try std.testing.expectEqual(switch (lanes.isa) {
        .neon => @as(?lanes.Width, .lanes32),
        .ssse3, .avx => .lanes16,
        .portable => null,
    }, lanes.widest);

    // Widths are nested, never disjoint: anything that can drive the pair
    // lookup can drive the single one. A build armed for 32 and not 16 would
    // send every small machine — the common case, and the one measured fastest
    // — down the scalar path while the wide ones flew.
    if (comptime lanes.armed(.lanes32)) try std.testing.expect(lanes.armed(.lanes16));
    if (comptime !lanes.armed(.lanes16)) try std.testing.expect(!lanes.armed(.lanes32));

    // And the dispatcher agrees with the claim. `run` picks `runNative` exactly
    // where `armed` says the kernel is real, so a table folded through it must
    // equal the scalar definition whichever branch this build took.
    var tbl: [256 * 16]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xA12E5);
    const r = prng.random();
    for (0..256) |row| {
        const cells = tbl[row * 16 ..][0..16];
        for (cells) |*c| c.* = r.uintLessThan(u8, 16);
        cells[15] = 15; // MATCH absorbs, the kernel's one precondition
    }
    var hay: [300]u8 = undefined;
    for (&hay) |*b| b.* = r.int(u8);
    try std.testing.expectEqual(
        lanes.reference(.lanes16, .byte, &hay, &tbl, 0, 15),
        lanes.run(.lanes16, .byte, &hay, &tbl, 0, 15),
    );
}

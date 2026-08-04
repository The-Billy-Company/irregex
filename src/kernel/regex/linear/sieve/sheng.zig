//! gist — the register-resident quotient kernel.
//!
//! A ≤16-state automaton needs no memory for its state. Hold the block id in
//! all sixteen lanes of a vector, keep the transition row for each byte in a
//! 4 KiB L1-resident table, and one `tbl` (NEON) / `pshufb` (SSSE3) advances
//! it: `state = row[byte][state]`. The row LOAD is indexed by the byte, which
//! the out-of-order engine has long before it needs it, so the loop-carried
//! dependency is the shuffle's ~2-cycle latency rather than the ~4-cycle
//! load-to-use of the table DFA's `trans[s + class[b]]` pointer chase. That is
//! the whole speed argument, and it is Langdale's Sheng (2018,
//! <https://branchfree.org/2018/05/25/say-hello-to-my-little-friend-sheng-a-small-but-fast-deterministic-finite-automaton/>,
//! shipped in Hyperscan) applied to an over-approximating quotient instead of
//! to an exact small DFA.
//!
//! Because every lane holds the same block id, the shuffle is self-broadcasting
//! — `tbl` gives every lane `row[state]` — and acceptance is one unsigned
//! compare against a splat threshold, since `quotient.induce` renumbers the
//! accepting blocks to the top. The kernel therefore answers "did any position
//! accept?" (one quotient) or "did any position see BOTH accept?" (two) with a
//! single vector OR accumulator and one horizontal reduce at the end.
//!
//! The kernel NEVER says a haystack matches. It says "no position could have"
//! or "don't know" — an over-approximation can refute, never confirm.
//!
//! The 16-wide shuffle itself is NOT written here. It is `compose/lanes.zig`'s
//! shared primitive — that file imports nothing but `std` and `builtin`
//! precisely so a sibling rung can take the instruction without taking the
//! rung — so the fourth copy of `tbl`/`pshufb` in this package does not exist.
//! Block ids are always in range (`quotient.induce` caps them at 16), which is
//! the in-range discipline that primitive asks of its callers.

const std = @import("std");
const builtin = @import("builtin");
const tbl = @import("../../../scan/lanes.zig");
const Quotient = @import("quotient.zig").Quotient;

const V16 = tbl.Vec;
const shuffle = tbl.shuffle;
const ones: V16 = @splat(0xFF);
const zeros: V16 = @splat(0);

/// Is this build's shuffle a real single-instruction table lookup? False on
/// targets where `lanes.shuffle` degrades to a scalar gather — the sieve is
/// still sound there, just not faster than the DFA it would front, so the
/// compile gate stands it down. Deliberately WIDER than `compose`'s own gate: that
/// gate needs the two-register `TBL` form only AArch64 has, while a quotient
/// needs one 16-lane lookup, which SSSE3 also does in one instruction.
///
/// Asked of the shuffle itself rather than re-derived from the architecture.
/// This used to read `switch (builtin.cpu.arch) { .aarch64, .aarch64_be,
/// .x86_64 => true, … }`, which is the same mistake `lanes.shuffle` and
/// `classrun.pshufb` each carry a paragraph warning against, one level up:
/// `pshufb` is SSSE3 and the x86_64 baseline is SSE2, so on a generic x86_64
/// build the predicate said "register-resident" while the kernel underneath it
/// was a sixteen-element scalar gather per byte — arming a pre-pass strictly
/// slower than the DFA it exists to skip. `isa-floor` gates the `asm` blocks
/// but cannot see a boolean derived from the wrong question, so the boolean
/// names its dependency instead of guessing at it.
pub const resident = tbl.isa != .portable;

inline fn accepts(state: V16, th: V16) V16 {
    return @select(u8, state >= th, ones, zeros);
}

/// Does any position of `hay` survive the single quotient `q` — i.e. is there a
/// byte after which the quotient sits in an accepting block? False is the
/// sieve's `.miss`: no match can end anywhere in `hay`.
pub fn survives1(q: *const Quotient, hay: []const u8) bool {
    return survivesFrom1(q, @splat(q.start), hay);
}

/// Does any position of `hay` survive BOTH quotients at once? This is the
/// conjunction proper — ∃ position where every conjunct accepts — not the
/// weaker "each accepted somewhere", so the two-quotient sieve is strictly more
/// selective than running the pair independently. The two `tbl` chains are
/// independent, so the second costs throughput rather than latency.
pub fn survives2(a: *const Quotient, b: *const Quotient, hay: []const u8) bool {
    return survivesFrom2(a, b, @splat(a.start), @splat(b.start), hay);
}

/// How many lines the whole-buffer scan advances at once. One `tbl` chain is
/// latency-bound at its ~2-cycle dependency, so a single stream leaves the
/// shuffle unit mostly idle; independent chains overlap that latency exactly as
/// `Dfa.docMatchDense` overlaps its dependent transition loads. Measured on
/// this corpus with one quotient: 1 lane 1.96 GB/s · 2 lanes 3.90 · **4 lanes
/// 5.11** · 8 lanes 3.54 — past four, the register file and the extra byte
/// streams cost more than the overlap buys. A two-quotient conjunction already
/// issues two chains and three ops per position per lane, so it reaches the
/// same ceiling at half the lanes and *loses* at four (measured 1.2 GB/s
/// against 1.9 for the plain pair).
fn laneCount(comptime n: usize) comptime_int {
    return if (n == 1) 4 else 2;
}

/// Where the lanes start. Each cut is snapped FORWARD to the byte after a
/// `\n`, which is the whole soundness argument for running them independently:
/// under the `nl_reset` license every state steps to `start` on `\n`, so a lane
/// beginning just past one reproduces the true continuous run from there. Null
/// when the buffer has too few newlines to split (long minified lines), or is
/// too short for the lockstep phase to outweigh the tails it leaves — the
/// caller runs the single chain instead.
fn split(comptime lanes: usize, doc: []const u8) ?[lanes + 1]usize {
    if (doc.len < lanes * 64) return null;
    var at: [lanes + 1]usize = undefined;
    at[0] = 0;
    at[lanes] = doc.len;
    const share = doc.len / lanes;
    for (1..lanes) |j| {
        const nl = std.mem.indexOfScalarPos(u8, doc, j * share, '\n') orelse return null;
        at[j] = nl + 1;
        if (at[j] <= at[j - 1] or at[j] >= doc.len) return null;
    }
    return at;
}

/// Does any position of a whole `\n`-bearing buffer survive the conjunction?
/// Requires the `nl_reset` license (`Sieve.doc_ok`); the per-line entry points
/// above carry no such requirement.
pub fn survivesDoc(qs: []const Quotient, doc: []const u8) bool {
    return if (qs.len == 1) docLanes(1, qs, doc) else docLanes(2, qs, doc);
}

/// Would `survivesDoc` actually take its multi-lane path over this buffer, or
/// fall through to the single chain?
///
/// The lane split is silent by design — too few newlines or too short a buffer
/// and the kernel simply runs `survives1`/`survives2` instead, which is the
/// right behavior and an invisible one. A differential over buffers that all
/// fell through would report thousands of agreeing cases while never executing
/// the burst lockstep, the per-lane accumulators, or the tails at all. The test
/// asks the kernel rather than re-deriving the threshold, so the two cannot
/// drift into a corpus that covers nothing.
pub fn lanesEngaged(qs: []const Quotient, doc: []const u8) bool {
    return if (qs.len == 1)
        split(laneCount(1), doc) != null
    else
        split(laneCount(2), doc) != null;
}

fn docLanes(comptime n: usize, qs: []const Quotient, doc: []const u8) bool {
    const lanes = comptime laneCount(n);
    const cut = split(lanes, doc) orelse
        return if (n == 1) survives1(&qs[0], doc) else survives2(&qs[0], &qs[1], doc);

    var th: [n]V16 = undefined;
    var s: [lanes][n]V16 = undefined;
    inline for (0..n) |c| th[c] = @splat(qs[c].th);
    inline for (0..lanes) |j| inline for (0..n) |c| {
        s[j][c] = @splat(qs[c].start);
    };
    var seen: [lanes]V16 = @splat(zeros);

    var burst: usize = std.math.maxInt(usize);
    inline for (0..lanes) |j| burst = @min(burst, cut[j + 1] - cut[j]);

    // Per-lane accumulators, folded once at the end: a shared accumulator would
    // chain the lanes back together through its own dependency and give back
    // every cycle the split just bought.
    for (0..burst) |i| {
        inline for (0..lanes) |j| inline for (0..n) |c| {
            s[j][c] = shuffle(qs[c].rows[doc[cut[j] + i]], s[j][c]);
        };
        inline for (0..lanes) |j| {
            if (n == 1) {
                seen[j] = @max(seen[j], s[j][0]);
            } else {
                var all = accepts(s[j][0], th[0]);
                inline for (1..n) |c| all &= accepts(s[j][c], th[c]);
                seen[j] |= all;
            }
        }
    }
    inline for (0..lanes) |j| {
        const hit = if (n == 1) @reduce(.Max, seen[j]) >= qs[0].th else @reduce(.Max, seen[j]) != 0;
        if (hit) return true;
    }

    // Tails: the lanes ran in lockstep to the shortest one, so each finishes
    // its own remainder from the state it reached.
    inline for (0..lanes) |j| {
        const rest = doc[cut[j] + burst .. cut[j + 1]];
        const hit = if (n == 1)
            survivesFrom1(&qs[0], s[j][0], rest)
        else
            survivesFrom2(&qs[0], &qs[1], s[j][0], s[j][1], rest);
        if (hit) return true;
    }
    return false;
}

/// `@max` is one throughput op off the critical chain and, because `induce`
/// renumbers the accepting blocks to the top, the running maximum reaching `th`
/// is exactly "some position accepted" — no compare in the loop at all.
fn survivesFrom1(q: *const Quotient, start: V16, hay: []const u8) bool {
    var s = start;
    var seen: V16 = zeros;
    for (hay) |b| {
        s = shuffle(q.rows[b], s);
        seen = @max(seen, s);
    }
    return @reduce(.Max, seen) >= q.th;
}

fn survivesFrom2(a: *const Quotient, b: *const Quotient, sa0: V16, sb0: V16, hay: []const u8) bool {
    var sa = sa0;
    var sb = sb0;
    const th_a: V16 = @splat(a.th);
    const th_b: V16 = @splat(b.th);
    var seen: V16 = zeros;
    for (hay) |c| {
        sa = shuffle(a.rows[c], sa);
        sb = shuffle(b.rows[c], sb);
        seen |= accepts(sa, th_a) & accepts(sb, th_b);
    }
    return @reduce(.Max, seen) != 0;
}

/// The scalar transcription both kernels above must agree with, position for
/// position. Not a fallback path — `survives1`/`survives2` are correct on every
/// target — but the oracle the differential test compares against, and the form
/// the bench uses to attribute per-position selectivity.
pub fn survivesScalar(qs: []const Quotient, hay: []const u8) bool {
    var st: [4]u8 = undefined;
    for (qs, 0..) |*q, i| st[i] = q.start;
    for (hay) |b| {
        var all = true;
        for (qs, 0..) |*q, i| {
            st[i] = q.rows[b][st[i]];
            all = all and st[i] >= q.th;
        }
        if (all) return true;
    }
    return false;
}

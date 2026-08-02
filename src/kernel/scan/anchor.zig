//! gist — the anchor decision for the two-probe literal block filter.
//!
//! `simd.zig::indexOfPos` filters 64-byte blocks on the conjunction of two byte
//! equalities at needle offsets `(probe, confirm)`. That choice, and nothing
//! else, decides the filter's two variable costs: how many blocks survive the
//! cheap `anyLane` gate, and how many lane positions survive the conjunction
//! and pay an `eql`. Everything else per block is fixed. So the choice is worth
//! its own module — and worth being the ONLY place the decision is made, so a
//! benchmark, a control, or a second engine cannot re-derive a different filter
//! and believe it is measuring this one.
//!
//! ## RECORDED DEFECT (2026-07-29) — the two-byte conjunction assumed independence
//!
//! The selection this module replaces ranked bytes by their INDIVIDUAL corpus
//! density and took the two rarest. A conjunction's real selectivity is
//! `P(a at i ∧ b at i+d)`; ranking marginals prices it as `P(a)·P(b)`, i.e.
//! assumes the two probes are independent draws. Text is the worst case for
//! that assumption — the correlated unit is the WORD, so byte correlation peaks
//! at exactly the short distances a needle offers. The digraph `st` in code or
//! `th` in prose occurs far more often than the marginal product predicts, so a
//! marginal-minimizing selector drifts toward correlated pairs and the
//! conjunction degenerates toward a single-byte filter.
//!
//! ## RECORDED DEFECT (2026-07-29) — a saturating table turned that drift into a collapse
//!
//! `rarity.zig` stored density as `min(255, P·32768)`. Twenty of twenty-six
//! lowercase letters saturated at 255, so for a lowercase identifier EVERY byte
//! tied. The old selector broke ties with a strict `<`, which never displaces
//! its initialisers, so it returned `probe = 0, confirm = 1` — the ADJACENT
//! pair, the single most-correlated choice available and the one case where a
//! two-byte conjunction buys almost nothing over one byte. Measured: that fired
//! on 122 of 177 code needles and 78 of 90 prose needles, which made the
//! "rarest two bytes" selector WORSE than the fixed first+last it replaced, in
//! both regimes, on every summary statistic (4.61× and 6.97× the survivors of
//! the best available pair, against first+last's 3.04× and 3.35×).
//!
//! Wall clock on Apple M4, anchor pair as the only variable: 18.1 GB/s → 35.5
//! GB/s on code and 13.1 → 33.4 GB/s on prose. Worst individual needles ran at
//! 2.4–4.6 GB/s — at or below the plain `memchr` baseline, while holding a
//! 64-byte-per-iteration vector filter. Confirmed in the shipped binary without
//! a patch: `stepSec` (7 bytes, 464 true hits) ran 41% SLOWER than `pgxpool`
//! (7 bytes, 8,856 true hits) — more real work, less time, because the pair
//! `pg` is a rare digraph and `st` is not.
//!
//! ## Two lessons that must not be relearned
//!
//! 1. **Any table feeding this decision must keep its ORDERING intact.** The old
//!    module doc said "only the coarse ordering matters; exact counts don't" —
//!    true, and precisely why the clamp was fatal: it destroyed the ordering it
//!    claimed to preserve. A saturating cell is not a small inaccuracy here, it
//!    is a tie, and a tie hands the decision to the fallback.
//! 2. **The fallback must never be the adjacent pair.** Ties are genuinely
//!    uninformative, so they are broken on the one structural axis known to
//!    reduce correlation without any model: SEPARATION. This is the same move
//!    zoekt makes when it prefers non-overlapping trigrams because overlapping
//!    ones intersect worse than their marginals predict.
//!
//! Prior art, so the credit sits next to the code: the marginal heuristic is the
//! Rust `memchr` crate's (whose author guarded the one degenerate case he
//! foresaw — identical byte VALUES — with a structural `index1 != index2`, but
//! carried no distance term). Richard Startin published this exact failure mode
//! in 2018 with real-corpus bigram matrices, and stopped at a fixed `0:1` pair.
//! Choosing filter positions against an empirically-estimated correlated
//! background rather than an independence assumption goes back to
//! Buhler–Keich–Sun (2003) in spaced-seed design. Full review and the measured
//! evidence: `research/pincer/`.
//!
//! ## The pair-aware policy that replaced the marginal one (2026-07-29)
//!
//! Marginals-plus-widest-tie repairs the collapse without fixing the pricing error
//! under it: it still prices a conjunction as `P(a)·P(b)` and merely refuses to be
//! maximally wrong. Measured against the best pair available per needle (the
//! "oracle"), on corpora and needle slates disjoint from everything fitted here,
//! with the marginal read through the real `rarity.density` — so these are the
//! shipped code's numbers, not a model's. 1.00x is optimal:
//!
//! | selector                                      | code   | prose  | size   |
//! |-----------------------------------------------|--------|--------|--------|
//! | fixed first+last                              | 3.04x  | 3.36x  | —      |
//! | marginals, clamped table (the shipped defect) | 4.61x  | 6.97x  | 256 B  |
//! | marginals + widest tie, unclamped (BASELINE)  | 1.50x  | 2.21x  | 256 B  |
//! | **this policy — folded-alphabet joint**       | **1.13x** | **1.29x** | **4 KB** |
//! | exact-alphabet joint, same 4 gap planes       | 1.10x  | 1.25x  | 272 KB |
//!
//! 4 KB buys ~93% of what 272 KB of exact bytes buys, cutting surviving lane
//! positions to 0.76x (code) / 0.58x (prose) of the baseline's. The baseline row is
//! ranked on raw `score()`: that rule never quantizes, and quoting it through this
//! policy's fixed-point grid would flatter it by 0.08x (code) purely by merging
//! ties. Prose is the harder regime because `rarity.density` is fitted on the host
//! CODE tree, so its marginal is out of distribution there — hence baseline 2.21x
//! and the larger prose win. Refitting `rarity.zig` on mixed bytes would shrink
//! both; that module's call, not this one's.
//!
//! ### Wall clock — and why the MEAN is the wrong statistic for a filter
//!
//! Apple M4, `contains` over 213 MB of code / 134 MB of prose, anchor pair the only
//! variable, best-of-5 interleaved, all three pairs required to agree on the match
//! count (they did, on all 267 needles — an independent byte-exactness check):
//!
//! | GB/s, mean over needles | baseline | this policy | oracle |
//! |-------------------------|----------|-------------|--------|
//! | code                    | 39.0     | 40.4        | 41.5   |
//! | prose                   | 32.2     | 36.0        | 38.3   |
//! | code, slowest decile    | 14.0     | 20.0        | 20.9   |
//! | prose, slowest decile   | 11.0     | 19.7        | 21.9   |
//!
//! The means (+3.6% code, +11.8% prose) understate this badly: most needles contain
//! no bad pair to pick, so they dilute the average with a decision that could not
//! have gone wrong. The defect was a TAIL defect and so is its repair — +43% and
//! +80% on the slowest decile, and the worst needle in each regime (`'the '` at 6.5
//! GB/s, `'hates'` at 6.1, both of which the baseline anchors on `th`) goes to 10.7
//! and 13.7. Judge this policy on that decile.
//!
//! ### Why a FOLDED alphabet is the compaction that works
//!
//! `research/pincer/PROOF.md` §6 records two failed compactions — log-quantizing and
//! gap-windowing the joint — and concludes compaction loses. That is too strong:
//! **both shortened the GAP axis and neither touched the ALPHABET axis.** The
//! correlated unit is the concrete digraph (`th`, `qu`, `::`, `->`), so the
//! correction must keep BYTE IDENTITY for the bytes that form digraphs and only
//! those; frequency decides which. The 24 most frequent keep their own, every other
//! byte answers for its class — 32 symbols, past which the curve is flat:
//!
//! | symbols                     | table    | code      | prose     |
//! |-----------------------------|----------|-----------|-----------|
//! | 8 (class only, no identity) | 256 B    | 1.40x     | 2.03x     |
//! | 24                          | 2.3 KB   | 1.24x     | 1.60x     |
//! | **32**                      | **4 KB** | **1.13x** | **1.29x** |
//! | 40                          | 6.4 KB   | 1.12x     | 1.26x     |
//! | 264 (exact bytes)           | 272 KB   | 1.10x     | 1.25x     |
//!
//! Row one is the honest negative result for "just bucket bytes into character
//! classes": it closes 20% of the baseline's gap to the oracle on code and 15% on
//! prose, where this policy closes 74% and 76%. A class bucket cannot tell `qu` from
//! `qz`, and that distinction is nearly the whole win — the curve is carried by the
//! identity axis, not by resolution on the class axis. Ranking which 24 keep
//! identity by excess correlation mass rather than plain frequency was measured and
//! changed nothing; the simpler rule stands.
//!
//! ### Why gap truncation works here and failed in §6
//!
//! Four planes are stored and `d > 4` reads the `d = 4` plane. §6's truncation failed
//! because an unmodelled gap fell back to the independence product — a strictly
//! OPTIMISTIC price — so the argmin walked to exactly the pairs the model could not
//! vouch for. Here it is priced by the widest MODELED correction, so every candidate
//! is quoted on one scale and no cell is cheap by omission. That makes the axis nearly
//! free: 4 planes score 1.13x/1.29x where all 15 score 1.14x/1.28x, while 3 cliffs on
//! prose (1.65x) and 2 gives back nearly the whole prose win (2.01x) — prose
//! correlation reaches further than code's, so truncate, but not below four.
//!
//! ### What the numbers are, and the summaries that backfire
//!
//! `pmi` holds `log2(Σ joint / Σ independence)` per (symbol-pair, gap), sixteenths of
//! a bit, i8 — the count-preserving log-linear lift, fitted over 186 MB of TRAINING
//! bytes (every fifth repo text file plus half the prose corpus, held out by
//! construction rather than after the fact) and scored on the disjoint remainder
//! against a needle slate sharing no string with it. Regenerating it means re-running
//! that fit — census the training split for joint and independence counts per
//! (symbol-pair, gap), then render the lift into i8 sixteenths — rather than editing
//! the digits: the recipe is the contract. The fitting tools were a pre-production
//! harness and are not in this tree.
//!
//! How a bucket is summarized decides whether the table helps at all. `lift` (used)
//! scores 1.13x/1.29x; a mean log-residual over the same buckets scores 1.18x/1.38x
//! evidence-gated and 1.25x/1.38x expectation-weighted, because a mean is dominated by
//! the byte pairs that never co-occur — of which there are most at `d = 1`, so the
//! correction comes out NEGATIVE at short gaps, a BONUS for the adjacent pair: the
//! original bug wearing a model. Only a count-preserving summary is carried by the
//! frequent digraphs a filter has to avoid. An observed-count-weighted mean is the one
//! real rival (1.12x/1.28x, a hair ahead) but collapses to 1.19x/1.40x at 1/8 where
//! `lift` holds 1.13x/1.34x, so `lift` is kept for being resolution-independent.
//!
//! It must also be fitted on a MIXED corpus: code-only reaches 1.12x on code but
//! leaves prose at 1.69x, prose-only gets prose to 1.34x and hands back half the code
//! win (1.30x). A static table cannot know which regime a buffer is, so only the union
//! fit is a policy. The blend is not a knob to tune, but not because it does nothing:
//! re-running the census over actually-concatenated bytes at four code shares gives
//! geometric means of 1.29x (0.15), **1.21x (0.28, the natural union)**, 1.22x (0.50)
//! and 1.25x (0.65) — flat across the middle, worse at both ends, and the two regimes
//! TRADE inside the flat band (code 1.13x → 1.09x as prose goes 1.29x → 1.37x). The
//! rows are also unequal corpus sizes, so read that band as "no tuning available
//! here", not as a located optimum. Blending two censuses arithmetically instead of
//! concatenating bytes is NOT the same experiment and will mislead: independence is
//! quadratic in the unigram distribution, so summing two `indep` arrays drops the
//! cross terms and every weight scores an identical marginal-only 1.42x/2.20x.
//!
//! ### Cost: O(needle.len), one pass, no allocation, ≤ 15 pairs priced
//!
//! Pricing every pair is O(n²) and `contains` cannot afford it. Measured, it need not
//! be: candidates restricted to the SIX marginally-rarest offsets score 1.13x/1.29x
//! where unrestricted enumeration scores 1.14x/1.25x, and sweeping every short pair on
//! top buys nothing. The bound is slightly BETTER on code than full enumeration — a
//! wide pair between two common bytes can only win on a clamped row it has no evidence
//! for. K = 4 is too tight (1.16x/1.41x); prose alone would want K = 8 (1.25x) for
//! twice the pairs, not a trade this site should make. Per call, against the two-pass
//! marginal selector it replaces (M4, ReleaseFast, 12M calls):
//!
//! | needle len    | two-pass marginal | this policy | full O(n²) |
//! |---------------|-------------------|-------------|------------|
//! | 4–8 (typical) | 3.7 ns            | ~21 ns      | 9.2 ns     |
//! | 16            | ~11 ns            | ~32 ns      | 67 ns      |
//! | 64            | ~47 ns            | ~40 ns      | 1.2 µs     |
//! | 200           | ~160 ns           | ~98 ns      | 11.5 µs    |
//!
//! Digits are rounded because the run-to-run spread is ~3%; the ratios are stable.
//! **This is a real regression on short needles: +17 ns on the typical 4–8 byte
//! case.** It crosses over near 32 bytes and is strictly cheaper above, because one
//! candidate pass replaces two marginal passes and the pair count is capped; the
//! O(n²) column is why the cap exists. Whether +17 ns is worth paying depends on how
//! much haystack one `select` serves, and that differs by an order of magnitude
//! across the slate: on the tail needles it repays inside ~200–800 bytes (prose worst
//! ~190 B, prose decile ~430 B, code decile ~800 B), but on a mean needle it needs
//! ~5 KB of prose or ~19 KB of code, because there the pair was never the problem. So
//! `contains` on ONE short line is the adverse case — ~80 bytes cannot repay 17 ns,
//! and a caller that selects per line rather than once per needle will lose. This
//! module is a pure function of the needle precisely so the answer can be hoisted.
//!
//! ### Roads measured and closed
//!
//! - **Concrete-digraph exception lists over a class background** — list the cells
//!   that deviate most from their class and let the rest answer for the class. Needs
//!   160 KB (32,768 cells, 4 B key + 1 B value) to reach 1.14x/1.49x: forty times
//!   this table's memory to tie it on code and lose badly on prose. Excess
//!   correlation is not sparse enough to list. **The ranking is where the trap is**:
//!   by raw |error| the same 160 KB buys literally nothing (1.40x/2.03x — bit for bit
//!   the class background), because the largest errors sit in cells no needle ever
//!   queries, non-ASCII pairs whose joint count is zero. Only weighting error by
//!   evidence (`× log2(indep + 1)`) makes the list buy anything at all.
//! - **Smooth parametric gap penalties** (power-law and exponential decay in `d`, two
//!   fitted parameters) — no form beat baseline on code. Gap alone is not the signal:
//!   `pS` at `d = 1` is rare and `Sc` at `d = 2` common, so correlation is not
//!   monotone in separation.
//! - **Forcing first+last into the candidate set** — costs code 1.13x → 1.14x by
//!   displacing a rare offset; six distinct offsets already contain a wide pair.
//! - **Free parameters fitted by coordinate descent directly on measured survivors**
//!   — the objective is the true one and it STILL loses, worse as it gets freer:
//!   15 gap-only numbers reach 1.46x/2.41x held out (worse than baseline on prose);
//!   1,080 class-pair×gap reach 1.41x/1.97x; 30,720 byte×partner-class fit the
//!   training slate best of all (1.20x) and generalize worst of all (1.62x on code,
//!   worse than baseline). 267 needles cannot pin thousands of parameters. This table
//!   fits NOTHING to the objective — it estimates a corpus statistic and lets the
//!   argmin use it — which is exactly why it holds up off the slate it was scored on.
//! - **Forbidding `spread == 1` outright** — costs over half the win on code and a
//!   sixth on prose (1.13x/1.29x → 1.34x/1.41x). This was the tempting structural
//!   guarantee and it is the wrong one: the correction already refuses the adjacent
//!   pair wherever the corpus says to, and overriding it discards the cases where the
//!   corpus says the opposite. Adjacent is picked on 61 of 177 code needles and is
//!   oracle-optimal on most of them; `aa` really is rarer than `a?a`. **So `spread()
//!   > 1` is NOT an invariant of this policy** — only of the degenerate
//!   all-equal-marginal case, which is what `anchor_test.zig` guards.
//!
//! Finally, this needs `rarity.zig` to have real dynamic range: the marginal is
//! `log2` of what `score` returns, so under a clamp most lowercase letters tie and the
//! correction discriminates alone. That degrades gracefully — the tie falls to a
//! measured digraph statistic instead of to offset order — but the numbers above
//! assume the unclamped table and are not claimed for a clamped one.
const std = @import("std");
const rarity = @import("rarity.zig");

/// The two offsets a block filter compares.
///
/// `probe` carries the RARER of the two bytes, because the single-load fast path
/// gates on `probe` alone and only touches the confirm window inside probe-hit
/// blocks — gate on the commoner byte and that path is worthless. The offsets
/// are therefore NOT sorted: `confirm` may be numerically smaller than `probe`.
/// That is safe because the block loops bound their tail on `needle.len - 1`,
/// which dominates both offsets regardless of order.
///
/// RECORDED DEFECT (2026-07-29, caught pre-merge): an earlier draft of this
/// module sorted the pair by offset for tidiness. On `stepSec` that put the
/// common `s` in `probe` and the rare `S` in `confirm`, so `singleProbeWorthwhile`
/// read 255 instead of 45 and the needle silently lost the single-load loop —
/// a 1.42× throughput regression on precisely the needles that had earned it.
/// Rarity decides which slot a byte occupies here. Never sort this pair.
pub const Pair = struct {
    probe: usize,
    confirm: usize,

    /// Distance between the anchors, order-independent. A pair with
    /// `spread == 1` is the maximally-correlated choice — see the second
    /// recorded defect above.
    pub fn spread(self: Pair) usize {
        return if (self.confirm > self.probe)
            self.confirm - self.probe
        else
            self.probe - self.confirm;
    }
};

/// Rarity of one byte, widened out of the table's storage width so this module
/// is indifferent to how much dynamic range `rarity.zig` currently carries.
/// Lower is rarer. Read through this rather than indexing `density` directly:
/// it is the seam that let the table's range be widened without touching the
/// selection policy.
pub inline fn score(b: u8) u32 {
    return rarity.density[b];
}

/// How many of the marginally-rarest offsets are considered. Measured, not
/// chosen (code/prose ratios): 4 scores 1.16×/1.41×, 5 scores 1.13×/1.31×, 6
/// scores 1.13×/1.29×, and 8 and unbounded both score 1.14×/1.25× — six is where
/// the code curve flattens, and it caps the priced pairs at `6·5/2 = 15`.
const candidates = 6;

/// Gap planes stored. `d > gaps` reads the last plane — never independence; that
/// distinction is the whole difference from §6's truncation failure.
const gaps = 4;

/// Fixed-point resolution of every log quantity here: sixteenths of a bit.
/// Marginal and correction must share ONE additive scale or summing them is
/// meaningless. Measured against 1/8 and 1/32: identical on code, and 1/16 is
/// 4% better on prose (1.29x vs 1.34x) across every K and gap-plane variation,
/// so it is not tie-break noise. It saturates 92 of 4096 cells at -128, all of
/// them zero-joint pairs whose mutual ordering carries no information.
const log_scale = 16;

/// Character classes in the order the fitted table's symbol axis uses — the
/// classes text is built from, not a tuned partition. The collapse this module
/// repairs happens on same-class runs.
const class_count = 8;

fn classOf(b: u8) u8 {
    return switch (b) {
        '\t', '\n', '\r', ' ' => 0,
        'a'...'z' => 1,
        'A'...'Z' => 2,
        '0'...'9' => 3,
        '_' => 4,
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => 6,
        0x80...0xff => 7,
        else => 5, // remaining printable punctuation
    };
}

const symbols = identity.len + class_count;

/// Which symbol a byte contributes to the joint table: the `identity` bytes carry
/// their own, everything else answers for its class.
const fold: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (&t, 0..) |*e, b| e.* = identity.len + classOf(@intCast(b));
    for (identity, 0..) |b, s| t[b] = s;
    break :blk t;
};

/// The marginal on the correction's scale: `log_scale · log2(score(b) + 1)`.
/// Monotone in `score`, so it reproduces the baseline's ordering wherever the
/// correction is flat, and it is the only form addable to a log-lift. Built at
/// comptime from `score`, so widening `rarity.zig` rebuilds it.
const marginal: [256]u16 = blk: {
    @setEvalBranchQuota(4096);
    var t: [256]u16 = undefined;
    for (&t, 0..) |*e, b| {
        const v: f64 = @floatFromInt(score(@intCast(b)) + 1);
        e.* = @intFromFloat(@round(@log2(v) * @as(f64, log_scale)));
    }
    break :blk t;
};

/// The bytes that keep their own symbol, by measured unigram rank:
/// sp e t a o n i s d h r l y m u . c p w g f \n b ,
const identity = [_]u8{ 32, 101, 116, 97, 111, 110, 105, 115, 100, 104, 114, 108, 121, 109, 117, 46, 99, 112, 119, 103, 102, 10, 98, 44 };

/// Symbol axis order: the `identity` bytes above, then space, lower, upper, digit, under, punct, ctrl, hi128.
const pmi = [gaps][symbols][symbols]i8{
    .{ // d = 1
        .{ -10, -50, 15, 9, -19, -20, -8, 12, -9, 6, -21, -3, -21, 4, -16, -78, 13, 11, 30, 2, 24, -51, 30, -128, -128, -5, 22, -3, -27, 6, -126, -15 }, // sp
        .{ 12, -32, -12, -11, -67, 13, -42, 3, 25, -88, 26, 3, 14, -10, -85, 10, 4, -17, -13, -34, -14, -38, -53, 7, -128, 13, -37, -77, 7, -13, -128, -103 }, // e
        .{ 2, 2, -21, -15, 24, -125, 2, -18, -74, 44, 0, -13, -9, -82, -4, 8, -19, -51, -44, -94, -69, -43, -87, -3, -128, -65, -27, -29, 18, 2, -128, -62 }, // t
        .{ -15, -128, 8, -128, -128, 34, 2, 20, 5, -96, 20, 19, 30, 19, -9, -36, 15, 14, 6, 7, -22, -76, 1, -52, -128, 16, -95, -61, -37, -53, -128, -128 }, // a
        .{ -5, -78, 1, -48, 5, 21, -33, -24, -13, -65, 20, 0, 1, 35, 43, -21, -6, 5, 23, 14, 29, -63, 2, -13, -128, 23, -69, -65, -21, -46, -126, -128 }, // o
        .{ -3, 2, 9, -12, -1, -25, -17, -8, 44, -128, -96, -41, -4, -88, -31, 7, 16, -57, -102, 44, -30, -45, -58, 7, -128, -2, -45, -73, 3, -6, -125, -57 }, // n
        .{ -96, -12, 19, -34, -14, 35, -128, 21, 18, -128, 9, 22, -128, 34, -73, -63, 21, -14, -128, 29, 13, -94, -24, -47, -128, 19, -58, -80, -51, -54, -123, -128 }, // i
        .{ 10, 1, 16, 10, 2, -56, -5, -7, -99, 11, -76, -34, -27, 0, 2, 24, 1, 4, -19, -56, -73, -31, -117, 12, -128, -1, -44, -62, 5, -4, -121, -113 }, // s
        .{ 24, -2, -85, -2, 7, -50, -4, -5, -31, -128, -28, -39, -17, -44, -30, 24, -67, -73, -85, -32, -99, -41, -36, 32, -128, -42, -26, -68, 11, -10, -105, -111 }, // d
        .{ -22, 44, -27, 19, 3, -83, 19, -80, -100, -128, -39, -96, -37, -83, -14, -16, -128, -94, -104, -128, -128, -59, -71, -35, -128, -105, -69, -88, -14, -44, -121, -128 }, // h
        .{ -4, 21, -14, 1, 15, -13, 17, -7, -2, -94, -8, -17, 28, -16, 2, 15, -17, -15, -73, -15, -13, -40, -44, -3, -128, 7, -42, -91, 0, -14, -120, -109 }, // r
        .{ -12, 13, -28, 13, 18, -123, 23, -15, 10, -101, -88, 32, 30, -57, -3, 2, -53, 8, -24, -100, -8, -40, -50, -11, -128, -6, -48, -94, 17, -24, -115, -111 }, // l
        .{ 25, -20, -44, -57, 9, -61, -19, -1, -115, -128, -121, -61, -128, -25, -38, 39, -56, 1, -46, -75, -65, -40, -27, 46, -128, -94, -36, -79, 9, 3, -105, -79 }, // y
        .{ 4, 23, -81, 17, 17, -76, 9, -26, -55, -128, -128, -58, 13, 4, 0, 26, -72, 24, -106, -119, -56, -71, 10, 9, -111, -83, -52, -70, -6, -15, -105, -91 }, // m
        .{ -30, -9, 20, -44, -99, 29, -12, 20, -8, -128, 24, 26, -54, 16, -101, -25, 21, 33, -126, 32, -2, -128, 7, -12, -128, -47, -97, -34, -56, -45, -104, -83 }, // u
        .{ 27, -76, -53, -58, -77, -76, -57, -40, -55, -86, -54, -51, -89, -26, -45, -27, -21, -21, -60, -26, -31, 62, -41, -108, -128, -13, 7, 18, 3, 6, -79, -30 }, // .
        .{ -51, 10, 4, 27, 27, -95, 0, -52, -75, 26, 1, 12, 0, -64, 2, -27, -21, -60, -92, -109, -71, -72, -97, -49, -128, 38, -61, -29, -4, -32, -101, -128 }, // c
        .{ -22, 10, -21, 7, 19, -119, 5, -25, -59, -33, 17, 37, 28, -80, 18, 4, -29, 43, -111, -56, -53, -67, 5, -9, -128, -47, -54, -48, 3, -24, 24, -123 }, // p
        .{ -8, 9, -128, 43, 3, -7, 30, -40, -96, 12, -34, -35, -87, -70, -99, -12, -117, -118, -114, -125, -106, -52, -64, -5, -128, -106, -55, -93, -24, -35, -101, -122 }, // w
        .{ 9, 13, -68, -1, 11, -37, 10, -4, -114, 18, 12, -4, -42, -64, -7, 21, -77, -62, -104, 8, -104, -37, -102, 22, -128, -61, -33, -75, 0, -10, -98, -98 }, // g
        .{ -8, -5, 13, 3, 27, -73, 21, -70, -110, -128, 31, 13, -22, -48, 37, -2, -97, -74, -128, -66, 19, -63, -67, -30, -128, -100, -66, -28, -15, -18, -96, -109 }, // f
        .{ 10, -65, -76, -79, -112, -98, -54, -71, -58, -124, -95, -105, -128, -73, -89, -91, -39, -53, -94, -107, -5, 44, -79, -128, 84, -64, 47, -3, -22, 34, 100, -34 }, // \n
        .{ -48, 19, -108, 17, 25, -113, 35, -24, -95, -106, 6, 18, 11, -79, 41, 0, -69, -58, -68, -62, -104, -80, 6, -35, -128, -34, -62, -24, 13, -27, -93, -123 }, // b
        .{ 35, -128, -128, -128, -64, -78, -128, -128, -128, -128, -120, -128, -128, -128, -128, -128, -118, -54, -128, -128, -128, 44, -123, -128, -128, -77, -125, 27, -128, -16, -93, -50 }, // ,
        .{ -79, -81, -46, -73, -70, -45, 19, -22, -35, -68, 15, -43, -128, -4, -49, -128, -1, -23, -37, -58, -1, -128, 1, -128, 116, -18, -5, 36, 9, 27, -65, 49 }, // space
        .{ -10, 35, 0, -15, -16, -15, 14, -12, -88, -119, -98, -38, -8, -81, 21, 17, -9, 3, -89, -60, -49, -37, -47, 5, -128, -22, -33, 33, 13, -6, -45, -92 }, // lower
        .{ -34, 5, -17, -2, 13, 6, 20, -38, -43, 34, -14, -25, -33, -29, 19, -55, -35, -10, -52, -56, -26, -43, -68, -30, -26, -13, 38, 1, 28, -14, -121, -72 }, // upper
        .{ -24, -80, -95, -68, -107, -94, -91, -67, -67, -82, -73, -77, -98, -59, -54, 29, -47, -46, -68, -88, -24, 10, -32, 52, 45, 6, -8, 96, 35, 32, -84, -34 }, // digit
        .{ -63, -26, -2, -1, -19, -14, 8, 18, 0, -33, 3, -2, -4, 23, -3, -75, 33, 28, -8, 6, 18, -82, 22, -16, -128, 22, 34, 18, 41, -34, -63, -113 }, // under
        .{ 3, -27, -23, -40, -56, -36, -37, 2, -25, -63, -31, -38, -95, -13, -38, -13, -2, -10, -39, -10, -16, 57, -8, 22, -96, -2, 16, 18, -9, 45, -26, -28 }, // punct
        .{ -128, -61, -107, -115, -110, -83, 22, -66, -10, -105, -95, -90, -105, -89, -40, -104, -32, 34, -101, -82, -19, -95, -68, -93, -65, -42, -36, -84, -15, 67, 108, -15 }, // ctrl
        .{ -12, -128, -67, -128, -128, -128, -128, -44, -122, -128, -95, -90, -128, -75, -128, -82, -106, -106, -119, -122, -112, 3, -104, -82, -128, -103, -21, -29, -64, -47, -68, 125 }, // hi128
    },
    .{ // d = 2
        .{ -6, 0, -18, 18, 24, 10, 17, -27, -53, 24, 0, -3, -41, -21, 14, -49, -26, -7, -30, -32, -9, -17, -40, -42, -128, -17, -18, -15, -43, -13, -128, -13 }, // sp
        .{ 6, -13, 10, -12, -26, -29, -14, 7, 10, -10, -5, -4, 1, -8, 2, 14, 14, 17, 17, 0, 11, -6, 21, 9, -57, -3, -28, -46, 2, -3, -45, -40 }, // e
        .{ -3, 21, -7, -6, -2, -18, 3, -6, -1, -12, 8, 2, 2, 5, -15, -19, -5, -4, 10, -2, -2, -11, 1, -22, -39, 9, -25, -17, -1, 2, -54, -37 }, // t
        .{ 4, 9, 0, -26, -28, -19, -8, 1, 33, -20, -29, 14, -8, -20, -31, 7, -1, 14, -18, 4, -16, -43, 17, 17, -83, 17, -53, -49, 7, -22, -6, -75 }, // a
        .{ 6, 8, 8, -27, -26, 0, -20, 10, -1, -5, -11, 8, -20, 1, -28, 15, -7, 11, -25, 13, 0, -29, -2, 12, -101, 16, -32, -73, 9, -6, -94, -59 }, // o
        .{ 15, -3, 10, -6, -6, -34, -5, 4, -17, -22, -17, -12, -6, 13, -22, 10, -7, -20, 14, -32, -17, -3, -18, 7, -50, -11, -28, -18, 5, -2, -67, -35 }, // n
        .{ 7, 12, 1, -30, -62, 5, -21, -7, 4, 10, -40, 7, 14, -39, -21, 15, -19, -11, -60, 41, -32, -37, -28, 26, -78, -3, -53, -65, 4, -14, -91, -84 }, // i
        .{ -8, -3, -7, 16, 1, -7, 17, -1, -2, -17, 8, -8, -9, 13, -8, -1, 1, -9, 18, 2, 16, 6, 7, -5, -43, 2, -19, -28, 13, -2, -28, -29 }, // s
        .{ -9, -27, 18, 8, -20, -2, -10, 8, -1, 3, -9, -9, 21, -10, -19, 1, 11, 0, 16, 9, 33, 5, 12, -15, -66, -8, 6, -47, -20, -7, -4, -36 }, // d
        .{ 15, -52, -1, -27, -36, 8, -16, 8, 2, -26, 24, 2, 32, 14, 0, -39, -27, 17, -9, -14, -22, -28, -36, -37, -45, -8, -58, -61, -45, -43, -89, -69 }, // h
        .{ 3, 3, 3, 1, -14, 3, -7, 4, -3, -19, -21, -11, -6, 16, 5, 16, 12, 3, 5, 0, 11, 1, 8, 2, -38, 0, -28, -43, 2, -5, -65, -46 }, // r
        .{ 7, -15, 2, -6, -2, 0, -22, 4, -1, -32, -17, -42, 30, -10, -6, 19, 10, -11, 11, -3, -4, -16, 11, 12, -38, 25, -33, -53, 8, 0, -67, -51 }, // l
        .{ -1, -22, -2, 6, -16, 0, -20, 11, 8, 4, -20, 3, -57, -5, 30, -13, 14, 10, 38, -7, 19, 16, 19, -12, -50, -18, -50, -46, -53, -8, -80, -27 }, // y
        .{ -3, -31, 4, -3, -19, 6, -24, 15, 13, -29, 1, 20, -3, 24, -7, 6, 3, -15, 19, 2, 3, -7, -20, 29, -93, 15, -32, -61, -3, 0, -73, -55 }, // m
        .{ 4, 0, -1, -27, -9, 2, -16, 4, 25, 13, -19, 1, -10, -18, -36, 18, 13, 12, -22, 1, 1, -38, 0, 5, -128, 2, -46, -35, 4, -8, -104, -60 }, // u
        .{ -43, -33, -54, -36, -22, -38, -28, -41, -47, -69, -24, -51, -42, -65, -26, -27, -46, -33, -78, -67, -44, 25, -61, -34, -23, -39, 67, 15, -44, 21, 39, -17 }, // .
        .{ -3, 1, -3, -7, -5, 13, 3, 1, -6, -84, 16, 8, -22, 26, 27, 19, -19, 0, -41, -36, -26, -31, -26, 0, -85, -6, -19, -47, 29, 2, -69, -68 }, // c
        .{ -19, -3, 3, 20, 7, 17, 5, -9, -5, -34, 19, -1, 29, -34, -27, 16, 23, -9, -20, -19, -38, -16, -10, -14, -77, -32, -40, -28, 15, -3, -64, -56 }, // p
        .{ -29, -21, 20, -1, -19, 23, -8, 42, -26, -26, 22, 7, 15, -16, 3, -20, -36, -35, -15, -31, -7, -36, -14, -19, -28, -24, -32, -55, -48, -33, -76, -62 }, // w
        .{ -7, -7, 24, 3, 5, 4, 3, -2, -15, -18, 13, -19, -9, -2, -12, 4, 2, -5, 9, -22, 8, 4, 15, -9, -50, 6, -23, -54, -6, -4, -53, -36 }, // g
        .{ -36, 12, -8, -24, 11, 17, 20, -2, -54, -32, 30, 27, 1, -9, 19, -17, 11, -26, -22, -13, 1, -26, -23, -29, -93, 1, -33, -19, 13, -12, -42, -68 }, // f
        .{ 11, -37, -44, -28, -12, 18, 4, -30, -52, 12, -26, -50, -62, -24, 11, -74, -36, -32, -87, -87, -2, 18, -65, -128, 71, -24, 12, 8, -13, 31, 25, -33 }, // \n
        .{ -22, -7, 15, -3, -2, -20, -2, -4, -7, -42, 20, 22, 16, -60, 12, -29, 34, -50, -15, 51, 7, -42, -14, -41, -109, 16, -41, -23, -13, -26, -93, -76 }, // b
        .{ -17, -43, 15, 13, -39, -33, -13, 9, -32, -2, -25, -15, -16, -9, -31, -46, -2, -6, 7, -27, -2, -78, 38, -42, 18, -21, 29, 35, -7, 33, -93, 0 }, // ,
        .{ -39, -2, -34, -22, -15, -32, 14, -21, -39, -70, 11, -43, -80, -14, -26, -4, -5, -23, -29, -50, 42, 44, 3, -19, 99, 17, -1, -21, -44, 18, -65, 49 }, // space
        .{ -3, -14, -10, -16, -9, 6, -2, -2, 27, -39, 27, -2, 5, -11, -30, 10, 11, -11, -3, -20, -19, -4, -9, -8, -17, -19, -23, 24, 7, 19, -39, -47 }, // lower
        .{ -14, 19, -12, -16, -16, -4, -25, -8, -17, -47, -8, 9, -21, 36, -6, -45, 15, -14, -8, -20, -24, -15, -5, -2, -12, 5, 35, 2, 29, -9, -49, -19 }, // upper
        .{ -9, -71, -58, -47, -54, -53, -50, -37, -44, -68, -49, -45, -58, -31, -37, -7, -25, -26, -44, -53, -27, 35, -15, 47, 49, -1, 10, 89, 13, 34, 15, 26 }, // digit
        .{ -53, 1, -8, 9, 20, -3, 11, -10, 4, -18, 10, 0, -3, -16, 17, -47, -8, 4, -32, -43, -5, -52, -4, -34, -66, -5, 30, 32, 6, 9, 17, -59 }, // under
        .{ 1, -8, -25, -18, -5, -3, -11, -15, -37, -21, -16, -20, -26, -29, -6, -14, -12, -8, -38, -36, -15, 48, -12, -6, 49, -13, 26, 40, -2, 30, 67, -1 }, // punct
        .{ -4, -28, -107, 5, -54, -72, -62, -56, -56, -43, -45, -78, -48, 40, -32, -104, -85, -64, -101, -72, -96, 26, -93, -93, -65, -17, -89, -21, -63, 61, 68, -15 }, // ctrl
        .{ -9, -60, -31, -47, -50, -57, -58, -26, -66, -49, -53, -56, -91, -48, -61, -60, -38, -37, -46, -62, -43, 10, -40, -61, -69, -53, 0, -10, -49, 2, -68, 121 }, // hi128
    },
    .{ // d = 3
        .{ 0, 8, -2, -4, -2, -1, -2, 5, 10, -43, 10, 6, 1, 18, 7, -31, 4, -1, -4, 9, -14, -20, -2, -25, -9, 8, -34, -7, -34, -14, -17, -13 }, // sp
        .{ -6, -7, 5, 17, 13, -6, 12, -1, -21, 1, 2, -4, -16, -8, 6, -1, -10, 2, 3, -24, 3, 3, -1, -8, -29, -19, 3, -36, 1, 1, -11, -25 }, // e
        .{ 4, 3, 7, -2, -1, 10, -4, -5, -21, 3, 5, -10, 4, -4, -1, -5, -1, 5, -23, -4, -2, 14, -3, -18, -25, -7, -7, -31, -8, -12, -22, -27 }, // t
        .{ 10, -1, -12, 3, -8, -12, 11, 1, 1, -5, -12, -12, 10, -7, -4, 15, -15, -22, 5, -28, -5, -10, -5, 20, -52, -8, -20, -38, 5, -7, -61, -48 }, // a
        .{ -2, 5, 6, 4, -9, -12, -3, 3, 11, 7, -6, 6, -2, -19, -10, 16, 3, -16, 6, -15, 7, -5, -2, 5, -43, -19, -15, -35, 6, -1, -60, -32 }, // o
        .{ -1, -9, 5, 0, -5, -9, -8, 7, 11, 13, -3, -8, -6, -11, -15, 5, 1, 1, 7, -3, 24, 5, 4, -6, -27, -8, 4, -10, -10, -2, -2, -21 }, // n
        .{ 10, -17, 3, -11, -15, -16, -11, 6, 15, -18, -18, 8, -11, -4, -21, 19, -8, -14, 11, -24, 8, 0, 5, 22, -44, -29, -13, -19, 20, 8, -50, -39 }, // i
        .{ -8, 1, -11, -1, 11, 9, 0, -9, 11, -3, 15, 8, -20, -5, -1, -5, 6, 8, -4, -1, 10, -4, -8, -14, -28, -3, 5, -20, -3, -4, -4, -20 }, // s
        .{ -12, -8, 3, 11, 22, 10, 9, -17, -47, 13, -7, -3, -39, -25, 5, -1, -16, -6, -13, -8, -6, -4, -13, 21, -44, -14, 8, -42, -6, 9, -22, -14 }, // d
        .{ 9, -3, -8, -23, -24, -26, -16, 10, -3, -3, -1, -2, -29, -3, -25, 6, 13, 35, 17, 25, 11, -33, 31, -1, -39, 5, -25, -50, -26, -31, -52, -53 }, // h
        .{ -9, -4, 0, -4, 4, 17, -2, 2, 5, 2, -7, -1, -14, -3, 9, 4, 9, -3, 15, 15, 2, 2, 2, -1, -15, 2, -1, -29, 3, 1, -36, -27 }, // r
        .{ -6, 8, 5, 3, -11, -3, -4, 5, 0, -2, -5, -15, -5, -12, -23, 0, -3, 0, 7, 23, 9, 9, 21, -5, -49, 15, -8, -39, -1, 0, -22, -25 }, // l
        .{ -12, -3, -18, 22, 17, 9, 10, -14, -44, -2, 6, 4, -48, -14, 4, -15, -32, -23, -20, 11, -30, -1, -16, -5, -41, -16, 24, -37, -28, -7, -17, -21 }, // y
        .{ -1, 7, -3, 8, -2, 5, 0, 3, -21, 7, -2, 3, 4, -15, -16, 1, -6, -20, -7, -9, -3, -4, 7, -6, -42, -17, 8, -49, 7, 0, 22, -32 }, // m
        .{ 6, 1, 10, -1, -5, 3, 5, -1, -14, -13, 0, -12, 12, -30, -24, 14, -10, -21, 4, -32, 2, 5, -5, 1, -59, -8, -12, -42, 23, -2, -32, -37 }, // u
        .{ -43, 6, -6, -15, 4, 6, 11, -20, -50, 46, -13, -23, -58, -15, 18, -13, -25, -10, -47, -31, -18, -19, -39, -43, -38, -9, 20, -3, -26, 13, -9, -14 }, // .
        .{ -10, 11, 2, -4, -3, -2, -5, 15, 6, -34, -3, 17, -12, 3, 22, 1, 8, 11, -1, -16, 5, -1, -1, -7, -48, -3, -25, -21, -7, 0, -31, -26 }, // c
        .{ -2, -10, 12, -11, -16, 6, -5, 5, -5, -9, -11, -7, 39, -16, -14, 14, 7, -2, -32, -9, -6, 1, -13, -6, -42, 24, -6, -35, -1, -1, -23, -39 }, // p
        .{ 11, -2, 20, -28, -18, -9, -24, -11, -11, 29, -9, 13, -71, -22, -39, -3, 1, -22, -28, -2, -20, -28, -33, -19, -26, 10, -26, -53, -50, -35, -44, -50 }, // w
        .{ -7, 1, -5, 3, 6, 13, 1, -8, 9, 13, -3, 9, -23, -20, 8, 2, -14, -6, -9, -5, -8, 3, 13, -4, -43, -28, 6, -38, 2, -3, -22, -23 }, // g
        .{ -5, 13, 0, -23, -12, 0, -7, -15, -1, 6, 2, 16, -47, 24, -5, 10, 9, -23, 10, 6, -30, -21, -27, -14, -20, 32, -27, -25, -15, -13, -35, -50 }, // f
        .{ 11, 19, -24, -32, -17, -6, -18, -28, -25, -36, -16, -8, -38, 15, -15, -59, 29, -4, -50, -44, 4, 16, -18, -38, 58, -22, -12, 10, -7, 9, 78, -20 }, // \n
        .{ 7, -19, 6, 0, -21, -3, -18, -12, 14, -8, -4, 17, -15, -27, -12, 13, 15, -29, -10, -1, -12, -33, -9, 15, -67, 31, -31, 17, 31, -12, -48, -58 }, // b
        .{ -9, -8, -27, -5, 14, 13, 12, -29, -22, 31, -11, -18, -48, -22, 30, -35, -32, -13, -37, -10, -41, -38, -40, -14, 12, -21, 28, 32, -36, -13, -68, 1 }, // ,
        .{ -11, -7, 8, -27, -20, -29, 7, -12, -24, -75, 11, -41, -71, -10, -31, 0, -22, -14, -34, -33, 30, 33, 1, -23, 90, 1, 12, 11, -58, 16, -65, 48 }, // space
        .{ 1, -19, 4, -6, -4, -6, -3, 0, -18, -16, -12, -16, 30, -25, -3, 3, 9, 6, 14, 15, -3, -1, -12, 6, -2, -13, 10, -3, 11, 19, -16, -32 }, // lower
        .{ 8, -11, -10, -15, -25, -12, -14, -9, -22, -28, -18, -5, 34, -5, -16, -2, -10, -8, 6, -20, -14, -10, -21, 11, 0, 0, 33, 8, 28, 3, -29, -4 }, // upper
        .{ -6, -38, -41, -35, -32, -31, -27, -33, -42, -58, -34, -35, -53, -27, -25, -11, -21, -19, -48, -39, -19, 35, -12, 44, 54, 18, -1, 84, -11, 32, 17, 41 }, // digit
        .{ -42, -19, 4, -1, 1, 7, -9, 5, -7, -63, 9, 3, -25, 17, -6, -47, 13, 12, -22, 13, -8, -20, 2, -3, -44, 21, 29, 17, 58, 19, -26, -56 }, // under
        .{ -9, -19, -13, -10, -3, 12, -2, -6, -1, -7, -5, -8, -22, 1, 1, -16, -1, 0, -12, -6, -1, 28, -8, -4, 44, -1, 17, 40, -4, 26, 40, 4 }, // punct
        .{ 3, -64, -52, -71, -47, -46, -66, -40, -52, -89, -69, -78, -89, -38, -104, -104, 36, 45, -64, -14, 17, -34, -29, -93, -65, -31, 9, -24, -63, 56, 42, -11 }, // ctrl
        .{ -8, -37, -25, -27, -24, -35, -34, -20, -52, -13, -34, -38, -57, -30, -25, -48, -28, -27, -30, -41, -31, 13, -29, -47, -66, -31, 12, -4, -47, 8, -52, 115 }, // hi128
    },
    .{ // d = 4 — and every d > 4
        .{ 12, 0, 2, -17, -20, -6, -3, -5, -4, -9, -2, 4, 16, -1, -7, -1, 1, 9, 0, -4, -7, -13, -13, 3, -15, 5, -29, -10, -23, -8, -22, -39 }, // sp
        .{ -18, -5, -2, 0, 15, 10, 3, 4, -2, 7, 13, 1, 8, -8, 7, -11, 3, -3, 3, 6, 11, -7, 0, -18, -15, 2, 2, -25, -13, 0, -3, -17 }, // e
        .{ -2, 1, 1, -9, -6, -12, -5, 9, -6, 2, 0, 3, -18, 1, -3, 6, 5, 7, -4, 22, 8, 0, 22, 11, -12, 1, -6, -17, 5, 4, -14, -26 }, // t
        .{ -4, -11, 6, 7, 4, 5, -1, 3, 7, 3, -5, -7, -3, 1, -5, 2, 0, -3, 6, 20, 6, 0, 2, -11, -43, -14, 5, -30, -5, -5, -40, -29 }, // a
        .{ -1, -3, -3, 10, 1, 1, 3, -6, -9, 12, 1, -6, -15, -8, -1, 3, 2, -3, -4, -7, 1, 4, -4, -3, -31, 15, 3, -32, 12, -5, -22, -20 }, // o
        .{ -10, 4, 8, 12, 9, -3, 1, -4, -4, 10, -1, 0, -21, -12, 17, -7, -7, -8, -1, -6, -1, 1, -6, -18, -20, -5, 0, -19, -1, -2, -9, -19 }, // n
        .{ -4, -8, 1, 8, 8, 0, -2, 7, -13, 8, 4, -8, -13, -13, -5, 6, -4, -7, 7, -9, 1, 9, 0, 1, -15, -13, 1, -10, -4, 12, -29, -10 }, // i
        .{ -8, 3, 3, 1, -5, 1, 3, -3, 0, -2, 7, 7, -1, 7, -2, 10, 4, 9, -3, 0, -7, -6, 1, 25, -27, 0, -2, -14, 2, -5, -11, -16 }, // s
        .{ -1, 6, -1, -5, -1, 4, 1, -2, 6, -4, 0, 3, -13, 12, 3, -11, -2, -5, -4, 3, -15, -7, 2, -19, -22, 2, 9, -27, -6, -6, -14, -11 }, // d
        .{ -7, -1, -5, 18, 10, -13, 12, 5, -7, 5, 1, -1, 9, 4, 6, 3, -5, -1, 11, -17, 14, -11, 8, -11, -38, -12, -29, -33, -25, -22, -51, -44 }, // h
        .{ -6, -2, -6, 9, 1, -2, 5, 1, 13, -3, 2, -1, -6, 6, 0, 10, -4, -12, -6, -8, -2, 2, 1, -2, -11, -8, 5, -23, 9, 5, -5, -20 }, // r
        .{ -8, 0, -8, 5, 8, 6, 6, 1, 11, 0, -4, 14, -8, -4, -2, 3, -13, -16, 7, -4, -10, -2, -9, -7, 12, -9, 6, -23, 12, -1, 12, -18 }, // l
        .{ -13, -5, 3, 0, 2, 4, 4, -1, 14, 10, 8, 3, 3, 9, 13, -19, 9, 4, 10, 5, -9, -30, -27, -4, -20, 7, -8, -6, -31, -3, -29, -18 }, // y
        .{ -4, -5, 1, 2, 2, -1, 11, 8, 11, 0, -5, -4, -9, -3, -1, 8, 1, -17, 3, -16, -6, -5, -17, -9, -28, -2, 16, -35, -2, -4, -8, -25 }, // m
        .{ -4, -10, -2, 3, 3, 11, 5, -8, 5, 10, 4, -4, -9, -8, -2, -2, -3, -2, -2, -16, 13, 4, 2, -6, -37, -9, 6, -5, 11, 5, -1, -22 }, // u
        .{ -4, 34, -8, -22, -6, -14, -13, -17, -18, -10, -19, 0, -31, 26, 1, -37, -11, -23, -17, -29, -34, -12, -14, -9, -29, -9, -13, -6, -12, -13, 28, -27 }, // .
        .{ -5, 1, -1, -5, 2, 9, -2, 2, 16, -7, 2, -8, -20, -10, -1, 8, -9, 24, -10, -4, 6, -2, 8, -4, -41, -11, 3, -24, 13, -3, -8, -17 }, // c
        .{ -1, 12, 3, 9, 2, -5, 5, -5, 0, -8, -11, -6, -12, -20, -1, 17, -7, -17, -11, -13, -10, 5, -14, -4, -12, -24, -3, 12, 6, -1, 0, -27 }, // p
        .{ 12, 6, -14, 9, -17, -12, -8, 11, -3, 3, -8, -13, -24, -14, -22, 1, -12, -10, -4, -4, -3, -17, 14, -17, -24, 11, -19, -45, -13, -26, -48, -41 }, // w
        .{ 0, 5, 0, -1, 0, 4, -2, 2, 1, 1, 7, -5, -27, 0, 1, 14, -6, -3, -9, 10, -6, -4, 4, -9, -3, -6, -3, -25, -5, -5, -18, -16 }, // g
        .{ 1, -2, 18, -10, -18, 21, -9, 1, 11, -7, -7, -9, -4, -14, -6, 11, -17, -12, -13, -21, -9, 0, -8, -12, -18, -23, -12, -34, 21, -2, -32, -38 }, // f
        .{ 19, -3, -15, -22, -17, 20, -16, -23, -34, -50, -23, -17, 10, -3, -27, -48, 7, -16, -30, -34, 4, 7, -32, -11, 48, -17, -10, 6, -34, 5, 23, -15 }, // \n
        .{ 6, -7, -1, -8, -14, 1, -8, 5, -5, 5, -9, -16, 0, 4, 5, 25, 5, -9, 3, 6, -3, -10, 16, 5, -60, 12, -18, -8, 14, -4, -38, -38 }, // b
        .{ -4, 16, 8, -13, 0, -12, -9, -21, 14, -10, -6, 14, -13, 28, 2, -40, -1, -12, -17, -14, -17, -32, 6, 15, -14, 6, -31, 11, -20, -15, 29, -2 }, // ,
        .{ -11, -4, 4, -23, -28, -23, 1, -10, -23, -58, 13, -14, -40, -2, 32, -7, -20, -4, -24, -27, 24, 29, 5, -42, 81, -6, 16, 30, -11, 14, -65, -89 }, // space
        .{ 2, -6, 12, -1, 2, -6, 1, -4, -8, 6, -10, -16, -24, -16, 11, -7, -9, -10, -10, -19, -11, 36, -9, -13, 10, 3, 0, 10, 2, 2, -6, -24 }, // lower
        .{ 1, -18, -12, 2, -11, -17, -13, 8, 1, -11, -11, 0, 6, -5, -15, -14, 1, -8, 19, -13, 3, -4, 7, 5, 13, -3, 33, 13, 25, 3, -17, 4 }, // upper
        .{ -5, -39, -27, -28, -33, -29, -29, -23, -16, -56, -25, -30, -53, -24, -26, -13, -13, -22, -46, 3, -18, 30, -14, 30, 59, 11, 4, 85, -4, 25, 19, 49 }, // digit
        .{ -19, 7, 3, -17, -19, -3, 2, -2, -7, -15, -1, 2, -33, -2, -2, -16, 11, 8, -34, -6, -6, -3, 1, 11, -35, 5, 26, 19, 66, 18, -37, -46 }, // under
        .{ -5, -2, -10, -12, 7, 4, -2, -9, 1, -18, -2, -2, -25, 5, -1, -17, 12, 1, -27, -18, -5, 18, -7, 9, 37, 0, 3, 31, 3, 24, 51, 0 }, // punct
        .{ -16, -24, -45, -28, 24, -28, -25, -1, -42, -39, -36, -27, -44, 16, 14, -104, 15, -13, -48, -31, -38, 39, -28, -93, -65, 33, 46, -30, -63, 12, 22, 8 }, // ctrl
        .{ -32, -18, -21, -18, -16, -24, -22, -21, -37, -11, -22, -25, -45, -20, -17, -52, -16, -18, -27, -30, -25, 1, -21, -34, -63, -19, 17, -5, -40, 7, -52, 115 }, // hi128
    },
};

/// The most selective pair of offsets in `needle`, with ties broken toward the
/// WIDEST separation.
///
/// A pair costs `marginal(a) + marginal(b) + lift(a, b, gap)`: the independence
/// estimate plus the measured departure from it for that symbol pair at that
/// separation. Both terms are sixteenths of a bit, so the sum is one quantity and
/// the argmin estimates the conjunction's true log selectivity, not `P(a)·P(b)`.
///
/// Ties still break toward separation. That key rarely decides now, but it is the
/// floor that holds when the model has no opinion — an all-tied needle, or a byte
/// the fitted corpus never showed a digraph for — and it is the regression guard
/// for the collapse recorded above. Never remove it.
///
/// O(needle.len), one pass, no allocation, at most `candidates·(candidates-1)/2`
/// priced pairs however long the needle is. `contains` may call this per candidate
/// line, so that tail is fixed by construction rather than by a length cap that
/// would silently change policy at some magic needle length.
pub fn select(needle: []const u8) Pair {
    std.debug.assert(needle.len > 1);

    // Pass 1 — the `candidates` marginally-rarest offsets, held sorted by rarity.
    // A tie keeps the EARLIER offset, so the set is a deterministic function of
    // the bytes and never of iteration incident.
    var off: [candidates]usize = undefined;
    var rare: [candidates]u16 = undefined;
    var n: usize = 0;
    for (needle, 0..) |b, k| {
        const m = marginal[b];
        if (n == candidates and m >= rare[candidates - 1]) continue;
        var i = if (n < candidates) n else candidates - 1;
        while (i > 0 and rare[i - 1] > m) : (i -= 1) {
            rare[i] = rare[i - 1];
            off[i] = off[i - 1];
        }
        rare[i] = m;
        off[i] = k;
        if (n < candidates) n += 1;
    }
    std.debug.assert(n > 1); // guaranteed: needle.len > 1

    // Pass 2 — price every pair among them.
    var best: i32 = std.math.maxInt(i32);
    var widest: usize = 0;
    var lo: usize = 0;
    var hi: usize = 0;
    for (0..n) |x| for (x + 1..n) |y| {
        const p = @min(off[x], off[y]);
        const q = @max(off[x], off[y]);
        const d = q - p;
        const cost = @as(i32, rare[x]) + @as(i32, rare[y]) +
            @as(i32, pmi[@min(d, gaps) - 1][fold[needle[p]]][fold[needle[q]]]);
        if (cost < best or (cost == best and d > widest)) {
            best = cost;
            widest = d;
            lo = p;
            hi = q;
        }
    };

    // The rarer byte probes — see `Pair`. A tie hands it to the earlier offset so
    // a hit is found on the earliest possible window.
    return if (score(needle[hi]) < score(needle[lo]))
        .{ .probe = hi, .confirm = lo }
    else
        .{ .probe = lo, .confirm = hi };
}

/// Whether the single-load block filter is worth entering for this pair: one
/// load and one compare per block, touching the confirm window only inside
/// probe-hit blocks. Gated on the PROBE's density rather than its rank, because
/// rank flattens the skew — rank 198 of 255 sounds selective and is `c` at a 77%
/// per-block hit rate, and a dense probe turns the block gate into an
/// unpredictable branch that mispredicts the loop into the ground.
pub inline fn singleProbeWorthwhile(needle: []const u8, pair: Pair) bool {
    return score(needle[pair.probe]) <= rarity.single_probe_max;
}

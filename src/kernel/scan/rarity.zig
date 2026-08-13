//! irregex — corpus-derived byte density, the statistical prior behind anchor
//! selection in the SIMD substring kernel (the memchr crate's "rare byte" idea,
//! re-derived from OUR corpus instead of English prose).
//!
//! `density[b] = round(P(byte b) * 65535)`, unclamped, measured over 253 MB of
//! the host tree (24,602 text files; walk and caps in
//! `tools/build_rarity_table.py`, which emits the declaration below). The scan
//! kernel anchors its block filter on the needle's two RAREST bytes
//! (`anchor.zig` owns the policy), and when the rarest is genuinely rare
//! (`<= single_probe_max`) it probes with ONE load per block, touching the
//! second window only inside probe-hit blocks. Density — not rank position —
//! is what decides that dispatch: rank flattens the wild skew (rank 198 of 255
//! sounds selective; it's `c` at a 77% per-64B-block hit rate), and probing a
//! dense byte turns the block gate into an unpredictable branch that
//! mispredicts the loop into the ground (measured: single-probing a
//! uniform-random buffer halved throughput; probing `Z` at 1.3% block density
//! raised the corpus scan 14%).
//!
//! ## RECORDED DEFECT (2026-07-29) — the table saturated, and saturation is a tie
//!
//! This table stored `min(255, P * 32768)`. Thirty printable bytes hit the
//! ceiling, twenty of the twenty-six lowercase letters among them, so for a
//! lowercase identifier like `stepSec` EVERY byte carried the same value. A
//! table with no opinion hands the decision to whatever the selector does with
//! a tie, and the selector of the day broke ties with a strict `<` that never
//! displaces its initialisers — it returned offsets `0:1`, the ADJACENT pair,
//! which is the most-correlated choice available and the one case where a
//! two-byte conjunction buys almost nothing over one byte. That fired on 122 of
//! 177 code needles and 78 of 90 prose needles, making the "two rarest bytes"
//! selector WORSE than the fixed first+last it replaced, in both regimes, on
//! every summary statistic.
//!
//! The measured cost, with the anchor pair as the only variable (Apple M4):
//! 18.1 → 35.5 GB/s on 37.8 GB of code, 13.1 → 33.4 GB/s on 12.1 GB of prose;
//! worst individual needles ran at 2.4–4.6 GB/s while holding a 64-byte-per-
//! iteration vector filter. Visible in the shipped binary without a patch:
//! `stepSec` (7 bytes, 464 true hits) ran 41% SLOWER than `pgxpool` (7 bytes,
//! 8,856 true hits) — more real work, less time. That control now reads 56.4 vs
//! 55.7 ms over the same 1.71 GB — 1.3% apart, both at ~30 GB/s, with this
//! table and the repaired tie-break in place. Evidence: `research/pincer/`.
//!
//! **So the invariant this file exists to hold is ORDERING.** The old module
//! doc said "only the coarse ordering matters; exact counts don't" — true, and
//! exactly why the clamp was fatal: it destroyed the only property it claimed
//! to preserve. Exact probabilities remain uninteresting; the RANK of every
//! byte against every other is the whole product. Any future regeneration must
//! therefore be monotone in true corpus frequency and must not saturate — a
//! ceiling is not a rounding error here, it is a mass tie at the top of the
//! range, which is precisely where a needle made of common bytes is decided.
//!
//! `u16` at scale 65535 is the narrowest cell that holds this. Censused against
//! the table it replaces: `u8/32768` sat 30 printable bytes on the ceiling and
//! left 441 printable pairs — 190 of them lowercase — sharing a cell while
//! differing in true frequency. `u16/65535` leaves 7 printable pairs, no
//! lowercase pair, one byte alone at the top (the space, which genuinely is the
//! maximum), and zero rank inversions across all 256 cells. Those 7 differ in
//! true frequency by under 0.7% (`{`/`}` by 0.05%, `H`/`W` by 0.03%) — a tie
//! there is an honest report that the corpus cannot separate them, where `u32`
//! buys their separation at twice the L1 footprint plus a widened
//! `prefilter.Economics`.
//!
//! What the range is worth, with the anchor policy held fixed and only the
//! table varying, priced against the best pair that exists for each needle
//! (survivors of the two-offset AND filter counted exactly, the oracle taken by
//! brute force over every offset pair of every needle in the slate): 2.55×
//! → 1.50× of oracle survivors on 203 MB of code, 2.99× → 2.21× on 128 MB of
//! prose. The prose figure is honestly cross-distribution — this is a code
//! prior, and a prose-fitted census reaches 1.76× there.
//!
//! Deliberately a table, not a runtime census: anchor choice must cost a few L1
//! loads per query, and a statically-known density keeps `indexOfPos`
//! allocation- and IO-free. Drift shifts which anchors are picked — the eql
//! verify keeps correctness independent of this table, which is what makes
//! regenerating it safe.

/// Ceiling on a probe byte's density for the single-load fast path: ~9% of
/// 64-byte blocks hit (`P ≈ 0.15%`, block-hit ≈ 1-(1-P)^64). Above it the
/// second anchor loads unconditionally — the branch a dense probe would add
/// costs more than the load it saves. This is a PROBABILITY bar, so it moves
/// with the scale: 96/65535 is the same 0.15% the previous 48/32768 meant.
pub const single_probe_max: u16 = 96;

/// Per-byte corpus probability as `round(P * 65535)`, UNCLAMPED. Measured over
/// 253 MB of the host tree (24,602 text files; see
/// `tools/build_rarity_table.py` for the exact walk). Regenerate with that
/// script and review the diff — never widen, floor, or ceiling a cell by hand.
/// Rows are 16 bytes wide; the legend marks the printable span, `_` for space.
pub const density = [256]u16{
    0,     0,    0,    0,    0,    0,    0,   0,   0,   759,  1607, 0,   0,    0,   0,    0,
    0,     0,    0,    0,    0,    0,    0,   0,   0,   0,    0,    0,   0,    0,   0,    0,
    // 20  _!"#$%&'()*+,-./
    11576, 41,   1137, 56,   15,   18,   36,  138, 529, 522,  256,  65,  774,  673, 868,  540,
    // 30  0123456789:;<=>?
    463,   368,  268,  187,  188,  177,  169, 130, 138, 133,  618,  133, 105,  415, 134,  32,
    // 40  @ABCDEFGHIJKLMNO
    48,    273,  141,  230,  139,  289,  126, 127, 74,  244,  53,   52,  167,  126, 183,  118,
    // 50  PQRSTUVWXYZ[\]^_
    135,   36,   249,  298,  236,  102,  86,  74,  43,  51,   55,   154, 197,  154, 2,    573,
    // 60  `abcdefghijklmno
    271,   2445, 613,  1434, 1455, 4597, 792, 796, 853, 2442, 70,   290, 1586, 918, 2448, 2393,
    // 70  pqrstuvwxyz{|}~.
    1184,  93,   2702, 2489, 3276, 1056, 477, 331, 461, 526,  75,   262, 72,   262, 3,    0,
    206,   1,    2,    1,    1,    1,    10,  1,   2,   2,    1,    1,   1,    1,   1,    1,
    8,     1,    10,   1,    204,  8,    1,   2,   1,   1,    1,    1,   1,    1,   1,    1,
    1,     1,    1,    1,    1,    1,    3,   2,   1,   1,    1,    1,   1,    1,   1,    1,
    1,     1,    1,    1,    1,    1,    1,   4,   1,   1,    1,    1,   1,    1,   1,    1,
    0,     0,    6,    2,    0,    0,    0,   0,   0,   0,    0,    0,   0,    0,   1,    0,
    0,     0,    0,    0,    0,    0,    0,   0,   0,   0,    0,    0,   0,    0,   0,    0,
    0,     0,    227,  0,    0,    3,    3,   3,   3,   2,    0,    1,   1,    1,   1,    0,
    1,     0,    0,    0,    0,    0,    0,   0,   0,   0,    0,    0,   0,    0,   0,    0,
};

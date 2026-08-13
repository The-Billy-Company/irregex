//! irregex — the anchor decision priced on the buffer being searched.
//!
//! `simd.zig::indexOfPos` filters `block_bytes`-wide blocks on the conjunction
//! of two byte equalities at needle offsets `(probe, confirm)`. That choice is
//! the filter's only variable cost. The static selector next door
//! (`anchor.zig`) prices it against a corpus-derived byte-frequency table —
//! i.e. against a distribution shipped in the binary, which is a statement
//! about the tree it was measured on and about nothing else. A base64 blob, a
//! minified bundle, a log file, non-English prose, and a `.tar` all get priced
//! by a table describing none of them.
//!
//! This module ships no distribution. It prices every candidate pair on a
//! sample of the buffer in hand and returns the cheapest, so the buffer answers
//! for itself. Total survivors against the best pair that exists (2026-07-29,
//! Apple M4, 177 code needles over a 213 MB code tree / 90 prose needles over
//! 128 MB of English / the code slate over a 192 MB base64+code+prose buffer;
//! `static` is this tree's `anchor.zig` as measured, and it MOVES — an earlier
//! run of the same slate against the pre-unclamping table read 2.55x/2.99x/2.08x):
//!
//!     regime     static (anchor.zig)   calibrated @ 64 KB   oracle
//!     code               1.50x                1.04x          1.00x
//!     prose              2.21x                1.03x          1.00x
//!     heterogeneous      1.39x                1.03x          1.00x
//!
//! Those three slates are needles of 16 bytes or fewer, where every offset is a
//! candidate. Needles past the offset cap are a separate regime, measured and
//! recorded at `candidates` below.
//!
//! Calibration is not uniformly better needle-for-needle: it loses to the table
//! on 28/177 code needles (worst 10.7x its survivor count). None of those is
//! material — the largest is +0.014 percentage points of survivor density, one
//! extra `eql` per ~7,400 positions — and the net is negative in all three
//! regimes (code -5.8M survivors over 37.8 G positions). The mechanism is
//! sampling variance on needles whose true survivor density is already near
//! zero, which is exactly where being wrong is cheapest.
//!
//! **This is adoption, not invention.** zoekt already picks its two trigram
//! probes from posting-list lengths read out of the index being searched;
//! Optimal Seed Solver (Xin et al. 2013) runs a DP over seed positions against
//! frequencies read from the real reference index; the Rust `memchr` crate
//! publishes `HeuristicFrequencyRank` precisely so a caller can substitute a
//! table measured on their own data. Rust's `regex` records the opposite
//! decision and its reason — "doing frequency analysis on the haystack is far
//! too expensive" — which is publication of the considered alternative. The
//! only thing added here is the price of that objection, measured: 0.19% of a
//! 214 MB scan (§ the size gate below). Full review: `research/pincer/`.
//!
//! ## Three constraints that are measured, not assumed
//!
//! 1. **Sampling is STRATIFIED, never a prefix.** A prefix of a real buffer is
//!    one region's distribution. Measured on the heterogeneous buffer at a
//!    64 KB budget: prefix lands at 4.30x oracle where stratified lands at
//!    1.04x — and prefix does not improve with budget (4.30x at 64 KB, 4.33x at
//!    256 KB, 3.62x at 1 MB), because the bias is systematic rather than noise.
//!    On homogeneous English prose a prefix is fine (1.05x); that is exactly
//!    why measuring only prose would have shipped the bug.
//! 2. **Pairs are priced from per-offset bitvectors, never by re-scanning bytes
//!    per pair.** One `u64` word of a per-offset match bitvector holds 64
//!    candidate positions (bit `p` set iff `hay[base + p + off] == needle[off]`),
//!    so `popCount(B_i & B_j)` IS the survivor count the kernel would pay —
//!    the same arithmetic, counted instead of branched on. Cost is therefore
//!    `k` vector passes over the sampled bytes plus ~2 word-ops per sampled
//!    position, i.e. `k x budget`. Pricing each pair against the raw bytes
//!    instead would be `C(k,2) x budget` — 120/16 = 7.5x over budget at
//!    `k = 16`, and 15x at the `C(n,2)/n` ratio for a 31-offset needle — which
//!    moves the size gate out past where anything pays for itself.
//! 3. **Below the size gate this returns `null` and costs nothing.** Not "very
//!    little" — the candidate count is `min(len, cap)` without enumerating the
//!    offsets, so declining is two comparisons and a return, and a small buffer
//!    never touches a bitvector.
//!
//! ## WIRED at `simd.planOn` — read before moving it
//!
//! `simd.zig::planOn` is the only entry point, and everything upstream reaches it
//! through one of three document-grain seams. Two properties of that call site are
//! load-bearing, and both were mistakes first:
//!
//! · It calls `refine`, not `best`. Adopting the sample's favorite
//!   unconditionally was a measured 0.5–1.1% CPU tax with no row it won — see
//!   `refine` for the two mechanisms and the numbers.
//! · It is per DOCUMENT, never per line. The size gate is a claim about the scan
//!   the sampling amortizes against, so evaluating it on a slice prices the wrong
//!   thing.
//!
//! ## The three seams, and why there are exactly three
//!
//! A plan must be minted where a WHOLE document first arrives and then reused by
//! every scan of it, so each seam is a place where that admission happens:
//!
//! · **`simd.Gate.on(hay)`** — the required-literal gate, re-priced on one body.
//!   `Emitter.openOn` calls it per file (serial render, the swarm worker, the
//!   single-file shard driver, stdin, and the resident session's fold),
//!   `json.emitOne` and `json.soloShard` do the same for the record stream, and
//!   `verify.gateWide` calls it for the whole-file drop in `quarry/intake.zig`.
//!   Idempotent by construction: it re-decides from `planFor(bytes)`, never from
//!   `self.plan`, so a long-lived gate cannot carry file N's pair into file N+1.
//! · **`Emitter.lit_plan`** — the literal SWEEP plan, for the loops that re-enter
//!   the scanner once per match: `skim.fileLit`, `Emitter.litCandidates`, and
//!   `skim.litNextSpan` (the NFA-free `-o`/`--count-matches` span walk). A field
//!   and not a local because those loops would otherwise re-sample per hit, and
//!   because `emitFileSharded` cuts one file across cores and must hand every shard
//!   the same value. `json.zig` keeps the same value in its own shard struct and in
//!   `litCandidates`, hoisted above the loop for the same reason.
//! · **`PikeScratch.litPlan`** — the span walks (`span.zig::litSpan`), memoized on
//!   the haystack slice because that function's ~20 callers each build their own
//!   `SpanSim` at a different grain. See it for why a stale memo is sound.
//!
//! `LiteralSet.findOn` and `verdict.docMatch` ride the first seam's reasoning at
//! the fused whole-document grain, and `render.anyHit`'s `-q` presence sweep mints
//! one directly because it holds a body and answers from a single jump.
//!
//! **The per-hit hoists are not only about calibration.** Since `anchor.zig` gained
//! its distance-conditioned joint correction, `anchor.select` costs ~21 ns on a
//! typical 4–8 byte needle rather than ~3.7 ns. Every loop above re-derived that
//! decision once per HIT before it took a plan, so on a match-dense body the hoist
//! is worth more than the sampling it also enables — and a one-literal set is
//! exactly the case that pays it (an alternation anchors each needle on its own
//! first+last and never calls `select`).
//!
//! **MEASURED REACH, 2026-07-30** (M4, single-threaded, child CPU, best of 7,
//! interleaved in-binary A/B via `<prefix>NO_CALIBRATE`. Corpus: a 200 MB buffer whose
//! alphabet is the statically-rare bytes, holding needles whose locally-rarest byte
//! the shipped table ranks common — `zeqXtj`, `tzeQjq`, `ezQtj`, three of them so a
//! row is not one needle's luck. Wall clock on a 200 MB mmap is mostly page-fault
//! noise, which is why CPU is the reported quantity.)
//!
//!     -Fc / -F / -Fn / -Fo / --count-matches   6.9–8.0x
//!     --json  /  --json -o                     7.8x / 8.3x
//!     -q  (presence, one jump)                 7.0x
//!     -Fl  (exits at the first hit)            4.5–4.7x
//!     regex, required literal, -o / --count-matches   2.00x    -l  4.6x
//!     regex per-line modes (-c/-n/-w/-U/-A)    1.23–1.26x      -i  1.00x (no pair)
//!
//! Ground truth under the CLI: one hit-to-hit kernel sweep in the `fileLit` loop
//! shape, clocked inside the kernel so intake, walk and emit stay out of the timed
//! region, best of 3 per arm with the hit count asserted equal across arms. That
//! sweep is 70 ms on the table's pair and 3.9–4.0 ms re-priced, **17.6–17.9x**
//! — and the table's pair takes the *single*-probe shape there, so the fast loop on
//! the wrong byte loses to the two-probe loop on the right pair by an order of
//! magnitude. Selectivity underneath: 4.09 M block survivors on the static pair,
//! 34–42 on the calibrated one.
//!
//! Neutral where the table is already right — median 1.002x (min 0.996x, max 1.012x)
//! over 15 mode×needle rows on a 213 MB many-small-files code tree, where the size
//! gate declines in two comparisons. Read the MEDIAN of repeats there and not the
//! best-of-N: at ~0.03 s a run, one lucky outlier in either arm reads as a 1.4x
//! swing, which is how a phantom `-q` regression was manufactured and then dissolved
//! by nine paired reps. Output is byte-identical: 411/411 rgsuite parity on both
//! engines, and 420 in-binary mode×needle×corpus differentials with zero divergence.
//!
//! The two ceilings are structural, not wiring gaps. `-i` has no pair to choose
//! (`containsCaseless` is a different kernel). The per-line ENGINE modes cap near
//! the whole-file gate's contribution because a 60-byte line is one block, where the
//! choice of two offsets inside it barely moves anything — every 7–8x row is a
//! whole-buffer hit-jumping sweep, which is the shape the pair actually governs.
//! The same split shows inside one engine mode: `-o`/`--count-matches` reach 2.00x
//! because they sweep, while `-c`/`-n` over the same pattern stay at 1.25x.
//!
//! The wiring that is still WRONG — swap `anchorsOf(needle)` for a calibrated
//! pair inside `simd.zig::indexOfPos` itself — **cannot pay, and would
//! re-commit a defect this package has already recorded twice.**
//!
//! 1. **The size gate can never fire at that call site.** `indexOfPos` is not
//!    called once per buffer. `query.zig::countGeneric` calls
//!    `simd.contains(line, needle)` **once per line**, and the whole-document
//!    literal gate calls it once per document. The gate here needs
//!    `len >= 16 * k * budget` — 3.1 MB for a 3-byte needle, 7.3 MB at the
//!    median needle length of 7. A line is tens of bytes; almost no document
//!    clears 3 MB. So at `indexOfPos` this module returns `null` on
//!    approximately every real call, and the measured 1.04x/1.03x/1.03x —
//!    taken by calibrating ONCE over a 213 MB buffer — describes a call shape
//!    production does not have. Removing the gate does not fix it; it inverts
//!    it, re-paying 3.5-36.8 us per line.
//! 2. **It would put the roofline control back out of sync with the kernel.**
//!    `bench/bounds/roofline/bandwidth.zig` builds its control from
//!    `simd.anchorsOf` / `simd.singleProbeEligible`, which are published for
//!    exactly that purpose. A calibrated pair inside `indexOfPos` that those
//!    two functions cannot see means the control bounds a filter production
//!    never runs — the same mistake as the local `suggestVectorLength` below
//!    and the first+last control above it.
//! 3. **`singleProbeWorthwhile` would be asked a question it cannot answer.**
//!    It prices the probe byte against the STATIC table. A calibrated pair can
//!    hold a byte that is statically rare and locally common, which is the one
//!    input that makes the single-probe shape lose (measured at halved
//!    throughput on a uniform-random buffer). The in-loop demotion counter
//!    catches it, but only after paying for it.
//!
//! The seam this needed — and now has — is a **per-scan plan**: calibrate once
//! when a document is admitted, then thread the chosen pair through every line of
//! that document. That is `simd.Plan` + `indexOfPosWith(hay, from, needle, plan)`,
//! with `indexOfPos` keeping the static behavior the roofline control reads, the
//! plan owned by `CompiledQuery`, and the gate on the DOCUMENT size rather than
//! the per-call slice. Defect 3 above is why an adopted pair still declares
//! `single = false`, and why `refine` declining is the outcome that preserves the
//! single-probe shape.
//!
//! `block_bytes` is a PARAMETER, not a local constant: the caller owns the
//! block stride and this module must not re-derive it. RECORDED DEFECT
//! (2026-07-29): `bench/bounds/roofline` declared `suggestVectorLength(u8)
//! orelse 16` locally — 16 bytes on NEON against the kernel's 64 — and
//! consequently measured a different kernel than the one it claimed to bound.
//! The one number this module does own is the 64 in `word_bits`, which is the
//! bit width of a survivor-accumulator word and has nothing to do with the
//! block stride; `block_bytes` decides window ALIGNMENT so every sampled window
//! is a whole run of the caller's blocks.

const std = @import("std");
const bits = @import("../math/bits.zig");

/// Sampling budget, window grain, and candidate-offset cap. Public because a
/// benchmark that re-declares these is measuring a different selector — the
/// same reason `simd.zig` publishes `block_bytes` and `anchorsOf`.
pub const Config = struct {
    /// Total sampled bytes. Cost is `k x budget_bytes`, so this is the whole
    /// price and it sets the size gate.
    budget_bytes: usize,
    /// Stratification grain — one contiguous window, spread evenly with its
    /// siblings across the whole buffer. Must be a multiple of `word_bits`.
    window_bytes: usize,
    /// Candidate offsets considered. `C(cap,2)` pairs are priced, so this is
    /// quadratic in pricing and linear in sampling cost.
    max_offsets: usize,
};

/// The shipped tuning, from the budget x window x cap sweep in
/// `research/pincer/` (aggregate survivors vs the oracle, code/prose/hetero):
///
///     budget    64 KB: 1.03x / 1.02x / 1.04x     256 KB: 1.02x / 1.01x / 1.01x
///     window    256 B: 1.03/1.02/1.04   1 KB: 1.08/1.05/1.05   4 KB: 1.11/1.08/1.05
///               8 KB: 1.11/1.05/1.11    16 KB: 1.19/1.05/1.11
///     cap       4: 1.43/1.50/1.31   8: 1.14/1.09/1.06   12: 1.12/1.08/1.05   16: 1.11/1.08/1.05
///
/// 64 KB is the striking budget: it buys essentially all of the available win
/// for 0.19% of a 214 MB scan, where 256 KB buys another ~1% of oracle for 4x
/// the price and a 4x higher size gate. Small windows beat large ones at a
/// FIXED budget in all three regimes — 256 B spends the same bytes on 256
/// strata instead of 16, and heterogeneity is what the budget is fighting. The
/// cap is 16 because 12 and 16 are within noise of each other while 8 costs
/// 2-3% on code, and because needles of 16 bytes or fewer (mean 7.4, median 7,
/// max 16 in the measured code slate) then use every offset they have.
///
/// DIVERGENCE from `research/pincer/` §7, which used 4 KB windows: at a fixed
/// budget that is measurably the wrong grain. 4 KB is 1.11x/1.08x/1.05x where
/// 256 B is 1.03x/1.02x/1.04x — the same bytes, ~7% closer to oracle on code,
/// for strictly less stack (`k x window_bytes / 8` = 512 B rather than 8 KB).
pub const shipped: Config = .{
    .budget_bytes = 64 << 10,
    .window_bytes = 256,
    .max_offsets = 16,
};

/// Bit width of one survivor-accumulator word — NOT the caller's block stride
/// (that is `block_bytes`). A `u64` holds 64 candidate positions, so one
/// vector-equality pass over 64 bytes yields exactly one word.
const word_bits: usize = @bitSizeOf(u64);

/// How many times the buffer must exceed the sampling cost before calibrating.
/// Derived from rates measured on this kernel, not chosen round:
///
///   calibration = k x budget / R_cal        scan = len / R_scan
///   saving      = (len / R_scan) x (1 - 1/speedup)
///
/// Measured here (2026-07-29, M4; both rates taken through the shipped code
/// paths rather than a replica, page cache pre-warmed by a full pass, best of 5):
/// a fully-filtered scan of the 213 MB code tree — an absent rare needle, so
/// every block is filtered out — runs at R_scan = 37.9 GB/s,
/// and calibrating at the shipped budget costs 3.5 us at k = 3 rising to
/// 36.8 us at k = 16 — `R_cal / R_scan` = 1.46 falling to 0.76, because the
/// sampling reads `k` streams out of cache (fast) while paying a pricing term
/// quadratic in `k` (slow). Take the ratio as 1.0.
///
/// The SAVING is the term not to overstate. Repairing the anchors is worth
/// 1.13x on code and 1.25x on prose in wall clock — `research/pincer/` §4,
/// measured against the unclamped table, which is the regime today's
/// `anchor.zig` is in (1.50x / 2.21x oracle above). So `1 - 1/speedup` is 0.12
/// to 0.20, NOT the 0.49 that §4's clamped-table baseline suggests, and
/// break-even is
///
///   len >= k x budget x (R_scan/R_cal) / 0.12 = 6.4 x k x budget   (code)
///                                     / 0.20 = 3.5 x k x budget   (prose)
///
/// 16 is that with 2.5-4.6x of margin, and the margin is deliberate: the static
/// table already picks the oracle pair on 80/177 code needles, where sampling
/// is pure loss. The factor bounds that loss at `1/16 x (R_scan/R_cal)` of one
/// scan — 4.3% at k = 3, 8.2% at k = 16 — against an expected 12-20% win. A
/// factor at break-even would instead make the threshold a coin flip.
///
/// Thresholds at the shipped 64 KB budget: 3.1 MB for a 3-byte needle, 7.3 MB
/// at the median code needle length of 7, 16.8 MB at the 16-offset cap.
const gate_factor: usize = 16;

/// Price every candidate anchor pair on a stratified sample of `hay` and return
/// the cheapest as `.{ probe, confirm }` with `probe <= confirm`. Returns null
/// when the buffer is too small for the sampling to pay for itself, in which
/// case the caller keeps its static choice.
///
/// Prefer `refine` in production: this reports the sample's favorite with no
/// regard for what the caller already had, so a caller that adopts it
/// unconditionally pays for a swap even when the two agree. See `refine`.
pub fn best(hay: []const u8, needle: []const u8, block_bytes: usize) ?[2]usize {
    return tuned(shipped, hay, needle, block_bytes);
}

/// `best` at an explicit tuning — the seam the sweep in `research/pincer/`
/// drives, so the measured curve describes THIS code and not a replica of it.
pub fn tuned(comptime cfg: Config, hay: []const u8, needle: []const u8, block_bytes: usize) ?[2]usize {
    var offs: [cfg.max_offsets]usize = undefined;
    var seen: [cfg.max_offsets][cfg.max_offsets]u32 = undefined;
    const k = sample(cfg, hay, needle, block_bytes, &offs, &seen) orelse return null;
    const win = cheapest(cfg, offs[0..k], &seen);
    return .{ offs[win.a], offs[win.b] };
}

/// `best`, but as an IMPROVEMENT TEST against the pair the caller already holds:
/// null means "keep what you have", and a pair means the sample says the
/// incumbent is materially worse. `incumbent` is a pair of needle offsets in
/// either slot order (`anchor.Pair` is not sorted — its slots carry meaning).
///
/// RECORDED DEFECT (2026-07-30): the first wiring adopted `best` unconditionally
/// and was a measured 0.5–1.1% CPU *tax* end-to-end, with no row it won. Two
/// mechanisms, both invisible to a survivor-count sweep:
///
///  1. The static table already picks the oracle pair on 80/177 code needles
///     (§ the module head). On those the swap buys nothing, so all that is left
///     of it is the sampling.
///  2. Adopting a calibrated pair forfeits the single-probe block shape —
///     `singleProbeWorthwhile` prices against the STATIC table and cannot judge
///     a calibrated byte (defect 3 above). So a needle whose static plan was
///     single-probe-eligible gets *demoted* by a swap that gains nothing.
///
/// Both vanish once the incumbent competes on the same sample. It is pinned into
/// the candidate set, priced with everything else, and displaced only when the
/// winner beats it by `margin_shift` — which is why declining is the common
/// answer and the caller keeps its `single` eligibility with it.
pub fn refine(hay: []const u8, needle: []const u8, block_bytes: usize, incumbent: [2]usize) ?[2]usize {
    return refineTuned(shipped, hay, needle, block_bytes, incumbent);
}

/// The RELATIVE half of the margin, as a right shift: a winner must save at
/// least `1/2^n` of the incumbent's sampled survivors. 3 (12.5%) separates the
/// two measured populations cleanly and is not a tuned constant — when the table
/// is right it aggregates to 1.00–1.04x the oracle, and when it is wrong it is
/// 1.39–2.21x (§ the module head), so anything inside a few percent is sampling
/// variance on a decision that does not matter.
const margin_shift: u5 = 3;

/// The ABSOLUTE half, in standard deviations of the incumbent's own count.
///
/// RECORDED DEFECT (2026-07-30): a purely relative margin is a winner's curse.
/// `cheapest` is the argmin of `C(k,2)` — up to 120 — noisy estimates of the same
/// underlying density, so its expected value sits several sigma BELOW the true
/// minimum even when every pair is truly identical. The randomized suite caught
/// it immediately: on a 6-letter alphabet, where all 120 pairs have the same true
/// density by construction, a 34-byte needle's sample claimed a >12.5% win over
/// an incumbent that was in fact 0.3% BETTER over the whole buffer. The relative
/// floor cannot see this because the bias scales with `sqrt(count)`, not with
/// `count`.
///
/// A survivor count is a sum of Bernoulli trials, so its standard deviation is
/// `~sqrt(count)`; 4 sigma covers the multiplicity at `k = 16` (a 120-way argmin
/// reaches ~3.5 sigma routinely). This term dominates at small sampled counts —
/// which is exactly where the relative floor is worthless — and is negligible at
/// the shipped budget's thousands, where the relative floor takes over. Take the
/// larger of the two and both regimes are covered by one comparison.
const noise_sigmas: f64 = 4.0;

/// Is the winner enough better than the incumbent to be worth swapping to?
/// Both halves of the margin, whichever binds harder. `>=` and not `>` on the
/// way out: two pairs that tie are the same decision, and the incumbent is the
/// one whose `single` eligibility is already known-good.
fn worthSwapping(win: u32, incumbent: u32) bool {
    const relative = incumbent >> margin_shift;
    const noise: u32 = @intFromFloat(noise_sigmas * @sqrt(@as(f64, @floatFromInt(incumbent))));
    return win + @max(relative, noise) < incumbent;
}

/// `refine` at an explicit tuning.
pub fn refineTuned(
    comptime cfg: Config,
    hay: []const u8,
    needle: []const u8,
    block_bytes: usize,
    incumbent: [2]usize,
) ?[2]usize {
    var offs: [cfg.max_offsets]usize = undefined;
    var seen: [cfg.max_offsets][cfg.max_offsets]u32 = undefined;

    // Order matters: the incumbent has to be in the candidate set BEFORE the
    // sample is taken, or it cannot be priced on the same bytes as its rivals.
    const k = layout(cfg, hay, needle, &offs) orelse return null;
    const held = pin(offs[0..k], incumbent) orelse return null;
    if (!measure(cfg, hay, needle, block_bytes, offs[0..k], &seen)) return null;

    const win = cheapest(cfg, offs[0..k], &seen);
    if (!worthSwapping(win.cost, seen[held[0]][held[1]])) return null;
    return .{ offs[win.a], offs[win.b] };
}

/// The candidate offsets plus the gates that decide whether sampling can pay at
/// all. Null is "decline"; the return is how many of `offs` were filled.
fn layout(comptime cfg: Config, hay: []const u8, needle: []const u8, offs: *[cfg.max_offsets]usize) ?usize {
    comptime std.debug.assert(cfg.window_bytes % word_bits == 0);
    comptime std.debug.assert(cfg.budget_bytes >= cfg.window_bytes);
    comptime std.debug.assert(cfg.max_offsets >= 2);

    // A 2-byte needle has exactly one pair, so every selector agrees and
    // sampling can only cost. Nothing to decide is not the same as a cheap
    // decision.
    if (needle.len < 3) return null;

    // The size gate, before any work at all: the candidate count is `min(len,
    // cap)` by construction, so the decision to decline needs no offset scan and
    // a small buffer really does pay zero — two comparisons and a return in the
    // generated code, not "very little".
    const k = @min(needle.len, cfg.max_offsets);
    if (hay.len / gate_factor < k * cfg.budget_bytes) return null;

    const filled = candidates(cfg.max_offsets, needle.len, offs);
    std.debug.assert(filled == k);
    return k;
}

/// `layout` then `measure` — the whole sample for a caller with no incumbent.
fn sample(
    comptime cfg: Config,
    hay: []const u8,
    needle: []const u8,
    block_bytes: usize,
    offs: *[cfg.max_offsets]usize,
    seen: *[cfg.max_offsets][cfg.max_offsets]u32,
) ?usize {
    const k = layout(cfg, hay, needle, offs) orelse return null;
    if (!measure(cfg, hay, needle, block_bytes, offs[0..k], seen)) return null;
    return k;
}

/// Force `want` into an already-sorted candidate set, so the incumbent is priced
/// on the same sample as its rivals. Offsets at or under the cap already hold
/// every offset the needle has, so this is a no-op there; past the cap each
/// wanted offset displaces its nearest neighbor. A slot holding a wanted value
/// is never evicted, and a value already present is never re-inserted, so the
/// set stays strictly increasing — which the `probe < confirm` invariant below
/// depends on. Returns the incumbent's `[lo, hi]` indices into the set.
fn pin(offs: []usize, want: [2]usize) ?[2]usize {
    for (want) |w| {
        if (std.mem.indexOfScalar(usize, offs, w) != null) continue;
        var victim: usize = 0;
        var nearest: usize = std.math.maxInt(usize);
        for (offs, 0..) |o, i| {
            if (o == want[0] or o == want[1]) continue;
            const d = if (o > w) o - w else w - o;
            if (d < nearest) {
                nearest = d;
                victim = i;
            }
        }
        if (nearest == std.math.maxInt(usize)) return null;
        offs[victim] = w;
    }
    std.mem.sort(usize, offs, {}, std.sort.asc(usize));
    const a = std.mem.indexOfScalar(usize, offs, want[0]) orelse return null;
    const b = std.mem.indexOfScalar(usize, offs, want[1]) orelse return null;
    if (a == b) return null; // a degenerate incumbent has nothing to compare
    return if (a < b) .{ a, b } else .{ b, a };
}

/// Fill `seen[a][b]` with how many sampled positions survive the pair
/// `(offs[a], offs[b])`. False when the buffer cannot host one window.
fn measure(
    comptime cfg: Config,
    hay: []const u8,
    needle: []const u8,
    block_bytes: usize,
    offs: []const usize,
    seen: *[cfg.max_offsets][cfg.max_offsets]u32,
) bool {
    std.debug.assert(block_bytes > 0);
    const k = offs.len;

    // One window reads `window_bytes` candidate positions at every offset, so
    // it touches `[lo, lo + window_bytes + needle.len - 1)`. Solving for the
    // last legal start makes the last sampled position exactly `hay.len -
    // needle.len` — the last real candidate start — so the geometry needs no
    // separate tail guard.
    const reach = cfg.window_bytes + needle.len - 1;
    if (hay.len < reach + 1) return false;
    const last_lo = hay.len - reach;

    const window_words = cfg.window_bytes / word_bits;
    var n_win = cfg.budget_bytes / cfg.window_bytes;
    const stride = if (n_win > 1) last_lo / (n_win - 1) else 0;
    if (stride == 0) n_win = 1;

    // The whole working set: `k x window_words` words of bitvector (512 B at
    // the shipped tuning) plus the pair matrix (1 KB). Built one window at a
    // time deliberately — a bitvector over the WHOLE budget would be
    // `k x budget_bytes / 8` = 8 KB at 64 KB, and 128 KB at a 1 MB budget,
    // which is not a thing to put on a worker thread's stack. Survivor counts
    // are additive over disjoint position ranges, so windowing is exact, not an
    // approximation.
    seen.* = @splat(@splat(0));
    var vec: [cfg.max_offsets][window_words]u64 = undefined;

    for (0..n_win) |w| {
        // Align down to the caller's block stride so a sampled window is a
        // whole run of the blocks the kernel will actually run. `last_lo` is
        // the clamp, and aligning down can only move `lo` lower, so both
        // bounds hold.
        const raw = @min(w * stride, last_lo);
        const lo = raw - raw % block_bytes;
        for (vec[0..k], offs[0..k]) |*v, off| fill(v, hay, lo, off, needle[off]);
        for (0..k) |a| for (a + 1..k) |b| {
            var s: u32 = 0;
            for (vec[a], vec[b]) |x, y| s += @popCount(x & y);
            seen[a][b] += s;
        };
    }
    return true;
}

/// Argmin over the priced pairs, ties to the WIDEST separation — the same
/// structural anti-correlation axis `anchor.zig` breaks its ties on, and for the
/// same reason: a tie means the evidence has no opinion, and separation is the
/// only correlation-reducing axis available without a model. The accumulator
/// starts at `maxInt` and at the widest pair, so no pair can fail to displace
/// the initialiser — the recorded `0:1` collapse next door was exactly a strict
/// `<` against initialisers that were already the answer.
fn cheapest(
    comptime cfg: Config,
    offs: []const usize,
    seen: *const [cfg.max_offsets][cfg.max_offsets]u32,
) struct { a: usize, b: usize, cost: u32 } {
    const k = offs.len;
    var bi: usize = 0;
    var bj: usize = k - 1;
    var low: u32 = std.math.maxInt(u32);
    var spread: usize = 0;
    for (0..k) |a| for (a + 1..k) |b| {
        const s = seen[a][b];
        const d = offs[b] - offs[a];
        if (s < low or (s == low and d > spread)) {
            low = s;
            spread = d;
            bi = a;
            bj = b;
        }
    };

    // Structural invariant. The pair changes only WHICH filter runs — the
    // caller always `eql`-verifies survivors — so a wrong-but-valid pair is a
    // throughput bug, while an out-of-bounds offset is memory corruption at
    // `hay[i + confirm ..][0..block_bytes]`.
    std.debug.assert(offs[bi] < offs[bj]);
    return .{ .a = bi, .b = bj, .cost = low };
}

/// The offsets a pair may be drawn from: every offset of a needle up to the
/// cap, else `cap` of them spread evenly with both ends included.
///
/// Which 16 barely matters; HAVING only 16 does. Measured on 80 needles of
/// 20-64 bytes over a 213 MB code tree, against an oracle free to use every
/// offset the needle has: even spacing 3.14x, first-16 3.55x, last-16 3.08x,
/// random-16 3.23x. So the cap costs ~3x on needles long enough for it to bite
/// and the choice among subsets costs at most 15% — a rarity-ranked
/// preselection has almost nothing to win here, which is why this module takes
/// no rarity parameter and stays independent of `rarity.zig`. Even spacing is
/// the deterministic subset that maximizes the minimum gap while keeping offset
/// 0 and `len - 1`, and reaching WIDE pairs is what `research/pincer/` §6 found
/// the joint objective actually depends on.
///
/// Capping is still worth it on those needles: on the same slate (64 MB code)
/// the static table aggregates to 4.96x oracle where the capped calibrator
/// reaches 2.97x. The median needle is slightly worse (4.31x vs 3.83x) and 40
/// of 80 lose to the table, but by ~0.001pp of survivor density each, so the
/// aggregate — which is what the scan pays — improves.
fn candidates(comptime cap: usize, n: usize, out: *[cap]usize) usize {
    if (n <= cap) {
        for (out[0..n], 0..) |*o, i| o.* = i;
        return n;
    }
    // `n - 1 >= cap > cap - 1`, so consecutive offsets differ by at least
    // `(n - 1) / (cap - 1) >= 1`: strictly increasing, ending on `n - 1`.
    for (out, 0..) |*o, t| o.* = t * (n - 1) / (cap - 1);
    return cap;
}

/// One offset's match bitvector over the window at `lo`: bit `p` of word `w` is
/// set iff `hay[lo + word_bits*w + p + off] == b`.
///
/// `bits.blockMask` rather than a bitcast movemask per 16 lanes: this loop pays
/// a movemask for EVERY word (the kernel pays one only inside blocks its cheap
/// `anyLane` gate already proved hot), and on NEON the per-chunk
/// `@bitCast(bool16)` is a shift-narrow ladder each, where the simdjson fold
/// collapses 64 lanes with three `addp`s.
fn fill(out: []u64, hay: []const u8, lo: usize, off: usize, b: u8) void {
    const V = @Vector(16, u8);
    const splat: V = @splat(b);
    for (out, 0..) |*word, w| {
        const base = lo + w * word_bits + off;
        var chunks: [word_bits / 16]@Vector(16, bool) = undefined;
        inline for (&chunks, 0..) |*c, t| c.* = @as(V, hay[base + t * 16 ..][0..16].*) == splat;
        word.* = bits.blockMask(chunks);
    }
}

//! gist — the anchor decision priced on the buffer being searched.
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
//! ## NOT WIRED, and the reason is a call-shape mismatch — read before wiring
//!
//! Nothing calls this yet. It is registered in `root.zig` so it builds and its
//! tests run, and that is deliberately as far as it goes. The obvious wiring —
//! swap `anchorsOf(needle)` for a calibrated pair inside
//! `simd.zig::indexOfPos` — **cannot pay, and would re-commit a defect this
//! package has already recorded twice.**
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
//! The seam this actually needs is a **per-scan plan**: calibrate once when a
//! document is admitted, then thread the chosen pair through every line of that
//! document — `indexOfPosWith(hay, from, needle, pair)`, with `indexOfPos`
//! keeping today's static behavior, the plan owned by `CompiledQuery`, and the
//! gate moved onto the DOCUMENT size rather than the per-call slice. That is an
//! interface change across `simd.zig` and `query.zig`, and it is the decision
//! this module is waiting on — not a missing import.
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
/// Measured here (2026-07-29, M4, `spikes/anchor-calibrate/time.zig`):
/// a fully-filtered scan of the 213 MB code tree runs at R_scan = 37.9 GB/s,
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
pub fn best(hay: []const u8, needle: []const u8, block_bytes: usize) ?[2]usize {
    return tuned(shipped, hay, needle, block_bytes);
}

/// `best` at an explicit tuning — the seam the sweep in `research/pincer/`
/// drives, so the measured curve describes THIS code and not a replica of it.
pub fn tuned(comptime cfg: Config, hay: []const u8, needle: []const u8, block_bytes: usize) ?[2]usize {
    comptime std.debug.assert(cfg.window_bytes % word_bits == 0);
    comptime std.debug.assert(cfg.budget_bytes >= cfg.window_bytes);
    comptime std.debug.assert(cfg.max_offsets >= 2);
    std.debug.assert(block_bytes > 0);

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

    var offs: [cfg.max_offsets]usize = undefined;
    const filled = candidates(cfg.max_offsets, needle.len, &offs);
    std.debug.assert(filled == k);

    // One window reads `window_bytes` candidate positions at every offset, so
    // it touches `[lo, lo + window_bytes + needle.len - 1)`. Solving for the
    // last legal start makes the last sampled position exactly `hay.len -
    // needle.len` — the last real candidate start — so the geometry needs no
    // separate tail guard.
    const reach = cfg.window_bytes + needle.len - 1;
    if (hay.len < reach + 1) return null;
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
    var seen: [cfg.max_offsets][cfg.max_offsets]u32 = @splat(@splat(0));
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

    // Argmin, ties to the WIDEST separation — the same structural
    // anti-correlation axis `anchor.zig` breaks its ties on, and for the same
    // reason: a tie means the evidence has no opinion, and separation is the
    // only correlation-reducing axis available without a model. The accumulator
    // starts at `maxInt` and at the widest pair, so no pair can fail to
    // displace the initialiser — the recorded `0:1` collapse next door was
    // exactly a strict `<` against initialisers that were already the answer.
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

    // Structural invariants. The pair changes only WHICH filter runs — the
    // caller always `eql`-verifies survivors — so a wrong-but-valid pair is a
    // throughput bug, while an out-of-bounds offset is memory corruption at
    // `hay[i + confirm ..][0..block_bytes]`.
    const probe = offs[bi];
    const confirm = offs[bj];
    std.debug.assert(probe < confirm);
    std.debug.assert(confirm < needle.len);
    return .{ probe, confirm };
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
/// the deterministic subset that maximises the minimum gap while keeping offset
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

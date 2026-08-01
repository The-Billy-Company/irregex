//! gist — dwell: the states a scan sits still in, and the bytes that get it out.
//!
//! A scan parked in state `s` reading byte `b` either goes somewhere — a different
//! interior state, or a match at end-of-line — or it stays in `s`. If it stays,
//! reading `b` changed nothing, so a scanner may *skip* `b` outright. Collect the
//! bytes that don't stay and you have the state's **exit set**: the smallest thing
//! a skip has to stop for. A state whose exit set is narrow is a state you can
//! `memchr` your way out of instead of walking a byte at a time.
//!
//! **This module owns one question:** given a finished automaton and a state,
//! which bytes leave it, and is that set selective enough that skipping beats
//! stepping. That is a property of one state's out-transitions — derivable,
//! decidable, and local.
//!
//! **It deliberately owns nothing else.** It does not own how a skip is executed;
//! that is `analysis/prefilter.zig` and the vector range kernels beneath it. It
//! has no claim on the trigram index, the parabix bitstream lane, the SIMD
//! shuffle path, or the sieve. Every one of those makes something faster, and
//! "makes something faster" is exactly the membership rule that would turn this
//! file into the place all of them end up. A fast path is not a dwell. The test
//! for admission here is structural, not consequential: does it answer *which
//! bytes leave a state?*
//!
//! Why it sits in `automata/` — the exit set is read off transition rows, so it
//! cannot tell whether the byte powerset construction or the symbolic decoder
//! product built them. Both roads want it and neither owns it. See this folder's
//! README for the membership rule it inherits.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const prefilter = @import("../../analysis/prefilter.zig");
const Dfa = @import("../dfa/dfa.zig").Dfa;

/// Widest exit set the vector range kernel can price without dropping to a scalar
/// byte-set probe. Cardinality alone does not decide admission — four rare bytes
/// skip farther than one common byte — so this is a ceiling on what the kernel can
/// express, and `Prefilter`'s corpus economics has the last word on whether the
/// skip is worth arming.
pub const max_exit_bytes: usize = 8;

/// Bytes of expected stride a skip must clear to be worth arming over stepping.
/// Calibrated for the START state, whose skip may run across newlines and so has no
/// line-length ceiling.
///
/// **Independently confirmed at 30 bytes for interior states, which was not
/// expected.** An interior dwell must stop at every `\n`, capping its stride at the
/// mean line length, so this number had no reason to transfer. `automata-rung --
/// dwell` built the interior skip and swept the line length — the only knob that
/// moves the realized stride without touching the automaton, alphabet, or
/// instruction mix — and its ratio against the shipped multi-lane walk crosses
/// 1.000× between a 23.1-byte stride (0.79×) and a 31.0-byte one (1.03×). Waiving
/// this bar arms the skips below it and costs 0.41× geomean. Claim C4 is retired on
/// that measurement; see `research/automata/CLAIM.md`.
///
/// `survey` still takes it as an argument, because passing 0 is how a caller
/// separates the automaton's shape from this threshold's opinion.
pub const min_profitable_stride: u16 = 32;

/// What a byte costs the **span** walk, in units of what it costs the boolean
/// walk this file's bar was calibrated against. A boolean step is a
/// premultiplied table load; a span step reaches through a state's priority key
/// to decide dead/matched, re-derives the gap's shape, and indexes a memo row
/// keyed on both — a dependent-load chain, not one load. First measured at 3.2 ns
/// per byte, walking one megabyte to its end with no match and no skip armed,
/// stable across three patterns, against the boolean walk's ~0.25 — which brackets
/// what `zig build automata-rung -- burst` reports for the mirrored doc walk,
/// 0.23–0.36 ns/byte over an 8 MiB match-free document. That puts the true figure
/// nearer 13; taken conservatively low, because underrating the walker can only
/// make the bar *stricter* than break-even.
///
/// The span walk has since got cheaper per byte — offset-currency cells took it
/// to 1.49 ns, so the honest ratio is now ~6 and this 8 sits a little *above* it
/// rather than below. Left as it is deliberately: a bar of 4 against a
/// break-even nearer 5 is a difference no measurement here can see (`bar=4` and
/// `bar=5` are within noise of each other on both the saturated line and the
/// real tree), and the failure it now risks is the cheap one. Skipping a hair
/// too eagerly wastes one `memchr` per span; the bar being too *high* is what
/// caused the original 31× — and it is the more expensive mistake in both
/// directions of this drift, since a cheaper walker also makes an over-strict
/// bar hurt less than it did. Re-derive from a fresh measurement before moving
/// it, not from this arithmetic.
const span_step_cost: u16 = 8;

/// The same bar, restated for the span walk.
///
/// A skip trades one fixed cost — a `memchr` call plus a re-entry closure — for
/// not walking `stride` bytes. **The fixed cost does not change when the walker
/// gets more expensive**, so break-even scales with the per-byte cost alone, and
/// a bar calibrated on the boolean walk is roughly an order of magnitude too
/// strict here. Concretely: it withheld the skip from every pattern beginning
/// with a merely-uncommon byte (`f` prices at stride 16), which is most of them,
/// and those patterns then walked every byte between matches — 31× the cost of
/// the memchr that was available the whole time.
///
/// Floored at 2: a stride of 1 means every byte is a candidate, where a skip is
/// pure overhead no matter what it stands down.
pub const min_profitable_span_stride: u16 = @max(2, min_profitable_stride / span_step_cost);

/// A state worth dwelling in, and the exit set that ends the dwell. `state` is in
/// whatever coordinate the caller's tables use — a state id before freezing, a
/// premultiplied row offset after.
pub const Skippable = struct {
    state: u32,
    exits: prefilter.Prefilter,
};

/// The pre-freeze view: transition tables still expressed in state ids, with match
/// status in a side array. This is what a determinizer holds at fixpoint.
const Ids = struct {
    trans_in: []const u32,
    trans_fin: []const u32,
    is_match: []const bool,

    fn matched(v: Ids, target: u32) bool {
        return v.is_match[target];
    }
};

/// The frozen view: the automaton as it ships. Values are premultiplied row
/// offsets and match status is the C1 bound, so "did this target match?" is a
/// compare rather than a load. Premultiplication is monotone in the id, so
/// comparing offsets decides state identity exactly as comparing ids would.
const Frozen = struct {
    trans_in: []const u32,
    trans_fin: []const u32,
    match_hi: u32,

    fn matched(v: Frozen, target: u32) bool {
        return target < v.match_hi;
    }
};

/// The one transcription of the exit-set rule, over either view.
///
/// Byte `b` must stop a skip parked in `self` when it either (a) leaves `self` for
/// a different interior state — the progress case — or (b) produces a match at
/// end-of-line through `trans_fin`, the `$` case where `b` keeps `self` in itself
/// yet still matches as the line's last byte (`;$`, `\w+$`). Every other byte both
/// keeps `self` in itself and cannot match under `$`, so it is provably skippable.
///
/// `cross_lines` says whether the skip may run past `\n`. When it may not, `\n`
/// is pinned into the exit set so the scanner stops there and the byte-at-a-time
/// loop resolves the line boundary. When it may, crossing `\n` while parked is a
/// pure no-op and omitting it lets the skip `memchr` straight across newlines —
/// and for a single exit byte collapses the prefilter to a one-byte `memchr`
/// instead of a two-range scan (ripgrep's exact `;$` strategy).
fn exitsOf(
    view: anytype,
    class: *const [256]u8,
    ncls: u16,
    self_val: u32,
    cross_lines: bool,
    min_stride: u16,
) Verdict {
    const base = @as(usize, self_val) * @as(usize, ncls);
    var exits: syn.ByteSet = .{};
    var n: usize = 0;
    for (0..256) |bi| {
        const b: u8 = @intCast(bi);
        if (b == '\n') continue; // line boundary, decided separately below
        const off = base + class[b];
        if (view.trans_in[off] != self_val or view.matched(view.trans_fin[off])) {
            exits.set(b);
            n += 1;
        }
    }
    if (n == 0) return .sealed;
    if (n > max_exit_bytes) return .porous;
    const nl = base + class['\n'];
    const nl_exits = view.trans_in[nl] != self_val or view.matched(view.trans_fin[nl]);
    if (!cross_lines or nl_exits) exits.set('\n');
    const pf = prefilter.Prefilter.init(exits);
    return if (pf.economics.beatsDense(min_stride)) .{ .skippable = pf } else .unprofitable;
}

/// Why a state is or is not worth skipping out of. The three refusals are
/// different facts about the automaton, and collapsing them to `null` is what
/// makes a survey of zero unreadable — a corpus that says "stepping is cheaper"
/// is a threshold, where a sealed sink is a shape.
pub const Verdict = union(enum) {
    /// Narrow exit set, and the corpus prior says skipping to it beats stepping.
    skippable: prefilter.Prefilter,
    /// No byte leaves this state at all: a sink. There is nothing to skip *to*,
    /// and a scan that entered it has already decided the line.
    sealed,
    /// The exit set is wider than the vector kernel prices, so every skip would
    /// stop almost immediately. Common for states mid-way through a character
    /// class, where most of the alphabet makes progress.
    porous,
    /// Narrow enough to express, but the bytes in it are common enough that the
    /// expected stride doesn't cover the cost of arming the skip. This is the
    /// interesting refusal: it is a *threshold*, so it moves with the corpus
    /// prior rather than with the automaton.
    unprofitable,
};

/// The frozen view's row offset for state `self_val` is already `self_val`, so the
/// shared derivation's `id * ncls` would square it. Freezing premultiplies every
/// value; this view therefore passes `ncls = 1` and lets `self_val` be the base.
const premultiplied: u16 = 1;

/// The start state's dwell, derived from its transition row before freezing.
///
/// Anchored programs decline: there is no re-seed, so the scan does not park in
/// start waiting for a match to begin — it dies. Word-context programs decline
/// too, at the caller, because their split start and doubled interior table are
/// not the row shape this models. Both are optimizations, never correctness
/// levers.
///
/// Callers pass id-based (never premultiplied) tables — this reasons about state
/// identity, not row offsets. Both drivers reach it on ROW-LOCAL data only, which
/// the eager driver has at fixpoint and the on-demand driver gets from
/// `Subset.forceStartRow`; hence the same skip on the same patterns either way.
pub fn ofStart(
    anchored: bool,
    empty_match: bool,
    trans_in: []const u32,
    trans_fin: []const u32,
    is_match: []const bool,
    class: *const [256]u8,
    ncls: u16,
    start_id: u32,
) ?prefilter.Prefilter {
    if (anchored) return null;
    const view = Ids{ .trans_in = trans_in, .trans_fin = trans_fin, .is_match = is_match };
    // An empty line can match ⇒ the skip must stop at every `\n` to resolve it.
    return switch (exitsOf(view, class, ncls, start_id, !empty_match, min_profitable_stride)) {
        .skippable => |pf| pf,
        else => null,
    };
}

/// What every state of a FROZEN automaton is: skippable (written into `out`), or
/// refused for one of three reasons. Stops writing at `out.len` but keeps
/// counting, so the census is whole even under a caller's budget.
///
/// This is the census behind claim C4 — the start state is the only dwell the engine
/// skips, and the question was how much of a real automaton's interior is skippable
/// too. The answer is *most of it*: ~97% of a document's bytes sit in a state with a
/// narrow exit set, and every refusal is the profitability bar rather than the shape.
/// C4 is nonetheless retired, because an interior dwell may not cross a line — a line
/// matcher never sees `\n` inside its line, and a document scan resolves `$` at one,
/// so `\n` stays pinned into every interior exit set. Pinning a byte that appears
/// every ~40 bytes of real text caps the stride at one line, which lands the interior
/// skip right at break-even; the rung's cost arm timed it there and it loses. So this
/// stays an instrument rather than becoming a build step.
///
/// Match states are excluded because the scan cannot dwell in one — reaching a
/// match state ends the search. Anchoring is not a veto here, unlike at the start:
/// an anchored pattern's interior `.*` is still a state the scan sits in.
///
/// `min_stride` is the profitability bar. `min_profitable_stride` is what the
/// engine's start skip uses; passing 0 waives it and yields the *ceiling* — every
/// state whose exit set is narrow enough to express at all — which is how a caller
/// separates "no state has a narrow exit set" (a fact about the automaton) from
/// "narrow, but the prior says stepping is cheaper" (a fact about the threshold).
pub fn survey(d: *const Dfa, out: []Skippable, min_stride: u16) Census {
    if (d.word_ctx) return .{}; // split starts / doubled interior table: not this shape
    const view = Frozen{
        .trans_in = d.trans_in,
        .trans_fin = d.trans_fin,
        .match_hi = d.match_hi,
    };
    var c: Census = .{};
    var off: u32 = d.match_hi; // skip the match band — a scan never dwells there
    while (off < d.nstates * d.ncls) : (off += d.ncls) {
        switch (exitsOf(view, &d.class, premultiplied, off, false, min_stride)) {
            .skippable => |pf| {
                if (c.skippable < out.len) out[c.skippable] = .{ .state = off, .exits = pf };
                c.skippable += 1;
            },
            .sealed => c.sealed += 1,
            .porous => c.porous += 1,
            .unprofitable => c.unprofitable += 1,
        }
    }
    return c;
}

/// The `survey`'s tally, one bucket per `Verdict`.
pub const Census = struct {
    skippable: usize = 0,
    sealed: usize = 0,
    porous: usize = 0,
    unprofitable: usize = 0,
};

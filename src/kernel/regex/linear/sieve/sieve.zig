//! irregex — the quotient sieve: a two-valued rung that retires haystacks the
//! deciders below it would otherwise have to walk.
//!
//! The sieve answers `.miss` — proven, no match anywhere in this haystack — or
//! `.unproven`, in which case the ladder falls through unchanged. **It can
//! never answer `.hit`**, and that is not a conservatism: an over-approximating
//! quotient admits a superset of the language, so it can refute a match and can
//! never confirm one. Every uncertainty in this file degrades to `.unproven`.
//!
//! Three things have to be true before a sieve is armed, and all three are
//! decided at compile time so the scan loop carries no policy:
//!
//! 1. **Soundness.** `quotient.project` refuses any automaton whose real run
//!    this single continuous interior-table walk does not reproduce — word
//!    context, `^` anchoring, a zero-width match, an armed start accelerator —
//!    and proves the two structural licenses (`$` accepts are also interior
//!    accepts; `\n` resets every state to start) against the finished tables.
//! 2. **Residency.** Every conjunct partitions into ≤16 blocks, so it runs in a
//!    shuffle register with no gather (`sheng.zig`).
//! 3. **Worth.** The estimated fallthrough rate has to be low enough that the
//!    pre-pass plus surviving calls costs less than the selected exact path —
//!    judged once per grain, since the line and buffer kernels are two machines
//!    at two prices, and admitted if either pays (`lineSafe` / `docSafe` then
//!    hold each path to its own verdict). This is the failure mode the prior
//!    art already mapped — CODFA (INFOCOM 2014) measured +26% when everything
//!    survives to verification — and our own harvested selectivity is bimodal,
//!    so the hazard is live. It is also decidable before the scan starts, which
//!    is the mitigation: `quotient.fallthroughRate` estimates it structurally,
//!    under two byte priors, and the pessimistic one decides.
//!
//! Failing any of the three leaves the field null. Nothing here learns, adapts,
//! or disables itself at runtime.

const std = @import("std");
const Dfa = @import("../dfa/dfa.zig").Dfa;
const prefilter = @import("../../analysis/prefilter.zig");
const ByteSet = @import("../../syntax/syntax.zig").ByteSet;
/// The measured plane every cost below is quoted from. The sieve owns its
/// SELECTIVITY (a structural property of its quotients) and none of its prices.
/// The measured price plane. Re-exported because this rung's whole cost policy is
/// a reading of it, and a bench that publishes the gate has to quote the same
/// coefficients the gate consulted rather than a second copy of them.
pub const price = @import("../ladder/price.zig");
/// The lattice harvest and the kernel are re-exported through this entry file
/// rather than reached around it: a caller that holds a `Sieve` sometimes needs
/// the `Quotient` type (to walk one beside the DFA) or `sheng.resident` (to ask
/// whether this build has a shuffle at all), and both belong to the sieve.
pub const quotient = @import("quotient.zig");
pub const sheng = @import("sheng.zig");

const Quotient = quotient.Quotient;
/// The byte-class type accepted by the no-DFA builder. Re-exported so benches
/// and parents need not reach through the sieve into syntax internals.
pub const Class = ByteSet;

/// A sieve's two answers. There is deliberately no `.hit`.
pub const Verdict = enum { miss, unproven };

/// The sieve's speed against the dense byte-class walk, at the grain and
/// conjunct count actually in play — DERIVED from two measured per-byte costs in
/// `ladder/price.zig` rather than declared here.
///
/// It used to be one constant, `0.40`, and that single number carried three
/// assumptions it could not distinguish: that one conjunct costs what two do,
/// that the four-lines-at-once document kernel costs what the per-line one does,
/// and — worst — that whatever the sieve fronts costs what a dense DFA costs.
/// The inequality below only ever needed the sieve's own absolute price, so that
/// is what it asks for now; this function survives because the README argues in
/// ratios and a ratio should be a quotient of measurements, not a rival to them.
pub fn speedRatio(conjuncts: u8, grain: price.Grain) f64 {
    return price.sieveSpeedRatio(conjuncts, grain);
}

/// The two haystack grains the rung can be consulted at: a line from
/// `lineMatch`, and a whole buffer from `docMatch`.
///
/// **Worth is judged once per grain, and the field exists if EITHER pays.**
/// The two are different kernels against a possibly different incumbent, so one
/// verdict cannot speak for both: `survives1`/`survives2` walk a line at ~1.27
/// cyc/B while `survivesDoc` takes four lines at a time at 0.729, and on every
/// row of the production slate the buffer total is the cheaper of the two. A
/// single line-grain gate therefore withheld the sieve from the DOCUMENT path
/// wherever the incumbent's price fell between them — which is the path
/// `docMatch` actually takes, and the grain the bench publishes its gate at.
/// Each path then enforces its own half (`lineSafe`, `docSafe`), so nothing can
/// arm on one grain's economics and run on the other's.
///
/// This corrected a real disagreement rather than a cosmetic one: the doc
/// comment here claimed the coarse grain decided, the bench banner printed
/// "at buffer grain", and `finish` gated on `.line`. The premise the old wording
/// rested on — "a sieve serves both paths from one field, so it must pay at the
/// harder grain" — had already been retired by `doc_ok`, which is exactly the
/// per-grain license that makes serving one path without the other safe.
///
/// The estimate feeding both tests is still known to be OPTIMISTIC —
/// `fallthroughRate` prices each position under a memoryless byte prior, and
/// real text is not memoryless: pattern-shaped bytes cluster, so one survivor
/// drags a whole buffer into verification. Measured on this corpus, the model
/// was low by up to five orders of magnitude (`uuid`: est 4.3e-7 vs 1.6e-2).
/// That is an argument for the *length* the survival term is amortized over —
/// 4 KiB is how a structural estimate buys margin against its own known bias
/// without observing traffic — not for which grain gates the field.
///
/// The row that made the clustering concrete: `[0-9]{4}-[0-9]{2}-[0-9]{2}`
/// rejects 99.03% of POSITIONS and still keeps 80.6% of documents — dates
/// cluster. It declines at both grains today (line 1.31 vs 0.44, doc 1.16 vs
/// 0.44), which is why the gate change moved no row on the slate.
///
/// Both lengths are defined once in the price plane — an anchored walk's
/// per-line cost and this rung's survival arithmetic are the same assumption,
/// and two copies of it could drift apart.
pub const nominal_line = price.nominal_line;
pub const nominal_doc = price.nominal_doc;

/// Would a sieve with per-position fallthrough `f` pay for itself on haystacks
/// of `len` bytes? Survival is `1 - (1-f)^len`; it has to stay under the margin
/// the kernel's speed advantage buys.
fn survival(f: f64, len: f64) f64 {
    return 1.0 - std.math.pow(f64, 1.0 - f, len);
}

/// End-to-end inequality: sieve + survivors × selected decider < decider.
///
/// Both sides are now in the same measured unit and neither is a ratio. The
/// sieve's own cost comes from `price.zig` at the grain and conjunct count of
/// THIS candidate; the decider's comes from whatever actually won the ladder's
/// auction. That is what makes the arithmetic stand a sieve down in front of a
/// cheap decider on its own — the outcome a boolean "only front the DFA"
/// prohibition used to produce, without needing to know which machine it faced.
///
/// `decider_cost` arrives as the auction's document-grain number, so it is lifted
/// to the grain being judged (`price.atGrain`) before the comparison. Both sides
/// then describe the same kernel shape — which they did not while the sieve's
/// single-chain line pre-pass was being weighed against the walk's four-line one.
///
/// The arithmetic itself lives on `CostFact`, which admission retains whether the
/// candidate arms or declines. So the gate, the census row, and the bench's audit
/// are one expression rather than three that agree by hand.
fn sieveCost(n: usize, grain: price.Grain) f64 {
    return price.sievePerByte(@intCast(n), grain) * price.unit;
}

/// Whether to enforce the worth test. `.ungated` (the differential oracles)
/// says the caller wants the sieve whatever its selectivity — soundness is a
/// property of the quotient construction and must hold on every pattern that
/// harvests one, not only on the ones the cost policy admits. Mirrors
/// `powerset.Budget`: the policy is negotiable, the soundness preconditions in
/// `quotient.project` never are.
pub const Gate = enum { worth, ungated };

/// Facts the sieve cannot see from a `Dfa` alone. A prefilter's economics are
/// retained for census attribution; admission itself compares the complete
/// sieve-plus-survivor path against the selected Compose, Parabix, or DFA
/// decider through `decider_cost`, so a cheap rival naturally makes the sieve
/// stand down without a producer-specific prohibition.
pub const Above = struct {
    /// Shared byte-density fact, retained for the admission census.
    prefilter: ?prefilter.Economics = null,
    /// Cost of the exact path this sieve would front, in ladder `Cost.scan`
    /// units. The dense eager walk by default, which is the machine the kernel
    /// was designed against and what a standalone bench is fronting.
    decider_cost: u32 = price.dense_default.scan,
};

/// Why a compile-time attempt produced no sieve. These facts are intentionally
/// public: census and benches need to distinguish "not representable" from
/// "representable but not worth prefixing to this particular decider."
pub const Decline = enum {
    target,
    projection_unproven,
    no_filter,
    malformed_window,
    too_many_windows,
    state_budget,
    unprofitable,
};

pub const Source = enum { dfa_quotient, byte_window };

/// The exact arithmetic used by admission, retained whether the candidate arms
/// or declines so a census can explain the decision without reconstructing it.
pub const CostFact = struct {
    fallthrough: f64,
    line_survival: f64,
    doc_survival: f64,
    /// The pre-pass's own price at each grain — two numbers because there are
    /// two kernels (`survives1`/`survives2` per line, `survivesDoc` four lines at
    /// a time), which one ratio against the DFA could not tell apart.
    line_cost: f64,
    doc_cost: f64,
    decider_cost: u32,

    /// The gate's left side: pre-pass plus the verifications that survive it.
    pub fn total(self: CostFact, grain: price.Grain) f64 {
        const survived = if (grain == .line) self.line_survival else self.doc_survival;
        const cost = if (grain == .line) self.line_cost else self.doc_cost;
        return cost + survived * self.exact(grain);
    }

    /// The gate's right side: deciding every position with no sieve in front,
    /// at this grain. Not `decider_cost` itself — that number was measured by a
    /// document-grain walk, and a line-grain comparison has to pay line-grain
    /// dispatch on both sides or it flatters whichever side skips it.
    pub fn exact(self: CostFact, grain: price.Grain) f64 {
        return price.atGrain(@floatFromInt(self.decider_cost), grain);
    }

    /// Whether this candidate pays at `grain` — the arithmetic admission itself
    /// applies, so a census, a bench, and the gate can never drift apart.
    pub fn pays(self: CostFact, grain: price.Grain) bool {
        return self.total(grain) < self.exact(grain);
    }
};

pub const BuildResult = struct {
    sieve: ?*Sieve = null,
    decline: ?Decline = null,
    cost: ?CostFact = null,
};

/// A necessary contiguous byte-class window at a proven fixed distance from a
/// match's end. `tail` bytes follow the last class before that match can end.
///
/// The parent may derive this from an AST concat or a Thompson path only when
/// every accepting path contains the window at exactly this offset. Optional,
/// repeated, asserted, Unicode-scalar, or branch-dependent steps are not such a
/// proof and must never be offered. Appending `tail` wildcard steps aligns all
/// filters at the real match endpoint, making their same-position conjunction
/// sound. The builder validates every property it can observe and declines the
/// rest; the fixed-offset proof is the caller's input contract.
pub const Window = struct {
    classes: []const Class,
    tail: u8 = 0,
};

pub const max_windows = quotient.max_conjuncts;
pub const max_window_width: usize = 15; // prefix bits 1..15 fit one u16

fn costFact(n: usize, f: f64, decider_cost: u32) CostFact {
    return .{
        .fallthrough = f,
        .line_survival = survival(f, nominal_line),
        .doc_survival = survival(f, nominal_doc),
        .line_cost = sieveCost(n, .line),
        .doc_cost = sieveCost(n, .doc),
        .decider_cost = decider_cost,
    };
}

fn finish(
    gpa: std.mem.Allocator,
    qs: [quotient.max_conjuncts]Quotient,
    n: usize,
    nl_reset: bool,
    above: Above,
    gate: Gate,
    source: Source,
) std.mem.Allocator.Error!BuildResult {
    var f: f64 = 1.0;
    for (qs[0..n]) |*q| {
        f = @min(f, @max(quotient.fallthroughRate(q, .uniform), quotient.fallthroughRate(q, .text)));
    }
    const fact = costFact(n, f, above.decider_cost);
    // Worth per grain, not one verdict for both. The buffer license needs
    // `nl_reset` as well, so a sieve that only pays at the coarse grain and
    // cannot legally run there is still unprofitable rather than armed-and-inert.
    const line_pays = fact.pays(.line);
    const doc_pays = nl_reset and fact.pays(.doc);
    if (gate == .worth and !line_pays and !doc_pays)
        return .{ .decline = .unprofitable, .cost = fact };

    const s = try gpa.create(Sieve);
    s.* = .{
        .gpa = gpa,
        .n = @intCast(n),
        .q = qs,
        .fallthrough = f,
        .line_ok = gate == .ungated or line_pays,
        .doc_ok = nl_reset and (gate == .ungated or fact.pays(.doc)),
        .source = source,
        .cost = fact,
    };
    return .{ .sieve = s, .cost = fact };
}

/// Build one exact substring automaton for a fixed-offset byte-class window.
/// Active prefix lengths form a subset state; determinization is bounded at
/// sixteen reachable subsets, after which uncertainty declines instead of
/// widening the language by guesswork.
fn windowQuotient(window: Window) union(enum) { ok: Quotient, decline: Decline } {
    const width = window.classes.len + @as(usize, window.tail);
    if (window.classes.len == 0 or width == 0 or width > max_window_width) return .{ .decline = .malformed_window };
    for (window.classes) |*set| if (set.count() == 0) return .{ .decline = .malformed_window };

    var states: [quotient.cap]u16 = @splat(0);
    var rows: [quotient.cap][256]u8 = undefined;
    var n: u8 = 1;
    var head: u8 = 0;
    while (head < n) : (head += 1) {
        for (0..256) |raw| {
            const b: u8 = @intCast(raw);
            const current = states[head];
            var next: u16 = 0;
            if (window.classes[0].has(b)) next |= 1 << 1;
            for (1..width) |i| {
                if (current & (@as(u16, 1) << @intCast(i)) == 0) continue;
                const accepts = if (i < window.classes.len) window.classes[i].has(b) else true;
                if (accepts) next |= @as(u16, 1) << @intCast(i + 1);
            }
            var id: ?u8 = null;
            for (states[0..n], 0..) |known, i| if (known == next) {
                id = @intCast(i);
                break;
            };
            if (id == null) {
                if (n == quotient.cap) return .{ .decline = .state_budget };
                states[n] = next;
                id = n;
                n += 1;
            }
            rows[head][raw] = id.?;
        }
    }

    const accept_bit = @as(u16, 1) << @intCast(width);
    var relabel: [quotient.cap]u8 = @splat(0);
    var nonaccepting: u8 = 0;
    for (states[0..n]) |state| nonaccepting += @intFromBool(state & accept_bit == 0);
    if (nonaccepting == 0 or nonaccepting == n) return .{ .decline = .no_filter };
    var lo: u8 = 0;
    var hi = nonaccepting;
    for (states[0..n], 0..) |state, i| {
        if (state & accept_bit == 0) {
            relabel[i] = lo;
            lo += 1;
        } else {
            relabel[i] = hi;
            hi += 1;
        }
    }

    var q: Quotient = .{ .nb = n, .th = nonaccepting, .start = relabel[0], .rows = undefined };
    for (0..256) |b| for (0..quotient.cap) |s| {
        q.rows[b][s] = if (s < n) relabel[rows[s][b]] else 0;
    };
    return .{ .ok = q };
}

/// A compiled conjunction of Sheng-resident SP quotients. Immutable and
/// scratch-free after `build`, like the `Dfa` it fronts, so one sieve serves
/// every thread.
pub const Sieve = struct {
    gpa: std.mem.Allocator,
    /// How many conjuncts are live (1 or 2 — see `quotient.max_conjuncts`).
    n: u8,
    q: [quotient.max_conjuncts]Quotient,
    /// Estimated per-position fallthrough — the share of byte positions the
    /// sieve is expected to hand on to the real matcher. Structural, from the
    /// quotients' own stationary distributions; published by the bench beside
    /// the measured rate so the model can be judged.
    fallthrough: f64,
    /// Construction and admission evidence consumed by census/bench tooling.
    source: Source,
    cost: CostFact,
    /// Does the per-line pre-pass pay in front of the selected decider? Pure
    /// worth, with no correctness half — `scan` is valid on any haystack — so
    /// unlike `doc_ok` this one never gates an assert, only the ladder's line
    /// walk. It exists because the two kernels have genuinely different prices
    /// and the line one is the dearer: without this license the coarse grain
    /// could not be armed on its own economics.
    line_ok: bool,
    /// May `scan` be run over a whole multi-line buffer in one pass? Two
    /// independent halves, and only the first is about correctness: every state
    /// must reset to start on `\n`, so a continuous run IS the per-line model.
    /// The second is worth — the estimate has to say a buffer-sized pre-pass
    /// pays — and like every other worth test here it answers to `Gate`, so an
    /// `.ungated` build carries the license alone.
    doc_ok: bool,

    /// Build the sieve for a determinized pattern, or decline. Declining is a
    /// cost or soundness decision with no semantic content: the ladder simply
    /// runs the rung below.
    pub fn build(gpa: std.mem.Allocator, d: *const Dfa, above: Above, gate: Gate) std.mem.Allocator.Error!?*Sieve {
        return (try buildDfa(gpa, d, above, gate)).sieve;
    }

    /// Fact-bearing DFA builder. `build` remains the compact ladder seam.
    pub fn buildDfa(gpa: std.mem.Allocator, d: *const Dfa, above: Above, gate: Gate) std.mem.Allocator.Error!BuildResult {
        if (gate == .worth and !sheng.resident) return .{ .decline = .target };
        var core = (try quotient.project(gpa, d)) orelse return .{ .decline = .projection_unproven };
        defer core.deinit();

        var qs: [quotient.max_conjuncts]Quotient = undefined;
        const n = try quotient.harvest(gpa, &core, &qs);
        if (n == 0) return .{ .decline = .no_filter };
        return finish(gpa, qs, n, core.nl_reset, above, gate, .dfa_quotient);
    }

    /// Build without an eager DFA from one or two mandatory fixed-offset
    /// byte-class windows extracted by the parent from its AST/NFA.
    pub fn buildWindows(gpa: std.mem.Allocator, windows: []const Window, above: Above, gate: Gate) std.mem.Allocator.Error!BuildResult {
        if (gate == .worth and !sheng.resident) return .{ .decline = .target };
        if (windows.len == 0 or windows.len > max_windows)
            return .{ .decline = if (windows.len == 0) .no_filter else .too_many_windows };

        var qs: [quotient.max_conjuncts]Quotient = undefined;
        for (windows, 0..) |window, i| switch (windowQuotient(window)) {
            .ok => |q| qs[i] = q,
            .decline => |why| return .{ .decline = why },
        };
        var nl_reset = true;
        for (qs[0..windows.len]) |*q| for (0..q.nb) |state| {
            nl_reset = nl_reset and q.rows['\n'][state] == q.start;
        };
        return finish(gpa, qs, windows.len, nl_reset, above, gate, .byte_window);
    }

    pub fn deinit(self: *Sieve) void {
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    /// Can any match end anywhere in `hay`? `.miss` is a proof that none can;
    /// `.unproven` means the real matcher still has to look.
    ///
    /// This is the per-line entry: one shuffle chain, no assumption about the
    /// contents. Valid on any haystack, including a whole buffer — but a buffer
    /// should go through `scanDoc`, which is the same answer several times
    /// faster.
    pub fn scan(self: *const Sieve, hay: []const u8) Verdict {
        const survived = if (self.n == 1)
            sheng.survives1(&self.q[0], hay)
        else
            sheng.survives2(&self.q[0], &self.q[1], hay);
        return if (survived) .unproven else .miss;
    }

    /// `scan` over a whole `\n`-bearing buffer, advancing four lines at once.
    /// **Requires `doc_ok`** — the `nl_reset` license is what makes a lane
    /// starting just past a newline reproduce the true run — and asserts it
    /// rather than silently degrading, because a caller who ignores the flag is
    /// asking for an unsound answer, not a slow one.
    pub fn scanDoc(self: *const Sieve, doc: []const u8) Verdict {
        std.debug.assert(self.doc_ok);
        return if (sheng.survivesDoc(self.q[0..self.n], doc)) .unproven else .miss;
    }

    /// The ladder's name for `line_ok` — the mirror of `docSafe`, and the reason
    /// arming may be judged at either grain. `rungs.walk` asks every rung it is
    /// about to consult at the line grain whether it consents, so a sieve armed
    /// on the buffer kernel's price is simply never run per line, rather than
    /// running there at a loss the arithmetic already predicted.
    pub fn lineSafe(self: *const Sieve) bool {
        return self.line_ok;
    }

    /// The ladder's name for `doc_ok`, and the reason `scanDoc` may assert
    /// rather than degrade: `rungs.walk` asks every rung it is about to consult at
    /// the document grain whether it consents, and a rung that declares no such
    /// method is simply unrestricted. Before this existed the assert was held up
    /// only by an arming coincidence — the line-grain worth test happening to
    /// refuse everything the doc-grain one refused — and a pre-pass that armed on
    /// worth while lacking the `nl_reset` license walked straight into it.
    pub fn docSafe(self: *const Sieve) bool {
        return self.doc_ok;
    }

    /// The same verdict computed one position at a time by the scalar oracle.
    /// The differential test holds `scan` to this; the bench uses it to
    /// attribute per-position selectivity.
    pub fn scanScalar(self: *const Sieve, hay: []const u8) Verdict {
        return if (sheng.survivesScalar(self.q[0..self.n], hay)) .unproven else .miss;
    }
};

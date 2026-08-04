//! gist — the accelerator tier: every optional machine that can answer a
//! boolean faster than the byte-class DFA, behind one interface.
//!
//! The ladder in `verdict.zig` used to name each engine it consulted. That does
//! not scale past two: each rung arrives with its own constructor shape (a DFA,
//! an AST, a rival census), its own ownership (heap handle or plain value), its
//! own verdict spelling (`bool` or `miss`/`unproven`), and its own opinion about
//! whether it can serve a whole buffer — and every one of those differences
//! would otherwise land in `Regex`, in `lower.zig`, and twice in the dispatch.
//!
//! So this file absorbs the variance and exports four questions:
//!
//!   `build`  — which rungs admit this pattern, in ladder order
//!   `line`   — the cheapest sound answer for "does this SLICE match"
//!   `doc`    — the same for "does any LINE of this buffer match"
//!   `fused`  — is a whole-buffer machine armed (a caller's loop preference)
//!
//! `Regex` therefore carries ONE field, `lower.zig` ONE call, and `verdict.zig`
//! ONE line per entry point. Adding the next rung is an entry in `order` plus a
//! clause in `build`; it touches nothing outside this file.
//!
//! ## The protocol, which is the whole contract
//!
//! Three-valued, and it unifies the two rung kinds exactly rather than papering
//! over them. A DECIDER (`compose`, `parabix`) answers `.hit`/`.miss` completely
//! for the patterns it accepts and declines at COMPILE time by being null — it
//! may never say "not sure" mid-scan. A SIEVE (`sieve`) answers `.miss` (proven
//! no match) or `.unproven`, and can never say `.hit`, because an
//! over-approximating quotient admits supersets. Both meanings of `.miss`
//! coincide — "return false" — which is why one enum serves both and the walk
//! below needs no per-kind branch.
//!
//! The second axis is `Model`, and it is the one that is easy to get wrong
//! because getting it wrong produces a WRONG ANSWER rather than a crash. The two
//! entry points are two different questions — a slice, versus the lines inside a
//! buffer — and they coincide only when the haystack holds no `\n`. Nothing in
//! the ladder promises that, so each rung declares which question it answers and
//! `walk` consults it only there.
//!
//! Dispatch only, never semantics: every rung answers identically to the Pike
//! VM, and `.unproven` falls through rather than guessing. Correctness never
//! depends on a rung being present — an empty `Rungs` is the engine as it was.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const prefilter = @import("../../analysis/prefilter.zig");
const dfa_mod = @import("../dfa/dfa.zig");
const compose_mod = @import("../shuffle/shuffle.zig");
const parabix_mod = @import("../parabix/parabix.zig");
const sieve_mod = @import("../sieve/sieve.zig");
/// Every number this file bids with. Re-exported because a caller reading an
/// `Admission` needs the unit those costs are in, and the unit belongs with the
/// measurements rather than with the dispatch.
pub const price = @import("price.zig");

/// Cycles per byte in `price.unit`s — one measured plane, one comparison. Lives
/// there so a bid and the kernel timing behind it cannot drift apart.
pub const Cost = price.Cost;

/// MAY this vector rung arm on this build? Two conjuncts, and keeping them
/// distinct is the whole point:
///
///   * the kernel exists here — each rung's own arch predicate, which stays
///     inside the rung because that is a fact about its instructions;
///   * somebody TIMED it here — `price.calibrated`, which is not a fact about
///     any rung but one fact about this machine, so it is asked once, in the
///     file that does the bidding.
///
/// Porting a vector rung to a new target is therefore two steps that cannot be
/// confused: make it compile, then mint its calibration. Before the second, the
/// rung is not merely unarmed but unBUILT — an unmeasured target should not pay
/// a lowering's allocation for a machine that has no price to bid.
///
/// Published so the benches and gate tests read the same predicate the ladder
/// acts on. They used to read a bare `lanes.widest` / `parabix.vectorized`,
/// which answered half the question and would have reported a rung as armable
/// on a freshly-ported target where nothing had been measured yet.
///
/// Compose asks whether ANY width arms, because the width is a property of the
/// individual machine rather than of the build: a target with only the 16-lane
/// lookup still serves every pattern under sixteen lanes, and `lower` is what
/// declines the wider ones.
pub const compose_armable: bool = compose_mod.lanes.widest != null and price.calibrated;
pub const parabix_armable: bool = parabix_mod.vectorized and price.calibrated;

/// One independently representable candidate offered to the ladder.
pub const Offer = struct {
    kind: Selection,
    cost: Cost,
};

/// WHICH machine ends up answering. `settled` is not a bidder that won — it is
/// the outcome where no auction was held at all, because a kernel above the tier
/// decides the pattern (`Admit.settled`). Keeping it in the same enum is what
/// makes `selected_cost` mean one thing everywhere: the per-byte price of the
/// machine that actually answers.
pub const Selection = enum { settled, fallback, compose, parabix };

/// Compile-time admission evidence consumed by benches/census tools without
/// putting counters or policy branches in the scan loop.
pub const Admission = struct {
    selected: Selection = .fallback,
    selected_cost: Cost = price.dense_default,
    fallback_cost: Cost = price.dense_default,
    /// WHICH walker the fallback actually is, which is the fact the flat 30_000
    /// hid: a pattern the powerset declined falls to the lazy DFA or the Pike
    /// VM, and a challenger held to an eager DFA's price stands down against a
    /// machine this pattern never got. Pair it with `prefilter` to know whether
    /// that walker also had a skip in front of it.
    fallback_machine: price.Walk = .eager,
    prefilter: ?prefilter.Economics = null,
    sieve: bool = false,
};

/// What a rung answers. See the protocol note above: `.hit` is a decider's
/// yes, `.miss` is either kind's proven no, `.unproven` is "ask the next rung".
pub const Verdict = enum { hit, miss, unproven };

/// Does this rung decide the question, or only narrow it? Drives `fused`, and
/// the admission policy in `build` that stops a second decider arming behind
/// the first.
const Kind = enum { sieve, decider };

/// WHICH QUESTION a rung answers — the distinction that makes the two entry
/// points genuinely different rather than two spellings of one.
///
/// `verdict.lineMatch` promises nothing about `\n`. It asks: does the pattern
/// match a substring of THESE bytes, with `^`/`$` bound to this slice's edges?
/// `verdict.docMatch` asks the per-line question: does any `\n`-delimited line
/// of this buffer match? On a `\n`-free slice the two coincide, which is why
/// every production per-line caller (an `-A/-B/-C` line view, a `body[ls..le]`
/// slice) may use either — but `lineMatch` itself is reachable with a raw
/// multi-line buffer, and there the answers differ.
const Model = enum {
    /// `\n` is an ordinary byte to this rung and it carries no anchor, so both
    /// questions have the same answer and it serves both entries.
    byte,
    /// `\n` is a line boundary to this rung: it re-seeds, so `^` fires after
    /// every terminator. That is precisely the document question, and precisely
    /// wrong for a `line` call handed a buffer. Document grain by default — but
    /// this is the rung KIND's model, and an individual machine may prove
    /// better: see `sliceSafe`, which lets one instance opt back into `line`
    /// when its reset row turned out to be an ordinary byte row.
    per_line,
};

/// One rung's place in the ladder, the question it answers, and the two methods
/// it answers with. The method names are comptime strings, so a typo is a
/// compile error and a rung whose API drifts fails the build rather than
/// silently going unconsulted.
const Spec = struct {
    field: []const u8,
    line: []const u8,
    doc: []const u8,
    kind: Kind,
    model: Model,
};

/// THE LADDER ORDER, and the only place it is written down.
///
/// Cheapest-first among the rungs that overlap, with the sieve above the
/// deciders because it prunes bytes they would otherwise retire. Reordering is
/// a one-line data edit here, which matters while the compose-vs-parabix
/// head-to-head is still open: their measured figures (2.26 and 1.29 B/cycle)
/// come from different patterns against different baselines, so the order below
/// is the best evidence available rather than a settled result.
const order = [_]Spec{
    // An over-approximating quotient of the DFA's byte transitions: `\n` is a
    // byte like any other and a `.miss` is "no match can end anywhere in these
    // bytes", which is true at either grain.
    .{ .field = "sieve", .line = "scan", .doc = "scanDoc", .kind = .sieve, .model = .byte },
    // The one per-line machine here: its `\n` table row maps every lane back to
    // START, which reproduces the line model in one fused pass and is exactly
    // why it may not answer a raw-buffer `lineMatch`.
    .{ .field = "compose", .line = "match", .doc = "docMatch", .kind = .decider, .model = .per_line },
    // One function serves both grains, and the admission gate is what earns
    // that: `admit.zig` refuses any class containing `\n` and every assertion
    // node, so the language holds no terminator and no anchor. No match can
    // cross a line and none is bound to a slice edge, so "some line matches"
    // and "the buffer matches somewhere" are the same question.
    .{ .field = "parabix", .line = "match", .doc = "match", .kind = .decider, .model = .byte },
};

/// Every rung a pattern admitted. Immutable and scratch-free after `build`,
/// like the `Dfa` it fronts, so one instance serves every thread.
///
/// All three are boxed handles even though `Parabix` is a value type. The
/// uniformity is worth one allocation per compile: it keeps the walk below free
/// of per-field type gymnastics, and it means the hot path borrows each rung in
/// place instead of copying a program into the stack frame per line.
pub const Rungs = struct {
    sieve: ?*sieve_mod.Sieve = null,
    compose: ?*compose_mod.Compose = null,
    parabix: ?*parabix_mod.Parabix = null,
    admission: Admission = .{},

    /// Nothing admitted — the engine as it was before this tier existed. The
    /// value a caller uses when it has no DFA to offer.
    pub const none: Rungs = .{};

    /// What a rung needs to admit itself, gathered once by the caller that
    /// already holds all of it.
    pub const Admit = struct {
        /// The determinized program. `compose` lowers it to transformation
        /// tables; `sieve` harvests SP-quotients from it. Null (a powerset
        /// decline, or multiline) leaves both unarmed.
        dfa: ?*const dfa_mod.Dfa = null,
        /// The parsed pattern. `parabix` compiles class bitstream circuits from
        /// the AST rather than the automaton, so it is the one rung that still
        /// needs the tree.
        ast: ?*const syn.Node = null,
        /// Shared corpus-priced prefilter fact from the eager or lazy DFA. Null
        /// means the fallback walks densely; non-null prices its expected stride.
        prefilter: ?prefilter.Economics = null,
        /// Intrinsic scan semantics Parabix admits against — the grain and
        /// whether word assertions must decode Unicode. No sibling-engine state.
        parabix_model: parabix_mod.Model = .{},
        /// The determinizer declined its budget, so states are discovered on
        /// demand. Only the caller knows this — `dfa == null` is also how a
        /// pattern with no automaton at all arrives — and it is the difference
        /// between a fallback at ~5 cyc/B and one at ~34.
        lazy: bool = false,
        /// Every match begins at a line start (`^…`). The fallback then never
        /// walks densely: it verifies a few bytes per line and hunts the next
        /// terminator with SIMD, which is a per-line cost. Priced, because the
        /// regret gate caught this axis missing — an anchored walk bid as a dense
        /// one at 2.98 cyc/B measures 0.31, and a challenger won an auction it
        /// lost by 2.8× in fact.
        anchored: bool = false,
        /// A cheaper machine ABOVE this tier already decides the pattern, at both
        /// grains, for every haystack.
        ///
        /// `verdict.zig` consults the literal engine, then the class-run kernel,
        /// then this tier. The first two are SIMD scans at classification
        /// bandwidth, and when either settles its verdict is final — so nothing
        /// admitted here can ever be reached. It is not that a rung would lose
        /// the auction; it is that the auction is never held.
        ///
        /// This is the axis whose absence let a sieve arm in front of
        /// `[0-9]{40,}`. That pattern is a pure class run, decided by the SIMD
        /// kernel at 0.37 cyc/B, and the ladder was pricing its incumbent as an
        /// eager DFA walk at 1.32 — a machine the pattern never gets. Every rung
        /// then bid against a phantom nearly four times dearer than the truth,
        /// and the pre-pass the sieve won that auction with was pure cost: the
        /// kernel above had already answered.
        ///
        /// Carries WHICH kernel rather than a boolean, so the admission can
        /// publish what the machine that answers costs. A bench that reads
        /// `selected_cost` to price a hypothetical pre-pass gets the truth, where
        /// a bool would have left the dense walk's default in place — the same
        /// phantom, one indirection further along.
        settled: ?price.Settle = null,
    };

    /// WHICH machine answers when no rung arms. It is the incumbent every offer
    /// below is measured against, so naming it exactly is the whole reason the
    /// fallback bids a price instead of a constant.
    ///
    /// Returns the walk itself rather than a `price.Machine`, because the walk is
    /// what both consumers want: one prices it, the other publishes its identity,
    /// and neither should have to re-narrow a union that can only ever hold this.
    fn fallbackWalk(a: Admit) @FieldType(price.Machine, "walk") {
        return .{
            .kind = if (a.dfa != null) .eager else if (a.lazy) .lazy else .pike,
            // A skip is priced from its own published expectation, so a weak one
            // loses to the dense walk here rather than needing a threshold.
            .stride = if (a.prefilter) |p| p.stride else 0,
            .anchored = a.anchored,
        };
        // The DFA's table size is deliberately NOT here. It reads like the fact a
        // walk's cost would turn on, and the residency sweep in `ladder-price`
        // found it does not move the step at all — see `price.dfa_step`.
    }

    /// The incumbent, described. Both outcomes need all three facts: a settled
    /// pattern's walker still EXISTS — it is merely never consulted — so an
    /// admission that quoted the settler here would tell a bench comparing a
    /// hypothetical pre-pass against the walk a price no walk ever had.
    fn incumbent(a: Admit) Admission {
        const w = fallbackWalk(a);
        const cost = price.price(.{ .walk = w });
        return .{
            .selected_cost = cost,
            .fallback_cost = cost,
            .fallback_machine = w.kind,
            .prefilter = a.prefilter,
        };
    }

    /// Admit the rungs this pattern earns, in ladder order.
    ///
    /// Two policies live here rather than in any rung, because neither is
    /// visible from inside one:
    ///
    /// 1. **At most one decider.** They are alternatives, not a pipeline — the
    ///    ladder consults the first that armed, so a second would cost compile
    ///    time and memory to be unreachable.
    /// 2. **The sieve is priced against whatever won.** It is not in the
    ///    deciders' contest: it narrows without deciding, so it receives the
    ///    winner's per-byte cost and applies its own survival inequality against
    ///    it (`sieve.zig`). That inequality is what stands it down in front of a
    ///    cheap decider — where a boolean "only front the DFA" prohibition used
    ///    to, on a ratio measured against a machine it might not be fronting.
    ///
    /// 3. **A settled pattern gets no tier at all.** Before any of the above:
    ///    an auction whose winner can never be consulted is not an auction, and
    ///    the honest answer to "what should arm here" is nothing. See
    ///    `Admit.settled`.
    ///
    /// Every bid here comes from `price.zig`, whose coefficients are re-timed and
    /// gated by `zig build ladder-price`. Nothing in this function knows a
    /// cycle count.
    pub fn build(gpa: std.mem.Allocator, a: Admit) std.mem.Allocator.Error!Rungs {
        // Nothing to bid for: a kernel above this tier decides every haystack, so
        // every rung below it is unreachable. Declining here rather than in the
        // auction is what makes it free — no lowering, no Sheng tables, no
        // allocation for a machine that will never be asked. The admission still
        // names the machine and its price, because "nothing armed" and "nothing
        // could" are different facts and a bench has to be able to tell them apart.
        if (a.settled) |kernel| {
            var ad = incumbent(a);
            ad.selected = .settled;
            ad.selected_cost = price.price(.{ .settle = kernel });
            return .{ .admission = ad };
        }

        var r: Rungs = .{};
        errdefer r.deinit(gpa);

        // Build representability independently; ordering never hides a candidate.
        // Each is gated on its own two-conjunct evidence flag above.
        var compose: ?*compose_mod.Compose = if (comptime compose_armable)
            if (a.dfa) |d| try compose_mod.Compose.lower(gpa, d) else null
        else
            null;
        errdefer if (compose) |c| c.deinit();
        const parabix: ?parabix_mod.Parabix = if (comptime parabix_armable)
            if (a.ast) |root| switch (parabix_mod.Parabix.build(root, a.parabix_model)) {
                .armed => |p| p,
                .declined => null,
            } else null
        else
            null;

        var ad = incumbent(a);
        var selected = Offer{ .kind = .fallback, .cost = ad.fallback_cost };
        if (compose) |c| {
            const offer = Offer{ .kind = .compose, .cost = price.price(.{ .compose = .{
                .width = c.width,
                .eol = c.index == .byte_eol,
                .table_bytes = c.table.len,
            } }) };
            if (offer.cost.lessThan(selected.cost)) selected = offer;
        }
        if (parabix) |*p| {
            const offer = Offer{ .kind = .parabix, .cost = price.price(.{ .parabix = .{
                .stripe_ops = p.economics.stripe_ops,
                .instrs = p.prog.ninstrs,
            } }) };
            if (offer.cost.lessThan(selected.cost)) selected = offer;
        }

        switch (selected.kind) {
            // Never bid: the settled case returned above, before any candidate
            // was even built.
            .settled => unreachable,
            .fallback => {},
            .compose => {
                r.compose = compose;
                compose = null;
            },
            .parabix => if (parabix) |p| {
                const box = try gpa.create(parabix_mod.Parabix);
                box.* = p;
                r.parabix = box;
            },
        }
        if (compose) |c| c.deinit();

        // A sieve is an optional prefix, not a competing decider. Its own gate
        // applies the survival inequality against this selected path.
        if (a.dfa) |d| r.sieve = try sieve_mod.Sieve.build(
            gpa,
            d,
            .{ .prefilter = a.prefilter, .decider_cost = selected.cost.scan },
            .worth,
        );
        ad.selected = selected.kind;
        ad.selected_cost = selected.cost;
        ad.sieve = r.sieve != null;
        r.admission = ad;
        return r;
    }

    pub fn deinit(self: *Rungs, gpa: std.mem.Allocator) void {
        inline for (order) |s| if (@field(self, s.field)) |rung| {
            // A rung that manages its own tables frees them; a plain value only
            // has the box this tier put it in.
            if (comptime @hasDecl(@TypeOf(rung.*), "deinit")) rung.deinit() else gpa.destroy(rung);
            @field(self, s.field) = null;
        };
    }

    /// The cheapest sound answer to `verdict.lineMatch`'s question — does the
    /// pattern match a substring of exactly these bytes — or `.unproven` when no
    /// rung can settle it and the caller falls through to the DFA family.
    ///
    /// `hay` may contain `\n`; nothing in the ladder above promises otherwise.
    /// A rung is consulted here only if its model is `byte`, or if the
    /// particular machine proved itself `sliceSafe` — so that costs no
    /// soundness, and the proof is what keeps the common unanchored pattern on
    /// the fast rung instead of forfeiting it to the kind's worst case.
    pub fn line(self: *const Rungs, hay: []const u8) Verdict {
        return self.walk(hay, .line);
    }

    /// The same for `verdict.docMatch`'s question — does any `\n`-delimited line
    /// of this buffer match. Every rung is eligible: a `per_line` machine
    /// answers this question natively, and a `byte` machine's language holds no
    /// terminator, so for it the two questions coincide.
    pub fn doc(self: *const Rungs, buf: []const u8) Verdict {
        return self.walk(buf, .doc);
    }

    /// Is a whole-buffer decider armed? Callers with their own gated per-line
    /// loops use this to prefer one fused pass. A sieve does not count: it
    /// narrows the question without answering it, so the machine that actually
    /// decides is still the DFA below.
    pub fn fused(self: *const Rungs) bool {
        return self.armed(.decider);
    }

    // ── the walk ───────────────────────────────────────────────────────────
    //
    // One loop, unrolled at compile time into exactly the branches the naive
    // wiring would have written by hand — but written once, so a rung cannot be
    // consulted on lines and forgotten on documents.

    const Grain = enum { line, doc };

    fn walk(self: *const Rungs, hay: []const u8, comptime g: Grain) Verdict {
        inline for (order) |s| {
            if (@field(self, s.field)) |rung| eligible: {
                // A per-line rung is not, in general, an answer to the line
                // question (see `Model`) — but a particular machine may have
                // PROVEN at lowering time that it reads `\n` as an ordinary
                // byte, and then it is. `fits` is comptime, so a `byte` rung
                // generates no check at all and the document walk generates
                // none either; only a `per_line` rung on the line walk pays a
                // single predictable bool ahead of a whole scan.
                const fits = comptime g == .doc or s.model == .byte;
                if (!fits and !sliceSafe(rung)) break :eligible;
                // …and the mirror image: a rung whose KIND serves the document
                // grain may still have an instance that does not. `docSafe` is
                // that veto, absent on rungs with nothing to withhold, so this
                // costs one predictable bool for the sieve and nothing at all
                // for the deciders.
                if (comptime g == .doc) if (!docSafe(rung)) break :eligible;
                // …and its twin. A rung whose two grains are two kernels at two
                // prices may consent to one and not the other, so each grain
                // asks separately. Absent on everything but the sieve, which is
                // the only rung that is an optional PREFIX and therefore the
                // only one whose worth can differ by grain.
                if (comptime g == .line) if (!lineSafe(rung)) break :eligible;
                const method = comptime if (g == .line) s.line else s.doc;
                switch (normalize(@call(.auto, @field(@TypeOf(rung.*), method), .{ rung, hay }))) {
                    .hit => return .hit,
                    .miss => return .miss,
                    .unproven => {},
                }
            }
        }
        return .unproven;
    }

    /// Is any rung of this kind armed?
    fn armed(self: *const Rungs, comptime k: Kind) bool {
        inline for (order) |s| {
            if (s.kind == k and @field(self, s.field) != null) return true;
        }
        return false;
    }
};

/// Has this particular machine proven it answers the SLICE question too? A rung
/// declares the refinement by growing a `sliceSafe` method; one that never does
/// is simply held to its static `Model`, which is the conservative reading.
inline fn sliceSafe(rung: anytype) bool {
    const T = @TypeOf(rung.*);
    return @hasDecl(T, "sliceSafe") and rung.sliceSafe();
}
/// …and does it consent to the DOCUMENT grain? The two default the opposite way,
/// on purpose. `sliceSafe` WIDENS a rung past its kind's conservative model, so
/// its absence means "no refinement offered" — false. `docSafe` NARROWS one
/// below its kind's model, so its absence means "nothing withheld" — true. A
/// rung that needs neither declares neither and pays for neither.
inline fn docSafe(rung: anytype) bool {
    const T = @TypeOf(rung.*);
    return !@hasDecl(T, "docSafe") or rung.docSafe();
}
/// …and the same veto at the line grain. Narrowing too, so absent means
/// "nothing withheld". The pair is what lets a rung be admitted on the strength
/// of one grain alone: the sieve's line and buffer kernels are priced
/// separately, and before both vetoes existed the field could only be armed on
/// the dearer of the two — which withheld it from the document walk in exactly
/// the band where the cheaper kernel was the one that paid.
inline fn lineSafe(rung: anytype) bool {
    const T = @TypeOf(rung.*);
    return !@hasDecl(T, "lineSafe") or rung.lineSafe();
}

/// Fold a rung's own spelling of its answer into the shared protocol. A decider
/// speaks `bool`; the sieve speaks its own two-valued enum and structurally
/// cannot produce `.hit`. Any other return type is a rung that has not agreed
/// to the contract, and says so at compile time.
inline fn normalize(v: anytype) Verdict {
    return switch (@TypeOf(v)) {
        bool => if (v) .hit else .miss,
        sieve_mod.Verdict => switch (v) {
            .miss => .miss,
            .unproven => .unproven,
        },
        else => @compileError("rung answered with " ++ @typeName(@TypeOf(v)) ++
            "; a rung must answer `bool` (decider) or `sieve.Verdict` (sieve)"),
    };
}

test "an empty tier is the engine as it was" {
    var r: Rungs = .none;
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(Verdict.unproven, r.line("anything"));
    try std.testing.expectEqual(Verdict.unproven, r.doc("anything\n"));
    try std.testing.expect(!r.fused());
}

test "build with nothing to offer admits nothing" {
    var r = try Rungs.build(std.testing.allocator, .{});
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.sieve == null and r.compose == null and r.parabix == null);
}

test "a vector rung is not BUILT where its evidence is missing, only where it loses" {
    // The evidence flag has to govern CONSTRUCTION rather than just the bid: the
    // allocation and the lowering are the cost being avoided on a target that
    // cannot price the rung, and a machine built-then-discarded would have paid
    // it anyway. `[a-z]{4}[0-9]{4}` is Unicode-free with bounded star height, so
    // parabix's OWN gate admits it wherever the kernel exists, and with no DFA in
    // the admission the incumbent is the Pike VM at ~30 cyc/B — an auction this
    // rung wins by an order of magnitude when it is allowed to enter.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var parser = syn.Parser{ .src = "[a-z]{4}[0-9]{4}", .arena = arena_state.allocator() };
    const ast = try parser.parseAlt();

    var r = try Rungs.build(std.testing.allocator, .{ .ast = ast });
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(parabix_armable, r.parabix != null);
    // So a null field above is the ladder withholding evidence, never the pattern
    // being unrepresentable — the two reasons the single arch predicate conflated.
    if (comptime parabix_mod.vectorized)
        try std.testing.expect(parabix_mod.Parabix.build(ast, .{}) == .armed);
}

test "the byte-model annotation is a claim about a gate, and the gate keeps it" {
    // `order` marks parabix `.byte`: ONE `match` answers both the line question
    // and the document question. Two properties license that, and the gate keeps
    // both — so exercise the behavior, not a label. (1) A class containing `\n`
    // would let a match span two lines and break the equivalence, so under the
    // per-line grain it is refused. (2) A line anchor is now ADMITTED (the
    // capability lane's superinstructions), but as a re-seed at every `\n`, so
    // "some line matches" and "the buffer matches somewhere" stay the same
    // question. Relaxing (1), or admitting an anchor that bound to the slice edge
    // instead of a line's, would not crash — it would silently answer the wrong
    // question — which is why this is pinned.
    if (comptime !parabix_mod.vectorized) return error.SkipZigTest;
    const a = std.testing.allocator;
    // (1) The newline class still stands the rung down under the line grain.
    try std.testing.expect(switch (parabix_mod.Parabix.compileOffer(a, "[a-z\\n]+[0-9]+", .{})) {
        .armed => false,
        .declined => true,
    });
    // (2) An anchored pattern arms, and its whole-buffer answer is identical to
    // the OR over its lines — the equivalence the `.byte` annotation asserts.
    const anchored = switch (parabix_mod.Parabix.compileOffer(a, "^[a-z]+[0-9]+$", .{})) {
        .armed => |p| p,
        .declined => return error.TestUnexpectedResult,
    };
    const buf = "!!!\nab12\n!!!";
    var per_line = false;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |ln| per_line = per_line or anchored.match(ln);
    try std.testing.expectEqual(per_line, anchored.match(buf));
    // The control: strip the hazard from the same shape and it still arms, so the
    // refusal above is the gate discriminating rather than the rung being unable
    // to admit anything at all.
    try std.testing.expect(switch (parabix_mod.Parabix.compileOffer(a, "[a-z]+[0-9]+", .{})) {
        .armed => true,
        .declined => false,
    });
}

test "the ladder names each rung once, and every method it names exists" {
    // Guards the one hazard a comptime table introduces: a duplicated or
    // misspelled field would make a rung unreachable rather than fail loudly.
    comptime {
        for (order, 0..) |a, i| {
            if (!@hasField(Rungs, a.field)) @compileError("no rung field " ++ a.field);
            for (order[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.field, b.field)) @compileError("duplicate rung " ++ a.field);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 3), order.len);
}

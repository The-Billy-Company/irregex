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
const compose_mod = @import("../compose/compose.zig");
const parabix_mod = @import("../parabix/parabix.zig");
const sieve_mod = @import("../sieve/sieve.zig");

/// Fixed-point cycles per 100 bytes. These are dispatch facts, not benchmark
/// prose: every candidate publishes the same unit, so admission compares total
/// paths instead of asking whether some unrelated field happened to arm.
pub const Cost = struct {
    scan: u32,
    compile: u32 = 0,

    pub fn lessThan(a: Cost, b: Cost) bool {
        return a.scan < b.scan or (a.scan == b.scan and a.compile < b.compile);
    }
};

/// One independently representable candidate offered to the ladder.
pub const Offer = struct {
    kind: Selection,
    cost: Cost,
};

pub const Selection = enum { fallback, compose, parabix };

/// Compile-time admission evidence consumed by benches/census tools without
/// putting counters or policy branches in the scan loop.
pub const Admission = struct {
    selected: Selection = .fallback,
    selected_cost: Cost = .{ .scan = 30_000 },
    fallback_cost: Cost = .{ .scan = 30_000 },
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
    };

    /// Admit the rungs this pattern earns, in ladder order.
    ///
    /// Two policies live here rather than in any rung, because neither is
    /// visible from inside one:
    ///
    /// 1. **At most one decider.** They are alternatives, not a pipeline — the
    ///    ladder consults the first that armed, so a second would cost compile
    ///    time and memory to be unreachable.
    /// 2. **The sieve only fronts the DFA.** It was measured pruning bytes for
    ///    the byte-class walk (0.335 B/cycle) and earns 2.06× there. In front of
    ///    a decider that already runs at 2.26 it is unmeasured, and an unmeasured
    ///    filter on every byte is the exact failure mode the prior art maps. When
    ///    that pairing is measured, delete the condition — not before.
    pub fn build(gpa: std.mem.Allocator, a: Admit) std.mem.Allocator.Error!Rungs {
        var r: Rungs = .{};
        errdefer r.deinit(gpa);

        // Build representability independently; ordering never hides a candidate.
        var compose = if (a.dfa) |d| try compose_mod.Compose.lower(gpa, d) else null;
        errdefer if (compose) |c| c.deinit();
        const parabix = if (a.ast) |root| switch (parabix_mod.Parabix.build(root, a.parabix_model)) {
            .armed => |p| p,
            .declined => null,
        } else null;

        const fallback = Offer{
            .kind = .fallback,
            // Dense eager DFA is ~3 cyc/B. A start skip pays a small fixed scan
            // plus verification at one candidate per expected stride.
            .cost = .{ .scan = if (a.prefilter) |p| 500 + 30_000 / @max(p.stride, 1) else 30_000 },
        };
        var selected = fallback;
        if (compose) |c| {
            const offer = Offer{
                .kind = .compose,
                .cost = .{
                    .scan = switch (c.width) {
                        .lanes16 => @as(u32, 4_400),
                        .lanes32 => @as(u32, 8_000),
                    } + if (c.index == .byte_eol) @as(u32, 800) else 0,
                    .compile = @intCast(c.table.len),
                },
            };
            if (offer.cost.lessThan(selected.cost)) selected = offer;
        }
        if (parabix) |*p| {
            const offer = Offer{
                .kind = .parabix,
                .cost = .{
                    .scan = 9_000 + @as(u32, @intCast(p.economics.stripe_ops / 8)),
                    .compile = p.prog.ninstrs,
                },
            };
            if (offer.cost.lessThan(selected.cost)) selected = offer;
        }

        switch (selected.kind) {
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
        r.admission = .{
            .selected = selected.kind,
            .selected_cost = selected.cost,
            .fallback_cost = fallback.cost,
            .prefilter = a.prefilter,
            .sieve = r.sieve != null,
        };
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
    if (comptime !parabix_mod.native) return error.SkipZigTest;
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

//! REGRET: was the auction's pick the fastest machine actually available?
//!
//! Every coefficient can verify clean and the auction can still be wrong, because
//! a model is a claim about how coefficients COMPOSE and no per-coefficient check
//! can test composition. So this file ignores the model entirely: for each
//! pattern it runs every machine the pattern admits over the same haystack,
//! measures each one, and asks what the ladder chose.
//!
//! Regret is the chosen machine's measured time over the best available one's.
//! 1.00 is a perfect pick. It is the ONE number here that would survive
//! replacing every coefficient with something else, which is exactly why it is
//! the gate: a bad model shows up as regret even when it is internally
//! consistent, and a good model that happens to disagree with a stale constant
//! does not.
//!
//! Two rules keep it honest:
//!
//!   * **Only representable machines are in the field.** A rung that declined
//!     this pattern is not a missed opportunity, it is not an option.
//!   * **The haystack cannot match.** A boolean scan returns at the first hit,
//!     so on a matching haystack "fastest" would mean "found it soonest" and the
//!     whole comparison would be about match position.

const std = @import("std");
const gist = @import("irregex");
const probe = @import("probe.zig");

const price = gist.regex_price;
const rungs = gist.regex_rungs;
const Regex = gist.regex.Regex;
const Compose = gist.regex_compose.Compose;
const Parabix = gist.regex_parabix.Parabix;

/// One machine's measured throughput on one pattern, beside what it bid.
pub const Arm = struct {
    kind: rungs.Selection,
    measured: f64,
    bid: f64,
};

/// One slot per `Selection`, so the field is indexable by the ladder's own
/// answer and a machine added to the enum cannot quietly go unjudged — it
/// arrives here as an untimed `null` the gate will point at.
pub const Field = [@typeInfo(rungs.Selection).@"enum".fields.len]?Arm;

pub const Verdict = struct {
    pattern: []const u8,
    /// Every representable machine, cheapest MEASURED first is not assumed —
    /// the order is the ladder's `Selection` order and the caller reads the
    /// numbers.
    arms: Field,
    chose: rungs.Selection,
    /// Measured time of the pick over measured time of the best arm. ≥ 1.
    regret: f64,
    /// The fastest arm, so a row with regret can name what it should have taken.
    best: rungs.Selection,

    pub fn arm(self: Verdict, k: rungs.Selection) ?Arm {
        return self.arms[@intFromEnum(k)];
    }
};

/// The slate. Deliberately spans the auction's decision boundaries rather than
/// its comfortable middle: patterns where one machine obviously wins teach
/// nothing about whether the pricing works.
pub const slate = [_][]const u8{
    // Dense walks — no skip, and small enough that composition should take them.
    "[a-z][0-9]wxy",
    "[a-z]{4}[0-9]{4}",
    "[a-z]{8}[0-9]{2}w",
    // Past the 31-lane ceiling: composition is not representable, so the field
    // narrows and the fallback must win without a rival to beat.
    "[a-z]{40}[0-9]",
    // A rare-literal skip: the DFA's accelerated walk should beat both vector
    // rungs, which is the boundary the old boolean dwell gate encoded by hand.
    "Qzxjvw",
    "Qzxjvw.*Wmkp",
    // Bit-parallel shapes: unbounded classes Parabix is built for.
    "[a-z]+[0-9]+wxy",
    "[a-y]+[0-9]+",
    // Anchored, so the end-of-line index is in play.
    "^[a-z]{6}[0-9]$",
    // A byte-CLASS dwell rather than a literal one. These three are the sieve
    // proof's own slate, promoted here because that bench measured the fallback
    // on the real corpus at a third of what it bid — and a rung mispriced by 3×
    // is the auction's problem, not the sieve's. A dwell whose exit set is a
    // whole class is the shape `Qzxjvw` cannot test: its stride comes from ten
    // bytes' summed density, not one rare byte's.
    "[0-9]{40,}",
    "[0-9]{4}-[0-9]{2}-[0-9]{2}",
    "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}",
    // Word context: composition cannot carry it, so the field is fallback plus
    // whatever Parabix makes of it.
    "\\b[a-z]{4}[0-9]{4}",
};

/// Measure every arm of one pattern and compare with what the shipped auction
/// chose. `null` when the pattern compiles to nothing this lane can time.
pub fn judge(rig: probe.Rig, hay: []const u8, pattern: []const u8) !?Verdict {
    var re = Regex.compileOpts(rig.gpa, pattern, .{ .force_dfa = true }) catch return null;
    defer re.deinit();

    var arms: Field = @splat(null);
    const ad = re.rungs.admission;

    // The one arm that is not a bidder. When a SIMD kernel above the tier
    // decides the pattern outright, nothing below it runs — so timing the DFA
    // and calling it the incumbent measures a machine the haystack never meets.
    // That is exactly how the sieve lane came to arm in front of a kernel four
    // times cheaper than its quote, and it is why this arm exists.
    if (probe.settledBy(rig, hay, &re)) |s| {
        arms[@intFromEnum(rungs.Selection.settled)] = .{
            .kind = .settled,
            .measured = s.cyc,
            .bid = price.price(.{ .settle = s.kind }).cycPerByte(),
        };
    }

    // The fallback arm is whichever walker this pattern actually got. It is
    // always in the field: it is what answers when everything else declines.
    // No eager automaton ⇒ that walker is not timeable here, so there is no
    // field to judge at all.
    const d = re.dfa orelse return null;
    arms[@intFromEnum(rungs.Selection.fallback)] = .{
        .kind = .fallback,
        .measured = rig.rate(probe.DfaPass{ .on = d, .hay = hay }, hay.len),
        .bid = ad.fallback_cost.cycPerByte(),
    };

    if (try Compose.lower(rig.gpa, d)) |cx| {
        defer cx.deinit();
        arms[@intFromEnum(rungs.Selection.compose)] = .{
            .kind = .compose,
            .measured = rig.rate(probe.ComposePass{ .on = cx, .hay = hay }, hay.len),
            .bid = price.price(.{ .compose = .{
                .width = cx.width,
                .eol = cx.index == .byte_eol,
                .table_bytes = cx.table.len,
            } }).cycPerByte(),
        };
    }

    switch (Parabix.compileOffer(rig.gpa, pattern, .{})) {
        .declined => {},
        .armed => |p| arms[@intFromEnum(rungs.Selection.parabix)] = .{
            .kind = .parabix,
            .measured = rig.rate(probe.ParabixPass{ .on = &p, .hay = hay }, hay.len),
            .bid = price.price(.{ .parabix = .{
                .stripe_ops = p.economics.stripe_ops,
                .instrs = p.prog.ninstrs,
            } }).cycPerByte(),
        },
    }

    var best: rungs.Selection = .fallback;
    var best_t = arms[@intFromEnum(rungs.Selection.fallback)].?.measured;
    for (arms) |maybe| if (maybe) |x| if (x.measured > 0 and x.measured < best_t) {
        best_t = x.measured;
        best = x.kind;
    };
    // A pick the ladder made but this lane could not time is not evidence of
    // anything, so it reads as no regret rather than as a win or a loss.
    const chosen_t = if (arms[@intFromEnum(ad.selected)]) |x| x.measured else best_t;
    return .{
        .pattern = pattern,
        .arms = arms,
        .chose = ad.selected,
        .best = best,
        .regret = if (best_t > 0) chosen_t / best_t else 1,
    };
}

//! irregex — the ladder's auction, tested through the front door.
//!
//! `rungs.zig` keeps the tests it can reach on its own: the admission policy, the
//! comptime rung table, the fail-closed gates. This file holds the ones that need
//! a real compile, because the claim is about what a PATTERN gets — and a pattern
//! only exists after the parser, the literal analysis, the class-run analysis and
//! the determinizer have each had their say. Reading `Regex.rungs.admission`
//! rather than calling the pricer directly also means these assert what the engine
//! shipped, not what a test reassembled.

const std = @import("std");
const regex = @import("../program/core.zig");
const rungs = @import("rungs.zig");
const price = @import("price.zig");
const literal_set = @import("../../../scan/literal_set.zig");

const Regex = regex.Regex;
const a = std.testing.allocator;

fn compile(pattern: []const u8) !Regex {
    return Regex.compileOpts(a, pattern, .{ .force_dfa = true });
}

test "a pattern a cheaper kernel already decides gets no tier at all" {
    // The defect this closes. `[0-9]{40,}` is a pure class run: `verdict.zig`
    // settles it with a SIMD membership scan at 0.15 cyc/B, above the ladder, and
    // neither a rung nor the DFA is ever consulted. The ladder did not know that.
    // It priced the incumbent as an eager DFA walk at 1.37 cyc/B — a machine this
    // pattern never gets — and a sieve, shown a phantom nine times dearer than the
    // truth, won that auction and armed. The pre-pass it then ran was pure cost,
    // and the sieve bench measured it as one.
    var run = try compile("[0-9]{40,}");
    defer run.deinit();
    try std.testing.expect(run.classrun != null and run.classrun.?.decides());
    const ad = run.rungs.admission;
    try std.testing.expectEqual(rungs.Selection.settled, ad.selected);
    // Not "every rung lost" — nothing was built to lose. That is the whole saving:
    // no lowering, no Sheng tables, no allocation for a machine never asked.
    try std.testing.expect(run.rungs.sieve == null);
    try std.testing.expect(run.rungs.compose == null);
    try std.testing.expect(run.rungs.parabix == null);
    try std.testing.expect(!run.rungs.fused());
    // And the published price is the kernel that answers, not the walk it
    // replaced. This is the number a bench reads to decide whether a pre-pass in
    // front of this pattern could ever pay, so a dense-walk default here is not a
    // cosmetic default — it is the phantom incumbent, one indirection along.
    try std.testing.expectEqual(price.price(.{ .settle = .class_ranges }), ad.selected_cost);
    try std.testing.expect(ad.selected_cost.lessThan(price.dense_default));
    // The walk is still described, though, because it still EXISTS — it is merely
    // never asked. An admission that overwrote this with the settler's price would
    // hand the next bench the same phantom pointing the other way.
    try std.testing.expectEqual(price.price(.{ .walk = .{ .kind = .eager } }), ad.fallback_cost);

    // An `.exact` literal set is the other authoritative kernel above the tier,
    // and it settles for the same reason: the set IS the pattern.
    var lit = try compile("alpha|omega");
    defer lit.deinit();
    if (lit.literal_scan) |*s| if (s.authority == .exact) {
        try std.testing.expectEqual(rungs.Selection.settled, lit.rungs.admission.selected);
        try std.testing.expect(lit.rungs.sieve == null);
    };
}

test "a settling kernel is priced by its classifier, not by its name" {
    // What the regret gate caught after the settled outcome first landed. `Qzxjvw`
    // settles on ONE literal — a single anchored SIMD scan, measured 0.04 cyc/B —
    // and one `settle_literal` coefficient minted on a three-needle alternation
    // quoted it at 0.47. It still won its own row, so no regret appeared; but
    // `selected_cost` is the divisor in the sieve's survival inequality, so a 12×
    // overstatement there is a sieve arming in front of a kernel it cannot beat.
    // The shapes are therefore separate coefficients, and each pattern must land
    // on its own.
    var one = try compile("Qzxjvw");
    defer one.deinit();
    const set = one.literal_scan orelse return error.SkipZigTest;
    try std.testing.expectEqual(literal_set.Authority.exact, set.authority);
    try std.testing.expectEqual(rungs.Selection.settled, one.rungs.admission.selected);
    try std.testing.expectEqual(
        price.price(.{ .settle = .literal_one }),
        one.rungs.admission.selected_cost,
    );

    var many = try compile("alpha|omega|kappa");
    defer many.deinit();
    if (many.literal_scan) |*s| if (s.authority == .exact and s.arity() == .many) {
        try std.testing.expectEqual(
            price.price(.{ .settle = .literal_many }),
            many.rungs.admission.selected_cost,
        );
    };

    // And the split is load-bearing rather than decorative: a bucket pass over a
    // set really is dearer per byte than one anchored scan, so collapsing them
    // would misprice whichever side lost the coin flip.
    try std.testing.expect(price.price(.{ .settle = .literal_one })
        .lessThan(price.price(.{ .settle = .literal_many })));
}

test "a kernel that only NARROWS leaves the tier its auction" {
    // The distinction the `settled` flag has to draw, or it would strangle the
    // ladder wholesale. `[0-9a-fA-F]{8}-[0-9a-fA-F]{4}` carries a required `-`, so
    // the literal engine is a `.candidate`: a miss rejects, a hit proves nothing,
    // and the machine that DECIDES is still the one the ladder elects. So the
    // auction must still be held.
    var re = try compile("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}");
    defer re.deinit();
    if (re.literal_scan) |*s| try std.testing.expectEqual(literal_set.Authority.candidate, s.authority);
    try std.testing.expect(re.rungs.admission.selected != .settled);
    try std.testing.expect(re.dfa != null);
    // And the incumbent it bids against is the walk that really answers.
    try std.testing.expectEqual(price.Walk.eager, re.rungs.admission.fallback_machine);
}

test "a class run that can cross a line does not settle the buffer grain" {
    // Why `decides` takes `nl_free` and not just exactness. A run of members that
    // includes `\n` may span a line boundary, and then "the buffer holds a run"
    // stops answering "some line holds one" — the kernel is still authoritative
    // per line, but the doc grain belongs to the tier below it.
    //
    // Under the per-line model this can't arise: `lower` strips `\n` from the set
    // (a line contains none, so removing it is exact), which is why the ordinary
    // path is always newline-free. `-U` is where the set is kept verbatim and the
    // obligation becomes real. Pinned because dropping it would not crash — it
    // would silently answer a different question at whole-buffer grain.
    var re = try Regex.compileOpts(a, "[0-9\\n]{40,}", .{ .force_dfa = true, .multiline = true });
    defer re.deinit();
    const cr = re.classrun orelse return error.SkipZigTest;
    try std.testing.expect(cr.exact); // the verdict half is discharged …
    try std.testing.expect(!cr.nl_free); // … and the grain half is not
    try std.testing.expect(!cr.decides());
    try std.testing.expect(re.rungs.admission.selected != .settled);

    // The control: the same shape without `\n` in the set settles, so the refusal
    // above is the obligation discriminating rather than `-U` disabling the kernel.
    var ok = try Regex.compileOpts(a, "[0-9]{40,}", .{ .force_dfa = true, .multiline = true });
    defer ok.deinit();
    try std.testing.expect(ok.classrun.?.decides());
}

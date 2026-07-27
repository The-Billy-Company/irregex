//! irregex patterns — adversarial tests for the multi-pattern set.
//!
//! The one contract that matters: a `PatternSet` answer must be EXACTLY the
//! answer N independent single-pattern `CompiledQuery` runs would give — the
//! fused gate and the muster's SIMD roll are accelerators, never oracles. So
//! every test here compares the set against the per-pattern engine directly (a
//! true independent oracle, not a mirror), including the heterogeneous shapes
//! that force the gate OFF (mixed case demands, non-linear bodies) and a
//! differential fuzz over random haystacks.
//!
//! Every parity assertion runs TWICE — once with the muster armed and once with
//! it stripped — because an accelerator that changes an answer is only visible
//! when you can compare against its own absence. Three answers must agree on
//! every document: muster on, muster off, and N independent searches.

const std = @import("std");
const patterns = @import("patterns.zig");
const query = @import("../match/query/query.zig");

const gpa = std.testing.allocator;
const PatternSet = patterns.PatternSet;
const Spec = query.Spec;

/// Oracle: does `spec` alone match `doc`? Straight through the single-pattern
/// engine, no set machinery.
fn oracleMatches(spec: Spec, doc: []const u8) !bool {
    var q = try query.CompiledQuery.compile(gpa, spec);
    defer q.deinit(gpa);
    var sc = try q.scratch(gpa);
    defer sc.deinit();
    return q.docMatches(doc, &sc);
}

/// Assert the set's docMask over `doc` equals the per-pattern oracle, bit for
/// bit — with the muster armed AND with it stripped, so the SIMD roll is proven
/// to be a pure accelerator rather than a second (possibly disagreeing) oracle.
fn expectMaskParity(specs: []const Spec, doc: []const u8) !void {
    try expectMaskParityOne(specs, doc, true);
    try expectMaskParityOne(specs, doc, false);
}

fn expectMaskParityOne(specs: []const Spec, doc: []const u8, armed: bool) !void {
    var set = try PatternSet.compile(gpa, specs);
    defer set.deinit(gpa);
    if (!armed) if (set.muster) |*m| {
        m.deinit(gpa);
        set.muster = null;
    };
    var sc = try set.scratch(gpa);
    defer sc.deinit(gpa);
    const mask = try gpa.alloc(u64, patterns.maskWords(specs.len));
    defer gpa.free(mask);
    const any = set.docMask(doc, &sc, mask);

    var oracle_any = false;
    for (specs, 0..) |spec, i| {
        const want = try oracleMatches(spec, doc);
        oracle_any = oracle_any or want;
        try std.testing.expectEqual(want, patterns.maskHas(mask, i));
    }
    try std.testing.expectEqual(oracle_any, any);
    try std.testing.expectEqual(oracle_any, set.anyMatch(doc, &sc));
}

test "attribution parity: mixed literals + regex against the single-pattern oracle" {
    const doc =
        \\const wallet = try WalletService.init(gpa);
        \\pub fn handleRefund(w: *WalletService) !void {
        \\    return w.refund(amount);
        \\}
    ;
    const specs = [_]Spec{
        .{ .pattern = "WalletService", .fixed = true },
        .{ .pattern = "refund\\(", .fixed = false },
        .{ .pattern = "nonexistent_needle_zzz", .fixed = true },
        .{ .pattern = "handle[A-Z]\\w+", .fixed = false },
    };
    try expectMaskParity(&specs, doc);
}

test "gate off (mixed case demands): still exact" {
    // ignore_case differs across specs ⇒ no fused gate; confirm-only must
    // still produce oracle-exact attribution.
    const specs = [_]Spec{
        .{ .pattern = "WALLETSERVICE", .fixed = true, .ignore_case = true },
        .{ .pattern = "WALLETSERVICE", .fixed = true, .ignore_case = false },
    };
    var set = try PatternSet.compile(gpa, &specs);
    defer set.deinit(gpa);
    try std.testing.expect(set.gate == null);
    try expectMaskParity(&specs, "one WalletService here");
}

test "fixed metacharacters never leak into the gate as syntax" {
    // A `-F` pattern full of regex metachars: if the gate mis-escaped it, the
    // alternation would either fail to compile (gate null — acceptable) or,
    // worse, match the WRONG thing. Parity with the oracle catches both.
    const specs = [_]Spec{
        .{ .pattern = "a.b(c)*d", .fixed = true },
        .{ .pattern = "plainword", .fixed = true },
    };
    try expectMaskParity(&specs, "the literal a.b(c)*d appears; aXbccccd must not count");
    try expectMaskParity(&specs, "aXbccccd only — no fixed hit, no plainword");
}

test "lineHits attributes per line, only where the oracle agrees" {
    const specs = [_]Spec{
        .{ .pattern = "alpha", .fixed = true },
        .{ .pattern = "b[e3]ta", .fixed = false },
    };
    var set = try PatternSet.compile(gpa, &specs);
    defer set.deinit(gpa);
    var sc = try set.scratch(gpa);
    defer sc.deinit(gpa);

    var hits: std.ArrayList(u32) = .empty;
    defer hits.deinit(gpa);

    try set.lineHits("alpha and b3ta together", &sc, gpa, &hits);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, hits.items);

    hits.clearRetainingCapacity();
    try set.lineHits("only beta here", &sc, gpa, &hits);
    try std.testing.expectEqualSlices(u32, &.{1}, hits.items);

    hits.clearRetainingCapacity();
    try set.lineHits("neither one", &sc, gpa, &hits);
    try std.testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "single spec set: no gate, still exact" {
    const specs = [_]Spec{.{ .pattern = "needle", .fixed = true }};
    var set = try PatternSet.compile(gpa, &specs);
    defer set.deinit(gpa);
    try std.testing.expect(set.gate == null);
    try expectMaskParity(&specs, "a needle in a haystack");
    try expectMaskParity(&specs, "no such thing");
}

test "differential fuzz: random haystacks, set ≡ N oracles" {
    // Random lowercase haystacks against a fixed pattern slate whose needles
    // are short enough to actually occur — the classic mirror-free oracle
    // loop (same shape as regex/adversarial_test.zig).
    const specs = [_]Spec{
        .{ .pattern = "ab", .fixed = true },
        .{ .pattern = "c+d", .fixed = false },
        .{ .pattern = "e.g", .fixed = false },
        .{ .pattern = "hh", .fixed = true },
    };
    var prng = std.Random.DefaultPrng.init(0xdecaf);
    const r = prng.random();
    var buf: [96]u8 = undefined;
    for (0..200) |_| {
        const n = r.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*b| b.* = 'a' + r.uintLessThan(u8, 8);
        try expectMaskParity(&specs, buf[0..n]);
    }
}

test "a slate wider than the muster's bucket count stays exact" {
    // 24 patterns over 8 buckets: every bucket carries three literals, so a
    // candidate lane names three patterns and only the confirm can separate
    // them. Mixed shapes on purpose — bare literals (settled by presence),
    // caseless bodies (never settled), a `-w` body (nominated, never decided),
    // and a bare `.` (no derivable literal ⇒ permanently in play).
    const specs = [_]Spec{
        .{ .pattern = "alpha", .fixed = true },
        .{ .pattern = "alphabet", .fixed = true },
        .{ .pattern = "alphanumeric", .fixed = true },
        .{ .pattern = "bravo", .fixed = true },
        .{ .pattern = "bravado", .fixed = true },
        .{ .pattern = "charlie", .fixed = true },
        .{ .pattern = "delta", .fixed = true },
        .{ .pattern = "echo", .fixed = true },
        .{ .pattern = "foxtrot", .fixed = true },
        .{ .pattern = "golf", .fixed = true },
        .{ .pattern = "hotel", .fixed = true },
        .{ .pattern = "india", .fixed = true },
        .{ .pattern = "ALPHA", .fixed = true, .ignore_case = true },
        .{ .pattern = "BRAVO", .fixed = true, .ignore_case = true },
        .{ .pattern = "alpha", .fixed = true, .word = true },
        .{ .pattern = "del[t7]a", .fixed = false },
        .{ .pattern = "ech[o0]", .fixed = false },
        .{ .pattern = "gol[fF]|hote[lL]", .fixed = false },
        .{ .pattern = ".", .fixed = false },
        .{ .pattern = "zz_absent_zz", .fixed = true },
        .{ .pattern = "a.b(c)*d", .fixed = true },
        .{ .pattern = "j", .fixed = true }, // single byte: below the SIMD floor
        .{ .pattern = "k", .fixed = true },
        .{ .pattern = "juliett", .fixed = true },
    };
    // Short enough for the scalar tail, long enough for the vector body, and one
    // document holding nothing at all (the all-miss early rejection).
    try expectMaskParity(&specs, "alphabet");
    try expectMaskParity(&specs, "alpha bravado charlie delta echo foxtrot golf hotel india juliett");
    try expectMaskParity(&specs, "alphanumeric ALPHA and Bravo, del7a, ech0, a.b(c)*d, k");
    try expectMaskParity(&specs, "qqqqqqqq");
    try expectMaskParity(&specs, "");
}

test "differential fuzz: wide slate, muster on ≡ muster off ≡ N oracles" {
    // The same mirror-free loop as above, but with enough patterns to force
    // bucket sharing and enough shapes to exercise every muster arm.
    const specs = [_]Spec{
        .{ .pattern = "ab", .fixed = true },
        .{ .pattern = "ba", .fixed = true },
        .{ .pattern = "abc", .fixed = true },
        .{ .pattern = "c+d", .fixed = false },
        .{ .pattern = "e.g", .fixed = false },
        .{ .pattern = "hh", .fixed = true },
        .{ .pattern = "f|gg", .fixed = false },
        .{ .pattern = "AB", .fixed = true, .ignore_case = true },
        .{ .pattern = "ab", .fixed = true, .word = true },
        .{ .pattern = "d", .fixed = true },
        .{ .pattern = "efe", .fixed = true },
        .{ .pattern = "[gh]{2,3}", .fixed = false },
    };
    var prng = std.Random.DefaultPrng.init(0xdecaf2);
    const r = prng.random();
    var buf: [160]u8 = undefined;
    for (0..200) |_| {
        const n = r.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*b| b.* = 'a' + r.uintLessThan(u8, 8);
        try expectMaskParity(&specs, buf[0..n]);
    }
}

test "lineHits is muster-invariant" {
    const specs = [_]Spec{
        .{ .pattern = "alpha", .fixed = true },
        .{ .pattern = "b[e3]ta", .fixed = false },
        .{ .pattern = "GAMMA", .fixed = true, .ignore_case = true },
        .{ .pattern = "absent", .fixed = true },
    };
    const lines = [_][]const u8{
        "alpha and b3ta and Gamma",
        "only beta here",
        "neither one",
        "",
        "alphabetagamma runs them together",
    };
    for (lines) |line| {
        var armed: std.ArrayList(u32) = .empty;
        defer armed.deinit(gpa);
        var bare: std.ArrayList(u32) = .empty;
        defer bare.deinit(gpa);
        try collectLineHits(&specs, line, true, &armed);
        try collectLineHits(&specs, line, false, &bare);
        try std.testing.expectEqualSlices(u32, bare.items, armed.items);
        // …and both agree with the independent per-pattern engine.
        var want: std.ArrayList(u32) = .empty;
        defer want.deinit(gpa);
        for (specs, 0..) |spec, i| {
            if (try oracleMatches(spec, line)) try want.append(gpa, @intCast(i));
        }
        try std.testing.expectEqualSlices(u32, want.items, armed.items);
    }
}

fn collectLineHits(specs: []const Spec, line: []const u8, armed: bool, out: *std.ArrayList(u32)) !void {
    var set = try PatternSet.compile(gpa, specs);
    defer set.deinit(gpa);
    if (!armed) if (set.muster) |*m| {
        m.deinit(gpa);
        set.muster = null;
    };
    var sc = try set.scratch(gpa);
    defer sc.deinit(gpa);
    try set.lineHits(line, &sc, gpa, out);
}

test "prefilter delegates per pattern" {
    const specs = [_]Spec{
        .{ .pattern = "WalletService", .fixed = true },
        .{ .pattern = "ab", .fixed = true }, // too short for a trigram
    };
    var set = try PatternSet.compile(gpa, &specs);
    defer set.deinit(gpa);
    var one: [1][]const u8 = undefined;
    const lits = set.prefilter(0, &one);
    try std.testing.expectEqual(@as(usize, 1), lits.len);
    try std.testing.expectEqualStrings("WalletService", lits[0]);
    var one2: [1][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), set.prefilter(1, &one2).len);
}

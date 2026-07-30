//! irregex compose/candidates — contract differential for the typed CandidateSet.
//!
//! The ADR-367 exact-before-statistical seam in concrete terms: `select` over a
//! compiled `PatternSet` must equal the plain set-algebra of N independent
//! single-pattern substring runs — the union under `.any`, the intersection
//! under `.all` — and every surviving doc must carry the EXACT per-pattern mask.
//! The fused any-of gate is only an accelerator, so the oracle here is
//! `std.mem.indexOf` over fixed, case-sensitive literals: an engine-independent
//! ground truth, never a mirror of the batch matcher the code under test drives.

const std = @import("std");
const candidates = @import("candidates.zig");

const gpa = std.testing.allocator;
const t = std.testing;

const Expect = struct { ids: []u32, masks: []u64 };

/// Independent oracle: the (ids, masks) `select` must produce, derived purely
/// from substring membership. Caller owns the returned slices.
fn oracle(a: std.mem.Allocator, docs: []const []const u8, pats: []const []const u8, match: candidates.Match) !Expect {
    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(a);
    var masks: std.ArrayList(u64) = .empty;
    errdefer masks.deinit(a);
    for (docs, 0..) |doc, d| {
        var m: u64 = 0;
        for (pats, 0..) |p, pi| {
            if (std.mem.indexOf(u8, doc, p) != null) m |= @as(u64, 1) << @intCast(pi);
        }
        const admit = switch (match) {
            .any => m != 0,
            .all => @as(usize, @popCount(m)) == pats.len,
        };
        if (!admit) continue;
        try ids.append(a, @intCast(d));
        try masks.append(a, m);
    }
    return .{ .ids = try ids.toOwnedSlice(a), .masks = try masks.toOwnedSlice(a) };
}

/// Run `select` and assert byte-for-byte equality with the substring oracle,
/// plus the structural invariants the seam promises independent of any oracle.
fn expectSelectMatchesOracle(docs: []const []const u8, pats: []const []const u8, match: candidates.Match) !void {
    var set = try candidates.compileSet(gpa, pats);
    defer set.deinit(gpa);
    var cs = try candidates.select(gpa, docs, &set, match);
    defer cs.deinit();

    const exp = try oracle(gpa, docs, pats, match);
    defer gpa.free(exp.ids);
    defer gpa.free(exp.masks);

    try t.expectEqual(pats.len, cs.npatterns);
    try t.expectEqualSlices(u32, exp.ids, cs.ids);
    try t.expectEqualSlices(u64, exp.masks, cs.masks);

    // ids strictly ascending, and every survivor honestly admitted.
    var prev: ?u32 = null;
    for (cs.ids) |id| {
        if (prev) |p| try t.expect(id > p);
        prev = id;
    }
    for (cs.masks) |m| {
        try t.expect(m != 0);
        if (match == .all) try t.expectEqual(pats.len, @as(usize, @popCount(m)));
    }
}

test "select ≡ substring set-algebra: randomized differential (any + all)" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const pats = [_][]const u8{ "ab", "cd", "efg", "h", "bcd", "fgh", "aa" };
    const alphabet = "abcdefgh";
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();

    var docs: std.ArrayList([]const u8) = .empty;
    for (0..256) |_| {
        const buf = try a.alloc(u8, rnd.intRangeAtMost(usize, 0, 24));
        for (buf) |*c| c.* = alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)];
        try docs.append(a, buf);
    }
    // A handful of docs that contain every pattern, so `.all` has real survivors
    // to distinguish (an empty intersection would make the mode vacuously pass).
    for (0..4) |_| {
        var b: std.ArrayList(u8) = .empty;
        for (pats) |p| try b.appendSlice(a, p);
        for (0..rnd.intRangeAtMost(usize, 0, 6)) |_|
            try b.append(a, alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)]);
        try docs.append(a, try b.toOwnedSlice(a));
    }

    try expectSelectMatchesOracle(docs.items, &pats, .any);
    try expectSelectMatchesOracle(docs.items, &pats, .all);
}

test "select: overlapping literals get exact independent per-pattern masks" {
    const docs = [_][]const u8{ "cat", "category", "concatenate", "dog" };
    const pats = [_][]const u8{ "cat", "category" };
    try expectSelectMatchesOracle(&docs, &pats, .any);

    // Spot-check the masks so the intent stays legible: "category" and
    // "concatenate" both contain "cat", so attribution must NOT collapse them
    // into the fused gate's single bit.
    var set = try candidates.compileSet(gpa, &pats);
    defer set.deinit(gpa);
    var cs = try candidates.select(gpa, &docs, &set, .any);
    defer cs.deinit();
    try t.expectEqualSlices(u32, &.{ 0, 1, 2 }, cs.ids); // "dog" matches neither
    try t.expectEqual(@as(u64, 0b01), cs.masks[0]); // "cat" only
    try t.expectEqual(@as(u64, 0b11), cs.masks[1]); // "category" ⊃ "cat"
    try t.expectEqual(@as(u64, 0b01), cs.masks[2]); // "concatenate" ⊃ "cat"
}

test "select: 64 patterns fill the mask to bit 63 without overflow" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 64 distinct 3-byte literals p00..p63; none is a substring of another.
    var pats: [64][]const u8 = undefined;
    for (&pats, 0..) |*p, i| p.* = try std.fmt.allocPrint(a, "p{d:0>2}", .{i});

    const docs = [_][]const u8{ pats[63], "nothing here" };
    var set = try candidates.compileSet(gpa, &pats);
    defer set.deinit(gpa);
    var cs = try candidates.select(gpa, &docs, &set, .any);
    defer cs.deinit();

    try t.expectEqual(@as(usize, 64), cs.npatterns);
    try t.expectEqualSlices(u32, &.{0}, cs.ids);
    try t.expectEqual(@as(u64, 1) << 63, cs.masks[0]); // only the highest bit
}

test "select: rejects empty and over-cap pattern sets" {
    const docs = [_][]const u8{"whatever"};

    var empty = try candidates.compileSet(gpa, &.{});
    defer empty.deinit(gpa);
    try t.expectError(error.TooManyPatterns, candidates.select(gpa, &docs, &empty, .any));

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var pats: [65][]const u8 = undefined; // one past the u64 mask width
    for (&pats, 0..) |*p, i| p.* = try std.fmt.allocPrint(a, "q{d:0>2}", .{i});
    var over = try candidates.compileSet(gpa, &pats);
    defer over.deinit(gpa);
    try t.expectError(error.TooManyPatterns, candidates.select(gpa, &docs, &over, .any));
}

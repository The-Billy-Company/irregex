//! The definition of a minterm is checkable directly, so the oracle here is the
//! definition rather than a second implementation: over a space small enough to
//! enumerate, ask every scalar which sets contain it, and demand that two scalars
//! land in the same block **exactly when** those answers agree.
//!
//! That single biconditional is the whole contract. Left to right is stability —
//! no set splits a block, so the partition is legal. Right to left is minimality
//! — two blocks nothing distinguishes were not merged, so it is the *coarsest*
//! legal one. A sweep that emitted one atom per scalar would pass the first and
//! fail the second, which is what makes stating both worth the O(n²) loop.
//!
//! Checked at two instantiations, because the type is the caller's decision and a
//! generic that has only ever been instantiated once is a generic on paper: a
//! narrow window in `u21` (the regex engine's scalar), and the full byte line,
//! where a set touching the top of the space is the case that would wrap if the
//! sweep ran in `Scalar` rather than one bit wider.

const std = @import("std");
const minterm = @import("minterm.zig");

const t = std.testing;

/// A window of `u21` small enough for the quadratic oracle.
const Narrow = minterm.Space(u21, 40, 8);
/// The whole byte line, so the ceiling is a member of a set rather than beyond
/// every set.
const Bytes = minterm.Space(u8, 255, 8);

/// Every claim the partition makes, against the definition of a minterm.
fn audit(comptime S: type, gpa: std.mem.Allocator, family: []const []const S.Range) !void {
    var b = S.Builder.init(gpa);
    defer b.deinit();
    const slots = try gpa.alloc(S.Slot, family.len);
    defer gpa.free(slots);
    for (family, 0..) |set, i| slots[i] = try b.intern(set);

    const p = try b.finish();
    defer p.deinit(gpa);

    const span: usize = @as(usize, S.ceiling) + 1;

    // The atoms are a gapless, disjoint, ascending cover of the whole space.
    // Everything below reads `owner` positionally, so this has to hold first.
    var want_lo: usize = 0;
    for (p.atoms) |r| {
        try t.expectEqual(want_lo, @as(usize, r[0]));
        try t.expect(r[0] <= r[1]);
        want_lo = @as(usize, r[1]) + 1;
    }
    try t.expectEqual(span, want_lo);
    try t.expectEqual(p.atoms.len, p.owner.len);

    // Per scalar: which block it landed in, and which sets truly contain it.
    const mint = try gpa.alloc(S.Mint, span);
    defer gpa.free(mint);
    const sig = try gpa.alloc(u64, span);
    defer gpa.free(sig);
    for (p.atoms, p.owner) |r, o| {
        for (@as(usize, r[0])..@as(usize, r[1]) + 1) |x| mint[x] = o;
    }
    for (0..span) |x| {
        var live: u64 = 0;
        for (family, slots) |set, slot| {
            for (set) |r| if (x >= r[0] and x <= r[1]) {
                live |= @as(u64, 1) << @intCast(slot);
                break;
            };
        }
        sig[x] = live;
    }

    // The contract, both directions at once.
    for (0..span) |x| for (0..span) |y|
        try t.expectEqual(sig[x] == sig[y], mint[x] == mint[y]);

    // `count` is the number of distinct blocks, and ids are dense from zero.
    var distinct: u64 = 0;
    var top_id: u32 = 0;
    for (0..span) |x| {
        var fresh = true;
        for (0..x) |y| if (mint[y] == mint[x]) {
            fresh = false;
            break;
        };
        if (fresh) distinct += 1;
        top_id = @max(top_id, mint[x]);
    }
    try t.expectEqual(distinct, @as(u64, p.count));
    try t.expectEqual(p.count - 1, top_id);

    // Membership answers what direct interval containment answers.
    for (0..p.sets) |s| for (0..span) |x|
        try t.expectEqual(sig[x] >> @intCast(s) & 1 == 1, p.contains(@intCast(s), mint[x]));

    // `rangesOf` inverts `owner`: ascending, coalesced, and exactly the block.
    var m: S.Mint = 0;
    while (m < p.count) : (m += 1) {
        const got = try p.rangesOf(gpa, m);
        defer gpa.free(got);
        var covered: usize = 0;
        for (got, 0..) |r, i| {
            try t.expect(r[0] <= r[1]);
            // Strictly more than adjacent, or the two should have fused.
            if (i > 0) try t.expect(@as(usize, got[i - 1][1]) + 1 < @as(usize, r[0]));
            for (@as(usize, r[0])..@as(usize, r[1]) + 1) |x| {
                try t.expectEqual(m, mint[x]);
                covered += 1;
            }
        }
        var held: usize = 0;
        for (0..span) |x| if (mint[x] == m) {
            held += 1;
        };
        try t.expectEqual(held, covered);
    }
}

test "hand-picked families over a narrow window, checked against the definition" {
    const R = Narrow.Range;
    const cases: []const []const []const R = &.{
        &.{}, // no sets at all: one block, the whole line
        &.{&.{.{ 0, 40 }}}, // one set covering everything: still one block
        &.{&.{.{ 10, 20 }}}, // one cut in, one cut out
        &.{ &.{.{ 10, 20 }}, &.{.{ 15, 25 }} }, // overlap: four blocks
        &.{ &.{.{ 10, 20 }}, &.{.{ 21, 30 }} }, // abutting: no empty block between
        &.{ &.{.{ 10, 20 }}, &.{.{ 10, 20 }} }, // identical sets collapse to one slot
        &.{ &.{ .{ 0, 5 }, .{ 30, 40 } }, &.{.{ 3, 33 }} }, // multi-range set
        &.{&.{.{ 40, 40 }}}, // a set at the very top of the space
        &.{&.{.{ 0, 0 }}}, // and at the very bottom
        &.{ &.{.{ 0, 20 }}, &.{.{ 5, 25 }}, &.{.{ 10, 30 }}, &.{.{ 15, 35 }} }, // staircase
        // Two sets whose union is contiguous but which no third set separates —
        // the shape a byte-distance test would merge and a sweep must not.
        &.{ &.{ .{ 0, 9 }, .{ 20, 29 } }, &.{ .{ 10, 19 }, .{ 30, 40 } } },
    };
    for (cases) |family| try audit(Narrow, t.allocator, family);
}

test "random families, over the narrow window and over the whole byte line" {
    var prng: std.Random.DefaultPrng = .init(0xD15C0FFEE);
    const rnd = prng.random();

    inline for (.{ Narrow, Bytes }) |S| {
        for (0..30) |_| {
            var family: std.ArrayList([]const S.Range) = .empty;
            defer {
                for (family.items) |set| t.allocator.free(set);
                family.deinit(t.allocator);
            }
            const sets = rnd.intRangeAtMost(usize, 0, S.sets_max);
            for (0..sets) |_| {
                // Sorted and disjoint is the caller's contract, so build the
                // ranges by walking up the line rather than sorting after.
                var ranges: std.ArrayList(S.Range) = .empty;
                errdefer ranges.deinit(t.allocator);
                var at: usize = 0;
                while (at <= S.ceiling) {
                    at += rnd.intRangeAtMost(usize, 1, 6);
                    if (at > S.ceiling) break;
                    const lo = at;
                    at += rnd.intRangeAtMost(usize, 0, 6);
                    // Annotated: `@min` against a comptime bound narrows its
                    // result type, and `hi + 2` in a `u8` wraps at the ceiling.
                    const hi: usize = @min(at, @as(usize, S.ceiling));
                    try ranges.append(t.allocator, .{ @intCast(lo), @intCast(hi) });
                    at = hi + 2; // leave a gap, so the set stays disjoint
                }
                try family.append(t.allocator, try ranges.toOwnedSlice(t.allocator));
            }
            try audit(S, t.allocator, family.items);
        }
    }
}

test "interning is by content: the same set twice is one slot, a different one is not" {
    var b = Narrow.Builder.init(t.allocator);
    defer b.deinit();

    const a = try b.intern(&.{ .{ 1, 4 }, .{ 8, 9 } });
    const again = try b.intern(&.{ .{ 1, 4 }, .{ 8, 9 } });
    const other = try b.intern(&.{.{ 1, 4 }});
    const third = try b.intern(&.{ .{ 1, 4 }, .{ 8, 10 } });
    try t.expectEqual(a, again);
    try t.expect(a != other);
    try t.expect(other != third);

    const p = try b.finish();
    defer p.deinit(t.allocator);
    try t.expectEqual(@as(Narrow.Slot, 3), p.sets);
}

test "the ceiling on distinct sets refuses rather than truncating" {
    var b = Narrow.Builder.init(t.allocator);
    defer b.deinit();
    // Eight singletons fit; the ninth does not, and re-interning one already
    // held still answers, because dedup happens before the ceiling is consulted.
    for (0..Narrow.sets_max) |i|
        _ = try b.intern(&.{.{ @intCast(i), @intCast(i) }});
    try t.expectError(error.Oversized, b.intern(&.{.{ 30, 30 }}));
    try t.expectEqual(@as(Narrow.Slot, 0), try b.intern(&.{.{ 0, 0 }}));
}

test "a set touching the top of the space does not wrap the sweep" {
    // The exclusive end of `[200, 255]` is 256, which is not a `u8`. If the
    // sweep ran in `Scalar` it would close at 0 and the last block would be lost.
    var b = Bytes.Builder.init(t.allocator);
    defer b.deinit();
    const hi = try b.intern(&.{.{ 200, 255 }});
    const p = try b.finish();
    defer p.deinit(t.allocator);

    try t.expectEqual(@as(Bytes.Mint, 2), p.count);
    try t.expectEqual(@as(usize, 255), @as(usize, p.atoms[p.atoms.len - 1][1]));
    const top_block = p.owner[p.owner.len - 1];
    try t.expect(p.contains(hi, top_block));
    try t.expect(!p.contains(hi, p.owner[0]));

    const got = try p.rangesOf(t.allocator, top_block);
    defer t.allocator.free(got);
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expectEqual(Bytes.Range{ 200, 255 }, got[0]);
}

//! refine adversarial suite — two engines against a third algorithm.
//!
//! The load-bearing test is the differential. `moore` and `hopcroft` compute the
//! same partition by unrelated means, so each is evidence about the other, and
//! `textbook` below is a third: the quadratic pairwise marking algorithm out of
//! any automata course, which builds no signatures and holds no queue. All three
//! must agree on the whole `block` array, not merely on how many blocks there
//! are — a partition can have the right size and the wrong members.
//!
//! Then the properties the differential cannot see, because a shared bug would
//! satisfy all three: that the answer is *stable* (equivalent states step to
//! equivalent states) and *coarsest* (no two blocks could have merged), checked
//! directly against the definition rather than against another implementation.
//!
//! And the escalation, which needs its own test for a reason worth stating: a
//! budget that never fires and a budget that always fires both produce correct
//! answers, so correctness tests are blind to it. Only `Refinement.engine` can
//! tell, which is why it is in the return type.

const std = @import("std");
const refine = @import("refine.zig");

const t = std.testing;
const nowhere = refine.nowhere;

// ── the third algorithm ────────────────────────────────────────────────────

/// Myhill–Nerode by pairwise marking: two states are apart if the colouring
/// separates them, or if some symbol leads to a pair already known apart. Sweep
/// until nothing new is marked; whatever is left unmarked is equivalent.
///
/// O(n² · k) per sweep and O(n) sweeps, which is why it only ever runs on the
/// small half of the corpus below. It shares no data structure and no loop shape
/// with either engine — the point is that a bug would have to be in the
/// *definition* to fool all three.
fn textbook(
    gpa: std.mem.Allocator,
    table: refine.Table,
    colour: []const u32,
    block: []u32,
) !u32 {
    const n = table.states;
    const k = table.symbols;
    const apart = try gpa.alloc(bool, @as(usize, n) * n);
    defer gpa.free(apart);
    @memset(apart, false);

    const pair = struct {
        fn at(a: u32, b: u32, w: u32) usize {
            return @as(usize, a) * w + b;
        }
    };

    for (0..n) |i| for (0..n) |j| {
        if (colour[i] != colour[j]) apart[pair.at(@intCast(i), @intCast(j), n)] = true;
    };

    var moved = true;
    while (moved) {
        moved = false;
        for (0..n) |i| for (0..n) |j| {
            const ij = pair.at(@intCast(i), @intCast(j), n);
            if (apart[ij]) continue;
            for (0..k) |a| {
                const x = table.delta[i * k + a];
                const y = table.delta[j * k + a];
                if (x == y) continue; // the same successor is never evidence
                const split = if (x == nowhere or y == nowhere)
                    true // one steps into the sink and the other does not
                else
                    apart[pair.at(x, y, n)];
                if (split) {
                    apart[ij] = true;
                    apart[pair.at(@intCast(j), @intCast(i), n)] = true;
                    moved = true;
                    break;
                }
            }
        };
    }

    // Number by first appearance, the same contract `refine` promises: a state
    // joins the earliest block it is not apart from.
    var count: u32 = 0;
    for (0..n) |i| {
        block[i] = count;
        for (0..i) |j| {
            if (!apart[pair.at(@intCast(j), @intCast(i), n)]) {
                block[i] = block[j];
                break;
            }
        }
        if (block[i] == count) count += 1;
    }
    return count;
}

// ── properties, checked against the definition ─────────────────────────────

/// Stable: two states in one block step, on every symbol, into one block. This
/// is what "the partition is a congruence" means, and it is checkable without
/// recomputing anything.
fn stable(table: refine.Table, block: []const u32) !void {
    const n = table.states;
    const k = table.symbols;
    // The first state of each block is its witness; every later member must
    // agree with it, which is the same claim as all-pairs at n times less cost.
    const witness = try t.allocator.alloc(u32, n);
    defer t.allocator.free(witness);
    @memset(witness, nowhere);
    for (0..n) |s| if (witness[block[s]] == nowhere) {
        witness[block[s]] = @intCast(s);
    };
    for (0..n) |s| {
        const w = witness[block[s]];
        for (0..k) |a| {
            const mine = table.delta[s * k + a];
            const theirs = table.delta[@as(usize, w) * k + a];
            if (mine == nowhere or theirs == nowhere) {
                try t.expectEqual(mine, theirs); // the sink is its own block
            } else {
                try t.expectEqual(block[theirs], block[mine]);
            }
        }
    }
}

/// Coarsest: no two blocks share a colour and a successor-block vector, because
/// two that did would have merged. The contrapositive of stability, and the half
/// that catches an engine which splits too eagerly rather than not enough.
fn coarsest(
    gpa: std.mem.Allocator,
    table: refine.Table,
    colour: []const u32,
    block: []const u32,
    blocks: u32,
) !void {
    const n = table.states;
    const k = table.symbols;
    const w: usize = 1 + @as(usize, k);
    const sigs = try gpa.alloc(u32, @as(usize, blocks) * w);
    defer gpa.free(sigs);
    const filled = try gpa.alloc(bool, blocks);
    defer gpa.free(filled);
    @memset(filled, false);

    for (0..n) |s| {
        const b = block[s];
        if (filled[b]) continue;
        filled[b] = true;
        const sig = sigs[@as(usize, b) * w ..][0..w];
        sig[0] = colour[s];
        for (0..k) |a| {
            const to = table.delta[s * k + a];
            sig[1 + a] = if (to == nowhere) nowhere else block[to];
        }
    }
    for (0..blocks) |i| for (i + 1..blocks) |j| {
        const a = sigs[i * w ..][0..w];
        const b = sigs[j * w ..][0..w];
        if (std.mem.eql(u32, a, b)) {
            std.debug.print("blocks {d} and {d} are indistinguishable and did not merge\n", .{ i, j });
            return error.PartitionNotCoarsest;
        }
    };
}

/// Blocks are numbered by first appearance: the id `b` cannot show up before
/// `b - 1` has. This is the contract a caller compacting rows in place relies on,
/// and the reason all three implementations can be compared with `expectEqualSlices`.
fn canonical(block: []const u32, blocks: u32) !void {
    var expect: u32 = 0;
    for (block) |b| {
        try t.expect(b <= expect);
        if (b == expect) expect += 1;
    }
    try t.expectEqual(blocks, expect);
}

// ── random tables ──────────────────────────────────────────────────────────

const Shape = struct {
    states: u32,
    symbols: u32,
    colours: u32,
    /// How often a transition is missing, out of 256. Zero is a total function;
    /// a high value is a sparse table where the sink does most of the splitting.
    holes: u8,
};

/// A table of `shape`, with `delta` and `colour` owned by the caller.
fn deal(gpa: std.mem.Allocator, r: std.Random, shape: Shape) !struct { refine.Table, []u32 } {
    const cells = @as(usize, shape.states) * shape.symbols;
    const delta = try gpa.alloc(u32, cells);
    errdefer gpa.free(delta);
    for (delta) |*cell| {
        cell.* = if (r.int(u8) < shape.holes)
            nowhere
        else
            r.uintLessThan(u32, shape.states);
    }
    const colour = try gpa.alloc(u32, shape.states);
    errdefer gpa.free(colour);
    for (colour) |*c| c.* = r.uintLessThan(u32, shape.colours);
    return .{ .{ .states = shape.states, .symbols = shape.symbols, .delta = delta }, colour };
}

test "both engines and the textbook marking algorithm agree, state for state" {
    const gpa = t.allocator;
    var prng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15);
    const r = prng.random();

    for (0..600) |_| {
        const shape: Shape = .{
            .states = 1 + r.uintLessThan(u32, 24), // the oracle is O(n³k); stay small
            .symbols = r.uintLessThan(u32, 5),
            .colours = 1 + r.uintLessThan(u32, 3),
            .holes = switch (r.uintLessThan(u8, 3)) {
                0 => 0, // total function
                1 => 200, // mostly sink
                else => 64,
            },
        };
        const table, const colour = try deal(gpa, r, shape);
        defer gpa.free(table.delta);
        defer gpa.free(colour);

        const want = try gpa.alloc(u32, shape.states);
        defer gpa.free(want);
        const wanted = try textbook(gpa, table, colour, want);
        try canonical(want, wanted);

        const got = try gpa.alloc(u32, shape.states);
        defer gpa.free(got);
        for ([_]refine.Plan{ .moore, .hopcroft, .auto }) |plan| {
            @memset(got, 0xAA);
            const out = try refine.refine(gpa, table, colour, got, plan);
            try t.expectEqual(wanted, out.blocks);
            try t.expectEqualSlices(u32, want, got);
            try canonical(got, out.blocks);
            try stable(table, got);
            try coarsest(gpa, table, colour, got, out.blocks);
        }
    }
}

test "the engines still agree at a size the quadratic oracle cannot afford" {
    const gpa = t.allocator;
    var prng = std.Random.DefaultPrng.init(0xD1B54A32D192ED03);
    const r = prng.random();

    for (0..40) |_| {
        const shape: Shape = .{
            .states = 64 + r.uintLessThan(u32, 448),
            .symbols = 1 + r.uintLessThan(u32, 8),
            .colours = 1 + r.uintLessThan(u32, 6),
            .holes = r.int(u8),
        };
        const table, const colour = try deal(gpa, r, shape);
        defer gpa.free(table.delta);
        defer gpa.free(colour);

        const a = try gpa.alloc(u32, shape.states);
        defer gpa.free(a);
        const b = try gpa.alloc(u32, shape.states);
        defer gpa.free(b);

        const from_moore = try refine.refine(gpa, table, colour, a, .moore);
        const from_hopcroft = try refine.refine(gpa, table, colour, b, .hopcroft);
        try t.expectEqual(from_moore.blocks, from_hopcroft.blocks);
        try t.expectEqualSlices(u32, a, b);
        try stable(table, a);
        try coarsest(gpa, table, colour, a, from_moore.blocks);

        // And `auto` is not a third answer, whichever engine it settled on.
        const from_auto = try refine.refine(gpa, table, colour, b, .auto);
        try t.expectEqual(from_moore.blocks, from_auto.blocks);
        try t.expectEqualSlices(u32, a, b);
    }
}

// ── the escalation, which correctness alone cannot see ─────────────────────

test "a deep chain escalates to hopcroft; a shallow table never leaves moore" {
    const gpa = t.allocator;
    const n: u32 = 64;

    // Every state distinguishable only by its distance from the end: state i
    // steps to i+1, the last steps nowhere, and one colour throughout. Moore
    // learns exactly one new state per pass, so it needs n of them where the
    // budget allows ⌈log₂ n⌉ + 1 = 7.
    const chain = try gpa.alloc(u32, n);
    defer gpa.free(chain);
    for (chain, 0..) |*cell, i| cell.* = if (i + 1 == n) nowhere else @intCast(i + 1);
    const one = try gpa.alloc(u32, n);
    defer gpa.free(one);
    @memset(one, 7);
    const block = try gpa.alloc(u32, n);
    defer gpa.free(block);

    const deep = try refine.refine(
        gpa,
        .{ .states = n, .symbols = 1, .delta = chain },
        one,
        block,
        .auto,
    );
    try t.expectEqual(refine.Engine.hopcroft, deep.engine);
    try t.expectEqual(n, deep.blocks); // a chain shares nothing
    try t.expect(deep.passes <= std.math.log2_int_ceil(u32, n) + 1);
    // Numbered along the chain, which is what first-appearance numbering means
    // here: state i is block i.
    for (block, 0..) |b, i| try t.expectEqual(@as(u32, @intCast(i)), b);

    // The same size, one step deep: every state self-loops, so a single pass
    // settles it and the budget is never touched.
    const loops = try gpa.alloc(u32, n);
    defer gpa.free(loops);
    for (loops, 0..) |*cell, i| cell.* = @intCast(i);
    const two = try gpa.alloc(u32, n);
    defer gpa.free(two);
    for (two, 0..) |*c, i| c.* = @intCast(i % 2);

    const shallow = try refine.refine(
        gpa,
        .{ .states = n, .symbols = 1, .delta = loops },
        two,
        block,
        .auto,
    );
    try t.expectEqual(refine.Engine.moore, shallow.engine);
    try t.expectEqual(@as(u32, 2), shallow.blocks);
}

// ── hand-tallied cases ─────────────────────────────────────────────────────

test "two pairs merge across a swap, and the answer is hand-checkable" {
    const gpa = t.allocator;
    // 0 ⇄ 1 and 3 ⇄ 2, accepting on {0, 3}. Both accepting states step to a
    // rejecting one that steps back to an accepting one, so {0,3} and {1,2}.
    const delta = [_]u32{ 1, 0, 3, 2 };
    const colour = [_]u32{ 1, 0, 0, 1 };
    var block: [4]u32 = undefined;
    const out = try refine.refine(
        gpa,
        .{ .states = 4, .symbols = 1, .delta = &delta },
        &colour,
        &block,
        .auto,
    );
    try t.expectEqual(@as(u32, 2), out.blocks);
    try t.expectEqualSlices(u32, &.{ 0, 1, 1, 0 }, &block);
}

test "a cycle of one colour is one block, and does not spin" {
    const gpa = t.allocator;
    const delta = [_]u32{ 1, 2, 0 };
    const colour = [_]u32{ 4, 4, 4 };
    var block: [3]u32 = undefined;
    for ([_]refine.Plan{ .moore, .hopcroft, .auto }) |plan| {
        const out = try refine.refine(
            gpa,
            .{ .states = 3, .symbols = 1, .delta = &delta },
            &colour,
            &block,
            plan,
        );
        try t.expectEqual(@as(u32, 1), out.blocks);
        try t.expectEqualSlices(u32, &.{ 0, 0, 0 }, &block);
    }
}

test "the sink splits states nothing else could tell apart" {
    const gpa = t.allocator;
    // Both states share a colour and neither has a successor with any structure
    // to compare — only the presence of the transition differs. An engine that
    // treated a missing transition as a wildcard would merge these.
    const delta = [_]u32{ 0, nowhere };
    const colour = [_]u32{ 0, 0 };
    var block: [2]u32 = undefined;
    for ([_]refine.Plan{ .moore, .hopcroft, .auto }) |plan| {
        const out = try refine.refine(
            gpa,
            .{ .states = 2, .symbols = 1, .delta = &delta },
            &colour,
            &block,
            plan,
        );
        try t.expectEqual(@as(u32, 2), out.blocks);
        try t.expectEqualSlices(u32, &.{ 0, 1 }, &block);
    }
}

test "degenerate shapes: no states, no symbols, one state" {
    const gpa = t.allocator;
    var block: [4]u32 = undefined;

    const empty = try refine.refine(
        gpa,
        .{ .states = 0, .symbols = 3, .delta = &.{} },
        &.{},
        &block,
        .auto,
    );
    try t.expectEqual(@as(u32, 0), empty.blocks);

    // No symbols: nothing can refine the colouring, so the answer is exactly its
    // distinct colours — renumbered by first appearance.
    const colour = [_]u32{ 9, 3, 9, 400 };
    const bare = try refine.refine(
        gpa,
        .{ .states = 4, .symbols = 0, .delta = &.{} },
        &colour,
        &block,
        .auto,
    );
    try t.expectEqual(@as(u32, 3), bare.blocks);
    try t.expectEqualSlices(u32, &.{ 0, 1, 0, 2 }, &block);

    const lone = try refine.refine(
        gpa,
        .{ .states = 1, .symbols = 1, .delta = &.{0} },
        &.{77},
        &block,
        .auto,
    );
    try t.expectEqual(@as(u32, 1), lone.blocks);
    try t.expectEqual(@as(u32, 0), block[0]);
}

test "an arbitrary colouring is condensed, including one that collides with the sink" {
    const gpa = t.allocator;
    // A colour equal to `nowhere` must not read as a step into the sink when it
    // lands in a Moore signature. Both states step to state 0, so the colouring
    // is the only thing separating them, and it separates them.
    const delta = [_]u32{ 0, 0 };
    const colour = [_]u32{ nowhere, 0 };
    var block: [2]u32 = undefined;
    for ([_]refine.Plan{ .moore, .hopcroft, .auto }) |plan| {
        const out = try refine.refine(
            gpa,
            .{ .states = 2, .symbols = 1, .delta = &delta },
            &colour,
            &block,
            plan,
        );
        try t.expectEqual(@as(u32, 2), out.blocks);
        try t.expectEqualSlices(u32, &.{ 0, 1 }, &block);
    }
}

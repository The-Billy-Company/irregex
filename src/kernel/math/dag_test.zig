//! Adversarial tests for the hash-consed DAG. The three properties
//! everything downstream rests on get held directly — identity, ordering, and
//! the sharing `power` buys — and each sweep is checked against a naive
//! recursion that re-walks shared nodes, so an agreement failure means the
//! sweep is wrong rather than that the two disagree about what to compute.

const std = @import("std");
const dagmod = @import("dag.zig");

const t = std.testing;
const Id = dagmod.Id;

/// A miniature expression algebra with the same shape as the regex AST:
/// nullary leaves, unary quantifiers, binary structure.
const Op = union(enum) { lit: u8, cat, alt, star };
const T2 = dagmod.Dag(Op, 2);
const no: Id = .none;

fn leaf(tr: *T2, gpa: std.mem.Allocator, c: u8) !Id {
    return tr.intern(gpa, .{ .lit = c }, .{ no, no });
}
fn cat(tr: *T2, gpa: std.mem.Allocator, a: Id, b: Id) !Id {
    return tr.intern(gpa, .cat, .{ a, b });
}
fn alt(tr: *T2, gpa: std.mem.Allocator, a: Id, b: Id) !Id {
    return tr.intern(gpa, .alt, .{ a, b });
}

test "dag: equal shape interns to one id, and it is the shape that decides" {
    var tr: T2 = .empty;
    defer tr.deinit(t.allocator);

    const a = try leaf(&tr, t.allocator, 'a');
    const b = try leaf(&tr, t.allocator, 'b');
    try t.expectEqual(a, try leaf(&tr, t.allocator, 'a')); // same payload
    try t.expect(a != b);

    // Structural equality, not merely leaf equality: `ab` built twice from
    // scratch is one node, and equality is now an integer compare.
    const ab1 = try cat(&tr, t.allocator, a, b);
    const ab2 = try cat(&tr, t.allocator, try leaf(&tr, t.allocator, 'a'), try leaf(&tr, t.allocator, 'b'));
    try t.expectEqual(ab1, ab2);
    try t.expectEqual(tr.digest(ab1), tr.digest(ab2));

    // Order and operator are both part of the shape.
    try t.expect(ab1 != try cat(&tr, t.allocator, b, a));
    try t.expect(ab1 != try alt(&tr, t.allocator, a, b));

    // Five distinct nodes — a, b, ab, ba, a|b — retained from nine offered.
    try t.expectEqual(@as(usize, 5), tr.len());
    try t.expectEqual(@as(usize, 9), tr.stats.offered);
    try t.expect(tr.stats.sharing() > 1.0);
}

test "dag: a child's id is always below its parent's, so id order is topological" {
    var tr: T2 = .empty;
    defer tr.deinit(t.allocator);

    // Build something deep and shared enough that an accidental ordering would
    // show: a left spine, a right spine, and a rejoin.
    var rng = std.Random.DefaultPrng.init(0x7ea51e);
    const r = rng.random();
    var pool: std.ArrayList(Id) = .empty;
    defer pool.deinit(t.allocator);
    for (0..8) |i| try pool.append(t.allocator, try leaf(&tr, t.allocator, @intCast('a' + i)));
    for (0..400) |_| {
        const x = pool.items[r.uintLessThan(usize, pool.items.len)];
        const y = pool.items[r.uintLessThan(usize, pool.items.len)];
        try pool.append(t.allocator, if (r.boolean())
            try cat(&tr, t.allocator, x, y)
        else
            try alt(&tr, t.allocator, x, y));
    }

    for (0..tr.len()) |i| {
        for (tr.kidsOf(@enumFromInt(i))) |k| {
            if (k.present()) try t.expect(k.index() < i);
        }
    }
}

// The attribute both the sweep and the recursion compute: the shortest string
// the subexpression can match. Chosen because it reads every node kind and
// combines differently per kind, so an ordering or memo bug changes the answer.
fn minLenFold(_: void, _: Id, p: Op, kids: [2]Id, done: []const u32) u32 {
    return switch (p) {
        .lit => 1,
        .star => 0,
        .cat => done[kids[0].index()] + done[kids[1].index()],
        .alt => @min(done[kids[0].index()], done[kids[1].index()]),
    };
}

/// The same attribute by naive recursion, re-walking shared nodes exactly as
/// today's `*Node` visitors do. This is the "simpler alternative" the sweep has
/// to agree with before it is allowed to claim it is faster than.
fn minLenRec(tr: *const T2, id: Id) u32 {
    const kids = tr.kidsOf(id);
    return switch (tr.payload(id)) {
        .lit => 1,
        .star => 0,
        .cat => minLenRec(tr, kids[0]) + minLenRec(tr, kids[1]),
        .alt => @min(minLenRec(tr, kids[0]), minLenRec(tr, kids[1])),
    };
}

test "dag: the one-visit sweep agrees with the re-walking recursion at every node" {
    var tr: T2 = .empty;
    defer tr.deinit(t.allocator);

    var rng = std.Random.DefaultPrng.init(0xc0ffee);
    const r = rng.random();
    var pool: std.ArrayList(Id) = .empty;
    defer pool.deinit(t.allocator);
    for (0..5) |i| try pool.append(t.allocator, try leaf(&tr, t.allocator, @intCast('a' + i)));
    for (0..300) |_| {
        const x = pool.items[r.uintLessThan(usize, pool.items.len)];
        const y = pool.items[r.uintLessThan(usize, pool.items.len)];
        try pool.append(t.allocator, switch (r.uintLessThan(u8, 3)) {
            0 => try cat(&tr, t.allocator, x, y),
            1 => try alt(&tr, t.allocator, x, y),
            else => try tr.intern(t.allocator, .star, .{ x, no }),
        });
    }

    const swept = try tr.fold(t.allocator, u32, {}, minLenFold);
    defer t.allocator.free(swept);
    for (0..tr.len()) |i| {
        try t.expectEqual(minLenRec(&tr, @enumFromInt(i)), swept[i]);
    }
}

fn countLeaves(_: void, _: Id, p: Op, kids: [2]Id, done: []const u64) u64 {
    return switch (p) {
        .lit => 1,
        .star => done[kids[0].index()],
        .cat, .alt => done[kids[0].index()] + done[kids[1].index()],
    };
}

fn catCombine(_: void, tr: *T2, gpa: std.mem.Allocator, a: Id, b: Id) !Id {
    return tr.intern(gpa, .cat, .{ a, b });
}

test "dag: power denotes n copies in log-many nodes" {
    // The headline identity. `a{1000}` is a thousand leaves to the automaton
    // and two dozen nodes to every analysis.
    var tr: T2 = .empty;
    defer tr.deinit(t.allocator);

    const a = try leaf(&tr, t.allocator, 'a');
    const p1000 = (try tr.power(t.allocator, a, 1000, {}, catCombine)).?;

    const leaves = try tr.fold(t.allocator, u64, {}, countLeaves);
    defer t.allocator.free(leaves);
    try t.expectEqual(@as(u64, 1000), leaves[p1000.index()]); // language preserved
    try t.expect(tr.len() <= 2 * std.math.log2_int(usize, 1000) + 2); // ~19, not 1000

    // Left-folding the same repetition is what the parser does today; the
    // squared form must be a strict improvement, not a different answer.
    var naive: T2 = .empty;
    defer naive.deinit(t.allocator);
    const na = try leaf(&naive, t.allocator, 'a');
    var chain = na;
    for (1..1000) |_| chain = try cat(&naive, t.allocator, chain, na);
    const naive_leaves = try naive.fold(t.allocator, u64, {}, countLeaves);
    defer t.allocator.free(naive_leaves);
    try t.expectEqual(@as(u64, 1000), naive_leaves[chain.index()]);
    try t.expect(naive.len() > 40 * tr.len());
}

test "dag: power's boundary cases stay honest" {
    var tr: T2 = .empty;
    defer tr.deinit(t.allocator);
    const a = try leaf(&tr, t.allocator, 'a');

    try t.expectEqual(@as(?Id, null), try tr.power(t.allocator, a, 0, {}, catCombine));
    try t.expectEqual(a, (try tr.power(t.allocator, a, 1, {}, catCombine)).?);

    const leaves_of = struct {
        fn go(tri: *T2, gpa: std.mem.Allocator, id: Id) !u64 {
            const f = try tri.fold(gpa, u64, {}, countLeaves);
            defer gpa.free(f);
            return f[id.index()];
        }
    }.go;
    // Every n up to a power-of-two boundary and past it: the odd-bit path in
    // the squaring loop is where an off-by-one would hide.
    for (1..40) |n| {
        const p = (try tr.power(t.allocator, a, n, {}, catCombine)).?;
        try t.expectEqual(@as(u64, n), try leaves_of(&tr, t.allocator, p));
    }
}

// Inherited attribute: "how many `star`s enclose this node". Meet is `max`,
// so a node reached under two different nestings reports the deepest.
fn depthDown(_: void, _: Id, p: Op, _: usize, here: u32) u32 {
    return if (p == .star) here + 1 else here;
}
fn maxMeet(a: u32, b: u32) u32 {
    return @max(a, b);
}

test "dag: descend meets a shared node's parents instead of racing them" {
    var tr: T2 = .empty;
    defer tr.deinit(t.allocator);

    // `shared` is reached bare on the left and under two stars on the right.
    const shared = try leaf(&tr, t.allocator, 'x');
    const starred = try tr.intern(t.allocator, .star, .{ shared, no });
    const twice = try tr.intern(t.allocator, .star, .{ starred, no });
    const root = try alt(&tr, t.allocator, shared, twice);

    const depth = try tr.descend(t.allocator, u32, &.{root}, 0, 0, {}, depthDown, maxMeet);
    defer t.allocator.free(depth);

    try t.expectEqual(@as(u32, 0), depth[root.index()]);
    try t.expectEqual(@as(u32, 1), depth[starred.index()]);
    try t.expectEqual(@as(u32, 2), depth[shared.index()]); // the deeper claim wins
}

test "dag: census counts parents, and live separates the DAG from the rubble" {
    var tr: T2 = .empty;
    defer tr.deinit(t.allocator);

    const a = try leaf(&tr, t.allocator, 'a');
    const b = try leaf(&tr, t.allocator, 'b');
    const ab = try cat(&tr, t.allocator, a, b);
    const aab = try cat(&tr, t.allocator, a, ab); // `a` now has two parents
    const orphan = try alt(&tr, t.allocator, b, b); // interned, then abandoned

    const parents = try tr.census(t.allocator);
    defer t.allocator.free(parents);
    try t.expectEqual(@as(u32, 2), parents[a.index()]);
    try t.expectEqual(@as(u32, 3), parents[b.index()]); // ab, and twice in orphan
    try t.expectEqual(@as(u32, 0), parents[aab.index()]);

    const reachable = try tr.live(t.allocator, &.{aab});
    defer t.allocator.free(reachable);
    try t.expect(reachable[a.index()] and reachable[b.index()] and reachable[ab.index()]);
    try t.expect(!reachable[orphan.index()]); // a rewrite's superseded node
}

// A payload whose identity lives behind a slice — the case a bitwise hash gets
// wrong by interning on the address. Declaring the pair is the contract.
//
// Both halves read the bounds as VALUES. Reading them as bytes compiles, is
// shorter, and is what this fixture said until a `[2]u21` was measured: the
// type spans eight bytes and its two bounds fill forty-two bits, so a byte view
// carries twenty-two bits of whatever the allocation last held. The real
// payload this stands in for is `regex/ast/intern.zig`'s `uclass`, which had
// the byte spelling and split one class into two nodes.
const Ranges = struct {
    r: []const [2]u21,
    pub fn hash(self: Ranges) u64 {
        var h: std.hash.Wyhash = .init(0);
        for (self.r) |x| h.update(std.mem.asBytes(&[2]u32{ x[0], x[1] }));
        return h.final();
    }
    pub fn eql(a: Ranges, b: Ranges) bool {
        return a.r.len == b.r.len and for (a.r, b.r) |x, y| {
            if (x[0] != y[0] or x[1] != y[1]) break false;
        } else true;
    }
};

test "dag: a slice payload interns by content once it declares hash/eql" {
    var tr = dagmod.Dag(Ranges, 1){};
    defer tr.deinit(t.allocator);

    const one = [_][2]u21{.{ 'a', 'z' }};
    const other = [_][2]u21{.{ 'a', 'y' }};

    // The second copy is built on the heap over poison and assigned bound by
    // bound, which is what an `ArrayList` append does and what the parser's
    // scalar set is. Two `.rodata` literals — what this test compared for its
    // whole life — cannot tell an address-interner from a content-interner
    // that reads the slack, because a constant's slack is zero on both sides.
    const copy = try t.allocator.alloc([2]u21, 1);
    defer t.allocator.free(copy);
    @memset(std.mem.sliceAsBytes(copy), 0xAA);
    copy[0] = .{ 'a', 'z' };
    try t.expect(!std.mem.eql(u8, std.mem.sliceAsBytes(&one), std.mem.sliceAsBytes(copy)));

    const x = try tr.intern(t.allocator, .{ .r = &one }, .{.none});
    try t.expectEqual(x, try tr.intern(t.allocator, .{ .r = copy }, .{.none}));
    try t.expect(x != try tr.intern(t.allocator, .{ .r = &other }, .{.none}));
    try t.expectEqual(@as(usize, 2), tr.len());
}

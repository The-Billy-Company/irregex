//! Two claims worth an oracle: the automaton accepts exactly the keys it was
//! given, and it is the *smallest* automaton that does.
//!
//! The first is checked directly, including against near-misses — prefixes,
//! extensions, one-byte mutations — because a set that answers yes to everything
//! also accepts every key. The second is checked by a second route entirely: the
//! trie over the same keys, quotiented by `refine`. Two trie states merge exactly
//! when no suffix distinguishes them, which is Myhill–Nerode, so the class count
//! is the minimal state count. Incremental hash-consing and minimize-a-finished-
//! trie are different algorithms — the register never builds the trie, the
//! refinement never seals a state — and they have to land on the same size.

const std = @import("std");
const dafsa = @import("dafsa.zig");
const refine = @import("refine.zig");

const t = std.testing;

/// The automaton before anything but prefixes is shared. Dense over all 256
/// bytes because the oracle's job is to be obviously correct, not small.
const Trie = struct {
    /// `next[s * 256 + c]`, or `absent`.
    next: []u32,
    accepts: []bool,

    const absent = std.math.maxInt(u32);

    fn states(trie: Trie) u32 {
        return @intCast(trie.accepts.len);
    }

    fn deinit(trie: Trie, gpa: std.mem.Allocator) void {
        gpa.free(trie.next);
        gpa.free(trie.accepts);
    }
};

fn plant(gpa: std.mem.Allocator, keys: []const []const u8) !Trie {
    var next: std.ArrayList(u32) = .empty;
    errdefer next.deinit(gpa);
    var accepts: std.ArrayList(bool) = .empty;
    errdefer accepts.deinit(gpa);
    try next.appendNTimes(gpa, Trie.absent, 256);
    try accepts.append(gpa, false);

    for (keys) |key| {
        var s: u32 = 0;
        for (key) |c| {
            if (next.items[@as(usize, s) * 256 + c] == Trie.absent) {
                const born: u32 = @intCast(accepts.items.len);
                try next.appendNTimes(gpa, Trie.absent, 256);
                try accepts.append(gpa, false);
                next.items[@as(usize, s) * 256 + c] = born;
            }
            s = next.items[@as(usize, s) * 256 + c];
        }
        accepts.items[s] = true;
    }
    return .{
        .next = try next.toOwnedSlice(gpa),
        .accepts = try accepts.toOwnedSlice(gpa),
    };
}

const Size = struct { states: u32, edges: u32 };

/// The minimal automaton's size, by the other road: plant the trie, quotient it
/// by refinement, and measure the quotient.
fn quotient(gpa: std.mem.Allocator, keys: []const []const u8) !Size {
    const trie = try plant(gpa, keys);
    defer trie.deinit(gpa);
    const n = trie.states();

    // Only the bytes the keys use. Every other column is the sink in every row,
    // so it can separate nothing and only costs the refinement work.
    var seen: [256]bool = @splat(false);
    for (keys) |key| for (key) |c| {
        seen[c] = true;
    };
    var alphabet: std.ArrayList(u8) = .empty;
    defer alphabet.deinit(gpa);
    for (0..256) |c| if (seen[c]) try alphabet.append(gpa, @intCast(c));
    const k: u32 = @intCast(alphabet.items.len);

    const delta = try gpa.alloc(u32, @as(usize, n) * k);
    defer gpa.free(delta);
    const color = try gpa.alloc(u32, n);
    defer gpa.free(color);
    const block = try gpa.alloc(u32, n);
    defer gpa.free(block);

    for (0..n) |s| {
        color[s] = @intFromBool(trie.accepts[s]);
        for (alphabet.items, 0..) |c, j| {
            const to = trie.next[s * 256 + c];
            delta[s * k + j] = if (to == Trie.absent) refine.nowhere else to;
        }
    }

    const got = try refine.refine(
        gpa,
        .{ .states = n, .symbols = k, .delta = delta },
        color,
        block,
        .auto,
    );

    // One representative per class carries the class's out-degree: refinement
    // guarantees every member of a class agrees on where each symbol goes.
    var counted = try gpa.alloc(bool, got.blocks);
    defer gpa.free(counted);
    @memset(counted, false);
    var edges: u32 = 0;
    for (0..n) |s| {
        if (counted[block[s]]) continue;
        counted[block[s]] = true;
        for (alphabet.items) |c|
            if (trie.next[s * 256 + c] != Trie.absent) {
                edges += 1;
            };
    }
    return .{ .states = got.blocks, .edges = edges };
}

/// Both claims, over one key set: the language is exact, the ordinals are a
/// bijection, and the size matches the quotient of the trie.
fn agrees(gpa: std.mem.Allocator, keys: []const []const u8) !void {
    const d = try dafsa.build(gpa, keys);
    defer d.deinit(gpa);

    try t.expectEqual(@as(u32, @intCast(keys.len)), d.count());

    const buf = try gpa.alloc(u8, @max(1, d.longest));
    defer gpa.free(buf);

    for (keys, 0..) |key, i| {
        try t.expect(d.contains(key));
        // The keys arrive sorted, so a key's ordinal is its index — which pins
        // both that `rank` is dense and that it counts in the right order.
        try t.expectEqual(@as(?u32, @intCast(i)), d.rank(key));
        try t.expectEqualStrings(key, d.spell(@intCast(i), buf).?);
    }
    try t.expectEqual(@as(?[]const u8, null), d.spell(d.count(), buf));

    // Near misses. A structure that accepts its keys and also their neighbors
    // would pass every check above.
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    for (keys) |key| {
        for (0..key.len) |cut| {
            scratch.clearRetainingCapacity();
            try scratch.appendSlice(gpa, key[0..cut]);
            if (!member(keys, scratch.items)) {
                try t.expect(!d.contains(scratch.items));
                try t.expectEqual(@as(?u32, null), d.rank(scratch.items));
            }
        }
        for ([_]u8{ 0, 'z', 255 }) |tail| {
            scratch.clearRetainingCapacity();
            try scratch.appendSlice(gpa, key);
            try scratch.append(gpa, tail);
            if (!member(keys, scratch.items)) try t.expect(!d.contains(scratch.items));
        }
        for (0..key.len) |at| {
            scratch.clearRetainingCapacity();
            try scratch.appendSlice(gpa, key);
            scratch.items[at] ^= 1;
            if (!member(keys, scratch.items)) try t.expect(!d.contains(scratch.items));
        }
    }

    const want = try quotient(gpa, keys);
    try t.expectEqual(want.states, d.states());
    try t.expectEqual(want.edges, d.edges());
}

fn member(keys: []const []const u8, key: []const u8) bool {
    for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

test "the set accepts its keys, ranks them in order, and is as small as the quotient of a trie" {
    const cases: []const []const []const u8 = &.{
        &.{ "ab", "ac" },
        &.{ "a", "ab", "abc" }, // a key that is a prefix of another
        &.{ "cat", "cats", "dog", "dogs" }, // the shared `s` tail
        &.{ "tap", "taps", "top", "tops" },
        &.{ "aaa", "aab", "aba", "abb", "baa", "bab", "bba", "bbb" }, // full 3-cube
        &.{ "", "a", "b" }, // the empty key is a key
        &.{"alone"},
        &.{ "\x00", "\x00\xff", "\xff" }, // bytes, not text
    };
    for (cases) |keys| try agrees(t.allocator, keys);
}

test "suffix sharing is doing work: the automaton is strictly smaller than the trie" {
    // Sixteen keys, each a distinct two-byte head on a shared eight-byte tail.
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| t.allocator.free(k);
        keys.deinit(t.allocator);
    }
    for ("abcd") |x| for ("abcd") |y| {
        try keys.append(t.allocator, try std.fmt.allocPrint(
            t.allocator,
            "{c}{c}_test.zig",
            .{ x, y },
        ));
    };

    const d = try dafsa.build(t.allocator, keys.items);
    defer d.deinit(t.allocator);
    const trie = try plant(t.allocator, keys.items);
    defer trie.deinit(t.allocator);

    try t.expectEqual(@as(u32, 16), d.count());
    // A trie stores the tail sixteen times; the automaton stores it once, so the
    // sixteen heads converge and everything after them is one chain.
    try t.expect(d.states() * 3 < trie.states());
    try agrees(t.allocator, keys.items);
}

test "unsorted input is refused, and so is a duplicate" {
    try t.expectError(error.NonCanonical, dafsa.build(t.allocator, &.{ "b", "a" }));
    try t.expectError(error.NonCanonical, dafsa.build(t.allocator, &.{ "a", "a" }));
    try t.expectError(error.NonCanonical, dafsa.build(t.allocator, &.{ "ab", "a" }));
    try t.expectError(error.NonCanonical, dafsa.build(t.allocator, &.{ "a", "b", "b", "c" }));
}

test "degenerate shapes: no keys, and the empty key alone" {
    {
        const d = try dafsa.build(t.allocator, &.{});
        defer d.deinit(t.allocator);
        try t.expectEqual(@as(u32, 0), d.count());
        try t.expect(!d.contains(""));
        try t.expect(!d.contains("a"));
        try t.expectEqual(@as(u32, 0), d.longest);
    }
    {
        const d = try dafsa.build(t.allocator, &.{""});
        defer d.deinit(t.allocator);
        try t.expectEqual(@as(u32, 1), d.count());
        try t.expect(d.contains(""));
        try t.expectEqual(@as(?u32, 0), d.rank(""));
        try t.expect(!d.contains("a"));
        var buf: [1]u8 = undefined;
        try t.expectEqualStrings("", d.spell(0, &buf).?);
    }
}

test "random key sets, over a narrow alphabet so suffixes actually collide" {
    var prng: std.Random.DefaultPrng = .init(0x5A17ED);
    const rnd = prng.random();

    for (0..40) |_| {
        var keys: std.ArrayList([]const u8) = .empty;
        defer {
            for (keys.items) |k| t.allocator.free(k);
            keys.deinit(t.allocator);
        }
        const want = rnd.intRangeAtMost(usize, 1, 30);
        for (0..want) |_| {
            const len = rnd.intRangeAtMost(usize, 0, 6);
            const key = try t.allocator.alloc(u8, len);
            for (key) |*c| c.* = 'a' + rnd.uintLessThan(u8, 3);
            try keys.append(t.allocator, key);
        }

        // Sort and drop duplicates: `build` demands strictly ascending, and
        // shrinking the list here is what the contract asks a caller to do.
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        var kept: usize = 0;
        for (keys.items, 0..) |key, i| {
            if (i > 0 and std.mem.eql(u8, keys.items[kept - 1], key)) {
                t.allocator.free(key);
                continue;
            }
            keys.items[kept] = key;
            kept += 1;
        }
        keys.shrinkRetainingCapacity(kept);

        try agrees(t.allocator, keys.items);
    }
}

//! sais — the seam around libsais, not the sort itself (libsais has its own
//! upstream proof; the shifted-alphabet + sentinel identity this module adds
//! is what needs checking here, and gets its most exhaustive treatment as a
//! comparison-sort oracle inside `codex_test.zig`, per this file's own
//! docstring). This file is the seam's standalone proof, so it stands on its
//! own without a live FM-index: the sentinel invariant on adversarial small
//! texts, the `Oversized` guard fired before any real allocation, and a
//! from-scratch comparison-sort oracle independent of codex's.

const std = @import("std");
const sais = @import("sais.zig");

const t = std.testing;

test "build: refuses text past max_text_len before touching a single byte" {
    const bogus_len: usize = @as(usize, sais.max_text_len) + 1;
    // The guard `if (text.len > max_text_len) return error.Oversized;` reads
    // only `text.len`, never `text.ptr` — so a slice whose LENGTH lies past
    // the ceiling can be refused with no allocation anywhere near that size,
    // as long as nothing downstream ever dereferences the fake pointer.
    const fake: []const u8 = @as([*]const u8, @ptrFromInt(0x1000))[0..bogus_len];
    try t.expectError(error.Oversized, sais.build(t.allocator, fake));
}

test "build: the sentinel row is exactly text.len, and sa[1..] is a permutation of [0, text.len)" {
    const gpa = t.allocator;
    const cases = [_][]const u8{ "", "a", "aa", "ab", "banana", "\x00\x01\xff", "\xff\xff\xff\xff" };
    for (cases) |text| {
        const sa = try sais.build(gpa, text);
        defer gpa.free(sa);
        try t.expectEqual(text.len + 1, sa.len);
        try t.expectEqual(@as(u32, @intCast(text.len)), sa[0]);

        const seen = try gpa.alloc(bool, text.len);
        defer gpa.free(seen);
        @memset(seen, false);
        for (sa[1..]) |p| {
            try t.expect(p < text.len);
            try t.expect(!seen[p]);
            seen[p] = true;
        }
    }
}

test "build: deterministic across repeated calls on the same text" {
    const gpa = t.allocator;
    const text = "abracadabra, said the wizard, abracadabra";
    const a = try sais.build(gpa, text);
    defer gpa.free(a);
    const b = try sais.build(gpa, text);
    defer gpa.free(b);
    try t.expectEqualSlices(u32, a, b);
}

/// Direct comparison-sort oracle over the LIFTED alphabet the module doc
/// specifies (byte c ↦ c+1, sentinel 0 smallest of all) — independent of the
/// oracle `codex_test.zig` runs at corpus scale, so a bug shared by both
/// implementations' assumptions (rather than by libsais itself) still has a
/// second, differently-shaped check to fail.
fn expectMatchesOracle(gpa: std.mem.Allocator, text: []const u8) !void {
    const got = try sais.build(gpa, text);
    defer gpa.free(got);

    const n = text.len + 1;
    const want = try gpa.alloc(u32, n);
    defer gpa.free(want);
    for (want, 0..) |*v, i| v.* = @intCast(i);

    const Ctx = struct {
        text: []const u8,
        fn suffixOrder(self: @This(), a: u32, b: u32) std.math.Order {
            // Row `text.len` is the sentinel — lexicographically smallest by
            // construction, since it is shorter than (and a prefix-match
            // loser against) every real suffix.
            if (a == self.text.len or b == self.text.len) {
                return if (a == b) .eq else if (a == self.text.len) .lt else .gt;
            }
            return switch (std.mem.order(u8, self.text[a..], self.text[b..])) {
                .lt => .lt,
                .gt => .gt,
                .eq => .eq, // unreachable for a==b already excluded above and distinct suffixes of one string never tie
            };
        }
        fn lt(self: @This(), a: u32, b: u32) bool {
            return self.suffixOrder(a, b) == .lt;
        }
    };
    std.mem.sort(u32, want, Ctx{ .text = text }, Ctx.lt);
    try t.expectEqualSlices(u32, want, got);
}

test "build: matches a from-scratch comparison-sort oracle on adversarial small texts" {
    const gpa = t.allocator;
    const cases = [_][]const u8{
        "",
        "a",
        "aaaaaaaaaaaaaaaaaaaa", // maximal repetition: every rotation ties until the sentinel breaks it
        "abab",
        "banana",
        "mississippi",
        "\x00\x00\x01", // embedded NUL — the exact byte the sentinel lift exists to free up
        "the quick brown fox jumps over the lazy dog",
        "zyxwvutsrqponmlkjihgfedcba", // strictly descending: adversarial for induced-sort merge order
    };
    for (cases) |text| try expectMatchesOracle(gpa, text);

    var prng = std.Random.DefaultPrng.init(0x5a15);
    const rand = prng.random();
    for (0..40) |_| {
        const len = rand.intRangeAtMost(usize, 0, 200);
        const text = try gpa.alloc(u8, len);
        defer gpa.free(text);
        // A tiny alphabet forces the heavy ties SA-IS's induced-sort merge
        // step has to resolve correctly; a wide random alphabet alone would
        // rarely exercise it.
        for (text) |*c| c.* = rand.intRangeAtMost(u8, 'a', 'c');
        try expectMatchesOracle(gpa, text);
    }
}

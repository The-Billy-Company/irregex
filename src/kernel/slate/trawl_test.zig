//! irregex — the trawl's correctness suite.
//!
//! The trawl is the wide-slate tier: one Aho–Corasick automaton carrying every
//! pooled literal, swept as four interleaved streams. Both halves of that
//! sentence are places a fast multi-pattern matcher can be quietly wrong, so
//! each gets its own adverse case here:
//!
//!   * the automaton — suffix links (`he` inside `she`), one output state owned
//!     by two patterns, overlapping and repeated occurrences, and the compacted
//!     alphabet's catch-all column;
//!   * the split — a needle planted at every offset across every stripe
//!     boundary, plus a whole-document differential against the single-stream
//!     `crawl` the stripes replace.
//!
//! Every case is judged against the same oracle: a plain `std.mem.indexOf` per
//! literal. The trawl is only allowed to be faster than that, never different.

const std = @import("std");
const trawl_mod = @import("trawl.zig");
const bits = @import("../math/bits.zig");

const B64 = bits.Field(u64);
const Trawl = trawl_mod.Trawl;
const build = trawl_mod.build;
const max_states = trawl_mod.max_states;
const stripes = trawl_mod.stripes;
const t = std.testing;

/// The oracle every test here compares against: which patterns does a plain
/// per-literal substring search put in play?
fn expectPlay(lits: []const []const u8, owner: []const u32, npat: usize, hay: []const u8) !void {
    const pool = try t.allocator.alloc(u32, lits.len);
    defer t.allocator.free(pool);
    for (pool, 0..) |*p, i| p.* = @intCast(i);

    var trawl = (try build(t.allocator, lits, pool)).?;
    defer trawl.deinit(t.allocator);

    const words = B64.words(npat);
    const got = try t.allocator.alloc(u64, words);
    defer t.allocator.free(got);
    @memset(got, 0);
    _ = trawl.sweep(hay, owner, got, npat);

    for (0..npat) |p| {
        var want = false;
        for (lits, owner) |lit, o| {
            if (o == p and std.mem.indexOf(u8, hay, lit) != null) want = true;
        }
        try t.expectEqual(want, B64.get(got, p));
    }
}

test "the trawl reports exactly what a substring search would" {
    const lits = [_][]const u8{ "refund", "session", "Store", "fund" };
    const owner = [_]u32{ 0, 1, 2, 3 };
    try expectPlay(&lits, &owner, 4, "pub fn handleRefund(w: *AcmeStore) void {}");
    try expectPlay(&lits, &owner, 4, "refund the session");
    try expectPlay(&lits, &owner, 4, "nothing here at all");
    try expectPlay(&lits, &owner, 4, "");
}

test "a needle that is a suffix of another still reports (dictionary link)" {
    // The textbook case: `he` ends inside `she`, so reaching `she`'s output
    // state must also report `he` via the dictionary-suffix link.
    const lits = [_][]const u8{ "she", "he", "hers", "his" };
    const owner = [_]u32{ 0, 1, 2, 3 };
    try expectPlay(&lits, &owner, 4, "she");
    try expectPlay(&lits, &owner, 4, "ushers");
    try expectPlay(&lits, &owner, 4, "hishers");
}

test "distinct patterns owning byte-identical literals both report" {
    // One output state, two owners — the case a single `out` slot would drop.
    const lits = [_][]const u8{ "dup", "dup", "other" };
    const owner = [_]u32{ 0, 1, 2 };
    try expectPlay(&lits, &owner, 3, "a dup here");
    try expectPlay(&lits, &owner, 3, "other");
}

test "overlapping and repeated occurrences are idempotent" {
    const lits = [_][]const u8{ "aa", "aaa" };
    const owner = [_]u32{ 0, 1 };
    try expectPlay(&lits, &owner, 2, "aaaa");
    try expectPlay(&lits, &owner, 2, "aa");
    const single = [_][]const u8{"a"};
    const one_owner = [_]u32{0};
    try expectPlay(&single, &one_owner, 1, "aaaaaaaa");
}

test "bytes outside the literal alphabet fold into one column" {
    const lits = [_][]const u8{ "abc", "abd" };
    const owner = [_]u32{ 0, 1 };
    var pool = [_]u32{ 0, 1 };
    var trawl = (try build(t.allocator, &lits, &pool)).?;
    defer trawl.deinit(t.allocator);
    // a, b, c, d plus the catch-all ⇒ five columns, not 256.
    try t.expectEqual(@as(u32, 5), trawl.ncols);
    // And an unspelled byte cannot break a match that straddles it.
    try expectPlay(&lits, &owner, 2, "\xffabc\x00");
    try expectPlay(&lits, &owner, 2, "zzzabdzzz");
}

test "the early exit reports the same play set as a full sweep" {
    const lits = [_][]const u8{ "x", "y" };
    const owner = [_]u32{ 0, 1 };
    var pool = [_]u32{ 0, 1 };
    var trawl = (try build(t.allocator, &lits, &pool)).?;
    defer trawl.deinit(t.allocator);
    var play = [_]u64{0};
    // Both literals occur in the first two bytes, so `left` hits zero long
    // before the haystack ends — the remaining bytes must not change the answer.
    try t.expectEqual(@as(usize, 0), trawl.sweep("xy" ++ ("q" ** 4096), &owner, &play, 2));
    try t.expect(B64.get(&play, 0) and B64.get(&play, 1));
}

test "a needle straddling every stripe boundary is still found" {
    // The adverse case for the interleaved sweep: each stripe restarts at the
    // root, so an occurrence spanning a boundary is only caught by the previous
    // stripe's `longest - 1` overlap. Plant the needle at EVERY offset across
    // each boundary and demand it every time — an off-by-one in the overlap
    // shows up here and nowhere else.
    const lits = [_][]const u8{"NEEDLE_TOKEN"};
    const owner = [_]u32{0};
    const size = 8192; // comfortably above the striping floor
    const buf = try t.allocator.alloc(u8, size);
    defer t.allocator.free(buf);

    for (1..stripes) |w| {
        const boundary = w * ((size + stripes - 1) / stripes);
        for (0..lits[0].len) |shift| {
            const at = boundary - shift;
            @memset(buf, 'q');
            @memcpy(buf[at..][0..lits[0].len], lits[0]);
            try expectPlay(&lits, &owner, 1, buf);
        }
    }
    // And the absent case at the same scale, so the test cannot pass by
    // reporting everything.
    @memset(buf, 'q');
    try expectPlay(&lits, &owner, 1, buf);
}

test "striped and single-stream sweeps agree on a wide slate" {
    // Same document, same slate, both code paths: the striped loop is only a
    // performance story if it is answer-identical to the crawl it replaces.
    var lits: [64][]const u8 = undefined;
    var owner: [64]u32 = undefined;
    var names: [64][8]u8 = undefined;
    for (&lits, &owner, &names, 0..) |*l, *o, *n, i| {
        n.* = .{ 'k', 'e', 'y', '_', @intCast('a' + i % 26), @intCast('a' + i / 26), 'z', 'z' };
        l.* = n[0..];
        o.* = @intCast(i);
    }
    var pool: [64]u32 = undefined;
    for (&pool, 0..) |*p, i| p.* = @intCast(i);
    var trawl = (try build(t.allocator, &lits, &pool)).?;
    defer trawl.deinit(t.allocator);

    // A haystack holding a scattered subset, long enough to stripe.
    var hay: std.ArrayList(u8) = .empty;
    defer hay.deinit(t.allocator);
    for (0..600) |i| {
        try hay.appendSlice(t.allocator, "filler filler ");
        if (i % 7 == 0) try hay.appendSlice(t.allocator, lits[i % 64]);
    }

    const words = B64.words(64);
    const striped = try t.allocator.alloc(u64, words);
    defer t.allocator.free(striped);
    const serial = try t.allocator.alloc(u64, words);
    defer t.allocator.free(serial);
    @memset(striped, 0);
    @memset(serial, 0);

    _ = trawl.sweep(hay.items, &owner, striped, 64);
    _ = trawl.crawl(hay.items, &owner, serial, 64);
    try t.expectEqualSlices(u64, serial, striped);
    // And it must have actually found things — an all-zero agreement is vacuous.
    try t.expect(!B64.none(striped));
}

test "a slate too large for the table declines instead of allocating it" {
    var lits: [max_states][]const u8 = undefined;
    var pool: [max_states]u32 = undefined;
    for (&lits, &pool, 0..) |*l, *p, i| {
        l.* = "aaaaaaaaaa"; // 10 bytes each ⇒ the bound exceeds max_states
        p.* = @intCast(i);
    }
    try t.expectEqual(@as(?Trawl, null), try build(t.allocator, &lits, &pool));
}

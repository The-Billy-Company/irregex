//! Tests for the attributing union automaton (`chorus.zig`).
//!
//! Three tiers, and one differential that keeps them honest. The differential is
//! the load-bearing one: a chorus is only ever adopted as an accelerator, so the
//! bar is not "it finds matches" but "it finds exactly what N separate engines
//! find". Anything else is a silent wrong answer in a fast wrapper.

const std = @import("std");
const t = std.testing;
const chorus = @import("chorus.zig");
const core = @import("core.zig");

fn build(pats: []const []const u8) !chorus.Chorus {
    return (try chorus.Chorus.compile(t.allocator, pats, .{})) orelse error.Declined;
}

test "chorus: attribution names the patterns, not just the fact of a match" {
    var ch = try build(&.{ "foo", "bar", "qux" });
    defer ch.deinit();

    try t.expectEqual(@as(u64, 0b001), ch.lineMask("xxfooxx"));
    try t.expectEqual(@as(u64, 0b010), ch.lineMask("xxbarxx"));
    try t.expectEqual(@as(u64, 0b101), ch.lineMask("qux and foo"));
    try t.expectEqual(@as(u64, 0b111), ch.lineMask("foo bar qux"));
    try t.expectEqual(@as(u64, 0), ch.lineMask("nothing here"));
}

test "chorus: overlapping ends — the answer rust-regex needs MatchKind::All for" {
    // The canonical probe. A leftmost-first scan reports three NON-overlapping
    // matches; rust-`regex` only sees ends 6 and 9 after switching its
    // determinizer out of its default pruning mode, at the cost of a larger
    // automaton and a slower loop. Our recognizer never pruned, so all three
    // ends — and the patterns that produced them — fall out of one ordinary walk.
    var ch = try build(&.{ "foo", "foofoo", "foofoofoo" });
    defer ch.deinit();

    var it = ch.ends("foofoofoo");
    var at: [8]usize = undefined;
    var pats: [8]u64 = undefined;
    var n: usize = 0;
    while (it.next()) |e| : (n += 1) {
        at[n] = e.at;
        pats[n] = e.pats;
    }

    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqualSlices(usize, &.{ 3, 6, 9 }, at[0..3]);
    // Every end names exactly the patterns that ended there: `foo` at 3; `foo`
    // and `foofoo` both at 6; all three at 9.
    try t.expectEqual(@as(u64, 0b001), pats[0]);
    try t.expectEqual(@as(u64, 0b011), pats[1]);
    try t.expectEqual(@as(u64, 0b111), pats[2]);
}

test "chorus: a HalfMatch is the first end, and it costs no reverse pass" {
    var ch = try build(&.{ "a+b", "zzz" });
    defer ch.deinit();

    var it = ch.ends("xxaaab");
    const half = it.next().?;
    try t.expectEqual(@as(usize, 6), half.at);
    try t.expectEqual(@as(u64, 0b01), half.pats);
}

test "chorus: anchors and empty matches resolve per line" {
    var ch = try build(&.{ "^ab", "cd$", "e*" });
    defer ch.deinit();

    try t.expectEqual(@as(u64, 0b101), ch.lineMask("abZ")); // `^ab` fires, `e*` is nullable
    try t.expectEqual(@as(u64, 0b110), ch.lineMask("Zcd")); // `^ab` must not fire mid-line
    try t.expectEqual(@as(u64, 0b100), ch.lineMask("")); // empty line: only the nullable one
    // Per-line semantics across a document: `^`/`$` resolve at each newline.
    try t.expectEqual(@as(u64, 0b111), ch.docMask("Zcd\nabZ"));
}

test "chorus: declines rather than guessing" {
    try t.expectEqual(@as(?chorus.Chorus, null), try chorus.Chorus.compile(t.allocator, &.{}, .{}));
    try t.expectEqual(@as(?chorus.Chorus, null), try chorus.Chorus.compile(t.allocator, &.{"("}, .{}));
}

test "chorus: differential — one walk agrees with N separate engines" {
    // The parity proof. Every pattern also compiles standalone; for each line the
    // chorus's mask must equal the bit vector those standalone engines produce.
    // A disagreement here is the only way this module can be wrong in a way the
    // tiers above would not notice.
    const pats = [_][]const u8{ "foo", "b[aA]r", "^qux", "z+$", "a.c", "\\d+", "he(ll|LL)o" };
    const lines = [_][]const u8{
        "",              "foo",             "bar",          "BAR",     "qux at start",
        "not qux",       "trailing zzz",    "zzz trailing", "abc",     "a.c",
        "1234",          "hello",           "heLLo",        "foobar",  "qux",
        "xxfooxxbarxx",  "9 z",             "a-c-e",        "  ",      "\\d",
        "fooBARqux123z", "hello world zzz", "^qux",         "aXc9zzz",
    };

    var ch = try build(&pats);
    defer ch.deinit();

    var singles: [pats.len]core.Regex = undefined;
    for (&singles, pats) |*re, p| re.* = try core.Regex.compile(t.allocator, p);
    defer for (&singles) |*re| re.deinit();
    var sims: [pats.len]core.Regex.Sim = undefined;
    for (&sims, &singles) |*sim, *re| sim.* = try core.Regex.Sim.init(t.allocator, re);
    defer for (&sims) |*sim| sim.deinit();

    for (lines) |line| {
        var want: u64 = 0;
        for (&singles, &sims, 0..) |*re, *sim, i| {
            if (re.lineMatch(sim, line)) want |= @as(u64, 1) << @intCast(i);
        }
        const got = ch.lineMask(line);
        t.expectEqual(want, got) catch |e| {
            std.debug.print("line \"{s}\": want {b:0>7}, got {b:0>7}\n", .{ line, want, got });
            return e;
        };
    }
}

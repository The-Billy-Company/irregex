//! Tests for the anchored longest-match slate (`munch.zig`).
//!
//! Two properties carry the weight. The first is that anchoring is real: an
//! unanchored engine finds `abc` in `xabc`, and a lexer that accepted that
//! answer would silently swallow the `x`. The second is the differential — a
//! munch's verdict at every offset must equal what N separate anchored engines
//! would say, because the whole point of one automaton is that it is not a
//! different answer from N of them.

const std = @import("std");
const t = std.testing;
const munch = @import("munch.zig");
const core = @import("core.zig");

fn build(pats: []const []const u8) !munch.Munch {
    return (try munch.Munch.compile(t.allocator, pats, .{})) orelse error.Declined;
}

test "munch: longest wins, and the loser is not reported" {
    var m = try build(&.{ ">", ">>", ">>=" });
    defer m.deinit();

    const hit = m.longest(">>=x", 0).?;
    try t.expectEqual(@as(usize, 3), hit.len);
    try t.expectEqualSlices(u32, &.{2}, hit.patterns);
}

test "munch: a tie names every pattern that tied, ascending" {
    var m = try build(&.{ "if", "[a-z]+", "i." });
    defer m.deinit();

    // All three reach two bytes on `if`. Which of them deserves the token is
    // the grammar's business, and this type refuses to have an opinion.
    const hit = m.longest("if ", 0).?;
    try t.expectEqual(@as(usize, 2), hit.len);
    try t.expectEqualSlices(u32, &.{ 0, 1, 2 }, hit.patterns);
}

test "munch: the offset is the caller's, and nothing before it is consulted" {
    var m = try build(&.{ "[a-z]+", "[0-9]+" });
    defer m.deinit();

    const src = "abc123";
    const word = m.longest(src, 0).?;
    try t.expectEqual(@as(usize, 3), word.len);
    try t.expectEqualSlices(u32, &.{0}, word.patterns);

    const digits = m.longest(src, 3).?;
    try t.expectEqual(@as(usize, 3), digits.len);
    try t.expectEqualSlices(u32, &.{1}, digits.patterns);
}

test "munch: a token that cannot start here is a miss, not a later match" {
    var m = try build(&.{"abc"});
    defer m.deinit();

    // Unanchored, `abc` matches this haystack. Anchored at zero it does not,
    // and a lexer that saw a match here would skip the `x` in silence.
    try t.expectEqual(@as(?munch.Match, null), m.longest("xabc", 0));
    try t.expectEqual(@as(usize, 3), m.longest("xabc", 1).?.len);
}

test "munch: a slate wider than one automaton is still one question" {
    var bodies: [80][2]u8 = undefined;
    var pats: [80][]const u8 = undefined;
    for (0..80) |i| {
        bodies[i] = .{ 'a' + @as(u8, @intCast(i % 20)), 'a' + @as(u8, @intCast(i / 20)) };
        pats[i] = &bodies[i];
    }
    var m = try build(&pats);
    defer m.deinit();

    try t.expectEqual(@as(usize, 80), m.admitted());
    try t.expectEqual(@as(usize, 0), m.declined.len);
    try t.expect(m.voices.len > 1); // it really did have to split

    // Ordinal 60 is "ad" — row 3, column 0 — and it lives in a later automaton,
    // which the caller has no way to know and no need to.
    const hit = m.longest("ad", 0).?;
    try t.expectEqual(@as(usize, 2), hit.len);
    try t.expectEqualSlices(u32, &.{60}, hit.patterns);
}

test "munch: one unusable pattern costs one pattern, not the slate" {
    // `(` is a parse error; everything around it is ordinary. A lexer for a
    // real grammar meets exactly this — a token body outside the linear syntax
    // sitting among a hundred and fifty that are not — and losing the whole
    // slate to it would make the accelerator unusable in practice.
    var m = try build(&.{ "let", "(", "[0-9]+", "fn" });
    defer m.deinit();

    try t.expectEqualSlices(u32, &.{1}, m.declined);
    try t.expectEqual(@as(usize, 3), m.admitted());
    try t.expectEqualSlices(u32, &.{0}, m.longest("let x", 0).?.patterns);
    try t.expectEqualSlices(u32, &.{3}, m.longest("fn", 0).?.patterns);
}

test "munch: several unusable patterns are each named, and only they" {
    var m = try build(&.{ "a", "(", "b", "[", "c" });
    defer m.deinit();

    try t.expectEqualSlices(u32, &.{ 1, 3 }, m.declined);
    try t.expectEqual(@as(usize, 3), m.admitted());
    try t.expectEqualSlices(u32, &.{4}, m.longest("c", 0).?.patterns);
}

test "munch: a slate with nothing usable in it is a decline, not an empty munch" {
    try t.expectEqual(@as(?munch.Munch, null), try munch.Munch.compile(t.allocator, &.{ "(", "[" }, .{}));
    try t.expectEqual(@as(?munch.Munch, null), try munch.Munch.compile(t.allocator, &.{}, .{}));
}

test "munch: the empty string at the end of input is answerable" {
    var m = try build(&.{ "x*", "y" });
    defer m.deinit();

    const hit = m.longest("", 0).?;
    try t.expectEqual(@as(usize, 0), hit.len);
    try t.expectEqualSlices(u32, &.{0}, hit.patterns);

    // And at the end of a non-empty haystack, which is where a lexer stops.
    try t.expectEqual(@as(usize, 0), m.longest("y", 1).?.len);
}

test "munch: a word-boundary slate declines rather than answering from nowhere" {
    try t.expectEqual(
        @as(?munch.Munch, null),
        try munch.Munch.compile(t.allocator, &.{"\\bfoo"}, .{ .word = true }),
    );
    // And when the assertion arrives through a body rather than a flag, the
    // refusal has to be the same one.
    try t.expectEqual(
        @as(?munch.Munch, null),
        try munch.Munch.compile(t.allocator, &.{"\\bfoo"}, .{}),
    );
}

test "munch: a narrowed slate is not a filtered answer" {
    // The case that forces the restriction into the walk. `[^\"]+` reaches 12
    // bytes here and `:` reaches one, so filtering AFTER the fact returns
    // nothing at all — the long forbidden match has already hidden the short
    // permitted one. This is JSON's `string_content` against every structural
    // byte, and every state-directed lexer meets it.
    var m = try build(&.{ "[^\"]+", ":", "\\[", "[0-9]+" });
    defer m.deinit();

    const src = ": [1, true]\"";
    try t.expectEqual(@as(usize, 11), m.longest(src, 0).?.len);
    try t.expectEqualSlices(u32, &.{0}, m.longest(src, 0).?.patterns);

    var allow = try m.allowNone(t.allocator);
    defer allow.deinit(t.allocator);
    allow.admit(&m, 1);
    allow.admit(&m, 2);
    allow.admit(&m, 3);

    const hit = m.longestAmong(src, 0, &allow).?;
    try t.expectEqual(@as(usize, 1), hit.len);
    try t.expectEqualSlices(u32, &.{1}, hit.patterns);
    try t.expectEqual(@as(usize, 1), m.longestAmong(src, 2, &allow).?.len); // `[`
    try t.expectEqual(@as(usize, 1), m.longestAmong(src, 3, &allow).?.len); // `1`
}

test "munch: permitting everything is the unrestricted answer, exactly" {
    var m = try build(&.{ ">", ">>", ">>=", "[a-z]+" });
    defer m.deinit();

    var allow = try m.allowNone(t.allocator);
    defer allow.deinit(t.allocator);
    allow.admitAll();

    for ([_][]const u8{ ">>=", ">>x", "abc", "" }) |src| {
        for (0..src.len + 1) |at| {
            const free = m.longest(src, at);
            var want_len: ?usize = null;
            var want_pats: [4]u32 = undefined;
            var n: usize = 0;
            if (free) |f| {
                want_len = f.len;
                n = f.patterns.len;
                @memcpy(want_pats[0..n], f.patterns);
            }
            const bound = m.longestAmong(src, at, &allow);
            if (want_len) |w| {
                try t.expectEqual(w, bound.?.len);
                try t.expectEqualSlices(u32, want_pats[0..n], bound.?.patterns);
            } else {
                try t.expectEqual(@as(?munch.Match, null), bound);
            }
        }
    }
}

test "munch: permitting nothing finds nothing, and forbidding a refused pattern is not an error" {
    var m = try build(&.{ "a+", "(", "b+" });
    defer m.deinit();
    try t.expectEqualSlices(u32, &.{1}, m.declined);

    var allow = try m.allowNone(t.allocator);
    defer allow.deinit(t.allocator);
    try t.expectEqual(@as(?munch.Match, null), m.longestAmong("aaa", 0, &allow));

    // Ordinal 1 has no seat: admitting it is a no-op, not a crash and not a
    // stray bit landing on somebody else's pattern.
    allow.admit(&m, 1);
    allow.admit(&m, 99);
    try t.expectEqual(@as(?munch.Match, null), m.longestAmong("aaa", 0, &allow));

    allow.admit(&m, 2);
    try t.expectEqual(@as(?munch.Match, null), m.longestAmong("aaa", 0, &allow));
    try t.expectEqual(@as(usize, 2), m.longestAmong("bb", 0, &allow).?.len);
}

test "munch: a forbidden pattern may still be on the path to a permitted one" {
    // `ab` is forbidden and `abc` is not. A walk that stopped believing in the
    // automaton the moment it hit a forbidden accept would never reach `abc`.
    var m = try build(&.{ "ab", "abc" });
    defer m.deinit();

    var allow = try m.allowNone(t.allocator);
    defer allow.deinit(t.allocator);
    allow.admit(&m, 1);

    const hit = m.longestAmong("abc", 0, &allow).?;
    try t.expectEqual(@as(usize, 3), hit.len);
    try t.expectEqualSlices(u32, &.{1}, hit.patterns);
    // And with only the short one permitted, the long one does not leak out.
    allow.forbidAll();
    allow.admit(&m, 0);
    try t.expectEqual(@as(usize, 2), m.longestAmong("abc", 0, &allow).?.len);
}

test "munch: the restriction survives a slate wide enough to need several voices" {
    var bodies: [80][2]u8 = undefined;
    var pats: [80][]const u8 = undefined;
    for (0..80) |i| {
        bodies[i] = .{ 'a' + @as(u8, @intCast(i % 20)), 'a' + @as(u8, @intCast(i / 20)) };
        pats[i] = &bodies[i];
    }
    var m = try build(&pats);
    defer m.deinit();
    try t.expect(m.voices.len > 1);

    var allow = try m.allowNone(t.allocator);
    defer allow.deinit(t.allocator);
    allow.admit(&m, 60); // "ad", in a later voice than ordinal 0
    try t.expectEqualSlices(u32, &.{60}, m.longestAmong("ad", 0, &allow).?.patterns);
    try t.expectEqual(@as(?munch.Match, null), m.longestAmong("aa", 0, &allow));
}

test "munch: differential — one slate agrees with N anchored engines everywhere" {
    // A plausible lexer slate: identifiers against a keyword, three operator
    // families that share prefixes, and two numeric shapes that overlap. One
    // line, because the oracle below is a per-line engine and a token that
    // spans a newline would be asking it a question it does not answer.
    const pats = [_][]const u8{
        "[a-z_][a-z_0-9]*", "let",        "[0-9]+", "0x[0-9a-f]+",
        "==",               "=",          "\\+\\+", "\\+",
        "->",               "-",          "\\{",    "\\}",
        "[ \t]+",           "\"[^\"]*\"",
    };
    var m = try build(&pats);
    defer m.deinit();
    try t.expectEqual(@as(usize, 0), m.declined.len);

    // The oracle: each pattern as its own engine, wrapped so that a match is a
    // statement about the WHOLE candidate span. The longest span any of them
    // accepts is what a standalone lexer for that one token would take, and one
    // automaton must not disagree with fourteen.
    var engines: [pats.len]core.Regex = undefined;
    var sims: [pats.len]core.Regex.Sim = undefined;
    for (&pats, &engines, &sims) |p, *e, *sim| {
        const whole = try std.fmt.allocPrint(t.allocator, "^(?:{s})$", .{p});
        defer t.allocator.free(whole);
        e.* = try core.Regex.compile(t.allocator, whole);
        sim.* = try core.Regex.Sim.init(t.allocator, e);
    }
    defer for (&engines) |*e| e.deinit();
    defer for (&sims) |*sim| sim.deinit();

    const src = "let x_1 = 0xff + 42 -> { \"text\" ++ y } == z--";
    for (0..src.len + 1) |at| {
        var want: ?usize = null;
        for (&engines, &sims) |*e, *sim| {
            var len = src.len - at + 1;
            while (len > 0) {
                len -= 1;
                if (!e.lineMatch(sim, src[at .. at + len])) continue;
                if (want == null or len > want.?) want = len;
                break;
            }
        }

        const hit = m.longest(src, at);
        if (want) |w| {
            try t.expect(hit != null);
            try t.expectEqual(w, hit.?.len);
            // And every ordinal it named really does accept exactly that span.
            for (hit.?.patterns) |o| try t.expect(engines[o].lineMatch(&sims[o], src[at .. at + w]));
        } else {
            try t.expectEqual(@as(?munch.Match, null), hit);
        }
    }
}

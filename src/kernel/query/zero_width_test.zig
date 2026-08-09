//! irregex — the two match sequences, pinned against each other and against
//! the outside bars they each answer to.
//!
//! This package reports zero-width matches two ways, and the difference is a
//! decision rather than a drift (`../regex/glean/cursor.zig` has the table).
//! The risk that
//! creates is not that one of them is wrong today — both were measured against
//! their own bar when they were written — but that someone later "fixes" one to
//! agree with the other, because the disagreement reads like a bug until you
//! know which audience each serves. That is precisely the edit this file exists
//! to fail.
//!
//! So every case below carries BOTH expected sequences, side by side, with the
//! external authority for each spelled out:
//!
//!   * `library` — what `Cursor` must produce. Verified byte-for-byte against
//!     Python's `re` in BYTE mode (`re.finditer(b'l*', b'h\xc3\xa9llo')`), which
//!     agrees with `rust-regex` and with JS `String.matchAll`: every position
//!     yields its empty match, adjacency is not special, and the end of the
//!     haystack is a position like any other.
//!   * `grep` — what `query.zig`'s `walk` must produce for the SAME bytes as one
//!     unterminated unit. Verified byte-for-byte against ripgrep (`rg --json`),
//!     which suppresses an empty match adjacent to the previous one and, on an
//!     unterminated line, the one at the end.
//!
//! A case where the two agree is as load-bearing as one where they differ: it
//! proves the split is confined to the empty-match rule and has not leaked into
//! ordinary matching.
//!
//! This file sits in the `query` tier rather than beside the `Cursor` it pins,
//! and `charter.zone` is why: imports point one way down the stack, so
//! `query` may reach `regex` and never the reverse. A differential has to hold
//! both rules at once, which makes this the only height it can legally live at.

const std = @import("std");
const t = std.testing;

const qy = @import("query.zig");
const Pattern = @import("../regex/regex.zig").Pattern;
const Span = @import("../../mark.zig").Span;

/// One pattern, one haystack, and the sequence each rule owes.
const Case = struct {
    pat: []const u8,
    hay: []const u8,
    /// `Cursor`'s answer — the Python/rust-regex/JS sequence.
    library: []const [2]usize,
    /// `walk`'s answer over the same bytes, unterminated — the ripgrep sequence.
    grep: []const [2]usize,
    /// Why this row is in the table, so a failure reads as a broken promise
    /// rather than as a number that moved.
    why: []const u8,
};

const cases = [_]Case{
    .{
        .pat = "l*",
        .hay = "h\u{e9}llo",
        .library = &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 5 }, .{ 5, 5 }, .{ 6, 6 } },
        .grep = &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 5 } },
        // `(2,2)` is the whole reason the zero-width step is one BYTE. Byte 2 is
        // the continuation byte of `é`; a codepoint-sized step lands on 3 and
        // loses that match. Both rules report it — this is not where they split.
        .why = "empty match at a UTF-8 continuation byte survives in both rules",
    },
    .{
        .pat = "a*",
        .hay = "aa",
        .library = &.{ .{ 0, 2 }, .{ 2, 2 } },
        .grep = &.{.{ 0, 2 }},
        .why = "empty match adjacent to the previous match: kept by libraries, dropped by rg",
    },
    .{
        .pat = "b*",
        .hay = "abcb",
        .library = &.{ .{ 0, 0 }, .{ 1, 2 }, .{ 2, 2 }, .{ 3, 4 }, .{ 4, 4 } },
        .grep = &.{ .{ 0, 0 }, .{ 1, 2 }, .{ 3, 4 } },
        .why = "adjacency and end-of-content in one pattern, interleaved with real matches",
    },
    .{
        .pat = "x*",
        .hay = "abc",
        .library = &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 } },
        .grep = &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 } },
        .why = "the end position is a match site for a library, and not for an unterminated line",
    },
    .{
        .pat = "",
        .hay = "ab",
        .library = &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 } },
        .grep = &.{ .{ 0, 0 }, .{ 1, 1 } },
        .why = "the empty pattern, where every match is zero-width and nothing masks the rule",
    },
    .{
        .pat = "ab",
        .hay = "abcab",
        .library = &.{ .{ 0, 2 }, .{ 3, 5 } },
        .grep = &.{ .{ 0, 2 }, .{ 3, 5 } },
        .why = "a pattern that consumes bytes: the two rules MUST agree, or the split has leaked",
    },
    .{
        .pat = "a|",
        .hay = "ba",
        .library = &.{ .{ 0, 0 }, .{ 1, 2 }, .{ 2, 2 } },
        .grep = &.{ .{ 0, 0 }, .{ 1, 2 } },
        .why = "an alternation that is nullable on one arm only, so emptiness is position-dependent",
    },
};

fn expectSequence(want: []const [2]usize, got: []const Span, case: Case, rule: []const u8) !void {
    const ok = want.len == got.len and for (want, 0..) |w, i| {
        if (w[0] != got[i].start or w[1] != got[i].end) break false;
    } else true;
    if (ok) return;

    std.debug.print(
        \\
        \\{s} rule disagrees for pattern `{s}` over `{s}`
        \\  this case exists because: {s}
        \\  expected:
    , .{ rule, case.pat, case.hay, case.why });
    for (want) |w| std.debug.print(" ({d},{d})", .{ w[0], w[1] });
    std.debug.print("\n  actual:  ", .{});
    for (got) |s| std.debug.print(" ({d},{d})", .{ s.start, s.end });
    std.debug.print("\n", .{});
    return error.SequenceMismatch;
}

test "Cursor reports the library sequence (Python re / rust-regex / JS)" {
    const gpa = t.allocator;
    for (cases) |c| {
        var p = try Pattern.compile(gpa, c.pat);
        defer p.deinit();
        var cur = try p.matches(c.hay);
        defer cur.deinit();

        var got: std.ArrayList(Span) = .empty;
        defer got.deinit(gpa);
        while (cur.next()) |s| try got.append(gpa, s);

        try expectSequence(c.library, got.items, c, "library");
    }
}

test "walk reports the grep sequence (ripgrep) for the same bytes" {
    const gpa = t.allocator;
    for (cases) |c| {
        var q = try qy.CompiledQuery.compile(gpa, .{
            .pattern = c.pat,
            .mode = .lines,
            .unicode = true,
        });
        defer q.deinit(gpa);
        var sc = try q.matchScratch(gpa);
        defer sc.deinit();

        var got: std.ArrayList(qy.Span) = .empty;
        defer got.deinit(gpa);
        // `false`: one unterminated unit, which is how the C ABI hands a host's
        // buffer to this same walk (`surface/ffi/pattern.zig`).
        try q.collectSpans(gpa, c.hay, false, &sc, &got);

        try expectSequence(c.grep, got.items, c, "grep");
    }
}

test "the split is confined to zero-width: every non-empty span is in both" {
    for (cases) |c| {
        for (c.library) |w| {
            if (w[0] == w[1]) continue;
            const shared = for (c.grep) |g| {
                if (g[0] == w[0] and g[1] == w[1]) break true;
            } else false;
            if (!shared) {
                std.debug.print(
                    "pattern `{s}` over `{s}`: non-empty span ({d},{d}) is in the " ++
                        "library sequence but not the grep one — the two rules may " ++
                        "only differ on EMPTY matches\n",
                    .{ c.pat, c.hay, w[0], w[1] },
                );
                return error.SplitLeaked;
            }
        }
    }
}

test "a bounded window does not change which empty matches exist inside it" {
    const gpa = t.allocator;
    // `x*` over `abc` restricted to `[1,3)`. The library rule says every
    // position in the window matches, including its far end — the window moves
    // where the walk starts and stops, and never what counts as a match.
    var p = try Pattern.compile(gpa, "x*");
    defer p.deinit();
    var cur = try p.matchesIn(.{ .hay = "abc", .from = 1, .to = 3 });
    defer cur.deinit();

    var got: std.ArrayList(Span) = .empty;
    defer got.deinit(gpa);
    while (cur.next()) |s| try got.append(gpa, s);

    try t.expectEqual(@as(usize, 3), got.items.len);
    try t.expectEqual(Span{ .start = 1, .end = 1 }, got.items[0]);
    try t.expectEqual(Span{ .start = 2, .end = 2 }, got.items[1]);
    try t.expectEqual(Span{ .start = 3, .end = 3 }, got.items[2]);
}

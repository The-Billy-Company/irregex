//! irregex — the `-w` rule, pinned across the two doors that implement it.
//!
//! `-w` is not a clause a caller can write: it is a promise that a match stands
//! alone as a word. Two places keep that promise. `query`'s walk vets each span
//! with `wordOk` after the fact; `glean`'s `Cursor` does the same, and the linear
//! engine *additionally* lowers the rule into the program. Three mechanisms, one
//! contract — which is exactly the shape that drifts silently.
//!
//! It matters now because the C ABI's pattern plane moved from the first door to
//! the second. A host that set `IRGX_WORD` was getting `query`'s answer and now
//! gets `glean`'s, so the two have to be the same answer or that move was a
//! regression wearing a refactor's clothes. This file is the proof, and it runs
//! over both backends because only one of them can lower the rule: PCRE2 silently
//! ignored `word` until `Vet` was added, matching `cat` inside `concatenate`.
//!
//! Like `zero_width_test.zig`, this lives in the `query` tier rather than beside
//! the `Cursor` it pins, because `query` may import `regex` and never the reverse
//! — a differential has to see both rules at once.

const std = @import("std");
const t = std.testing;

const qy = @import("query.zig");
const rx = @import("../regex/regex.zig");
const Pattern = rx.Pattern;
const Span = @import("../../mark.zig").Span;

/// Every span `query`'s walk reports for `pat` over `hay` under `-w`.
fn viaQuery(gpa: std.mem.Allocator, pat: []const u8, hay: []const u8, pcre: bool) ![]Span {
    var q = try qy.CompiledQuery.compile(gpa, .{
        .pattern = pat,
        .mode = .lines,
        .unicode = true,
        .word = true,
        .pcre = pcre,
    });
    defer q.deinit(gpa);
    var sc = try q.matchScratch(gpa);
    defer sc.deinit();
    var out: std.ArrayList(qy.Span) = .empty;
    defer out.deinit(gpa);
    try q.collectSpans(gpa, hay, false, &sc, &out);

    var got: std.ArrayList(Span) = .empty;
    for (out.items) |sp| try got.append(gpa, .{ .start = sp.start, .end = sp.end });
    return got.toOwnedSlice(gpa);
}

/// Every span `glean`'s cursor reports for the same question.
fn viaGlean(gpa: std.mem.Allocator, pat: []const u8, hay: []const u8, pcre: bool) ![]Span {
    var p = try Pattern.compileOpts(gpa, pat, .{ .word = true, .unicode = true, .pcre = pcre });
    defer p.deinit();
    var cur = try p.matches(hay);
    defer cur.deinit();
    var got: std.ArrayList(Span) = .empty;
    while (cur.next()) |sp| try got.append(gpa, sp);
    return got.toOwnedSlice(gpa);
}

/// The cases worth disagreeing on: a word embedded in a longer one (the whole
/// point of `-w`), edges of the text, punctuation boundaries, a Unicode
/// neighbor, and a pattern whose own alternation straddles the rule.
const cases = [_]struct { pat: []const u8, hay: []const u8 }{
    .{ .pat = "cat", .hay = "concatenate cat scatter cat." },
    .{ .pat = "cat", .hay = "cat" },
    .{ .pat = "cat", .hay = "catcat cat" },
    .{ .pat = "cat", .hay = "" },
    .{ .pat = "cat", .hay = "-cat-" },
    .{ .pat = "cat", .hay = "écat caté cat" },
    .{ .pat = "\\w+", .hay = "one two-three four" },
    .{ .pat = "a|ab", .hay = "ab a abc" },
    .{ .pat = "[0-9]+", .hay = "x1 22 3y 44" },
    .{ .pat = "cats?", .hay = "cat cats catsup" },
};

test "the word rule agrees across query's walk and glean's cursor, on each backend" {
    // THE invariant the C ABI's move depends on. A host that set `IRGX_WORD` was
    // reading the left column and now reads the right one; per backend, they must
    // be the same spans. Both backends are checked because the ABI exposes
    // `IRGX_PCRE` alongside `IRGX_WORD` and a host may set both.
    const gpa = t.allocator;
    for ([_]bool{ false, true }) |pcre| {
        for (cases) |c| {
            const want = try viaQuery(gpa, c.pat, c.hay, pcre);
            defer gpa.free(want);
            const got = try viaGlean(gpa, c.pat, c.hay, pcre);
            defer gpa.free(got);
            t.expectEqualSlices(Span, want, got) catch |e| {
                std.debug.print("word rule diverged: pat={s} hay=\"{s}\" pcre={any}\n", .{ c.pat, c.hay, pcre });
                return e;
            };
        }
    }
}

test "the rule is LOWERED, not filtered — which is why the choosing case works" {
    // The case that distinguishes the two possible implementations, and the one
    // that caught the real bug. A post-hoc filter can only reject the span it was
    // handed; a lowered rule lets the automaton CHOOSE one that stands alone.
    //
    // Under `-w`, `a|ab` over `ab` must report `ab`. Leftmost-first offers `a`
    // first, so a filter rejects it, resumes past it, and never reconsiders the
    // `ab` that would have passed — one match instead of two. Both backends here
    // lower instead: the linear arm rewrites the AST, PCRE2 wraps the source in
    // `(?<!\w)(?:…)(?!\w)`. Nothing downstream vets a span afterwards.
    //
    // This is pinned separately from the differential above because the two
    // implementations agree on every ordinary case; only this shape tells them
    // apart. glean shipped the filter-equivalent behavior — `Options.pcreOpts`
    // silently dropped `word` — and every other row above still passed.
    const gpa = t.allocator;
    for ([_]bool{ false, true }) |pcre| {
        const got = try viaGlean(gpa, "a|ab", "ab a abc", pcre);
        defer gpa.free(got);
        try t.expectEqualSlices(Span, &.{ .{ .start = 0, .end = 2 }, .{ .start = 3, .end = 4 } }, got);
    }
}

test "a word flag that never reached the backend matches inside a longer word" {
    // The bug in its plainest form, kept as its own row because it is the one a
    // reader will check first: `cat` under `-w` must not match `concatenate`.
    const gpa = t.allocator;
    for ([_]bool{ false, true }) |pcre| {
        var p = try Pattern.compileOpts(gpa, "cat", .{ .word = true, .pcre = pcre });
        defer p.deinit();
        try t.expectEqual(@as(?Span, .{ .start = 12, .end = 15 }), try p.find("concatenate cat"));
        try t.expectEqual(@as(usize, 1), try p.count("concatenate cat"));
        try t.expectEqual(@as(?Span, null), try p.find("concatenate"));
        // The capture arm lowers it too, so `groups` cannot call a match that
        // `find` already ruled out.
        try t.expectEqual(@as(?Groups, null), try p.groups("concatenate"));
        try t.expectEqual(@as(usize, 12), (try p.groups("concatenate cat")).?.get(0).?.start);
    }
}

const Groups = rx.glean.Groups;

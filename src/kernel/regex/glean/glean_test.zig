//! The consumer face, held to the cases a hand-rolled loop gets wrong.
//!
//! Every assertion here is derived from what the pattern *means*, not from what
//! this tier happens to return: the empty-match counts come from counting the
//! positions the alphabet admits, the window cases from what the assertion is
//! defined to read, and the pool counts from how many searches were run.

const std = @import("std");
const glean = @import("glean.zig");

const Pattern = glean.Pattern;
const Window = @import("../../../mark.zig").Window;
const Span = @import("../../../mark.zig").Span;
const t = std.testing;

/// Every span a pattern finds in a haystack, rendered `start:end` — one string
/// to compare, so a wrong COUNT and a wrong POSITION fail differently.
fn walk(gpa: std.mem.Allocator, p: *Pattern, hay: []const u8) ![]u8 {
    var cur = try p.matches(hay);
    defer cur.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (cur.next()) |m| try out.print(gpa, "{d}:{d} ", .{ m.start, m.end });
    return out.toOwnedSlice(gpa);
}

test "zero-width matches advance by one position and terminate" {
    // `a*` over "abc": greedy "a" at 0, then the empty string is admitted at
    // every remaining position INCLUDING the end — 1, 2, 3. Four answers, and
    // the loop stops. Resuming at `span.end` would spin forever at position 1.
    var p = try Pattern.compile(t.allocator, "a*");
    defer p.deinit();
    const got = try walk(t.allocator, &p, "abc");
    defer t.allocator.free(got);
    try t.expectEqualStrings("0:1 1:1 2:2 3:3 ", got);
}

test "a zero-width advance steps one BYTE, in either alphabet" {
    // "é" is two bytes, and `x*` matches empty at all three offsets in it —
    // including offset 1, INSIDE the UTF-8 sequence. That reads wrong and is
    // right: spans are byte offsets, so the sequence of empty matches is
    // indexed by byte whatever alphabet the pattern's classes are written in.
    // Measured against Python's `re` in byte mode, which is the same engine
    // contract: `re.finditer(b'x*', 'é'.encode())` → (0,0) (1,1) (2,2).
    //
    // A codepoint-sized step is the plausible mistake here. It drops the middle
    // match, and `../../query/zero_width_test.zig` shows that ripgrep — which has every
    // reason to hide such a span, since it has no byte to print — reports it
    // too. Unicode-awareness changes which CLASSES match, never how the walk
    // advances past a match that consumed nothing.
    for ([_]bool{ true, false }) |unicode| {
        var p = try Pattern.compileOpts(t.allocator, "x*", .{ .unicode = unicode });
        defer p.deinit();
        const got = try walk(t.allocator, &p, "é");
        defer t.allocator.free(got);
        try t.expectEqualStrings("0:0 1:1 2:2 ", got);
    }
}

test "count equals the walk, and both see zero-width matches" {
    var p = try Pattern.compile(t.allocator, "b*");
    defer p.deinit();
    // "abcb": empty@0, empty@1? No — `b*` is greedy, so at 1 it takes "b".
    // Positions: 0 (empty), 1 ("b"), 2 (empty), 3 ("b"), 4 (empty at end).
    try t.expectEqual(@as(usize, 5), try p.count("abcb"));
}

test "a bounded window moves the search, not the haystack's edges" {
    // `c$` asks about the END OF THE TEXT. Bounding the search to the first
    // three bytes must not make position 3 look like the end — the whole point
    // of a window over a slice. "abcde" has no `c` at its end, so the answer is
    // no match; a slice would have answered `c` at 2.
    var p = try Pattern.compile(t.allocator, "c$");
    defer p.deinit();
    try t.expectEqual(@as(?@import("../../../mark.zig").Span, null), try p.findIn(.{ .hay = "abcde", .from = 0, .to = 3 }));

    // And the assertion still fires where it is genuinely true.
    const at_end = (try p.find("abc")).?;
    try t.expectEqual(@as(usize, 2), at_end.start);
}

test "a bound the backend cannot express is refused, never approximated" {
    // PCRE2's subject has one length, so honoring `to` would mean shortening the
    // subject — which moves `$` and every lookahead. Refusing is the only answer
    // that is not a different question wearing this one's name.
    var p = Pattern.compileOpts(t.allocator, "a", .{ .pcre = true }) catch |e| switch (e) {
        // A build without the vendored PCRE2 has nothing to assert here.
        error.BadPattern => return error.SkipZigTest,
        else => return e,
    };
    defer p.deinit();
    try t.expectError(error.BoundUnsupported, p.findIn(.{ .hay = "abc", .from = 0, .to = 2 }));
    // The inert bound asks nothing of the engine, so it still answers.
    try t.expect((try p.findIn(.{ .hay = "abc", .from = 0, .to = 3 })) != null);
}

test "an anchored find requires the match to begin where the search does" {
    // `findAt` is not `findIn` with a narrower window and not `\A`-rewriting:
    // it constrains the START, and the assertions keep reading the whole
    // haystack. `\Bb` is the case that separates the three — `\B` is false at
    // the text's start and true between two word bytes, so anchoring at 1 must
    // still see the `a` behind it.
    var p = try Pattern.compile(t.allocator, "b");
    defer p.deinit();
    const hay = "abc";
    // Leftmost finds the `b` at 1; anchored at 0 there is nothing here.
    try t.expectEqual(@as(usize, 1), (try p.findIn(.{ .hay = hay, .from = 0, .to = hay.len })).?.start);
    try t.expectEqual(@as(?Span, null), try p.findAt(.{ .hay = hay, .from = 0, .to = hay.len }));
    try t.expectEqual(@as(usize, 1), (try p.findAt(.{ .hay = hay, .from = 1, .to = hay.len })).?.start);

    var inner = try Pattern.compile(t.allocator, "\\Bb");
    defer inner.deinit();
    try t.expect((try inner.findAt(.{ .hay = hay, .from = 1, .to = hay.len })) != null);
}

test "an anchored walk is contiguous, and ends at the first gap" {
    // What anchoring means across a walk: each match must begin where the last
    // one ended, so the run stops rather than re-seeding past the `b`. The
    // unbounded walk over the same text is the control, and the difference is
    // exactly the span the gap hides.
    var p = try Pattern.compile(t.allocator, "a");
    defer p.deinit();
    const hay = "aaba";
    const loose = try walk(t.allocator, &p, hay);
    defer t.allocator.free(loose);
    try t.expectEqualStrings("0:1 1:2 3:4 ", loose);

    var cur = try p.matchesAt(.{ .hay = hay, .from = 0, .to = hay.len });
    defer cur.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    while (cur.next()) |m| try out.print(t.allocator, "{d}:{d} ", .{ m.start, m.end });
    try t.expectEqualStrings("0:1 1:2 ", out.items);

    // The advance rule is the walk's, not the anchor's: a zero-width match still
    // steps one BYTE, so the resume point moves even though the match consumed
    // nothing. An anchored walk over a nullable pattern therefore terminates
    // rather than pinning itself to `from` forever — and it keeps every empty
    // match, because each one does begin where its own search did.
    var nil = try Pattern.compile(t.allocator, "x*");
    defer nil.deinit();
    var spin = try nil.matchesAt(.{ .hay = "ab", .from = 0, .to = 2 });
    defer spin.deinit();
    var seen: usize = 0;
    while (spin.next()) |_| seen += 1;
    try t.expectEqual(@as(usize, 3), seen);
}

/// Every span of a walk under `mode`, rendered like `walk`'s.
fn under(gpa: std.mem.Allocator, p: *Pattern, hay: []const u8, mode: glean.Cursor.Mode) ![]u8 {
    var cur = try p.walk(Window.whole(hay, 0), mode);
    defer cur.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (cur.next()) |m| try out.print(gpa, "{d}:{d} ", .{ m.start, m.end });
    return out.toOwnedSlice(gpa);
}

test "an earliest walk reports the match that ENDS first, which no filter recovers" {
    // The definition, and the reason it needed a machine: leftmost-first picks a
    // match by where it STARTS and then extends it by priority, so `a+` over
    // "aaa" is the single span (0,3). Earliest picks by where a match ENDS, so
    // the same text holds three: (0,1) (1,2) (2,3). Neither sequence is a subset
    // of the other and no predicate over the first yields the second — the second
    // has spans the first never reported.
    //
    // These are the answers `regex-automata`'s earliest search and
    // `RE2::PartialMatch` give, derived here from what the pattern admits: `a+`
    // accepts after one `a`, so an acceptance exists at every offset one past an
    // `a`, and each is the earliest end from where the previous match left off.
    var plus = try Pattern.compile(t.allocator, "a+");
    defer plus.deinit();
    try t.expect(plus.halts());

    const loose = try under(t.allocator, &plus, "aaa", .{});
    defer t.allocator.free(loose);
    try t.expectEqualStrings("0:3 ", loose);

    const soon = try under(t.allocator, &plus, "aaa", .{ .earliest = true });
    defer t.allocator.free(soon);
    try t.expectEqualStrings("0:1 1:2 2:3 ", soon);
    try t.expectEqual(@as(?Span, .{ .start = 0, .end = 1 }), try plus.earliest("aaa"));

    // A nullable pattern is the sharp version of the same fact: greedy leftmost
    // takes the whole run, while the earliest acceptance is the empty match where
    // the walk stands — before a byte is read. The zero-width advance rule is
    // untouched, so the walk still steps one byte past each of them.
    var star = try Pattern.compile(t.allocator, "a*");
    defer star.deinit();
    const greedy = try under(t.allocator, &star, "aa", .{});
    defer t.allocator.free(greedy);
    try t.expectEqualStrings("0:2 2:2 ", greedy);
    const empty = try under(t.allocator, &star, "aa", .{ .earliest = true });
    defer t.allocator.free(empty);
    try t.expectEqualStrings("0:0 1:1 2:2 ", empty);
}

test "earliest is the earliest END, then the leftmost start reaching it" {
    // The tie-break, and the case that separates earliest from "shortest". `ab|b`
    // over "ab": the first acceptance anywhere is at offset 2, and TWO matches end
    // there — (0,2) via `ab` and (1,2) via `b`. Earliest reports (0,2), because
    // among the matches that end first the leftmost start wins; a shortest-match
    // search would report (1,2), and a leftmost-first search over the whole text
    // reports (0,2) for a different reason.
    var p = try Pattern.compile(t.allocator, "ab|b");
    defer p.deinit();
    const got = try under(t.allocator, &p, "ab", .{ .earliest = true });
    defer t.allocator.free(got);
    try t.expectEqualStrings("0:2 ", got);

    // And the start is genuinely searched for rather than assumed to be where the
    // walk stands: `b+` from 0 over "aab" ends earliest at 3, and the span that
    // reaches it starts at 2.
    var run = try Pattern.compile(t.allocator, "b+");
    defer run.deinit();
    const late = try under(t.allocator, &run, "aab", .{ .earliest = true });
    defer t.allocator.free(late);
    try t.expectEqualStrings("2:3 ", late);
}

test "an earliest ask is refused, not relabelled, when nothing can halt" {
    // Two compiles have no machine that can halt at an acceptance, both
    // structurally (see `Matcher.halts`): a positional assertion, whose
    // determinized states depend on the gap they were entered at, and the PCRE2
    // arm, which has no inspectable program. Refusing is the only answer that is
    // not the leftmost sequence under an earliest label.
    var anchor = try Pattern.compile(t.allocator, "^a+");
    defer anchor.deinit();
    try t.expect(!anchor.halts());
    try t.expectError(error.Unsupported, anchor.earliest("aaa"));
    // The same pattern without the assertion is answerable, so the refusal is
    // about the assertion rather than about the shape of the pattern.
    var bare = try Pattern.compile(t.allocator, "a+");
    defer bare.deinit();
    try t.expect(bare.halts());

    var pcre = Pattern.compileOpts(t.allocator, "a+", .{ .pcre = true }) catch |e| switch (e) {
        error.BadPattern => return error.SkipZigTest, // a build without PCRE2
        else => return e,
    };
    defer pcre.deinit();
    try t.expect(!pcre.halts());
    try t.expectError(error.Unsupported, pcre.earliest("aaa"));
}

test "the anchored sequence is identical whether or not a machine decided it" {
    // The rewiring's whole claim: the halting machine changes what an anchored
    // walk PAYS and nothing about what it reports. A pattern carrying an
    // assertion has no machine, so it takes the leftmost-plus-filter path this
    // lane inherited; an assertion-free one takes the machine. Both must agree
    // with the definition — every match begins where the last ended, and the run
    // stops at the first gap — so the two paths are held to one rule here.
    const rows = [_]struct { pat: []const u8, hay: []const u8, want: []const u8 }{
        .{ .pat = "a", .hay = "aaba", .want = "0:1 1:2 " },
        .{ .pat = "a|b", .hay = "abxa", .want = "0:1 1:2 " },
        .{ .pat = "\\w", .hay = "ab cd", .want = "0:1 1:2 " },
        .{ .pat = "a+", .hay = "aaab", .want = "0:3 " },
        .{ .pat = "x*", .hay = "ab", .want = "0:0 1:1 2:2 " },
        .{ .pat = "b", .hay = "abc", .want = "" }, // nothing begins at 0
    };
    for (rows) |row| {
        var p = try Pattern.compile(t.allocator, row.pat);
        defer p.deinit();
        try t.expect(p.halts()); // the machine path
        const got = try under(t.allocator, &p, row.hay, .{ .anchored = true });
        defer t.allocator.free(got);
        try t.expectEqualStrings(row.want, got);

        // The same walk with `\B?` welded on: a no-op on what matches (it is
        // vacuously true wherever these patterns start) that makes the pattern
        // assertion-bearing, so the probe declines and the inherited path answers.
        const guarded = try std.fmt.allocPrint(t.allocator, "(?:\\B|\\b){s}", .{row.pat});
        defer t.allocator.free(guarded);
        var q = try Pattern.compile(t.allocator, guarded);
        defer q.deinit();
        try t.expect(!q.halts()); // the inherited leftmost-plus-filter path
        const same = try under(t.allocator, &q, row.hay, .{ .anchored = true });
        defer t.allocator.free(same);
        try t.expectEqualStrings(row.want, same);
    }
}

test "an anchored boolean decides without locating a span" {
    // `isMatchAt` is `findAt` with the span dropped, except that the halting walk
    // answers it outright — so the two must never disagree, including where the
    // match is zero-width and where the window is bounded.
    const rows = [_]struct { pat: []const u8, hay: []const u8, at: usize }{
        .{ .pat = "b", .hay = "abc", .at = 0 },
        .{ .pat = "b", .hay = "abc", .at = 1 },
        .{ .pat = "a+", .hay = "aaa", .at = 3 },
        .{ .pat = "x*", .hay = "ab", .at = 2 },
        .{ .pat = "\\bfn", .hay = "a fn", .at = 2 },
        .{ .pat = "c$", .hay = "abc", .at = 2 },
    };
    for (rows) |row| {
        var p = try Pattern.compile(t.allocator, row.pat);
        defer p.deinit();
        const win: Window = .{ .hay = row.hay, .from = row.at, .to = row.hay.len };
        try t.expectEqual((try p.findAt(win)) != null, try p.isMatchAt(win));
    }
}

test "the pool reuses one scratch across many searches" {
    var p = try Pattern.compile(t.allocator, "\\w+");
    defer p.deinit();
    for (0..16) |_| _ = try p.isMatch("hello world");
    for (0..16) |_| _ = try p.find("hello world");
    // Sixteen boolean searches and sixteen span searches, run one at a time:
    // each returns its scratch before the next takes one, so the shelf holds
    // exactly one of each grain rather than growing with the call count.
    const idle = p.scratch.idle();
    try t.expectEqual(@as(usize, 1), idle.boolean);
    try t.expectEqual(@as(usize, 1), idle.spans);
}

test "a group that did not participate is absent, not empty" {
    // `(a)|(b)` on "b": group 1 never ran. Reporting it as an empty span at 0
    // would be indistinguishable from `(a?)` matching empty, which is a
    // different fact about a different pattern.
    var p = try Pattern.compile(t.allocator, "(a)|(b)");
    defer p.deinit();
    const g = (try p.groups("b")).?;
    try t.expectEqual(@as(?@import("../../../mark.zig").Span, null), g.get(1));
    try t.expectEqualStrings("b", g.text(2).?);
    try t.expectEqualStrings("b", g.all().?.of("b"));
}

test "named groups resolve by name, and an unknown name is not a match" {
    var p = try Pattern.compile(t.allocator, "(?<key>\\w+)=(?<val>\\d+)");
    defer p.deinit();
    const g = (try p.groups("port=8080")).?;
    try t.expectEqualStrings("port", g.namedText("key").?);
    try t.expectEqualStrings("8080", g.namedText("val").?);
    try t.expectEqual(@as(?@import("../../../mark.zig").Span, null), g.named("nope"));
    try t.expectEqual(@as(?usize, null), g.ordinal("nope"));
    try t.expectEqual(@as(?usize, 1), try p.group("key"));
}

test "the capture arm is compiled only when a group is asked for" {
    var p = try Pattern.compile(t.allocator, "(\\d+)");
    defer p.deinit();
    _ = try p.isMatch("x42");
    _ = try p.find("x42");
    try t.expect(p.caps == null); // matching never paid for the capture VM
    _ = try p.groups("x42");
    try t.expect(p.caps != null);
}

test "replace rewrites every match, and a limited reach stops" {
    var p = try Pattern.compile(t.allocator, "\\d+");
    defer p.deinit();

    const all = try p.replaceAll(t.allocator, "a1b22c333", "#");
    defer t.allocator.free(all);
    try t.expectEqualStrings("a#b#c#", all);

    const one = try p.replaceFirst(t.allocator, "a1b22c333", "#");
    defer t.allocator.free(one);
    try t.expectEqualStrings("a#b22c333", one);
}

test "replace over a zero-width pattern terminates and does not duplicate" {
    // `x*` matches empty at every position of "ab": 0, 1, 2. Each empty match
    // inserts the replacement without consuming anything, so the answer is the
    // haystack interleaved with three insertions — and the walk must end.
    var p = try Pattern.compile(t.allocator, "x*");
    defer p.deinit();
    const got = try p.replaceAll(t.allocator, "ab", "-");
    defer t.allocator.free(got);
    try t.expectEqualStrings("-a-b-", got);
}

test "replaceWith reaches capture groups without a template grammar" {
    var p = try Pattern.compile(t.allocator, "\\d+");
    defer p.deinit();
    // The callback sees the match and writes what it likes — here, the digits
    // wrapped and doubled in length, which no `$1` syntax could express.
    const Wrap = struct {
        pub fn put(_: @This(), out: *std.ArrayList(u8), gpa: std.mem.Allocator, hay: []const u8, m: @import("../../../mark.zig").Span) !void {
            try out.print(gpa, "[{s}:{d}]", .{ m.of(hay), m.len() });
        }
    };
    const got = try p.replaceWith(t.allocator, "a1b22", Wrap{}, .all);
    defer t.allocator.free(got);
    try t.expectEqualStrings("a[1:1]b[22:2]", got);
}

test "split yields one more piece than matches, edges included" {
    var p = try Pattern.compile(t.allocator, ",");
    defer p.deinit();

    const mid = try p.split(t.allocator, "a,b,c");
    defer t.allocator.free(mid);
    try t.expectEqual(@as(usize, 3), mid.len);
    try t.expectEqualStrings("a", mid[0]);
    try t.expectEqualStrings("c", mid[2]);

    // Separators at both edges produce empty pieces there, so field position
    // survives: ",a," is three fields, the first and last empty.
    const edges = try p.split(t.allocator, ",a,");
    defer t.allocator.free(edges);
    try t.expectEqual(@as(usize, 3), edges.len);
    try t.expectEqualStrings("", edges[0]);
    try t.expectEqualStrings("a", edges[1]);
    try t.expectEqualStrings("", edges[2]);
}

test "a cursor walks inside a window without seeing past it" {
    var p = try Pattern.compile(t.allocator, "\\w+");
    defer p.deinit();
    var cur = try p.matchesIn(.{ .hay = "aa bb cc", .from = 0, .to = 5 });
    defer cur.deinit();
    try t.expectEqual(@as(usize, 2), cur.tally());
}

test "the planner's face is still reachable through the handle" {
    // A `Pattern` hides the scratch, not the engine: an index integrating this
    // still needs the sound prefilter literal, and gets it without compiling
    // the pattern twice.
    var p = try Pattern.compile(t.allocator, "func\\s+\\w+");
    defer p.deinit();
    try t.expectEqualStrings("func", p.required());
    try t.expect(!p.nullable());
    try t.expect(p.engineOf().windows());
}

test "the cheap verb and the expensive one never disagree, over a generated slate" {
    // `isMatch` exists to let a caller decide whether to pay for spans, so a
    // case where it says no and the walk says yes is not an optimization that
    // went slightly wrong — it is the verb failing at its only job. The engine's
    // boolean kernels come from a LINE model, and each of the three ways that
    // model leaks was found here rather than by reading: an empty haystack (no
    // lines, so no match, though `b*` matches zero-width at 0), a nullable
    // pattern's dropped empty match, and a pattern that can match the newline
    // itself (`\n]*()` over `"a\nb"`). Hence `isMatch`'s three-part guard.
    //
    // Generated rather than enumerated because all three were patterns nobody
    // would think to write down. Deterministic PRNG, the repo's fuzz idiom.
    // The alphabet carries the CLASS ESCAPES, not just the metacharacters. A
    // slate of `abc.*+?()[]^$|\-\t \n` can never spell `\s`, `\d` or `\w`, so
    // the newline-claiming family it was meant to cover was only ever reachable
    // through a negated class — and `\s+` is the shape a real caller writes and
    // the one whose guard costs the most. `n`, `r` and `t` join for `\n`/`\r`/
    // `\t`, and the haystacks gain buffers whose newlines are interior, leading
    // and trailing, since a boolean kernel that treats a newline as an edge
    // fails differently at each.
    const gpa = t.allocator;
    const meta = "abc.*+?()[]^$|\\-\t \nsdwSDWnrt";
    const haystacks = [_][]const u8{
        "",                 "abc",                 "a\nb",     "aAbBcC 123",
        "\x00\x01\xff\x7f", "the quick brown fox", "\n",       "\n\n",
        "a\n",              "\nb",                 "a \t\n b", "one\ntwo\nthree\n",
        "x\r\ny",           "  \n  ",
    };
    var prng = std.Random.DefaultPrng.init(0xB1A57_ADBE);
    const r = prng.random();
    var pbuf: [12]u8 = undefined;
    var compiled: usize = 0;

    for (0..1500) |_| {
        const plen = r.uintLessThan(usize, pbuf.len + 1);
        for (pbuf[0..plen]) |*c| c.* = meta[r.uintLessThan(usize, meta.len)];
        var p = Pattern.compile(gpa, pbuf[0..plen]) catch continue;
        defer p.deinit();
        compiled += 1;
        for (haystacks) |hay| {
            const cheap = try p.isMatch(hay);
            const walked = (try p.find(hay)) != null;
            t.expectEqual(walked, cheap) catch |e| {
                std.debug.print("isMatch disagreed with find: pat={f} hay={f}\n", .{
                    std.zig.fmtString(pbuf[0..plen]), std.zig.fmtString(hay),
                });
                return e;
            };
        }
    }
    // The generator is not so hostile that nothing compiles, or the loop above
    // asserted nothing at all.
    try t.expect(compiled > 100);
}

test "the halting machine changed what anchored COSTS, not what it reports" {
    // The rewiring's guarantee, held over a generated slate rather than a table
    // of cases someone thought of. The inherited algorithm is written out here in
    // full — leftmost, then discard unless it began where the search did — and it
    // is the oracle: it is what this seam answered before a machine was wired in,
    // so any divergence is a regression by definition rather than by taste.
    //
    // Generated because the interesting inputs are the ones nobody writes down:
    // a nullable pattern under an anchor, a pattern whose leftmost match starts
    // one byte late, an alternation whose branches disagree about where they
    // begin. Deterministic PRNG, the file's own fuzz idiom.
    const gpa = t.allocator;
    const meta = "abc.*+?()[]^$|\\-\t \n";
    const haystacks = [_][]const u8{ "", "abc", "a\nb", "aabbab", "aAbBcC 123", "the quick brown fox" };
    var prng = std.Random.DefaultPrng.init(0x0F_1A_57);
    const r = prng.random();
    var pbuf: [12]u8 = undefined;
    var machined: usize = 0;
    var inherited: usize = 0;

    for (0..1500) |_| {
        const plen = r.uintLessThan(usize, pbuf.len + 1);
        for (pbuf[0..plen]) |*c| c.* = meta[r.uintLessThan(usize, meta.len)];
        var p = Pattern.compile(gpa, pbuf[0..plen]) catch continue;
        defer p.deinit();
        if (p.halts()) machined += 1 else inherited += 1;

        for (haystacks) |hay| {
            const win: Window = .{ .hay = hay, .from = 0, .to = hay.len };

            // The oracle walk, inlined so nothing shared can drift with it.
            var want: std.ArrayList(u8) = .empty;
            defer want.deinit(gpa);
            var at: usize = 0;
            while (at <= hay.len) {
                const got = (try p.findIn(.{ .hay = hay, .from = at, .to = hay.len })) orelse break;
                if (got.start != at) break;
                try want.print(gpa, "{d}:{d} ", .{ got.start, got.end });
                at = if (got.start == got.end) got.end + 1 else got.end;
            }

            const got = try under(gpa, &p, hay, .{ .anchored = true });
            defer gpa.free(got);
            t.expectEqualStrings(want.items, got) catch |e| {
                std.debug.print("anchored walk diverged from the inherited algorithm: pat={f} hay={f} halts={}\n", .{
                    std.zig.fmtString(pbuf[0..plen]), std.zig.fmtString(hay), p.halts(),
                });
                return e;
            };

            // And the single find, which is the walk's first step by construction
            // — asserted anyway, because "by construction" is a claim about code
            // that a caller cannot check.
            const first = try p.findAt(win);
            try t.expectEqual(first != null, try p.isMatchAt(win));
            if (first) |sp| try t.expect(sp.start == 0);
        }
    }
    // Both paths were actually exercised — a slate that only ever took one of
    // them would assert half of what this test claims.
    try t.expect(machined > 100 and inherited > 100);
}

/// `walk`, for a pattern the caller does not otherwise need a handle to: the
/// options ARE the subject in the test below, so each row compiles its own.
fn walkOpts(pat: []const u8, hay: []const u8, opts: glean.Options) ![]u8 {
    var p = try Pattern.compileOpts(t.allocator, pat, opts);
    defer p.deinit();
    return walk(t.allocator, &p, hay);
}

/// `walkOpts` plus the free, for a row asserted inline against a literal.
fn spansAre(want: []const u8, pat: []const u8, hay: []const u8, opts: glean.Options) !void {
    const got = try walkOpts(pat, hay, opts);
    defer t.allocator.free(got);
    t.expectEqualStrings(want, std.mem.trimEnd(u8, got, " ")) catch |e| {
        std.debug.print("  pattern {f}, multiline={}, dotall={}\n", .{
            std.zig.fmtString(pat), opts.multiline, opts.dotall,
        });
        return e;
    };
}

test "the haystack is a buffer, and that is not the same question as (?m)" {
    // Two things the engine spells with one word, kept apart here because a
    // `Pattern` needs opposite answers to them.
    //
    // `multiline` in `lower.zig` means "the haystack is a buffer, not one
    // line", and the per-line model it selects lets the compiler assume no
    // haystack holds a `\n` - it drops `\n` from a class run on that promise.
    // A face keeps the promise by feeding lines; a `Pattern` is handed buffers
    // and cannot, so per-line compilation makes `\s` over "a\nb\n" report
    // NOTHING. Not fewer spans - none. Hence the forced buffer model.
    //
    // `^`/`$` per line is the separate `(?m)` question, and every library a
    // caller is coming from - Python, Rust, PCRE2, Go - answers it "off" by
    // default. Inheriting it from the forced buffer model would have turned
    // `(?m)` on for everyone, which is what `line_anchors` exists to prevent.
    const hay = "a\nb\n";
    for ([_]bool{ false, true }) |m| {
        // The buffer model: a newline is ordinary text, under either anchor
        // answer. Each of these was the empty sequence when glean compiled
        // per-line.
        try spansAre("1:2 3:4", "\\s", hay, .{ .multiline = m });
        try spansAre("1:2 3:4", "\n", hay, .{ .multiline = m });
        try spansAre("1:2 3:4", "[\n\t]", hay, .{ .multiline = m });

        // `\A`/`\z` are the text's ends under either, which is what makes `^`
        // defaulting to the text start a convenience rather than the only way
        // to say it.
        try spansAre("0:1", "\\Aa", hay, .{ .multiline = m });
        try spansAre("", "a\\z", hay, .{ .multiline = m });
        try spansAre("3:4", "\n\\z", hay, .{ .multiline = m });
        try spansAre("0:1", "^a", hay, .{ .multiline = m });
    }

    // The anchor question, answered independently and defaulting off.
    try spansAre("", "^b", hay, .{});
    try spansAre("2:3", "^b", hay, .{ .multiline = true });
    try spansAre("", "b$", hay, .{});
    try spansAre("2:3", "b$", hay, .{ .multiline = true });

    // And `.` still stops at a newline unless asked otherwise. `dotall` was
    // inert before the buffer model - the parser only keeps `\n` in `.` when
    // dotall AND the buffer model agree, so per-line compilation removed the
    // byte the flag existed to put back.
    try spansAre("", "a.b", hay, .{});
    try spansAre("0:3", "a.b", hay, .{ .dotall = true });
}

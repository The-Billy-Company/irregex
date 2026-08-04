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
    const gpa = t.allocator;
    const meta = "abc.*+?()[]^$|\\-\t \n";
    const haystacks = [_][]const u8{ "", "abc", "a\nb", "aAbBcC 123", "\x00\x01\xff\x7f", "the quick brown fox" };
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
    // `gist` keeps the promise by feeding lines; a `Pattern` is handed buffers
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

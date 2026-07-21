//! Unit + oracle coverage for the shared compiled-query core (`query.zig`):
//! the compile shapes (literal vs regex vs escaped `-F -i`), the sound trigram
//! prefilter selection each face prunes by, the fail-closed compile boundary,
//! and the per-doc match/line-count kernels against hand-computed answers.

const std = @import("std");
const testing = std.testing;
const q = @import("query.zig");
const CompiledQuery = q.CompiledQuery;

fn compile(spec: q.Spec) !CompiledQuery {
    return CompiledQuery.compile(testing.allocator, spec);
}

/// Whether `pf` contains an exact literal (prefilter order is engine-internal).
fn pfHas(pf: []const []const u8, lit: []const u8) bool {
    for (pf) |p| if (std.mem.eql(u8, p, lit)) return true;
    return false;
}

test "compile: -F no-fold lowers to a literal body" {
    var cq = try compile(.{ .pattern = "foobar", .fixed = true });
    defer cq.deinit(testing.allocator);
    try testing.expect(cq.body == .literal);
    try testing.expect(!cq.caseless);
}

test "compile: plain pattern lowers to a regex body" {
    var cq = try compile(.{ .pattern = "foo.*bar" });
    defer cq.deinit(testing.allocator);
    try testing.expect(cq.body == .regex);
}

test "compile: -F -i escapes the literal and folds via the regex body" {
    var cq = try compile(.{ .pattern = "a.b+c", .fixed = true, .ignore_case = true });
    defer cq.deinit(testing.allocator);
    try testing.expect(cq.body == .regex);
    try testing.expect(cq.caseless);
    try testing.expect(cq.escaped != null); // the escaped `.`/`+` buffer is owned
    var sc = try cq.scratch(testing.allocator);
    defer sc.deinit();
    // The `.`/`+` are LITERAL (escaped), and the match is case-insensitive.
    try testing.expect(cq.docMatches("xx A.B+C yy", &sc));
    try testing.expect(!cq.docMatches("aXbXc", &sc)); // `.`/`+` are not metachars here
}

test "compile: a pattern outside the linear-time syntax is Unsupported, not fatal" {
    try testing.expectError(error.Unsupported, compile(.{ .pattern = "(foo" }));
}

test "prefilter: a >=3 literal prunes by itself; a short one declines" {
    var big = try compile(.{ .pattern = "foobar", .fixed = true });
    defer big.deinit(testing.allocator);
    var one: [1][]const u8 = undefined;
    const pf = big.prefilter(&one);
    try testing.expectEqual(@as(usize, 1), pf.len);
    try testing.expect(pfHas(pf, "foobar"));

    var small = try compile(.{ .pattern = "ab", .fixed = true });
    defer small.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), small.prefilter(&one).len);
}

test "prefilter: a caseless query prunes by case variants; escape orbits decline" {
    // A fold-closed literal prunes by the caseless variant OR-set (one window
    // of the raw literal in every case spelling) — the warm twin of cold's
    // `caselessFilter`.
    var cq = try compile(.{ .pattern = "foobar", .ignore_case = true });
    defer cq.deinit(testing.allocator);
    var one: [1][]const u8 = undefined;
    const pf = cq.prefilter(&one);
    try testing.expect(pf.len > 0);
    for (pf) |v| try testing.expect(std.ascii.eqlIgnoreCase(v, pf[0]));
    // …and the whole-literal caseless SIMD gate is mined alongside it.
    try testing.expectEqualStrings("foobar", cq.gate.?);

    // Every window of "sks" holds a Kelvin/long-s escape orbit under Unicode
    // fold, so both accelerations decline — the old engine-only path remains.
    var risky = try compile(.{ .pattern = "sks", .ignore_case = true });
    defer risky.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), risky.prefilter(&one).len);
    try testing.expect(risky.gate == null);
}

test "prefilter: a regex prunes by its required literal" {
    var cq = try compile(.{ .pattern = "foobar.*baz" });
    defer cq.deinit(testing.allocator);
    var one: [1][]const u8 = undefined;
    const pf = cq.prefilter(&one);
    try testing.expect(pf.len >= 1);
    try testing.expect(pfHas(pf, "foobar") or pfHas(pf, "baz"));
}

test "prefilter: an alternation prunes by its per-branch cover" {
    var cq = try compile(.{ .pattern = "foobar|bazqux" });
    defer cq.deinit(testing.allocator);
    var one: [1][]const u8 = undefined;
    const pf = cq.prefilter(&one);
    try testing.expect(pfHas(pf, "foobar"));
    try testing.expect(pfHas(pf, "bazqux"));
}

test "docMatches: literal is substring presence anywhere in the doc" {
    var cq = try compile(.{ .pattern = "needle", .fixed = true });
    defer cq.deinit(testing.allocator);
    var sc = try cq.scratch(testing.allocator);
    defer sc.deinit();
    try testing.expect(cq.docMatches("a\nb needle c\nd", &sc));
    try testing.expect(!cq.docMatches("no match here", &sc));
}

test "countLines: literal, rg line model (\\n terminates, no phantom final line)" {
    var cq = try compile(.{ .pattern = "foo", .fixed = true, .mode = .count });
    defer cq.deinit(testing.allocator);
    var sc = try cq.scratch(testing.allocator);
    defer sc.deinit();
    // 4 lines; "foo" on lines 2 and 4.
    try testing.expectEqual(@as(u64, 2), cq.countLines("bar\nfoo\nbaz\nfood\n", &sc));
    // No trailing newline: the last line still counts once.
    try testing.expectEqual(@as(u64, 1), cq.countLines("x\nfoo", &sc));
    // A line matched twice is still one matching LINE.
    try testing.expectEqual(@as(u64, 1), cq.countLines("foo foo foo\n", &sc));
}

test "countLines: regex over rg's line model" {
    var cq = try compile(.{ .pattern = "fo+", .mode = .count });
    defer cq.deinit(testing.allocator);
    var sc = try cq.scratch(testing.allocator);
    defer sc.deinit();
    // "fo+" matches lines 1 (foo) and 3 (fooo), not line 2 (f).
    try testing.expectEqual(@as(u64, 2), cq.countLines("foo\nf\nfooo\n", &sc));
}

// ── -w (word) rows: expectations hand-derived from ripgrep's post-match word
// rule as cold implements it (`output.zig::wordOk`/`nextSpan`) — never from a
// self-run of this engine. ──

test "word: literal occurrences filter by wordOk over the non-overlapping scan" {
    var cq = try compile(.{ .pattern = "run", .fixed = true, .word = true });
    defer cq.deinit(testing.allocator);
    var sc = try cq.scratch(testing.allocator);
    defer sc.deinit();
    try testing.expect(cq.docMatches("run runner\n", &sc)); // valid at [0,3)
    try testing.expect(cq.docMatches("rerun run\n", &sc)); // rejected at [2,5), valid at [6,9)
    try testing.expect(!cq.docMatches("runner rerun\n", &sc)); // every occurrence word-rejected
    try testing.expect(!cq.docMatches("\xc3\xa9run \xe4\xb8\xadrun\n", &sc)); // é / 中 neighbors reject
    try testing.expectEqual(@as(u64, 2), cq.countLines("run runner\nrerun run\nrunner only\n", &sc));
}

test "word: -F adjacent repeats scan leftmost non-overlapping (aa in aaa)" {
    var cq = try compile(.{ .pattern = "aa", .fixed = true, .word = true });
    defer cq.deinit(testing.allocator);
    var sc = try cq.scratch(testing.allocator);
    defer sc.deinit();
    // `aaa`: [0,2) is word-rejected; the scan resumes AT 2 (never 1), where no
    // full occurrence remains — cold reports no match. `aaaa`: [0,2) and [2,4)
    // are both rejected by their word neighbor. ` aa ` is valid.
    try testing.expect(!cq.docMatches("aaa\n", &sc));
    try testing.expect(!cq.docMatches("aaaa\n", &sc));
    try testing.expect(cq.docMatches(" aa aaa\n", &sc));
    try testing.expectEqual(@as(u64, 1), cq.countLines(" aa aaa\naaaa\n", &sc));
}

test "word: punctuation-only matches are word-valid; regex spans use nextSpan's rule" {
    var cq = try compile(.{ .pattern = "\\.", .word = true });
    defer cq.deinit(testing.allocator);
    var sc = try cq.scratch(testing.allocator);
    defer sc.deinit();
    try testing.expect(cq.docMatches("a . b\n", &sc)); // `.` bounded by spaces — a word match
    try testing.expect(!cq.docMatches(".dot\n", &sc)); // `d` after the span rejects it
    try testing.expectEqual(@as(u64, 1), cq.countLines("a . b\n.dot\n", &sc));
}

test "word: zero-width matches never count under -w" {
    var cq = try compile(.{ .pattern = "x*", .word = true, .mode = .count });
    defer cq.deinit(testing.allocator);
    var sc = try cq.scratch(testing.allocator);
    defer sc.deinit();
    // Without -w the boolean path counts every line (`x*` matches empty);
    // under -w only a NON-EMPTY word-valid x-run counts (cold lineHitWord).
    try testing.expectEqual(@as(u64, 1), cq.countLines("x x\nyy\n", &sc));
    try testing.expect(!cq.docMatches("yy\n", &sc));
    try testing.expect(cq.docMatches("x x\n", &sc));
}

test "word: composes with the case fold; the word check reads original bytes" {
    var cq = try compile(.{ .pattern = "run", .fixed = true, .ignore_case = true, .word = true });
    defer cq.deinit(testing.allocator);
    try testing.expect(cq.body == .regex); // -F -i escapes through the engine
    var sc = try cq.scratch(testing.allocator);
    defer sc.deinit();
    try testing.expect(cq.docMatches("RUN loud\n", &sc));
    try testing.expect(!cq.docMatches("RERUNNING\n", &sc)); // folded hit, still word-rejected
    try testing.expectEqual(@as(u64, 1), cq.countLines("RUN loud\nrerunning\n", &sc));
}

test "word: collectSpans emits only word-valid spans with nextSpan's progress" {
    const a = testing.allocator;
    // Literal body: the rejected `rerun` occurrence is skipped, the later
    // ` run` on the same line survives.
    {
        var cq = try compile(.{ .pattern = "run", .fixed = true, .word = true });
        defer cq.deinit(a);
        var ms = try cq.matchScratch(a);
        defer ms.deinit();
        var spans: std.ArrayList(q.Span) = .empty;
        defer spans.deinit(a);
        try cq.collectSpans(a, "rerun run", &ms, &spans);
        try testing.expectEqual(@as(usize, 1), spans.items.len);
        try testing.expectEqual(@as(usize, 6), spans.items[0].start);
        try testing.expectEqual(@as(usize, 9), spans.items[0].end);
    }
    // Regex body: same rule through the span VM.
    {
        var cq = try compile(.{ .pattern = "ru.", .word = true });
        defer cq.deinit(a);
        var ms = try cq.matchScratch(a);
        defer ms.deinit();
        var spans: std.ArrayList(q.Span) = .empty;
        defer spans.deinit(a);
        try cq.collectSpans(a, "rerun run runt", &ms, &spans);
        // `run` at [2,5) rejected (word char before); ` run` at [6,9) valid
        // (space after); `run` in `runt` at [10,13) matches `ru.`+`n`… the
        // span [10,13) is `run` inside `runt` → `t` after rejects it.
        try testing.expectEqual(@as(usize, 1), spans.items.len);
        try testing.expectEqual(@as(usize, 6), spans.items[0].start);
        try testing.expectEqual(@as(usize, 9), spans.items[0].end);
    }
    // The prefilter is unchanged by -w: the literal still prunes.
    {
        var cq = try compile(.{ .pattern = "foobar", .fixed = true, .word = true });
        defer cq.deinit(a);
        var one: [1][]const u8 = undefined;
        const pf = cq.prefilter(&one);
        try testing.expectEqual(@as(usize, 1), pf.len);
        try testing.expect(pfHas(pf, "foobar"));
    }
}

test "docMatches vs countLines>0 agree on whether any line matches" {
    const inputs = [_][]const u8{ "", "foo\n", "x\ny\nzfooz\n", "no\nmatch\n", "foo" };
    for (inputs) |doc| {
        var files_q = try compile(.{ .pattern = "foo", .fixed = true, .mode = .files });
        defer files_q.deinit(testing.allocator);
        var fs = try files_q.scratch(testing.allocator);
        defer fs.deinit();
        var count_q = try compile(.{ .pattern = "foo", .fixed = true, .mode = .count });
        defer count_q.deinit(testing.allocator);
        var cs = try count_q.scratch(testing.allocator);
        defer cs.deinit();
        try testing.expectEqual(files_q.docMatches(doc, &fs), count_q.countLines(doc, &cs) > 0);
    }
}

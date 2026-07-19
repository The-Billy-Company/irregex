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

test "prefilter: a caseless query never prunes (the fold makes a literal unsafe)" {
    var cq = try compile(.{ .pattern = "foobar", .ignore_case = true });
    defer cq.deinit(testing.allocator);
    var one: [1][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), cq.prefilter(&one).len);
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

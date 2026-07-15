//! gist — adversarial tests for the vendored PCRE2 `-P` backend.
//!
//! Exercises the PCRE-only constructs the linear engine cannot express
//! (lookaround, backreferences, named captures), the fail-closed resource
//! ceilings (catastrophic backtracking must terminate, never hang), invalid
//! UTF-8 tolerance, the zero-width / nullable contract, JIT↔interpreter parity,
//! compile diagnostics, and the sound required-literal extraction that feeds the
//! trigram prefilter. Registered in `../root.zig`.

const std = @import("std");
const t = std.testing;
const pcre2 = @import("pcre2.zig");
const engine = @import("pcre2/engine.zig");
const literal = @import("pcre2/literal.zig");

const Pcre = pcre2.Pcre;
const Options = pcre2.Options;
const Span = pcre2.Span;

// ── helpers ──────────────────────────────────────────────────────────────

fn compile(pattern: []const u8) !Pcre {
    return Pcre.compileOpts(t.allocator, pattern, .{});
}

fn firstSpan(re: *const Pcre, hay: []const u8) !?Span {
    var sim = try Pcre.SpanSim.init(t.allocator, re);
    defer sim.deinit();
    return re.matchSpan(&sim, hay, 0);
}

fn matches(re: *const Pcre, line: []const u8) !bool {
    var sim = try Pcre.Sim.init(t.allocator, re);
    defer sim.deinit();
    return re.lineMatch(&sim, line);
}

fn expectSpan(re: *const Pcre, hay: []const u8, start: usize, end: usize) !void {
    const sp = (try firstSpan(re, hay)) orelse return error.NoMatch;
    try t.expectEqual(start, sp.start);
    try t.expectEqual(end, sp.end);
}

// ── a previously-Unsupported compile now succeeds ──────────────────────────

test "compileOpts compiles a real pattern and reports a literal span" {
    var re = try compile("a.c");
    defer re.deinit();
    try expectSpan(&re, "xxaZcyy", 2, 5);
    try t.expect(!try matches(&re, "xyz"));
}

// ── PCRE-only constructs the linear engine cannot express ──────────────────

test "lookahead: matches the anchor, consumes only the lead" {
    var re = try compile("foo(?=bar)");
    defer re.deinit();
    try expectSpan(&re, "foobar", 0, 3); // "foo" only; the lookahead is zero-width
    try t.expect(!try matches(&re, "foobaz"));
}

test "negative lookahead" {
    var re = try compile("foo(?!bar)");
    defer re.deinit();
    try t.expect(try matches(&re, "foobaz"));
    try t.expect(!try matches(&re, "foobar"));
}

test "lookbehind" {
    var re = try compile("(?<=@)\\w+");
    defer re.deinit();
    try expectSpan(&re, "hi @name", 4, 8); // "name", not the '@'
    try t.expect(!try matches(&re, "no-sigil"));
}

test "backreference \\1" {
    var re = try compile("(\\w+) \\1");
    defer re.deinit();
    try t.expect(try matches(&re, "hello hello"));
    try t.expect(!try matches(&re, "hello world"));
}

test "named capture with (?P=name) backreference" {
    var re = try compile("(?P<w>\\w+)-(?P=w)");
    defer re.deinit();
    try t.expect(try matches(&re, "ab-ab"));
    try t.expect(!try matches(&re, "ab-cd"));
}

// ── Unicode / invalid UTF-8 (rg -P parity) ─────────────────────────────────

test "invalid UTF-8 subject matches its valid span instead of erroring" {
    var re = try compile("abc"); // unicode default on
    defer re.deinit();
    // Surrounding bytes are invalid UTF-8; MATCH_INVALID_UTF must degrade to a
    // clean match over the valid interior, never error out the whole search.
    try expectSpan(&re, "\xff\xfeabc\xff", 2, 5);
}

test "unicode property class honors Options.unicode" {
    var re = try compile("\\w+");
    defer re.deinit();
    // A 2-byte UTF-8 letter (é) is a word char under UCP.
    try t.expect(try matches(&re, "caf\xc3\xa9"));
}

// ── deterministic resource limit — no hang on catastrophic backtracking ────

test "catastrophic backtracking terminates deterministically as no-match" {
    var re = try compile("(a+)+$");
    defer re.deinit();
    // Classic exponential-blowup input: many 'a's then a char that defeats `$`.
    // Without a match limit this backtracks ~2^40; the ceiling turns it into a
    // clean, fast no-match. Reaching this assertion at all proves no hang.
    const evil = "a" ** 42 ++ "!";
    try t.expect(!try matches(&re, evil));
}

// ── zero-width / nullable contract ─────────────────────────────────────────

test "nullable flags zero-width patterns" {
    var star = try compile("a*");
    defer star.deinit();
    try t.expect(star.nullable);

    var look = try compile("(?=x)");
    defer look.deinit();
    try t.expect(look.nullable);

    var lit = try compile("abc");
    defer lit.deinit();
    try t.expect(!lit.nullable);
}

test "zero-width match yields an empty span at the position" {
    var re = try compile("a*");
    defer re.deinit();
    try expectSpan(&re, "bbb", 0, 0); // empty match at start
}

// ── options ────────────────────────────────────────────────────────────────

test "caseless option folds case" {
    var re = try Pcre.compileOpts(t.allocator, "abc", .{ .caseless = true });
    defer re.deinit();
    try t.expect(try matches(&re, "xABCx"));
}

test "multiline doc and buffer matching" {
    var re = try Pcre.compileOpts(t.allocator, "^bar$", .{ .multiline = true });
    defer re.deinit();
    try t.expect(re.multiline);

    var sim = try Pcre.Sim.init(t.allocator, &re);
    defer sim.deinit();
    try t.expect(re.docMatch(&sim, "foo\nbar\nbaz")); // per-line ^bar$
    try t.expect(re.bufMatch(&sim, "foo\nbar\nbaz")); // whole-buffer multiline
    try t.expect(!re.docMatch(&sim, "")); // empty doc never matches
    try t.expect(!re.bufMatch(&sim, ""));
}

// ── compile diagnostics ────────────────────────────────────────────────────

test "an invalid pattern is a BadPattern with a diagnostic message" {
    try t.expectError(error.BadPattern, compile("(unterminated"));
    try t.expect(pcre2.lastError().len > 0);
}

// ── JIT ↔ interpreter parity ───────────────────────────────────────────────

test "JIT compiles on this build target" {
    // The vendored sljit backend covers every arch Billy builds on (x86-64,
    // arm64, …), and the `-P` lane exists for rg-parity speed — so a silent
    // drop to the interpreter is a regression we want to see loudly. The
    // interpreter fallback's *correctness* is proven independently below.
    var re = try engine.compileMode(t.allocator, "a.c", .{}, true);
    defer re.deinit();
    try t.expect(re.jit);
}

test "JIT and interpreter agree byte-for-byte" {
    const cases = [_]struct { pat: []const u8, hay: []const u8 }{
        .{ .pat = "a.c", .hay = "zzabcyy" },
        .{ .pat = "foo(?=bar)", .hay = "foobar" },
        .{ .pat = "(?<=@)\\w+", .hay = "x @tag y" },
        .{ .pat = "(\\w+) \\1", .hay = "go go stop" },
        .{ .pat = "\\d{2,4}", .hay = "id=12345" },
        .{ .pat = "a*", .hay = "bbb" },
    };
    for (cases) |c| {
        var jit = try engine.compileMode(t.allocator, c.pat, .{}, true);
        defer jit.deinit();
        var interp = try engine.compileMode(t.allocator, c.pat, .{}, false);
        defer interp.deinit();
        try t.expect(!interp.jit); // forced off
        const a = try firstSpan(&jit, c.hay);
        const b = try firstSpan(&interp, c.hay);
        try t.expectEqual(a == null, b == null);
        if (a) |sa| {
            try t.expectEqual(sa.start, b.?.start);
            try t.expectEqual(sa.end, b.?.end);
        }
    }
}

// ── matchSpan offset + out-of-range ────────────────────────────────────────

test "matchSpan honors the from offset and tolerates from == len" {
    var re = try compile("ab");
    defer re.deinit();
    var sim = try Pcre.SpanSim.init(t.allocator, &re);
    defer sim.deinit();
    // Two occurrences; searching from past the first finds the second.
    try t.expectEqual(@as(usize, 0), re.matchSpan(&sim, "abXab", 0).?.start);
    try t.expectEqual(@as(usize, 3), re.matchSpan(&sim, "abXab", 1).?.start);
    try t.expect(re.matchSpan(&sim, "abXab", 5) == null); // from == len
}

// ── sound required-literal extraction (never over-claims) ──────────────────

fn expectRequired(pattern: []const u8, want: []const u8) !void {
    const got = try literal.required(t.allocator, pattern, false);
    defer t.allocator.free(got);
    try t.expectEqualStrings(want, got);
}

test "required-literal: longest mandatory run" {
    try expectRequired("hello.*world", "hello"); // first of two equal-length runs
    try expectRequired("foo123bar", "foo123bar");
    try expectRequired("abcx*def", "abc"); // x* is optional ⇒ breaks the run
}

test "required-literal: conservative on ambiguity (never over-claims)" {
    try expectRequired("foo|bar", ""); // top-level alternation ⇒ nothing common
    try expectRequired("ab", ""); // below the 3-byte trigram floor
    try expectRequired("\\d{3}xy", ""); // class shorthand + short tail
    try expectRequired("(abc)?def", "def"); // optional group contributes nothing
    try expectRequired("a[bc]defg", "defg"); // class breaks; tail survives
}

test "required-literal: caseless short-circuits to empty" {
    const got = try literal.required(t.allocator, "hello", true);
    defer t.allocator.free(got);
    try t.expectEqualStrings("", got);
}

test "compiled Pcre exposes the required literal" {
    var re = try compile("needle.*haystack");
    defer re.deinit();
    try t.expectEqualStrings("haystack", re.required); // 8 > 6, the longer run
    try t.expect(re.alts.len == 0); // this backend never claims an alt-cover set
}

//! gist T2 regex tests — split from `regex.zig` to keep the engine file under
//! the shape cap. Pulled into `zig build test` via `root.zig`'s test block.
//! Covers the parser/AST, the Pike VM, the required-literal + alternation
//! prefilters, and the scan accelerators (anchored fast path, first-byte skip),
//! the last with the overlapping-start cases that a naive skip would miss.

const std = @import("std");
const regex = @import("regex.zig");
const Regex = regex.Regex;
const ParseError = regex.ParseError;

fn matches(pattern: []const u8, line: []const u8) !bool {
    var re = try Regex.compile(std.testing.allocator, pattern);
    defer re.deinit();
    var sim = try Regex.Sim.init(std.testing.allocator, &re);
    defer sim.deinit();
    return re.lineMatch(&sim, line);
}

test "regex: literal substring (unanchored)" {
    try std.testing.expect(try matches("cat", "the cat sat"));
    try std.testing.expect(try matches("cat", "concatenate"));
    try std.testing.expect(!try matches("cat", "the dog ran"));
}

test "regex: dot, star, plus, quest" {
    try std.testing.expect(try matches("a.c", "xxabcyy"));
    try std.testing.expect(!try matches("a.c", "ac"));
    try std.testing.expect(try matches("ab*c", "ac"));
    try std.testing.expect(try matches("ab*c", "abbbbc"));
    try std.testing.expect(try matches("ab+c", "abc"));
    try std.testing.expect(!try matches("ab+c", "ac"));
    try std.testing.expect(try matches("colou?r", "color"));
    try std.testing.expect(try matches("colou?r", "colour")); // spellchecker:disable-line
}

test "regex: alternation and groups" {
    try std.testing.expect(try matches("cat|dog", "the dog ran"));
    try std.testing.expect(try matches("(foo|bar)baz", "xxbarbazyy"));
    try std.testing.expect(!try matches("(foo|bar)baz", "bazonly"));
}

test "regex: classes and escapes" {
    try std.testing.expect(try matches("[0-9]+", "abc123"));
    try std.testing.expect(!try matches("[0-9]+", "abcdef"));
    try std.testing.expect(try matches("\\d\\w*", "x9_yz"));
    try std.testing.expect(try matches("func\\s+\\w+\\(", "func  Foo("));
    try std.testing.expect(try matches("[^a-z]", "ABC"));
    try std.testing.expect(try matches("a\\.b", "xa.b"));
    try std.testing.expect(!try matches("a\\.b", "axb")); // escaped dot is literal
}

test "regex: '.' does not cross newline within a line search" {
    try std.testing.expect(!try matches("a.b", "a\nb"));
}

test "regex: {n} {n,} {n,m} counted repetition" {
    try std.testing.expect(try matches("a{3}", "aaa"));
    try std.testing.expect(!try matches("a{3}", "aa")); // exactly 3 needed
    try std.testing.expect(try matches("a{3}", "xaaay")); // unanchored
    try std.testing.expect(try matches("^a{3}$", "aaa"));
    try std.testing.expect(!try matches("^a{3}$", "aaaa")); // anchored exact count
    try std.testing.expect(try matches("a{2,}", "aaaa")); // n-or-more
    try std.testing.expect(!try matches("^a{2,}$", "a"));
    try std.testing.expect(try matches("a{2,4}", "aaa")); // in range
    try std.testing.expect(!try matches("^a{2,4}$", "aaaaa")); // above range
    try std.testing.expect(try matches("\\d{3}", "x123y"));
    try std.testing.expect(!try matches("^\\d{3}$", "12"));
    try std.testing.expect(try matches("(ab){2}", "abab"));
    try std.testing.expect(try matches("a{0}", "")); // {0} ⇒ empty
}

test "regex: an unescaped { without a valid count is rejected (matches rg)" {
    const a = std.testing.allocator;
    // rust-regex/ripgrep errors on a `{` that doesn't begin a valid count; gist
    // mirrors it rather than silently treating `{` as a literal.
    try std.testing.expectError(ParseError.BadPattern, Regex.compile(a, "interface{}"));
    try std.testing.expectError(ParseError.BadPattern, Regex.compile(a, "a{")); // unterminated
    try std.testing.expectError(ParseError.BadPattern, Regex.compile(a, "a{b")); // non-decimal
    try std.testing.expectError(ParseError.BadPattern, Regex.compile(a, "{3}")); // no expression
    // A stray `}` (no opening `{`) is literal, exactly like rg.
    try std.testing.expect(try matches("a}", "xa}y"));
    try std.testing.expect(try matches("interface\\{\\}", "type T interface{}")); // escaped braces
}

test "regex: counted-repetition required-literal for the prefilter" {
    const a = std.testing.allocator;
    {
        var re = try Regex.compile(a, "ab{3}c"); // a bbb c — "abbbc" mandatory
        defer re.deinit();
        try std.testing.expectEqualStrings("abbbc", re.required);
    }
    {
        var re = try Regex.compile(a, "x{2,5}"); // ≥2 x's ⇒ "xx" mandatory
        defer re.deinit();
        try std.testing.expectEqualStrings("xx", re.required);
    }
}

test "regex: ^ anchors to line start" {
    try std.testing.expect(try matches("^func", "func main"));
    try std.testing.expect(!try matches("^func", "  func main")); // not at start
    try std.testing.expect(try matches("^a.c", "abc")); // anchored + dot
    try std.testing.expect(try matches("\\^x", "a^xb")); // escaped caret is literal
    try std.testing.expect(!try matches("\\^x", "ax")); // … so a bare 'x' won't do
}

test "regex: $ anchors to line end" {
    try std.testing.expect(try matches("nil$", "return nil"));
    try std.testing.expect(!try matches("nil$", "nil pointer")); // not at end
    try std.testing.expect(try matches(";$", "x := 1;"));
    try std.testing.expect(try matches("x\\$", "ax$")); // escaped dollar is literal
}

test "regex: ^…$ whole-line anchoring incl. empty line" {
    try std.testing.expect(try matches("^$", "")); // empty line matches ^$
    try std.testing.expect(!try matches("^$", "x")); // non-empty does not
    try std.testing.expect(try matches("^abc$", "abc")); // exact whole line
    try std.testing.expect(!try matches("^abc$", "abcd")); // trailing byte breaks $
    try std.testing.expect(!try matches("^abc$", "xabc")); // leading byte breaks ^
}

test "regex: anchored required-literal still drives the prefilter" {
    const a = std.testing.allocator;
    var re = try Regex.compile(a, "^func");
    defer re.deinit();
    try std.testing.expectEqualStrings("func", re.required); // anchor is zero-width
}

test "regex: $ via docMatch picks the right line" {
    const a = std.testing.allocator;
    var re = try Regex.compile(a, "nil$");
    defer re.deinit();
    var sim = try Regex.Sim.init(a, &re);
    defer sim.deinit();
    try std.testing.expect(re.docMatch(&sim, "x := 1\nreturn nil\n}"));
    try std.testing.expect(!re.docMatch(&sim, "nil pointer\nok"));
}

test "regex: pathological (a+)+ stays linear, no catastrophic backtracking" {
    // A backtracking engine hangs on this; Thompson is linear and just answers.
    try std.testing.expect(!try matches("(a+)+z", "aaaaaaaaaaaaaaaaaaaaaaaa!"));
}

test "regex: required-literal extraction for the trigram prefilter" {
    const a = std.testing.allocator;
    {
        var re = try Regex.compile(a, "func\\s+\\w+\\(");
        defer re.deinit();
        try std.testing.expectEqualStrings("func", re.required); // "func" must appear
    }
    {
        var re = try Regex.compile(a, "ab.cd");
        defer re.deinit();
        // best mandatory run is len 2 — no usable ≥3 prefilter, caller scans all.
        try std.testing.expect(re.required.len == 2);
    }
    {
        var re = try Regex.compile(a, "cat|dog");
        defer re.deinit();
        try std.testing.expectEqualStrings("", re.required); // no single mandatory literal
        // …but the alternation cover set lets the prefilter union both branches.
        try std.testing.expectEqual(@as(usize, 2), re.alts.len);
        try std.testing.expectEqualStrings("cat", re.alts[0]);
        try std.testing.expectEqualStrings("dog", re.alts[1]);
    }
    {
        var re = try Regex.compile(a, "return|continue|break");
        defer re.deinit();
        try std.testing.expectEqual(@as(usize, 3), re.alts.len); // every branch ≥3 B
    }
    {
        var re = try Regex.compile(a, "x(foo|bar)");
        defer re.deinit();
        // No mandatory ≥3 run, but the mandatory alternation still covers the match.
        try std.testing.expectEqual(@as(usize, 2), re.alts.len);
    }
    {
        var re = try Regex.compile(a, "panic|0x");
        defer re.deinit();
        // A <3-byte branch (`0x`) can't be trigram-filtered ⇒ no cover, full scan.
        try std.testing.expectEqual(@as(usize, 0), re.alts.len);
    }
    {
        var re = try Regex.compile(a, "func\\s+\\w+\\(");
        defer re.deinit();
        try std.testing.expectEqual(@as(usize, 0), re.alts.len); // single literal wins
    }
}

test "regex: docMatch over multi-line doc" {
    const a = std.testing.allocator;
    var re = try Regex.compile(a, "return\\s+nil");
    defer re.deinit();
    var sim = try Regex.Sim.init(a, &re);
    defer sim.deinit();
    try std.testing.expect(re.docMatch(&sim, "x := 1\nreturn  nil\n}"));
    try std.testing.expect(!re.docMatch(&sim, "return\nnil")); // split across lines
}

// ── scan-accelerator correctness (the perf pass must not change semantics) ──

test "regex: first-byte skip honors overlapping starts" {
    // The skip search re-seeds a start only at first-byte positions; the danger
    // is dropping a match that begins where an earlier (now-dead) thread sat.
    // `ab` over "aab": the start at 0 consumes 'a' then dies on the 2nd 'a' — the
    // real match begins at offset 1 and must still be found.
    try std.testing.expect(try matches("ab", "aab"));
    try std.testing.expect(try matches("aab", "aaab"));
    try std.testing.expect(try matches("a.c", "aaac")); // match at offset 1
    try std.testing.expect(try matches("abc", "ababc")); // restart after partial
    try std.testing.expect(!try matches("ab", "aa"));
    try std.testing.expect(!try matches("xyz", "xyxy"));
}

test "regex: first-byte skip path equals plain semantics" {
    try std.testing.expect(try matches(";$", "x = 1;"));
    try std.testing.expect(!try matches(";$", "x = 1; y"));
    try std.testing.expect(try matches("[0-9]{4}", "year 2026 ok"));
    try std.testing.expect(!try matches("[0-9]{4}", "12 34 5")); // no run of 4
    try std.testing.expect(try matches("panic|0x", "v := 0xFF")); // {p,0} byteset start
    try std.testing.expect(try matches("panic|0x", "panic()"));
    try std.testing.expect(!try matches("panic|0x", "calm 1y")); // neither branch
}

test "regex: anchored fast path matches plain semantics" {
    try std.testing.expect(try matches("^\\}$", "}"));
    try std.testing.expect(!try matches("^\\}$", " }")); // leading space breaks ^
    try std.testing.expect(!try matches("^\\}$", "}}")); // trailing byte breaks $
    try std.testing.expect(try matches("^func|^type", "type T struct"));
    try std.testing.expect(!try matches("^func|^type", "  type T")); // both branches anchored
}

test "regex: mixed-anchor alternation seeds the ^-only branch (skip-path soundness)" {
    // alt(unanchored, ^anchored): the whole pattern isn't anchored, so it takes
    // the first-byte skip path. The `^package` branch's first byte (`p`) only
    // begins a match at line start — it MUST still be in the skip set, or those
    // matches are silently dropped (the false negatives the rg oracle caught).
    var re = try Regex.compile(std.testing.allocator, "import\\s+\\(|^package");
    defer re.deinit();
    var sim = try Regex.Sim.init(std.testing.allocator, &re);
    defer sim.deinit();
    try std.testing.expect(re.docMatch(&sim, "package main")); // ^package alone
    try std.testing.expect(re.docMatch(&sim, "import (\n\t\"x\"\n)")); // other branch
    try std.testing.expect(!re.docMatch(&sim, "  package main")); // ^ not at start
    try std.testing.expect(!re.docMatch(&sim, "// just a comment"));
}

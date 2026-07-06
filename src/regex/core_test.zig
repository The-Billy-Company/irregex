//! gist T2 regex tests — split from `core.zig` to keep the engine file under
//! the shape cap. Pulled into `zig build test` via `root.zig`'s test block.
//! Covers the parser/AST, the Pike VM, the required-literal + alternation
//! prefilters, and the scan accelerators (anchored fast path, first-byte skip),
//! the last with the overlapping-start cases that a naive skip would miss.

const std = @import("std");
const regex = @import("core.zig");
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

fn matchesCI(pattern: []const u8, line: []const u8) !bool {
    var re = try Regex.compileOpts(std.testing.allocator, pattern, .{ .caseless = true });
    defer re.deinit();
    var sim = try Regex.Sim.init(std.testing.allocator, &re);
    defer sim.deinit();
    return re.lineMatch(&sim, line);
}

test "regex: caseless (-i) folds literals, classes, and ranges both ways" {
    // Literal bytes fold both directions (the pattern case is irrelevant).
    try std.testing.expect(try matchesCI("WalletService", "type walletservice struct"));
    try std.testing.expect(try matchesCI("walletservice", "WALLETSERVICE = 1"));
    try std.testing.expect(try matchesCI("Func", "FUNC main"));
    // A class range gains its opposite-case twin: [a-c] also admits [A-C].
    try std.testing.expect(try matchesCI("[a-c]at", "BAT"));
    // Non-letters are untouched; a digit class stays exact.
    try std.testing.expect(try matchesCI("err[0-9]", "ERR7"));
    try std.testing.expect(!try matchesCI("err[0-9]", "ERRx"));
    // Sound vs case-SENSITIVE baseline: the same pattern must NOT match folded.
    try std.testing.expect(!try matches("WalletService", "walletservice"));
}

test "regex: nullable zero-width branch in .skip mode (boundary/EOL re-seed)" {
    // Regression for the differential-fuzz divergence: a pattern whose first-set
    // is non-empty (so the scanner picks `.skip`) but which ALSO has a branch that
    // matches zero-width via a word boundary (`\b{4,6}$`). `.skip` only seeds a
    // start before a first-byte — never at a bare boundary or EOL — so it dropped
    // the second branch's match. `nullable` now routes these to `.plain`.
    // `z|…` forces a first-set ({z}); the line carries no `z`, so only branch 2
    // can match — exactly the path `.skip` used to miss.
    try std.testing.expect(try matches("z|\\b{4,6}$", "abc")); // boundary before EOL
    try std.testing.expect(!try matches("z|\\b{4,6}$", "abc ")); // EOL after space ⇒ no boundary
    try std.testing.expect(try matches("z|\\b{2,}$", "ab12")); // {2,} unbounded form
    // `\B{2}` — two non-boundaries at the same gap (between two word bytes).
    try std.testing.expect(try matches("z|\\B{2}", "abcd")); // gap b|c is a non-boundary
    try std.testing.expect(!try matches("z|\\B{2}", "a")); // every gap of "a" IS a boundary
    // The bare nullable pattern (empty first-set ⇒ `.plain` already) stays correct.
    try std.testing.expect(try matches("\\b{4,6}$", "abc"));
    try std.testing.expect(!try matches("\\b{4,6}$", "abc "));
    // A genuinely consuming pattern stays NON-nullable (keeps the .skip fast path).
    var consuming = try Regex.compile(std.testing.allocator, "func\\s+\\w+");
    defer consuming.deinit();
    try std.testing.expect(!consuming.nullable);
    var zw = try Regex.compile(std.testing.allocator, "z|\\b{4,6}$");
    defer zw.deinit();
    try std.testing.expect(zw.nullable);
}

test "regex: caseless empties the required literal (prefilter falls back to scan)" {
    // A folded literal byte is a 2-member class, so `only()`→null and the longest
    // required literal is "" — the cli grep path then seeds every doc (sound,
    // since trigrams are case-sensitive and cannot prune a caseless needle).
    var re = try Regex.compileOpts(std.testing.allocator, "walletservice", .{ .caseless = true });
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 0), re.required.len);
    try std.testing.expectEqual(@as(usize, 0), re.alts.len);
    // The case-SENSITIVE compile keeps its full required literal for the prefilter.
    var cs = try Regex.compile(std.testing.allocator, "walletservice");
    defer cs.deinit();
    try std.testing.expectEqualStrings("walletservice", cs.required);
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

test "regex: POSIX bracket classes ([[:space:]] etc.) match rg byte-mode sets" {
    const a = std.testing.allocator;
    // Regression: `[[:space:]]` used to silently parse as the class {[,:,s,p,a,c,e}
    // followed by a literal `]`, matching almost nothing (`gist '[[:space:]]import'`
    // returned 0 where rg found 23k+). It must now match a single whitespace byte.
    try std.testing.expect(try matches("[[:space:]]", "a b")); // the space
    try std.testing.expect(try matches("[[:space:]]", "x\ty")); // the tab
    try std.testing.expect(!try matches("[[:space:]]", "abc")); // no whitespace
    // …and NOT the old mis-parse (a bare `]` after non-space letters).
    try std.testing.expect(!try matches("[[:space:]]import", "]import"));
    try std.testing.expect(try matches("[[:space:]]import", " import"));

    // Each named class carries exactly its ASCII members.
    try std.testing.expect(try matches("^[[:digit:]]+$", "12345"));
    try std.testing.expect(!try matches("^[[:digit:]]+$", "12a45"));
    try std.testing.expect(try matches("[[:alpha:]]", "9x9"));
    try std.testing.expect(!try matches("[[:alpha:]]", "909"));
    try std.testing.expect(try matches("[[:upper:]][[:lower:]]", "Go"));
    try std.testing.expect(!try matches("[[:upper:]][[:lower:]]", "GO"));
    try std.testing.expect(try matches("[[:xdigit:]]{2}", "3fh")); // "3f"
    try std.testing.expect(!try matches("^[[:xdigit:]]{2}$", "gz"));

    // Negated POSIX class `[[:^space:]]` = any non-whitespace byte.
    try std.testing.expect(try matches("[[:^space:]]", "  x  "));
    try std.testing.expect(!try matches("^[[:^space:]]$", " "));

    // Composes with literals/ranges in the same bracket.
    try std.testing.expect(try matches("^[[:alnum:]_]+$", "snake_case9"));
    try std.testing.expect(!try matches("^[[:alnum:]_]+$", "has-dash"));
    try std.testing.expect(try matches("[[:digit:]a-f]", "e")); // range parses alongside

    // A bare `[` that doesn't open `[:…:]` stays a literal member (rg semantics):
    // `[[x]` is the two-member class {'[','x'}.
    try std.testing.expect(try matches("[[x]", "z[z"));
    try std.testing.expect(try matches("[[x]", "zxz"));
    try std.testing.expect(!try matches("[[x]", "abc"));

    // An unknown class name inside a well-formed `[:…:]` is BadPattern (rg rejects too).
    try std.testing.expectError(ParseError.BadPattern, Regex.compile(a, "[[:bogus:]]"));
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

test "regex: \\b word boundary matches rg --no-unicode semantics" {
    // Whole-word search — the canonical agent use, and the foot-gun this fixes:
    // gist used to read `\b` as the literal byte 'b' (so `\bcat\b` ⇒ "bcatb").
    try std.testing.expect(try matches("\\bcat\\b", "the cat sat"));
    try std.testing.expect(!try matches("\\bcat\\b", "concatenate")); // substring only
    try std.testing.expect(try matches("\\bcat", "cat")); // boundary at BOL
    try std.testing.expect(try matches("cat\\b", "a cat")); // boundary at EOL
    try std.testing.expect(!try matches("\\bcat", "scat")); // no boundary before cat
    try std.testing.expect(!try matches("cat\\b", "cats")); // no boundary after cat
    try std.testing.expect(try matches("\\b\\w+\\b", "hello"));
    try std.testing.expect(try matches("\\b\\d{4}\\b", "year 2026 ok"));
    try std.testing.expect(!try matches("\\b\\d{4}\\b", "id12345")); // glued to a word
}

test "regex: \\B non-boundary is the complement of \\b" {
    try std.testing.expect(try matches("\\Bcat", "concat")); // no boundary before cat
    try std.testing.expect(!try matches("\\Bcat", "a cat")); // boundary ⇒ \B fails
    try std.testing.expect(try matches("a\\Bb", "ab")); // between two word bytes
    try std.testing.expect(!try matches("a\\bb", "ab")); // … so \b cannot match there
    // Empty line: no word byte anywhere ⇒ every position is a non-boundary.
    try std.testing.expect(!try matches("\\b", ""));
    try std.testing.expect(try matches("\\B", ""));
}

test "regex: \\b keeps the trigram prefilter and skips the DFA" {
    const a = std.testing.allocator;
    var re = try Regex.compile(a, "\\bfunc\\b");
    defer re.deinit();
    // The bounded literal is still extracted ⇒ the T0 trigram prefilter applies.
    try std.testing.expectEqualStrings("func", re.required);
    // A word-boundary pattern keeps the Pike VM (no byte-class DFA built).
    try std.testing.expect(re.dfa == null);
}

test "regex: \\b across lines via docMatch picks the whole-word line" {
    const a = std.testing.allocator;
    var re = try Regex.compile(a, "\\berr\\b");
    defer re.deinit();
    var sim = try Regex.Sim.init(a, &re);
    defer sim.deinit();
    try std.testing.expect(re.docMatch(&sim, "stderr = 1\nreturn err\n}")); // 2nd line
    try std.testing.expect(!re.docMatch(&sim, "stderr\nerrors\nterror")); // all glued
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

// ── `-o` / --only-matching leftmost-first span extraction (matchSpan) ──
//
// The span engine must reproduce rg's `(?-u)` match semantics EXACTLY: the
// leftmost start, then among threads sharing it the earliest alternation branch
// and greediest quantifier win. Every expectation below is cross-checked against
// `rg -o` on this machine (see .local/gist-dogfood/o_battery.sh, byte-identical).

/// The first match span in `line[from..]` as `[start,end)`, or null.
fn span1(pattern: []const u8, line: []const u8, from: usize) !?Regex.Span {
    var re = try Regex.compile(std.testing.allocator, pattern);
    defer re.deinit();
    var ss = try Regex.SpanSim.init(std.testing.allocator, &re);
    defer ss.deinit();
    return re.matchSpan(&ss, line, from);
}

/// Concatenate every non-overlapping match's TEXT with '|' — the `-o` stream
/// per line (empty matches advance one byte, exactly as `emitOnlyMatching`).
fn spansJoined(gpa: std.mem.Allocator, pattern: []const u8, line: []const u8) ![]u8 {
    var re = try Regex.compile(gpa, pattern);
    defer re.deinit();
    var ss = try Regex.SpanSim.init(gpa, &re);
    defer ss.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var from: usize = 0;
    var first = true;
    while (from <= line.len) {
        const sp = re.matchSpan(&ss, line, from) orelse break;
        if (sp.end == sp.start) {
            from = sp.start + 1;
            continue;
        }
        if (!first) try out.append(gpa, '|');
        first = false;
        try out.appendSlice(gpa, line[sp.start..sp.end]);
        from = sp.end;
    }
    return out.toOwnedSlice(gpa);
}

fn expectJoined(pattern: []const u8, line: []const u8, want: []const u8) !void {
    const got = try spansJoined(std.testing.allocator, pattern, line);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "matchSpan: leftmost-first prefers the earlier alternation branch (a|ab ⇒ a)" {
    const sp = (try span1("a|ab", "ab", 0)).?;
    try std.testing.expect(sp.start == 0 and sp.end == 1); // "a", not "ab"
    try expectJoined("a|ab", "abab", "a|a"); // then re-anchors after each 'a'
}

test "matchSpan: greedy quantifiers extend the end maximally" {
    try expectJoined("a+", "aaa", "aaa");
    try expectJoined("a+", "baaab", "aaa");
    try expectJoined("[0-9]+", "x12y345", "12|345");
    try expectJoined("[0-9]{2,}", "1 22 333", "22|333"); // the lone '1' is below the floor
}

// Lazy (non-greedy) quantifiers prefer the FEWEST repetitions — the split
// PRIORITY flips (exit before body) so the leftmost match ends as early as
// possible. Every expectation is byte-verified against `rg -o` (ripgrep 15.1.0,
// the Rust regex crate default engine, which shares gist's leftmost-first
// semantics) — see the probe battery in the same-PR proof log.
test "matchSpan: lazy quantifiers end the match as early as possible" {
    try expectJoined("a.*?b", "axbxb", "axb"); // greedy `a.*b` ⇒ "axbxb"; lazy stops at first b
    try expectJoined("a.+?b", "axbxb", "axb"); // ≥1 filler, then first b
    try expectJoined("<.*?>", "<a><bb>", "<a>|<bb>"); // canonical HTML-tag lazy case
    try expectJoined("\".*?\"", "\"x\" \"y\"", "\"x\"|\"y\""); // shortest quoted runs
    try expectJoined("a+?", "aaa", "a|a|a"); // each match minimal ⇒ three singletons
    try expectJoined("a{2,4}?", "aaaa", "aa|aa"); // counted-lazy: take the floor (2), not 4
    try expectJoined("a{2,}?", "aaaa", "aa|aa"); // open-ended lazy floor
}

test "matchSpan: lazy optional (`.??`) still satisfies a following required byte" {
    // `a.??b`: the optional filler prefers empty, but `ab`≠`aXb`, so it must
    // consume the `X` — laziness never sacrifices existence, only minimality.
    try std.testing.expect((try span1("a.??b", "aXb", 0)).?.end == 3);
    try expectJoined("a.??b", "ab", "ab"); // here the empty branch wins ⇒ "ab"
}

// A lazy quantifier changes only WHICH match is chosen (the span), never WHETHER
// one exists: `a.*?b` and greedy `a.*b` agree on match existence for every input,
// diverging solely on the end offset. Guards the split-priority invariant.
test "matchSpan: laziness never changes match existence, only the span" {
    const cases = [_][]const u8{ "axbxb", "ab", "aXXb", "no b here", "abc", "" };
    for (cases) |line| {
        const greedy = try span1("a.*b", line, 0);
        const lazy = try span1("a.*?b", line, 0);
        try std.testing.expect((greedy == null) == (lazy == null));
        if (greedy != null) {
            try std.testing.expect(greedy.?.start == lazy.?.start); // same leftmost start
            try std.testing.expect(lazy.?.end <= greedy.?.end); // lazy ends no later
        }
    }
}

test "matchSpan: non-overlapping, leftmost extraction of real code shapes" {
    try expectJoined("func \\w+", "func Foo() { func Bar() }", "func Foo|func Bar");
    try expectJoined("\\w+", "a.b_c d", "a|b_c|d");
    try expectJoined("0x[0-9a-fA-F]+", "v := 0xFF + 0x0a", "0xFF|0x0a");
}

test "matchSpan: anchors and word boundaries land the right span" {
    try std.testing.expect((try span1("^func", "func main", 0)).?.end == 4);
    try std.testing.expect((try span1("^func", " func", 0)) == null); // ^ not at start
    try expectJoined("\\bfunc\\b", "func funcs func", "func|func"); // 'funcs' is not a whole word
    // `$`-anchored greedy end sits at line end.
    try std.testing.expect((try span1("[0-9]+$", "id 42", 0)).?.end == 5);
}

test "matchSpan: resumes from a mid-line offset (non-overlapping iteration)" {
    // First match at 0..4; the next search from 4 finds the second at 9..13.
    try std.testing.expect((try span1("func", "func fn func", 0)).?.start == 0);
    try std.testing.expect((try span1("func", "func fn func", 4)).?.start == 8);
    try std.testing.expect((try span1("func", "func fn func", 9)) == null);
}

// ─────────────── rg-parity escapes: \< \> (word start/end), \A \z ───────────────
// Every expectation below is hand-verified against the installed ripgrep
// (`rg '\<bar' …` etc.) — the divergences this pass fixed were gist silently
// reading these as literal '<' '>' 'A' 'z' bytes.

test "regex: \\< matches only where a word STARTS, \\> only where one ENDS" {
    try std.testing.expect(try matches("\\<bar", "foo bar")); // gap ' |b' is a word start
    try std.testing.expect(try matches("bar\\>", "foo bar")); // gap 'r|EOL' is a word end
    try std.testing.expect(try matches("foo\\>", "foo bar")); // gap 'o| ' is a word end
    try std.testing.expect(!try matches("\\<ar", "foo bar")); // 'b|a' is word|word ⇒ not a start
    try std.testing.expect(!try matches("foo\\<", "foo bar")); // 'o| ' is an END, not a start
    try std.testing.expect(!try matches("\\>bar", "foo bar")); // ' |b' is a START, not an end
    try std.testing.expect(try matches("\\<bar\\>", "foo bar")); // whole word
    try std.testing.expect(!try matches("\\<bar\\>", "foobar")); // substring only
    // One-sided vs two-sided: `\b` holds at BOTH edges of a word, `\<` at one.
    try std.testing.expect(try matches("\\bfoo", "foo bar"));
    try std.testing.expect(try matches("\\<foo", "foo bar"));
    try std.testing.expect(try matches("foo\\b", "foo bar"));
    try std.testing.expect(!try matches("foo\\<", "foo bar"));
}

test "regex: \\A and \\z anchor the per-line haystack (rg default line model)" {
    try std.testing.expect(try matches("\\Afoo", "foo bar")); // line start
    try std.testing.expect(!try matches("\\Abar", "foo bar")); // mid-line ⇒ no
    try std.testing.expect(try matches("bar\\z", "foo bar")); // line end
    try std.testing.expect(!try matches("foo\\z", "foo bar")); // mid-line ⇒ no
    try std.testing.expect(try matches("\\Afoo bar\\z", "foo bar")); // exact line
    try std.testing.expect(try matches("\\A\\z", "")); // empty line: start==end
}

fn bufMatches(pattern: []const u8, buf: []const u8) !bool {
    var re = try Regex.compileOpts(std.testing.allocator, pattern, .{ .multiline = true });
    defer re.deinit();
    var sim = try Regex.Sim.init(std.testing.allocator, &re);
    defer sim.deinit();
    return re.bufMatch(&sim, buf);
}

test "regex: multiline \\A/\\z are BUFFER anchors while ^/$ hold at every line" {
    // `^` holds at each line start; `\A` only at the buffer's first byte.
    try std.testing.expect(try bufMatches("^beta", "alpha\nbeta\n"));
    try std.testing.expect(!try bufMatches("\\Abeta", "alpha\nbeta\n"));
    try std.testing.expect(try bufMatches("\\Aalpha", "alpha\nbeta\n"));
    // `$` holds at each line end; `\z` only at the buffer's very end.
    try std.testing.expect(try bufMatches("alpha$", "alpha\nbeta"));
    try std.testing.expect(!try bufMatches("alpha\\z", "alpha\nbeta"));
    try std.testing.expect(try bufMatches("beta\\z", "alpha\nbeta"));
    // A trailing `\n` is part of the buffer: `\z` sits after it, not before
    // (rg -U: `beta\z` does NOT match "alpha\nbeta\n" — verified).
    try std.testing.expect(!try bufMatches("beta\\z", "alpha\nbeta\n"));
    try std.testing.expect(try bufMatches("beta\n\\z", "alpha\nbeta\n"));
    // `\<`/`\>` keep working across the whole-buffer scan.
    try std.testing.expect(try bufMatches("\\<beta\\>", "alpha\nbeta\n"));
    try std.testing.expect(!try bufMatches("\\<eta", "alpha\nbeta\n"));
}

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
const pcre2 = @import("backend.zig");
const engine = @import("engine.zig");
const literal = @import("literal.zig");

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

test "whole-buffer dotall lookahead crosses newlines (the -U (?s)…(?=.*…) contract)" {
    // rg `-P -U '(?s)alpha(?=.*bar)'`: DOTALL lets `.*` span `\n`, so the
    // zero-width lookahead can see a `bar` on a LATER line than the `alpha`
    // anchor — the whole buffer is one subject. The span is the anchor only.
    var re = try Pcre.compileOpts(t.allocator, "alpha(?=.*bar)", .{ .multiline = true, .dotall = true });
    defer re.deinit();
    var sim = try Pcre.Sim.init(t.allocator, &re);
    defer sim.deinit();

    // Anchor on line 1, target on line 3: only whole-buffer dotall can bridge it.
    try t.expect(re.bufMatch(&sim, "alpha x\nmid\nyy bar\n"));
    const sp = re.matchSpan(&sim, "alpha x\nmid\nyy bar\n", 0).?;
    try t.expectEqual(@as(usize, 0), sp.start);
    try t.expectEqual(@as(usize, 5), sp.end); // "alpha" only — the lookahead is zero-width
    // Target absent ⇒ no match; target only BEFORE the anchor ⇒ no match (the
    // forward `.*` cannot see it), so gist never over-matches a satisfied-earlier
    // lookahead.
    try t.expect(!re.bufMatch(&sim, "alpha x\nmid\nno target\n"));
    try t.expect(!re.bufMatch(&sim, "bar first\nalpha here\n"));
}

test "JIT and interpreter agree on whole-buffer multiline dotall lookahead" {
    // The `-U` cross-line lookahead must not diverge between the JIT and the
    // interpreter fallback — the same fail-closed guarantee as the single-line
    // parity slate, on the whole-buffer path.
    const buf = "alpha x\nmid\nyy bar\n";
    var jit = try engine.compileMode(t.allocator, "alpha(?=.*bar)", .{ .multiline = true, .dotall = true }, true);
    defer jit.deinit();
    var interp = try engine.compileMode(t.allocator, "alpha(?=.*bar)", .{ .multiline = true, .dotall = true }, false);
    defer interp.deinit();
    try t.expect(!interp.jit);
    var js = try Pcre.Sim.init(t.allocator, &jit);
    defer js.deinit();
    var is = try Pcre.Sim.init(t.allocator, &interp);
    defer is.deinit();
    const a = jit.matchSpan(&js, buf, 0);
    const b = interp.matchSpan(&is, buf, 0);
    try t.expectEqual(a == null, b == null);
    try t.expectEqual(a.?.start, b.?.start);
    try t.expectEqual(a.?.end, b.?.end);
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

test "required-literal: a bound quantifier on a class shorthand claims nothing (regression)" {
    // The atoms `\s`/`\w`/`\d` match a CLASS, so nothing in `\s{1,2}` is a fixed
    // required byte. The extractor once scanned the interval's digits (`1`,`,`,`2`)
    // as literals → the bogus required run "1,2" (≥ the 3-byte floor), so the
    // trigram/in-file prefilter elided every line and `-P '\s{1,2}'` matched
    // NOTHING — fast but wrong. Every one of these MUST be "" (no over-claim).
    try expectRequired("\\s{1,2}", ""); // the exact reported false-negative
    try expectRequired("\\w{1,2}", "");
    try expectRequired("\\d{1,2}", "");
    try expectRequired("\\s{2,2}", "");
    try expectRequired("\\w{10,20}", ""); // wide interval: "10,20" is 5 bytes
    try expectRequired("\\d{3,4}\\s{1,2}", ""); // adjacent bound shorthands
    // A real literal AFTER a bound-quantified shorthand still survives — the
    // quantifier is folded, its digits never join the run.
    try expectRequired("\\w{2,3}foobar", "foobar");
    try expectRequired("id=\\d{4,8}done", "done"); // "id=" (3) and "done" (4) are separate runs; longer wins
}

test "required-literal: braced/multi-char escapes never leak their interior (over-claim floor)" {
    // A braced escape denotes ONE codepoint/byte; its interior name/hex is not a
    // required literal. Scanning it would over-claim (e.g. "Latin"/"2028") and
    // silently elide matching files.
    try expectRequired("\\p{Latin}", ""); // matches one Latin letter, not "Latin"
    try expectRequired("\\x{2028}", ""); // one codepoint U+2028, not "2028"
    try expectRequired("\\p{L}{2,4}", ""); // braced escape + bound quantifier
    try expectRequired("\\x41\\x42\\x43", ""); // \xHH bytes are not their hex spelling
    // A genuine literal tail past a braced escape is still required.
    try expectRequired("\\p{Lu}SECTION", "SECTION");
}

test "required-literal: lookaround/backreferences prefilter soundly (the PCRE-race premise)" {
    // gist beats every PCRE competitor on this class BECAUSE it prunes the read
    // set on a sound required literal these lookaround patterns still carry (the
    // lookaround itself is zero-width, so the surrounding literal is mandatory in
    // every match). If this regresses, gist silently loses its prefilter edge —
    // or worse, over-claims and elides a real match. These are the exact slate
    // patterns from bench/races/pcre_headtohead.sh.
    try expectRequired("func\\s+\\w+(?=\\()", "func"); // lookahead: "func" required
    try expectRequired("import\\s+(?!type)", "import"); // neg-lookahead: "import"
    try expectRequired("(?<=return\\s)nil", "nil"); // lookbehind: only "nil" is consumed
    try expectRequired("const\\s+\\w+(?=\\s*=)", "const");
    // Literal-free by construction — the prefilter correctly declines, so the
    // race falls through to gist's fused parallel PCRE2-JIT scan (still a win).
    try expectRequired("<(\\w+)>.*</\\1>", ""); // "</" is 2 bytes, below the trigram floor
    try expectRequired("\\b(\\w{3,})\\b.*\\b\\1\\b", ""); // pure backreference, no literal
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
    try t.expect(re.alts.len == 0); // required ≥ 3 bytes ⇒ no cover set needed
}

// ── the shadow gate (pcre2/shadow.zig) ──────────────────────────────────────

test "shadow: gateable patterns carry one; ungateable/nullable ones don't" {
    var backref = try compile("(\\w{4,})\\s+\\1");
    defer backref.deinit();
    try t.expect(backref.shadow != null);

    var look = try compile("func \\w+\\((?=.*ctx)");
    defer look.deinit();
    try t.expect(look.shadow != null);

    var nullable = try compile("a*"); // shadow would admit everything — discarded
    defer nullable.deinit();
    try t.expect(nullable.shadow == null);

    var recur = try compile("(a)(?1)"); // subroutine call — no containment proof
    defer recur.deinit();
    try t.expect(recur.shadow == null);
}

test "shadow: upgrades the trigram prefilter with the spliced-backref literal" {
    // literal.zig alone proves only "bar" (groups are opaque to it); the shadow
    // `(foo)bar(?:foo)` proves the contiguous "foobarfoo" — a 9-byte trigram
    // anchor for a pattern class that used to force a whole-corpus scan.
    var re = try compile("(foo)bar\\1");
    defer re.deinit();
    try t.expectEqualStrings("foobarfoo", re.required);
}

test "shadow gate: differential — gated ≡ ungated on every primitive" {
    // The one invariant that keeps the gate sound: stripping the shadow off a
    // compiled Pcre must never change any verdict. Adversarial corpus: empty
    // strings/lines, zero-width candidates, near-misses the shadow admits but
    // PCRE2 rejects (backref mismatch, lookahead failure), matches at every
    // boundary, multi-line docs, and the catastrophic-backtracking shape.
    const pats = [_][]const u8{
        "(\\w{4,})\\s+\\1",
        "(\\w+) \\1",
        "foo(?=bar)",
        "foo(?!bar)",
        "(?<=@)\\w+",
        "\\bword\\b",
        "^start",
        "end$",
        "(?P<w>\\d+)-(?P=w)",
        "(?>ab|a)c",
        "a++b",
        "<(\\w+)>.*</\\1>",
        "(a+)+$",
    };
    const hays = [_][]const u8{
        "",
        "\n",
        "word",
        "sword fish",
        "abcd abcd",
        "abcd efgh",
        "foobar",
        "foobaz",
        "x @tag y",
        "12-12 34-56",
        "abc\nac\nabc",
        "start middle end",
        "middle start\nend\n",
        "<b>bold</b>",
        "<b>bold</i>",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!",
        "go go stop\n\ngo stop go",
    };
    for (pats) |pat| {
        var gated = try compile(pat);
        defer gated.deinit();
        var raw = try compile(pat);
        defer raw.deinit();
        if (raw.shadow) |*sh| sh.deinit();
        raw.shadow = null;

        var gsim = try Pcre.Sim.init(t.allocator, &gated);
        defer gsim.deinit();
        var rsim = try Pcre.Sim.init(t.allocator, &raw);
        defer rsim.deinit();

        for (hays) |hay| {
            try t.expectEqual(raw.lineMatch(&rsim, hay), gated.lineMatch(&gsim, hay));
            try t.expectEqual(raw.docMatch(&rsim, hay), gated.docMatch(&gsim, hay));
            try t.expectEqual(raw.bufMatch(&rsim, hay), gated.bufMatch(&gsim, hay));
            // The full span walk (the -o/--json/--count-matches surface).
            var gfrom: usize = 0;
            var rfrom: usize = 0;
            while (true) {
                const gs = gated.matchSpan(&gsim, hay, gfrom);
                const rs = raw.matchSpan(&rsim, hay, rfrom);
                try t.expectEqual(rs == null, gs == null);
                const sp = gs orelse break;
                try t.expectEqual(rs.?.start, sp.start);
                try t.expectEqual(rs.?.end, sp.end);
                gfrom = if (sp.end > gfrom) sp.end else gfrom + 1;
                rfrom = gfrom;
                if (gfrom > hay.len) break;
            }
        }
    }
}

test "shadow gate: differential under multiline (-U) options" {
    const pats = [_][]const u8{ "(\\w{3,})\\n\\1", "alpha(?=.*bar)", "^bar$" };
    const hays = [_][]const u8{ "", "abc\nabc\n", "abc\nabd\n", "alpha x\nmid\nyy bar\n", "foo\nbar\nbaz", "bar first\nalpha here\n" };
    for (pats) |pat| {
        var gated = try Pcre.compileOpts(t.allocator, pat, .{ .multiline = true, .dotall = true });
        defer gated.deinit();
        var raw = try Pcre.compileOpts(t.allocator, pat, .{ .multiline = true, .dotall = true });
        defer raw.deinit();
        if (raw.shadow) |*sh| sh.deinit();
        raw.shadow = null;

        var gsim = try Pcre.Sim.init(t.allocator, &gated);
        defer gsim.deinit();
        var rsim = try Pcre.Sim.init(t.allocator, &raw);
        defer rsim.deinit();
        for (hays) |hay| {
            try t.expectEqual(raw.bufMatch(&rsim, hay), gated.bufMatch(&gsim, hay));
            const gs = gated.matchSpan(&gsim, hay, 0);
            const rs = raw.matchSpan(&rsim, hay, 0);
            try t.expectEqual(rs == null, gs == null);
            if (gs) |sp| {
                try t.expectEqual(rs.?.start, sp.start);
                try t.expectEqual(rs.?.end, sp.end);
            }
        }
    }
}

test "shadow gate: caseless folds into the gate" {
    var re = try Pcre.compileOpts(t.allocator, "(FOO)bar\\1", .{ .caseless = true });
    defer re.deinit();
    var sim = try Pcre.Sim.init(t.allocator, &re);
    defer sim.deinit();
    try t.expect(re.lineMatch(&sim, "xFooBARfOox")); // gate must not reject the folded form
    try t.expect(!re.lineMatch(&sim, "foobarbaz"));
}

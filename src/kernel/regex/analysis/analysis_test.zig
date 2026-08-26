//! irregex T2 regex *analysis* tests — adversarial, oracle-free unit coverage of
//! `analysis.zig`: the sound required-literal extraction (`literalInfo`), the
//! alternation cover set (`requiredAny`), and the anchored-start predicate
//! (`startsAnchored`). These feed the T0 trigram prefilter and the scan seeding,
//! so a wrong answer is either a missed match (unsound — never allowed) or a
//! needless full scan (suboptimal — caught here).
//!
//! No engine, no `rg`: every expectation is the literal/anchor property the
//! analysis is contractually obliged to compute. The sharp cases are the
//! soundness floor (a `<3`-byte alternation branch must defeat the whole cover)
//! and the maximality of `best` — a star/quest/plus PREFIX must not erase the
//! mandatory literal run that follows it.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const ana = @import("analysis.zig");
const cmp = @import("../compile/compile.zig");
const Node = syn.Node;
const State = syn.State;
const ByteSet = syn.ByteSet;
const ParseError = syn.ParseError;

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    node: *Node,
    fn alloc(self: *Parsed) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

fn parse(src: []const u8) ParseError!Parsed {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    var p = syn.Parser{ .src = src, .arena = arena.allocator() };
    const n = try p.parseAlt();
    if (p.pos != src.len) return ParseError.BadPattern;
    return .{ .arena = arena, .node = n };
}

/// Assert `literalInfo(pattern).best` — the longest literal that must appear in
/// EVERY match. The arena stays alive across the comparison.
fn expectBest(pattern: []const u8, want: []const u8) !void {
    var pr = try parse(pattern);
    defer pr.deinit();
    const li = try ana.literalInfo(pr.alloc(), pr.node);
    try std.testing.expectEqualStrings(want, li.best);
}

/// True iff `set` contains `want` (cover-set member order is unspecified).
fn coverHas(set: []const []const u8, want: []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, s, want)) return true;
    return false;
}

// ── literalInfo: exactness ───────────────────────────────────────────────────

test "analysis/literal: a pure literal is exact and is its own best" {
    var pr = try parse("function");
    defer pr.deinit();
    const li = try ana.literalInfo(pr.alloc(), pr.node);
    try std.testing.expectEqualStrings("function", li.exact.?);
    try std.testing.expectEqualStrings("function", li.best);
}

test "analysis/literal: a wildcard or repetition is never exact" {
    inline for (.{ "a.b", "a*", "a+", "a?", "ab|cd", "[0-9]" }) |pat| {
        var pr = try parse(pat);
        defer pr.deinit();
        const li = try ana.literalInfo(pr.alloc(), pr.node);
        try std.testing.expect(li.exact == null);
    }
}

// ── literalInfo: best (the maximality contract) ──────────────────────────────

test "analysis/literal: '.' breaks exactness but the longer run survives as best" {
    try expectBest("ab.cd", "ab"); // neither run > 2; first wins the tie
    try expectBest("ab.cdef", "cdef"); // the longer mandatory run is the suffix
}

test "analysis/literal: a star/quest PREFIX must not erase the mandatory suffix run" {
    // Regression: a left-folded `a*function` buries the non-exact `a*` at the
    // bottom-left, and a naive concat analysis collapses `best` to the first
    // byte ("f"). The mandatory literal is the whole trailing run.
    try expectBest("a*function", "function");
    try expectBest("(ab)*function", "function");
    try expectBest("\\d+package", "package");
    try expectBest("[0-9]+return", "return");
}

test "analysis/literal: a plus contributes a cross-boundary mandatory run" {
    // Every match of `(abc)+def` ends with an `abc` immediately before `def`, so
    // "abcdef" is mandatory and contiguous — the suffix-of-plus ⋈ prefix join.
    try expectBest("(abc)+def", "abcdef");
    try expectBest("xy(abc)+", "xyabc"); // prefix ⋈ prefix-of-plus
    // `ab+c` matches "abbc": no 3-byte run is mandatory — only "ab" (and "bc").
    try expectBest("ab+c", "ab");
}

test "analysis/literal: an interior optional splits the mandatory run" {
    try expectBest("colou?r", "colo"); // the `u?` splits color/colour; "colo" is mandatory
    try expectBest("ab?cdef", "cdef"); // optional 'b' ⇒ the suffix run wins
}

test "analysis/literal: optionals and alternation prove no single mandatory literal" {
    try expectBest("a*", ""); // matches empty ⇒ nothing mandatory
    try expectBest("(foo)?", ""); // optional group ⇒ nothing
    try expectBest("cat|dog", ""); // alternation ⇒ no single literal (see requiredAny)
}

test "analysis/literal: a zero-width anchor lets a mandatory run span it" {
    var pr = try parse("^func");
    defer pr.deinit();
    const li = try ana.literalInfo(pr.alloc(), pr.node);
    try std.testing.expectEqualStrings("func", li.best); // ^ is zero-width
    try expectBest("end$", "end"); // trailing $ likewise
    try expectBest("^abc$", "abc"); // whole-line anchored literal
}

test "analysis/literal: counted repetition yields the right mandatory run" {
    try expectBest("a{3}", "aaa"); // exact ⇒ 3 copies
    try expectBest("a{2,4}", "aa"); // {n,m} ⇒ n mandatory
    try expectBest("a{2,}", "aa"); // {n,} ⇒ n mandatory, then a*
    try expectBest("ab{3}c", "abbbc"); // run spans the expansion
    try expectBest("x{2,5}", "xx"); // ≥2 x's mandatory
}

// ── requiredAny: the alternation cover set ───────────────────────────────────

test "analysis/requiredAny: a single mandatory ≥3 literal is preferred over a cover" {
    var pr = try parse("func\\s+\\w+\\(");
    defer pr.deinit();
    const cover = (try ana.requiredAny(pr.alloc(), pr.node)).?;
    try std.testing.expectEqual(@as(usize, 1), cover.len);
    try std.testing.expectEqualStrings("func", cover[0]);
}

test "analysis/requiredAny: every branch yields a ≥3 literal ⇒ the union covers" {
    {
        var pr = try parse("cat|dog");
        defer pr.deinit();
        const cover = (try ana.requiredAny(pr.alloc(), pr.node)).?;
        try std.testing.expectEqual(@as(usize, 2), cover.len);
        try std.testing.expect(coverHas(cover, "cat") and coverHas(cover, "dog"));
    }
    {
        var pr = try parse("return|continue|break");
        defer pr.deinit();
        const cover = (try ana.requiredAny(pr.alloc(), pr.node)).?;
        try std.testing.expectEqual(@as(usize, 3), cover.len);
        try std.testing.expect(coverHas(cover, "return") and coverHas(cover, "break"));
    }
    {
        var pr = try parse("x(foo|bar)"); // no single ≥3 run, but the alt still covers
        defer pr.deinit();
        const cover = (try ana.requiredAny(pr.alloc(), pr.node)).?;
        try std.testing.expectEqual(@as(usize, 2), cover.len);
        try std.testing.expect(coverHas(cover, "foo") and coverHas(cover, "bar"));
    }
}

test "analysis/requiredAny: a sub-3 branch joins the cover, it does not defeat it" {
    // `0x` produces no trigram, so admitting {panic} ALONE would drop a match
    // arriving through that branch — the unsoundness this has always guarded. The
    // fix is to carry `0x` too, not to abandon the cover: the sliver tier answers
    // it from the same directory. (This asserted `== null` while `0x` was
    // unqueryable; that was the sound answer then, and the weak one now — it sent
    // the certificate's `regex-litalt` class to a 100% full scan.)
    var pr = try parse("panic|0x");
    defer pr.deinit();
    const cover = (try ana.requiredAny(pr.alloc(), pr.node)) orelse return error.CoverWithheld;
    try std.testing.expect(coverHas(cover, "panic") and coverHas(cover, "0x"));
}

test "analysis/requiredAny: a huge alternation bails past the cover cap" {
    // Beyond max_cover (64) branches the union is no cheaper than a full scan, so
    // the analysis returns null rather than a giant per-branch query set.
    var small = try parse("abc|def|ghi");
    defer small.deinit();
    try std.testing.expect((try ana.requiredAny(small.alloc(), small.node)) != null);

    var big = try parse("abc" ++ ("|abc" ** 80)); // 81 ≥3 branches > max_cover
    defer big.deinit();
    try std.testing.expect((try ana.requiredAny(big.alloc(), big.node)) == null);
}

// ── startsAnchored ───────────────────────────────────────────────────────────

test "analysis/anchored: ^ at the head of every branch anchors the whole pattern" {
    inline for (.{ "^func", "^a.c", "^a{3}", "(^a)bc", "^func|^type", "^a|^b|^c" }) |pat| {
        var pr = try parse(pat);
        defer pr.deinit();
        try std.testing.expect(ana.startsAnchored(pr.node));
    }
}

test "analysis/anchored: one un-anchored branch makes the whole pattern un-anchored" {
    inline for (.{ "func", "a.c", ".*", "^a|b", "a|^b", "^func|type", "(a|^b)c" }) |pat| {
        var pr = try parse(pat);
        defer pr.deinit();
        try std.testing.expect(!ana.startsAnchored(pr.node));
    }
}

test "analysis/literal: an OPTIONAL neighbor is never folded into best (over-claim guard)" {
    // The unsound failure mode is folding an optional/looped neighbor into
    // `best` — a match omitting it then lacks the claimed literal and is dropped.
    // (Soundness of `best` is fuzzed engine-side; these pin the EXACT value, so a
    // too-short `best` — sound but a missed prefilter — is also caught.)
    try expectBest("(abc)?def", "def"); // the optional group must NOT appear in best
    try expectBest("ab(cd)?", "ab");
    try expectBest("x*y*z", "z"); // only z is mandatory through the stars
}

test "analysis/requiredAny: an asymmetric short branch is covered, never dropped" {
    // `a|abc`: a match via the 1-byte `a` branch contains no "abc", so a cover of
    // {"abc"} alone would be UNSOUND. The short branch must therefore contribute
    // its own literal — {"a", "abc"} — which the sliver tier can now query. (This
    // asserted `== null` while a 1–2 byte branch was unqueryable; withholding the
    // whole cover was the sound answer then, and is merely the weaker one now.)
    // Order must not matter, so check both sides.
    inline for (.{ "a|abc", "abc|a" }) |pat| {
        var pr = try parse(pat);
        defer pr.deinit();
        // The soundness claim itself: EVERY branch contributes, so no match of
        // either branch can be filtered away.
        const cover = (try ana.requiredAny(pr.alloc(), pr.node)) orelse return error.CoverWithheld;
        try std.testing.expectEqual(@as(usize, 2), cover.len);
        try std.testing.expect(coverHas(cover, "a"));
        try std.testing.expect(coverHas(cover, "abc"));
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Adversarial second pass — the corners the extracted suite skipped:
//   • the prefix / suffix fields of `LitInfo` (the mandatory head & tail runs),
//     never asserted above even though `best` is computed from them;
//   • `analyzeFirst` and `reachesMatchEol` — the compiled-NFA visitors, which had
//     NO direct unit test (only indirect engine coverage);
//   • requiredAny / startsAnchored soundness boundaries.
// Every expectation is hand-derived from the contract, never an engine oracle.
// ════════════════════════════════════════════════════════════════════════════

/// `literalInfo(pattern)` with the arena kept alive across the comparison.
fn lit(pr: *Parsed) ParseError!ana.LitInfo {
    return ana.literalInfo(pr.alloc(), pr.node);
}

// ── literalInfo: prefix / suffix (the head & tail mandatory runs) ─────────────

test "analysis/affix: a pure literal is its own prefix and suffix" {
    var pr = try parse("function");
    defer pr.deinit();
    const li = try lit(&pr);
    try std.testing.expectEqualStrings("function", li.prefix);
    try std.testing.expectEqualStrings("function", li.suffix);
}

test "analysis/affix: a wildcard head clears the prefix but keeps the suffix" {
    var pr = try parse(".abc"); // any byte then abc ⇒ no fixed head, fixed tail
    defer pr.deinit();
    const li = try lit(&pr);
    try std.testing.expectEqualStrings("", li.prefix);
    try std.testing.expectEqualStrings("abc", li.suffix);
}

test "analysis/affix: a wildcard tail clears the suffix but keeps the prefix" {
    var pr = try parse("abc."); // abc then any byte ⇒ fixed head, no fixed tail
    defer pr.deinit();
    const li = try lit(&pr);
    try std.testing.expectEqualStrings("abc", li.prefix);
    try std.testing.expectEqualStrings("", li.suffix);
}

test "analysis/affix: an interior wildcard fixes both ends but not the exactness" {
    var pr = try parse("ab.cd");
    defer pr.deinit();
    const li = try lit(&pr);
    try std.testing.expectEqualStrings("ab", li.prefix);
    try std.testing.expectEqualStrings("cd", li.suffix);
    try std.testing.expect(li.exact == null);
}

test "analysis/affix: a plus tail joins through the following exact run" {
    // `(abc)+def` STARTS with abc (first iteration) but ENDS with abc⋈def (the
    // last iteration abuts def) — the prefix and suffix are asymmetric here.
    var pr = try parse("(abc)+def");
    defer pr.deinit();
    const li = try lit(&pr);
    try std.testing.expectEqualStrings("abc", li.prefix);
    try std.testing.expectEqualStrings("abcdef", li.suffix);
    try std.testing.expectEqualStrings("abcdef", li.best);
}

test "analysis/affix: a leading optional clears the prefix; a trailing one the suffix" {
    {
        var pr = try parse("a?bcd"); // optional head ⇒ no fixed prefix
        defer pr.deinit();
        const li = try lit(&pr);
        try std.testing.expectEqualStrings("", li.prefix);
        try std.testing.expectEqualStrings("bcd", li.suffix);
    }
    {
        var pr = try parse("abcd?"); // optional tail ⇒ no fixed suffix
        defer pr.deinit();
        const li = try lit(&pr);
        try std.testing.expectEqualStrings("abc", li.prefix);
        try std.testing.expectEqualStrings("", li.suffix);
    }
}

test "analysis/affix: zero-width anchors leave the affixes intact" {
    var pr = try parse("^abc$");
    defer pr.deinit();
    const li = try lit(&pr);
    try std.testing.expectEqualStrings("abc", li.prefix);
    try std.testing.expectEqualStrings("abc", li.suffix);
    try std.testing.expectEqualStrings("abc", li.exact.?);
}

// ── compiled-NFA visitors: analyzeFirst + reachesMatchEol ────────────────────

/// A compiled Thompson program (flat `State` slice + entry) for the visitor
/// tests. Mirrors `core.compile`'s prologue: `match` is state 0, the AST lowers
/// with every exit flowing to it. Owns `states`; the AST arena trails behind.
const Program = struct {
    arena: std.heap.ArenaAllocator,
    states: []State,
    start: u32,
    fn deinit(self: *Program) void {
        std.testing.allocator.free(self.states);
        self.arena.deinit();
    }
};

fn compileProgram(pattern: []const u8) ParseError!Program {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    var p = syn.Parser{ .src = pattern, .arena = arena.allocator() };
    const ast = try p.parseAlt();
    if (p.pos != pattern.len) return ParseError.BadPattern;
    var c = cmp.Compiler{ .gpa = std.testing.allocator };
    defer c.loom.deinit(std.testing.allocator);
    errdefer c.states.deinit(std.testing.allocator);
    const match_idx = try c.push(.match);
    const start = try c.compileNode(ast, match_idx);
    return .{ .arena = arena, .states = try c.states.toOwnedSlice(std.testing.allocator), .start = start };
}

/// The first-consumable-byte superset (`analyzeFirst`) of `pattern`.
fn firstSet(pattern: []const u8) ParseError!ByteSet {
    var prog = try compileProgram(pattern);
    defer prog.deinit();
    var set = ByteSet{};
    try ana.analyzeFirst(std.testing.allocator, prog.states, prog.start, &set);
    return set;
}

/// Whether `pattern` matches the zero-width end of every line (`reachesMatchEol`).
fn eolEmpty(pattern: []const u8) ParseError!bool {
    var prog = try compileProgram(pattern);
    defer prog.deinit();
    return ana.reachesMatchEol(std.testing.allocator, prog.states, prog.start);
}

test "analysis/first: a literal head is the lone first byte" {
    const s = try firstSet("abc");
    try std.testing.expectEqual(@as(?u8, 'a'), s.only());
}

test "analysis/first: alternation unions every branch's head" {
    const s = try firstSet("a|b|c");
    try std.testing.expect(s.has('a') and s.has('b') and s.has('c'));
    try std.testing.expectEqual(@as(usize, 3), s.count());
}

test "analysis/first: a star head is skippable, so the next byte joins the set" {
    const s = try firstSet("a*b"); // "b", "ab", "aab" … ⇒ {a, b}
    try std.testing.expect(s.has('a') and s.has('b'));
    try std.testing.expectEqual(@as(usize, 2), s.count());
}

test "analysis/first: a PLUS head is mandatory, so only it can begin a match" {
    const s = try firstSet("a+b"); // ≥1 'a' first ⇒ {a} only, never 'b'
    try std.testing.expectEqual(@as(?u8, 'a'), s.only());
}

test "analysis/first: ^ is traversed — the anchored byte stays reachable" {
    const s = try firstSet("^abc");
    try std.testing.expectEqual(@as(?u8, 'a'), s.only());
    const t = try firstSet("^a|b"); // anchored 'a' plus a free 'b'
    try std.testing.expect(t.has('a') and t.has('b') and t.count() == 2);
}

test "analysis/first: $ blocks — nothing is consumable past end-of-line" {
    const s = try firstSet("$a"); // a '$' before a byte can never consume ⇒ ∅
    try std.testing.expectEqual(@as(usize, 0), s.count());
}

test "analysis/first: a class head contributes its whole set" {
    const s = try firstSet("[0-9]x");
    try std.testing.expect(s.has('0') and s.has('9') and !s.has('x'));
    try std.testing.expectEqual(@as(usize, 10), s.count());
    const dot = try firstSet(".x"); // '.' is every byte but newline
    try std.testing.expect(!dot.has('\n') and dot.has('a'));
    try std.testing.expectEqual(@as(usize, 255), dot.count());
}

test "analysis/eol: a nullable prefix matches every line's zero-width end" {
    inline for (.{ "a*", "\\d*$", "x|$", "$", "a?$", "" }) |pat| {
        try std.testing.expect(try eolEmpty(pat));
    }
}

test "analysis/eol: a mandatory consume cannot reach the zero-width end" {
    inline for (.{ "abc", "a+$", "a+", "[0-9]" }) |pat| {
        try std.testing.expect(!(try eolEmpty(pat)));
    }
}

test "analysis/eol: ^ is blocked at a non-empty line's end" {
    // `^…` asserts start; at a non-empty EOL `at_start` is false, so neither `^a`
    // nor `^$` matches the zero-width end of an arbitrary line.
    try std.testing.expect(!(try eolEmpty("^a")));
    try std.testing.expect(!(try eolEmpty("^$")));
}

// ── requiredAny / startsAnchored: deeper soundness boundaries ─────────────────

test "analysis/requiredAny: a single best ≥3 wins even across a wildcard gap" {
    var pr = try parse("foo.*bar"); // both foo and bar mandatory; best is one of them
    defer pr.deinit();
    const cover = (try ana.requiredAny(pr.alloc(), pr.node)).?;
    try std.testing.expectEqual(@as(usize, 1), cover.len);
    try std.testing.expect(cover[0].len >= 3 and coverHas(cover, "foo"));
}

test "analysis/requiredAny: no branch reaching 3 bytes still yields a sound cover" {
    // Each expectation is derived from the contract — every match must contain a
    // member — not from what the implementation happens to return.
    inline for (.{
        .{ "ab|cd", "ab", "cd" }, // both branches contribute
        .{ "(ab|cd)ef", "ef", "ef" }, // `ef` is mandatory through EITHER branch,
        //                               so the one-literal cover beats two queries
        .{ "a|ab", "a", "ab" }, // the 1-byte branch must carry its own byte
    }) |case| {
        var pr = try parse(case[0]);
        defer pr.deinit();
        const cover = (try ana.requiredAny(pr.alloc(), pr.node)) orelse return error.CoverWithheld;
        try std.testing.expect(coverHas(cover, case[1]) and coverHas(cover, case[2]));
    }
}

test "analysis/anchored: ^ before a group / nullable still anchors the whole" {
    inline for (.{ "^(a|b)", "(^a|^b)c", "^a*", "^.*" }) |pat| {
        var pr = try parse(pat);
        defer pr.deinit();
        try std.testing.expect(ana.startsAnchored(pr.node));
    }
}

test "analysis/requiredAny: the cover cap is an inclusive boundary at max_cover" {
    // Exactly 64 (= max_cover) ≥3 branches still covers; 65 tips it to a full scan.
    var at = try parse("abc" ++ ("|abc" ** 63)); // 64 branches
    defer at.deinit();
    try std.testing.expect((try ana.requiredAny(at.alloc(), at.node)) != null);

    var over = try parse("abc" ++ ("|abc" ** 64)); // 65 branches
    defer over.deinit();
    try std.testing.expect((try ana.requiredAny(over.alloc(), over.node)) == null);
}

test "analysis/requiredAny: a concat takes the cover from whichever side proves one" {
    {
        var pr = try parse("(foo|bar)(ab|cd)"); // only the LEFT side covers
        defer pr.deinit();
        const cover = (try ana.requiredAny(pr.alloc(), pr.node)).?;
        try std.testing.expect(coverHas(cover, "foo") and coverHas(cover, "bar"));
    }
    {
        var pr = try parse("(ab|cd)(foo|bar)"); // only the RIGHT side covers
        defer pr.deinit();
        const cover = (try ana.requiredAny(pr.alloc(), pr.node)).?;
        try std.testing.expect(coverHas(cover, "foo") and coverHas(cover, "bar"));
    }
    {
        // Both sides carry a <3 branch ("x", "y"). Either side's cover is sound for
        // the whole concat, and a match like "xy" is now caught by the sliver
        // literal its side contributes rather than forcing a full scan.
        var pr = try parse("(foo|x)(bar|y)");
        defer pr.deinit();
        const cover = (try ana.requiredAny(pr.alloc(), pr.node)) orelse return error.CoverWithheld;
        const left = coverHas(cover, "foo") and coverHas(cover, "x");
        const right = coverHas(cover, "bar") and coverHas(cover, "y");
        try std.testing.expect(left or right);
    }
}

test "analysis/repeat: counted repetition of a multi-byte group keeps the run exact" {
    {
        var pr = try parse("(ab){2}"); // ⇒ exactly "abab"
        defer pr.deinit();
        const li = try lit(&pr);
        try std.testing.expectEqualStrings("abab", li.exact.?);
        try std.testing.expectEqualStrings("abab", li.best);
    }
    {
        var pr = try parse("(ab){2,}"); // ≥2 copies ⇒ "abab" mandatory, then (ab)*
        defer pr.deinit();
        const li = try lit(&pr);
        try std.testing.expect(li.exact == null);
        try std.testing.expectEqualStrings("abab", li.best);
    }
}

// ── classRunShape: the SIMD class-run reduction ──────────────────────────────

/// Parse under Unicode mode (so `\w`/`\d` lower to a `uclass`), as rg defaults.
fn parseU(src: []const u8) ParseError!Parsed {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    var p = syn.Parser{ .src = src, .arena = arena.allocator(), .unicode = true };
    const n = try p.parseAlt();
    if (p.pos != src.len) return ParseError.BadPattern;
    return .{ .arena = arena, .node = n };
}

/// Assert the pattern reduces to a class run with this floor + exactness, and
/// that the set matches on the probe bytes given (`ins` members, `outs` not).
fn expectShape(pr: *Parsed, min: u32, exact: bool, ins: []const u8, outs: []const u8) !void {
    const s = ana.classRunShape(pr.node) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(min, s.min);
    try std.testing.expectEqual(exact, s.exact);
    for (ins) |b| try std.testing.expect(s.set.has(b));
    for (outs) |b| try std.testing.expect(!s.set.has(b));
}

fn expectNoShape(pattern: []const u8) !void {
    var pr = try parse(pattern);
    defer pr.deinit();
    try std.testing.expect(ana.classRunShape(pr.node) == null);
}

test "analysis/classrun: the dense-class family reduces with exact floors" {
    // `+` is existence-transparent: one copy is the witness.
    {
        var pr = try parse("[a-z]+");
        defer pr.deinit();
        try expectShape(&pr, 1, true, "az", "AZ09 ");
    }
    // `{n}` expands to a forced concat chain: floors add.
    {
        var pr = try parse("[0-9]{4}");
        defer pr.deinit();
        try expectShape(&pr, 4, true, "09", "az");
    }
    // `{n,}` = n forced copies then a transparent star.
    {
        var pr = try parse("[0-9a-f]{2,}");
        defer pr.deinit();
        try expectShape(&pr, 2, true, "09af", "gz");
    }
    // `{n,m}` = n forced copies then transparent quests.
    {
        var pr = try parse("x{2,4}");
        defer pr.deinit();
        try expectShape(&pr, 2, true, "x", "y");
    }
    // ASCII `\w` (non-unicode parse) is a plain 4-range class.
    {
        var pr = try parse("\\w{3,8}");
        defer pr.deinit();
        try expectShape(&pr, 3, true, "aZ9_", " .-");
    }
}

test "analysis/classrun: same-set alternation takes the weaker floor" {
    {
        var pr = try parse("[0-9]{4}|[0-9]{2}");
        defer pr.deinit();
        try expectShape(&pr, 2, true, "09", "az");
    }
    // Different sets can't merge — existence would need per-branch tracking.
    try expectNoShape("[a-z]+|[0-9]+");
}

test "analysis/classrun: captures are transparent, nullable wrappers vanish" {
    {
        var pr = try parse("([a-z])+");
        defer pr.deinit();
        try expectShape(&pr, 1, true, "az", "09");
    }
    // A nullable prefix of ANY shape (even a non-class-run literal group)
    // drops out of the existence question entirely.
    {
        var pr = try parse("(foo)?[0-9]{3}");
        defer pr.deinit();
        try expectShape(&pr, 3, true, "09", "fo");
    }
    {
        var pr = try parse("(bar)*[a-f]+");
        defer pr.deinit();
        try expectShape(&pr, 1, true, "af", "gz");
    }
}

test "analysis/classrun: an interior optional blocks seam merging" {
    try expectNoShape("[0-9][a-z]?[0-9]");
    try expectNoShape("[0-9](foo)*[0-9]");
}

test "analysis/classrun: unicode \\w reduces to its ASCII projection" {
    var pr = try parseU("\\w{3,}");
    defer pr.deinit();
    const s = ana.classRunShape(pr.node) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), s.min);
    try std.testing.expect(!s.exact); // projection: high bytes defer to the engine
    try std.testing.expect(s.set.has('a') and s.set.has('_') and s.set.has('9'));
    try std.testing.expect(!s.set.has(' ') and !s.set.has(0xC3));
}

test "analysis/classrun: everything outside the family declines" {
    try expectNoShape("foo"); // multi-set concat (f·o·o sets differ)
    try expectNoShape("[a-z]+[0-9]"); // mixed forced sets
    try expectNoShape("^[a-z]+"); // positioned assertion
    try expectNoShape("[a-z]+$");
    try expectNoShape("\\b[a-z]+"); // word boundary outside a nullable wrapper
    try expectNoShape("[a-z]*"); // nullable whole pattern: eol_empty owns it
    try expectNoShape("a?"); // likewise
}

test "analysis/classrun: a repeated singleton literal is legitimately a class run" {
    // `aa` ≡ [a]{2} — the reduction is real and sound (memchr-grade scan).
    var pr = try parse("aa");
    defer pr.deinit();
    try expectShape(&pr, 2, true, "a", "b");
}

test "analysis/first+eol: a bare .* takes any non-newline byte and matches every EOL" {
    const s = try firstSet(".*");
    try std.testing.expect(!s.has('\n') and s.has('a') and s.has(0) and s.has(255));
    try std.testing.expectEqual(@as(usize, 255), s.count());
    try std.testing.expect(try eolEmpty(".*")); // nullable ⇒ matches the empty tail
}

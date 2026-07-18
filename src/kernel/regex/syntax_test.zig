//! gist T2 regex *syntax* tests — adversarial, oracle-free unit coverage of
//! `syntax.zig` in isolation: the `ByteSet` bit-class and the recursive-descent
//! parser (escapes, character classes, counted-repetition desugaring, the
//! error surface). The sound AST analyses that feed the prefilter live in
//! `analysis.zig` and are exercised by `analysis_test.zig`.
//!
//! These deliberately do NOT run the execution engine and do NOT diff against
//! `rg` — every expectation is a hand-computed property of the parser contract,
//! so a failure is a defect in `syntax.zig`, not a disagreement with an external
//! oracle. They probe the corners a happy-path suite skips: integer overflow in
//! `{n}` bounds, reversed class ranges, the exact byte-set of each escape, and
//! the `{` / `}` literal-vs-count disambiguation.

const std = @import("std");
const syn = @import("syntax.zig");
const Node = syn.Node;
const ByteSet = syn.ByteSet;
const ParseError = syn.ParseError;

// ── parse harness ────────────────────────────────────────────────────────────

/// A fully-parsed pattern plus the arena its AST lives in. Mirrors
/// `core.compile`'s contract: trailing unconsumed input ⇒ `BadPattern` (the
/// top-level `pos != len` guard lives in `core.zig`, so we replicate it here to
/// drive the parser exactly the way the engine does).
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
    if (p.pos != src.len) return ParseError.BadPattern; // trailing bytes ⇒ malformed
    return .{ .arena = arena, .node = n };
}

/// The sole consuming `class` set of a one-atom pattern (e.g. `\d`, `.`, `[..]`).
fn classOf(pr: *Parsed) !ByteSet {
    return switch (pr.node.*) {
        .class => |s| s,
        else => error.TestExpectedClass,
    };
}

/// Flatten a concat-of-singleton-classes AST into its literal bytes; errors on
/// any non-literal node. Lets a syntax test assert the EXACT byte sequence a
/// `{n}` expansion lowers to, without depending on `analysis.zig`.
fn flattenLiteral(pr: *Parsed) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try flattenInto(pr.node, &out, pr.alloc());
    return out.items;
}
fn flattenInto(node: *Node, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    switch (node.*) {
        .empty => {},
        .class => |s| try out.append(gpa, s.only() orelse return error.TestNotLiteral),
        .concat => |ab| {
            try flattenInto(ab[0], out, gpa);
            try flattenInto(ab[1], out, gpa);
        },
        .capture => |g| try flattenInto(g.child, out, gpa), // a group is transparent to its literal run
        else => return error.TestNotLiteral,
    }
}

// ── ByteSet ──────────────────────────────────────────────────────────────────

test "syntax/ByteSet: set/has across word boundaries and endpoints" {
    var s = ByteSet{};
    for ([_]u8{ 0, 63, 64, 127, 128, 255 }) |b| s.set(b);
    for ([_]u8{ 0, 63, 64, 127, 128, 255 }) |b| try std.testing.expect(s.has(b));
    // The bytes straddling the 64-bit word seam land in different words.
    try std.testing.expect(s.has(63) and s.has(64));
    try std.testing.expect(!s.has(1) and !s.has(62) and !s.has(254));
    try std.testing.expectEqual(@as(usize, 6), s.count());
}

test "syntax/ByteSet: setRange is inclusive and clamps at 255 without overflow" {
    var all = ByteSet{};
    all.setRange(0, 255);
    try std.testing.expectEqual(@as(usize, 256), all.count());
    try std.testing.expect(all.has(255) and all.has(0));
    try std.testing.expect(all.only() == null); // not a singleton

    var lo = ByteSet{};
    lo.setRange('a', 'z');
    try std.testing.expectEqual(@as(usize, 26), lo.count());
    try std.testing.expect(lo.has('a') and lo.has('z') and !lo.has('A'));

    // A reversed [lo,hi] adds nothing (lo > hi never enters the loop).
    var rev = ByteSet{};
    rev.setRange('z', 'a');
    try std.testing.expectEqual(@as(usize, 0), rev.count());
}

test "syntax/ByteSet: negate is an involution; union accumulates" {
    var empty = ByteSet{};
    try std.testing.expectEqual(@as(usize, 0), empty.count());
    empty.negate();
    try std.testing.expectEqual(@as(usize, 256), empty.count()); // ~∅ = universe
    empty.negate();
    try std.testing.expectEqual(@as(usize, 0), empty.count()); // back to ∅

    var a = ByteSet{};
    a.set('x');
    var b = ByteSet{};
    b.set('y');
    a.unionWith(b);
    try std.testing.expect(a.has('x') and a.has('y'));
    try std.testing.expectEqual(@as(usize, 2), a.count());
}

test "syntax/ByteSet: only() is the singleton or null" {
    var one = ByteSet{};
    one.set(200);
    try std.testing.expectEqual(@as(?u8, 200), one.only());
    var two = ByteSet{};
    two.set(1);
    two.set(2);
    try std.testing.expect(two.only() == null);
    try std.testing.expect((ByteSet{}).only() == null); // empty
}

// ── escapes & the dot ────────────────────────────────────────────────────────

test "syntax/escape: \\d \\w \\s carry the right ASCII members" {
    {
        var pr = try parse("\\d");
        defer pr.deinit();
        const s = try classOf(&pr);
        try std.testing.expect(s.has('0') and s.has('9') and !s.has('a'));
        try std.testing.expectEqual(@as(usize, 10), s.count());
    }
    {
        var pr = try parse("\\w");
        defer pr.deinit();
        const s = try classOf(&pr);
        try std.testing.expect(s.has('a') and s.has('Z') and s.has('5') and s.has('_'));
        try std.testing.expect(!s.has(' ') and !s.has('-'));
        try std.testing.expectEqual(@as(usize, 63), s.count()); // 26+26+10+'_'
    }
    {
        var pr = try parse("\\s");
        defer pr.deinit();
        const s = try classOf(&pr);
        for ([_]u8{ ' ', '\t', '\n', '\r', 0x0B, 0x0C }) |b| try std.testing.expect(s.has(b));
        try std.testing.expect(!s.has('a'));
        try std.testing.expectEqual(@as(usize, 6), s.count());
    }
}

test "syntax/escape: uppercase class is the exact complement of lowercase" {
    inline for (.{ .{ "\\d", "\\D" }, .{ "\\w", "\\W" }, .{ "\\s", "\\S" } }) |pair| {
        var lo = try parse(pair[0]);
        defer lo.deinit();
        var hi = try parse(pair[1]);
        defer hi.deinit();
        var ls = try classOf(&lo);
        const hs = try classOf(&hi);
        try std.testing.expectEqual(@as(usize, 256), ls.count() + hs.count());
        ls.negate(); // ~lower must equal upper, bit for bit
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const b: u8 = @intCast(i);
            try std.testing.expectEqual(ls.has(b), hs.has(b));
        }
    }
}

test "syntax/escape: metacharacter and punctuation escapes are literal" {
    inline for (.{ "\\.", "\\*", "\\+", "\\?", "\\(", "\\)", "\\[", "\\]", "\\^", "\\$", "\\\\", "\\|", "\\/", "\\-", "\\_" }) |pat| {
        var pr = try parse(pat);
        defer pr.deinit();
        const s = try classOf(&pr);
        try std.testing.expectEqual(@as(usize, 1), s.count()); // exactly the escaped byte
        try std.testing.expect(s.has(pat[1]));
    }
    {
        var pr = try parse("\\t");
        defer pr.deinit();
        const s = try classOf(&pr);
        try std.testing.expect(s.has('\t') and s.count() == 1);
    }
}

test "syntax/escape: backreferences \\0-\\9 are BadPattern (rg parity), in atom and class" {
    // rg (rust-regex) rejects `\0`…`\9` as backreference syntax, exit 2 — a
    // linear-time engine can't do backreferences, and `\0` is NOT NUL there
    // (NUL is spelled `\x00`). A silent NUL-class or literal digit was the
    // original head-to-head divergence this suite pins.
    inline for (.{ "\\0", "\\1", "\\5", "\\9", "a\\1b", "[\\047]", "[\\0]", "[a\\3]" }) |pat| {
        try std.testing.expectError(ParseError.BadPattern, parse(pat));
    }
    // The supported NUL spelling still yields exactly the NUL byte.
    var pr = try parse("\\x00");
    defer pr.deinit();
    const s = try classOf(&pr);
    try std.testing.expect(s.has(0) and s.count() == 1);
}

test "syntax/escape: unrecognized ASCII-letter escapes are BadPattern (rg parity)" {
    // rg exits 2 with "unrecognized escape sequence" — gist must never turn
    // `\q` into a confident literal-'q' non-match. `\Z` is rust-regex's
    // deliberate omission (end-of-haystack is `\z`), so it errors too.
    inline for (.{ "\\q", "\\e", "\\y", "\\h", "\\V", "\\Z", "\\p", "a\\qb" }) |pat| {
        try std.testing.expectError(ParseError.BadPattern, parse(pat));
    }
}

test "syntax/escape: assertion escapes are invalid inside a class (rg parity)" {
    // rg: "invalid escape sequence found in character class" — `\b` is NOT a
    // literal 'b' (or backspace) inside `[...]`, and the one-sided `\<`/`\>`
    // and haystack anchors are atom-position-only.
    inline for (.{ "[\\b]", "[\\B]", "[\\A]", "[\\z]", "[\\<]", "[\\>]", "[a\\b]" }) |pat| {
        try std.testing.expectError(ParseError.BadPattern, parse(pat));
    }
    // …while byte/class escapes still compose inside a class.
    var pr = try parse("[\\t\\d]");
    defer pr.deinit();
    const s = try classOf(&pr);
    try std.testing.expect(s.has('\t') and s.has('0') and s.has('9') and !s.has('b'));
}

test "syntax/escape: \\A \\z \\< \\> parse to zero-width assertion nodes" {
    // Per-line default: `\A`/`\z` lower to the existing line anchors (the line
    // IS the haystack), `\<`/`\>` to the one-sided word boundaries.
    {
        var pr = try parse("\\A");
        defer pr.deinit();
        try std.testing.expect(pr.node.* == .anchor_start);
    }
    {
        var pr = try parse("\\z");
        defer pr.deinit();
        try std.testing.expect(pr.node.* == .anchor_end);
    }
    {
        var pr = try parse("\\<");
        defer pr.deinit();
        try std.testing.expect(pr.node.* == .word_start);
    }
    {
        var pr = try parse("\\>");
        defer pr.deinit();
        try std.testing.expect(pr.node.* == .word_end);
    }
    // Multiline: the haystack is the whole buffer, so `\A`/`\z` become the
    // distinct buffer anchors (a line boundary is not a buffer edge there).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = syn.Parser{ .src = "\\A", .arena = arena.allocator(), .multiline = true };
    try std.testing.expect((try p.parseAlt()).* == .anchor_buf_start);
    var pz = syn.Parser{ .src = "\\z", .arena = arena.allocator(), .multiline = true };
    try std.testing.expect((try pz.parseAlt()).* == .anchor_buf_end);
}

test "syntax/escape: a trailing backslash is BadPattern, not a crash" {
    try std.testing.expectError(ParseError.BadPattern, parse("a\\"));
    try std.testing.expectError(ParseError.BadPattern, parse("\\"));
}

test "syntax/dot: '.' is every byte but newline" {
    var pr = try parse(".");
    defer pr.deinit();
    const s = try classOf(&pr);
    try std.testing.expect(s.has('a') and s.has(' ') and s.has(0) and s.has(255));
    try std.testing.expect(!s.has('\n'));
    try std.testing.expectEqual(@as(usize, 255), s.count());
}

// ── character classes ────────────────────────────────────────────────────────

test "syntax/class: ranges, multi-range and explicit members" {
    var pr = try parse("[a-f0-9_]");
    defer pr.deinit();
    const s = try classOf(&pr);
    try std.testing.expect(s.has('a') and s.has('f') and !s.has('g'));
    try std.testing.expect(s.has('0') and s.has('9'));
    try std.testing.expect(s.has('_'));
    try std.testing.expectEqual(@as(usize, 6 + 10 + 1), s.count());
}

test "syntax/class: a negated class also excludes newline (line semantics)" {
    var pr = try parse("[^a-z]");
    defer pr.deinit();
    const s = try classOf(&pr);
    try std.testing.expect(!s.has('a') and !s.has('z'));
    try std.testing.expect(s.has('A') and s.has('0') and s.has(' '));
    try std.testing.expect(!s.has('\n')); // negated classes still never cross a line
}

test "syntax/class: '-' is literal at the edges and ']' is literal first" {
    inline for (.{ "[-a]", "[a-]", "[a\\-z]" }) |pat| {
        var pr = try parse(pat);
        defer pr.deinit();
        const s = try classOf(&pr);
        try std.testing.expect(s.has('-') and s.has('a'));
    }
    {
        var pr = try parse("[]a]"); // leading ']' is a member, not a close
        defer pr.deinit();
        const s = try classOf(&pr);
        try std.testing.expect(s.has(']') and s.has('a') and s.count() == 2);
    }
}

test "syntax/class: escapes compose inside a class" {
    var pr = try parse("[\\d.]"); // digits plus a literal dot (escaped class member)
    defer pr.deinit();
    const s = try classOf(&pr);
    try std.testing.expect(s.has('0') and s.has('9') and s.has('.'));
    try std.testing.expect(!s.has('a'));
}

test "syntax/class: unterminated class is BadPattern" {
    try std.testing.expectError(ParseError.BadPattern, parse("[abc"));
    try std.testing.expectError(ParseError.BadPattern, parse("[a-"));
    try std.testing.expectError(ParseError.BadPattern, parse("[")); // bare open
    try std.testing.expectError(ParseError.BadPattern, parse("[^")); // negated, unterminated
}

test "syntax/class: a reversed range [z-a] is rejected (rust-regex parity)" {
    try std.testing.expectError(ParseError.BadPattern, parse("[z-a]"));
    try std.testing.expectError(ParseError.BadPattern, parse("[9-0]"));
    // A degenerate single-byte range [a-a] is valid and matches just 'a'.
    var pr = try parse("[a-a]");
    defer pr.deinit();
    const s = try classOf(&pr);
    try std.testing.expect(s.has('a') and s.count() == 1);
}

// ── counted repetition {n} {n,} {n,m} ───────────────────────────────────────

test "syntax/repeat: an unescaped { must begin a valid count" {
    // The famous one: `interface{}` is not a literal brace — it must error so the
    // engine matches rust-regex (a literal brace is `\{`).
    try std.testing.expectError(ParseError.BadPattern, parse("interface{}"));
    try std.testing.expectError(ParseError.BadPattern, parse("a{")); // unterminated
    try std.testing.expectError(ParseError.BadPattern, parse("a{3")); // no close
    try std.testing.expectError(ParseError.BadPattern, parse("a{b}")); // non-decimal
    try std.testing.expectError(ParseError.BadPattern, parse("a{,3}")); // missing min
    try std.testing.expectError(ParseError.BadPattern, parse("a{2,3,4}")); // junk after m
    try std.testing.expectError(ParseError.BadPattern, parse("{3}")); // repeat w/o atom
    // …but `\{\}` is the literal brace pair, and a stray `}` is itself literal.
    {
        var pr = try parse("interface\\{\\}");
        defer pr.deinit();
        try std.testing.expectEqualStrings("interface{}", try flattenLiteral(&pr));
    }
    {
        var pr = try parse("a}"); // stray '}' ⇒ literal
        defer pr.deinit();
        try std.testing.expectEqualStrings("a}", try flattenLiteral(&pr));
    }
}

test "syntax/repeat: m < n is rejected; bounds above the cap are rejected" {
    try std.testing.expectError(ParseError.BadPattern, parse("a{3,2}"));
    try std.testing.expectError(ParseError.BadPattern, parse("a{1001}")); // > max_repeat
    try std.testing.expectError(ParseError.BadPattern, parse("a{0,1001}"));
    // Exactly the cap is still allowed.
    var pr = try parse("a{1000}");
    defer pr.deinit();
}

test "syntax/repeat: a gigantic count overflows nothing — it is BadPattern" {
    // A naive `v = v*10 + d` accumulator panics on integer overflow in safe
    // builds; the parser must instead reject an out-of-range bound. 20 nines is
    // far past usize anyway, so this is the regression guard for that crash.
    try std.testing.expectError(ParseError.BadPattern, parse("a{" ++ ("9" ** 20) ++ "}"));
    try std.testing.expectError(ParseError.BadPattern, parse("a{2," ++ ("9" ** 25) ++ "}"));
}

test "syntax/repeat: {n} lowers to exactly n mandatory copies" {
    {
        var pr = try parse("a{0}"); // zero copies ⇒ the empty node
        defer pr.deinit();
        try std.testing.expect(pr.node.* == .empty);
    }
    {
        var pr = try parse("a{3}");
        defer pr.deinit();
        try std.testing.expectEqualStrings("aaa", try flattenLiteral(&pr));
    }
    {
        var pr = try parse("ab{3}c"); // the run spans the expansion: a bbb c
        defer pr.deinit();
        try std.testing.expectEqualStrings("abbbc", try flattenLiteral(&pr));
    }
    {
        var pr = try parse("(ab){2}"); // a group repeats whole
        defer pr.deinit();
        try std.testing.expectEqualStrings("abab", try flattenLiteral(&pr));
    }
}

// ── grouping & the malformed-structure surface ───────────────────────────────

test "syntax/group: unbalanced parens and bare operators are BadPattern" {
    try std.testing.expectError(ParseError.BadPattern, parse("(a")); // unclosed group
    try std.testing.expectError(ParseError.BadPattern, parse("a)")); // stray close (trailing)
    try std.testing.expectError(ParseError.BadPattern, parse(")")); // bare close
    try std.testing.expectError(ParseError.BadPattern, parse("(")); // bare open
    try std.testing.expectError(ParseError.BadPattern, parse("*")); // repeat w/o atom
    try std.testing.expectError(ParseError.BadPattern, parse("+abc"));
}

test "syntax/group: an empty alternation branch is the empty node, not an error" {
    // `a|` — the right branch is empty (matches the empty string); rust-regex
    // accepts this, and so must the parser (it lowers to alt(a, empty)).
    var pr = try parse("a|");
    defer pr.deinit();
    try std.testing.expect(pr.node.* == .alt);
    try std.testing.expect(pr.node.alt[1].* == .empty);
}

test "syntax/empty: the empty pattern is the empty node" {
    var pr = try parse("");
    defer pr.deinit();
    try std.testing.expect(pr.node.* == .empty);
}

test "syntax/safety: adversarial patterns parse or BadPattern, never panic/UB" {
    // The parser must terminate on every input with a value or `BadPattern` —
    // reaching the end of the loop is itself the assertion, since a panic, an
    // overflow, or an unterminated recursion would abort the test binary. Covers
    // deep nesting, stacked/empty repeats, half-open classes, lone/odd
    // backslashes, reversed bounds, and the saturating gigantic count.
    const pats = [_][]const u8{
        "",        "(((((((((a)))))))))",
        "a{0}{0}", "[^]",
        "[]",      "\\",
        "((",      "))",
        "a{2,1}",  "[\\d-\\w]",
        "**",      "^*$",
        "a|||b",   "(|)",
        "[a-]",    "[-a]",
        ".{1000}", "(a*)*",
        "[\\x00]", "\\\\\\",
        "{}{}",    "a{999999999999999999999}",
        "[z-a]", "(?:abc)", // `(?` is just '(' then literal '?…'
    };
    for (pats) |p| {
        var pr = parse(p) catch continue; // BadPattern is an acceptable outcome
        pr.deinit();
    }
}

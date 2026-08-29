//! irregex T2 regex *syntax* tests — adversarial, oracle-free unit coverage of
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

/// Parse under explicit engine modes — the `-i` fold and Unicode mode change what
/// a *negated* class means, and only the parser can get that ordering right.
fn parseMode(src: []const u8, caseless: bool, unicode: bool) ParseError!Parsed {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    var p = syn.Parser{ .src = src, .arena = arena.allocator(), .caseless = caseless, .unicode = unicode };
    const n = try p.parseAlt();
    if (p.pos != src.len) return ParseError.BadPattern;
    return .{ .arena = arena, .node = n };
}

/// Is `cp` a member of a one-atom pattern's codepoint class? Accepts either
/// lowering, since an all-ASCII set legitimately stays a byte `class`.
fn holdsCp(pr: *Parsed, cp: u21) !bool {
    return switch (pr.node.*) {
        .uclass => |ranges| for (ranges) |r| {
            if (cp >= r[0] and cp <= r[1]) break true;
        } else false,
        .class => |s| cp < 0x100 and s.has(@intCast(cp)),
        else => error.TestExpectedClass,
    };
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

test "syntax/escape: a bare \\1 is still backreference syntax, at atom position" {
    // A group reference is the one numeric escape a linear-time engine cannot
    // honor, so it stays an error rather than becoming a confident literal.
    // `re` agrees it is a reference here (it raises "invalid group reference");
    // we simply have no groups to point at. `\8`/`\9` are not octal digits, so
    // they are errors in EVERY position, which `re` also reports.
    inline for (.{ "\\1", "\\5", "a\\1b", "\\12", "\\8", "\\9", "[\\8]", "[\\9]" }) |pat| {
        try std.testing.expectError(ParseError.BadPattern, parse(pat));
    }
}

test "syntax/escape: octal — \\0oo at atom, every numeric escape inside a class" {
    // `re`'s rule, which rg refuses outright ("backreferences are not supported",
    // then it points you at PCRE2): a leading `0` or a full three digits commits
    // to octal at atom position, while inside `[…]` all of them do.
    inline for (.{
        .{ "\\0", @as(u8, 0) }, // NUL, no longer only spellable as \x00
        .{ "\\00", 0 },
        .{ "\\000", 0 },
        .{ "\\101", 'A' }, // three digits: 0o101
        .{ "\\377", 0xFF }, // the cap
        .{ "[\\047]", '\'' }, // in-class: 0o47
        .{ "[\\0]", 0 },
        .{ "[\\1]", 1 }, // `re` reads a bare \1 as octal HERE
        .{ "[\\12]", '\n' },
    }) |case| {
        var pr = try parse(case[0]);
        defer pr.deinit();
        const s = try classOf(&pr);
        try std.testing.expect(s.has(case[1]) and s.count() == 1);
    }
    // Past `re`'s cap the value would need a second byte, so it is an error
    // rather than a silent U+0100.
    inline for (.{ "\\400", "\\777", "[\\400]" }) |pat| {
        try std.testing.expectError(ParseError.BadPattern, parse(pat));
    }
}

test "syntax/escape: \\u and \\U, counted and braced" {
    // Counted is `re`'s and rg's alike; braced is rg's. An ASCII value is the
    // same single byte whichever mode reads it.
    inline for (.{
        .{ "\\u0041", @as(u8, 'A') },
        .{ "\\u{41}", 'A' },
        .{ "\\U00000041", 'A' },
        .{ "\\U{41}", 'A' },
        .{ "[\\u0041]", 'A' },
    }) |case| {
        var pr = try parse(case[0]);
        defer pr.deinit();
        const s = try classOf(&pr);
        try std.testing.expect(s.has(case[1]) and s.count() == 1);
    }
    // A short counted run is a typo, not a shorter character; empty braces, a
    // surrogate, and a value past U+10FFFF are all refused — rg's judgments.
    inline for (.{ "\\u00", "\\u{}", "\\uD800", "\\u{110000}", "\\U0041", "\\U{}" }) |pat| {
        try std.testing.expectError(ParseError.BadPattern, parse(pat));
    }
    // Byte mode: a SCALAR spelling is the character's UTF-8 sequence, not a
    // truncation of it, so nothing about it is unrepresentable. Measured against
    // rg, which for `(?-u)\u00e9` matches `é` (0xC3 0xA9) and does not match a
    // raw 0xE9 — disabling Unicode changes what a class, a fold, and a boundary
    // mean; it cannot change what a scalar value IS.
    inline for (.{
        .{ "\\u00ab", "\xc2\xab" },
        .{ "\\u00e9", "\xc3\xa9" },
        .{ "\\u01ff", "\xc7\xbf" },
        .{ "\\U{2603}", "\xe2\x98\x83" },
        .{ "\\x{e9}", "\xc3\xa9" },
        .{ "\\N{SNOWMAN}", "\xe2\x98\x83" },
    }) |case| {
        var pr = try parse(case[0]);
        defer pr.deinit();
        try std.testing.expectEqualStrings(case[1], try flattenLiteral(&pr));
    }
    // …while a BYTE spelling stays the raw byte. That is the whole distinction,
    // and it is rg's line too: `\xNN` and octal are byte syntax, `\x{…}` `\u` `\U`
    // `\N{…}` name characters.
    inline for (.{ .{ "\\xe9", @as(u8, 0xE9) }, .{ "\\351", 0xE9 }, .{ "[\\xe9]", 0xE9 } }) |case| {
        var pr = try parse(case[0]);
        defer pr.deinit();
        const s = try classOf(&pr);
        try std.testing.expect(s.has(case[1]) and s.count() == 1);
    }
    // A byte-mode CLASS holds one byte per member, so a scalar spelling above
    // ASCII names something it cannot express. rg refuses the same patterns
    // (`(?-u)[\u00e9]` is a regex parse error) rather than matching one byte of
    // the sequence, which is the only other option and a wrong answer.
    inline for (.{ "[\\u00e9]", "[\\x{e9}]", "[\\N{SNOWMAN}]" }) |pat| {
        try std.testing.expectError(ParseError.BadPattern, parse(pat));
    }
}

test "syntax/escape: a byte-mode character is one atom, so a quantifier binds it" {
    // `(?-u)é+` must repeat the CHARACTER, not its last byte — rg finds `éé` in
    // `éé` and a byte-at-a-time walk finds `é`. Same for the escape spelling,
    // which is the same atom written differently.
    inline for (.{ "é", "\\u00e9", "\\x{e9}" }) |body| {
        var pr = try parse(body ++ "{2}");
        defer pr.deinit();
        try std.testing.expectEqualStrings("\xc3\xa9\xc3\xa9", try flattenLiteral(&pr));
    }
}

test "syntax/escape: \\u carries a codepoint in Unicode mode, and can bound a range" {
    {
        var pr = try parseMode("\\u00ac", false, true);
        defer pr.deinit();
        try std.testing.expectEqual(@as(u21, 0x00AC), pr.node.uclass[0][0]);
    }
    { // the range machinery already existed for `\x{…}`; `\u` reaches it now
        var pr = try parseMode("[\\u00ab-\\u00bb]", false, true);
        defer pr.deinit();
        try std.testing.expect(try holdsCp(&pr, 0x00AB));
        try std.testing.expect(try holdsCp(&pr, 0x00B0));
        try std.testing.expect(try holdsCp(&pr, 0x00BB));
        try std.testing.expect(!try holdsCp(&pr, 0x00AA));
        try std.testing.expect(!try holdsCp(&pr, 0x00BC));
    }
    { // octal reaches Unicode mode as a codepoint too
        var pr = try parseMode("\\377", false, true);
        defer pr.deinit();
        try std.testing.expect(try holdsCp(&pr, 0xFF));
    }
}

test "syntax/escape: unrecognized ASCII-letter escapes are BadPattern (rg parity)" {
    // rg exits 2 with "unrecognized escape sequence" — this parser must never
    // turn `\q` into a confident literal-'q' non-match. `\p` is here because a
    // bare `\p` needs Unicode mode; `\Z` is NOT, since this arm reads it as
    // `re`'s absolute end (see the `\Z` test below).
    inline for (.{ "\\q", "\\e", "\\y", "\\h", "\\V", "\\p", "a\\qb" }) |pat| {
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
        try std.testing.expectEqual(syn.Word.start, pr.node.word);
    }
    {
        var pr = try parse("\\>");
        defer pr.deinit();
        try std.testing.expectEqual(syn.Word.end, pr.node.word);
    }
}

test "the braced word assertions, and the repetition they must not swallow" {
    // `\b{start}`/`\b{end}` are rust-regex's spellings of `\<`/`\>` — the same
    // mask, so nothing downstream can tell them apart. The halves are new: each
    // constrains one side and says nothing about the other.
    for ([_]struct { []const u8, syn.Word }{
        .{ "\\b{start}", .start },
        .{ "\\b{end}", .end },
        .{ "\\b{start-half}", .start_half },
        .{ "\\b{end-half}", .end_half },
    }) |case| {
        var pr = try parse(case[0]);
        defer pr.deinit();
        try std.testing.expectEqual(case[1], pr.node.word);
    }
    // `\b{2}` is `\b` repeated twice, not an assertion named "2". A brace whose
    // contents aren't a name is handed back to the repetition parser untouched,
    // which is the only reason the two syntaxes can share the character.
    {
        var pr = try parse("\\b{2}");
        defer pr.deinit();
        try std.testing.expect(pr.node.* == .concat);
    }
    // Every other shape is an error, exactly as rg reports it: an unknown name,
    // a name that never closes, and a brace holding neither a name nor a count
    // (the repetition parser rejects that last one, having been handed it back).
    for ([_][]const u8{ "\\b{foo}", "\\b{-half}", "\\b{start", "\\b{" }) |bad|
        try std.testing.expectError(ParseError.BadPattern, parse(bad));
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

test "syntax/class: a bare '[' opens a NESTED class, in both modes" {
    // rust-regex's class *set* grammar, which this engine had been missing: an
    // unescaped `[` inside a class is not a member, it recurses. So `[[x]` is
    // unclosed (rg: "unclosed character class") and the literal wants `[\[x]`.
    inline for (.{ false, true }) |uni| {
        try std.testing.expectError(ParseError.BadPattern, parseMode("[[x]", false, uni));
        var pr = try parseMode("[[x]y]", false, uni); // {x} ∪ {y}
        defer pr.deinit();
        try std.testing.expect(try holdsCp(&pr, 'x') and try holdsCp(&pr, 'y'));
        try std.testing.expect(!try holdsCp(&pr, '['));
        var lit = try parseMode("[\\[x]", false, uni);
        defer lit.deinit();
        try std.testing.expect(try holdsCp(&lit, '[') and try holdsCp(&lit, 'x'));
    }
}

test "syntax/class: && -- ~~ are set operators, left-associative, equal precedence" {
    // The operators swift's `simple_identifier` is spelled with. Each case is the
    // hand-computed set AND was diffed against rg 14 (`.local/classdiff.sh`).
    const Case = struct { pat: []const u8, in: []const u21, out: []const u21 };
    const cases = [_]Case{
        .{ .pat = "[a-e&&b-d]", .in = &.{ 'b', 'c', 'd' }, .out = &.{ 'a', 'e' } },
        .{ .pat = "[a-e--c]", .in = &.{ 'a', 'b', 'd', 'e' }, .out = &.{'c'} },
        .{ .pat = "[a-e~~c-g]", .in = &.{ 'a', 'b', 'f', 'g' }, .out = &.{ 'c', 'd', 'e' } },
        // Left-associative and equal precedence: (a-e ∩ b-d) − c = {b,d}. Under
        // rust-regex's documented `&&` > `--` precedence this would be a-e ∩ (b-d − c).
        .{ .pat = "[a-e&&b-d--c]", .in = &.{ 'b', 'd' }, .out = &.{ 'a', 'c', 'e' } },
        // …and the other order proves it is the FOLD, not the precedence: (a-e − b-d) ∩ c = ∅.
        .{ .pat = "[a-e--b-d&&c]", .in = &.{}, .out = &.{ 'a', 'c', 'e' } },
        .{ .pat = "[[a-e]&&[^c]]", .in = &.{ 'a', 'b', 'd' }, .out = &.{'c'} },
        .{ .pat = "[\\w&&[^_]]", .in = &.{ 'a', '7' }, .out = &.{'_'} },
        .{ .pat = "[_[:alpha:]&&[^0-9]]", .in = &.{ '_', 'Q' }, .out = &.{'4'} },
    };
    inline for (.{ false, true }) |uni| for (cases) |c| {
        var pr = try parseMode(c.pat, false, uni);
        defer pr.deinit();
        for (c.in) |cp| try std.testing.expect(try holdsCp(&pr, cp));
        for (c.out) |cp| try std.testing.expect(!try holdsCp(&pr, cp));
    };
}

test "syntax/class: \\p{Emoji} and the PropertyAliases short names resolve" {
    // Before this, an unknown `\p{...}` was BadPattern — and swift's identifier
    // body is spelled with three UTS #51 names plus `&&`, so the whole terminal
    // was declined and every identifier byte in a swift file surfaced as a stray.
    inline for (.{ "\\p{Emoji}", "\\p{ExtPict}", "\\p{EMod}", "\\p{Alpha}", "\\p{XIDS}", "\\p{WSpace}" }) |pat| {
        var pr = try parseMode(pat, false, true);
        defer pr.deinit();
    }
    { // 🍎 is Emoji; 'a' is not. An alias that resolved to the empty set would
        // pass a "does it parse" test and fail this one.
        var pr = try parseMode("\\p{Emoji}", false, true);
        defer pr.deinit();
        try std.testing.expect(try holdsCp(&pr, 0x1F34E) and !try holdsCp(&pr, 'a'));
    }
    { // `\p{XIDS}` must be `\p{XID_Start}`, not a near-miss.
        var pr = try parseMode("\\p{XIDS}", false, true);
        defer pr.deinit();
        try std.testing.expect(try holdsCp(&pr, 'F') and !try holdsCp(&pr, '4'));
    }
    { // swift's own body, whole: an ASCII letter is excluded by the `&&`, 🍎 is not.
        var pr = try parseMode("[\\p{XID_Continue}\\p{Emoji}\\x{FE0F}\\p{EMod}&&[^\\x{0}-\\x{7F}]]", false, true);
        defer pr.deinit();
        try std.testing.expect(try holdsCp(&pr, 0x1F34E) and !try holdsCp(&pr, 'F'));
    }
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

test "syntax/class: a shorthand cannot bound a range (rg parity)" {
    // rg: "invalid range boundary, must be a literal" — on EITHER side, in both
    // engine modes. `[a-\d]` silently meaning `a`,`-`,`\d` would be a lie.
    inline for (.{ "[a-\\d]", "[A-\\d]", "[\\d-a]", "[a-\\w]", "[\\w-\\d]", "[a-\\p{L}]", "[\\p{L}-a]" }) |pat| {
        try std.testing.expectError(ParseError.BadPattern, parseMode(pat, false, false));
        try std.testing.expectError(ParseError.BadPattern, parseMode(pat, false, true));
    }
    // A TRAILING dash after a shorthand stays a literal member, as rg keeps it.
    inline for (.{ false, true }) |uni| {
        var pr = try parseMode("[\\d-]", false, uni);
        defer pr.deinit();
        try std.testing.expect(try holdsCp(&pr, '-') and try holdsCp(&pr, '7'));
        try std.testing.expect(!try holdsCp(&pr, 'a'));
    }
}

test "syntax/class: a literal escape DOES bound a range" {
    // `\t`-`\r` is 0x09–0x0D, so the interior bytes 0x0B/0x0C are members — the
    // set is a RANGE, not the three literals `\t`, `-`, `\r`.
    inline for (.{ false, true }) |uni| {
        var pr = try parseMode("[\\t-\\r]", false, uni);
        defer pr.deinit();
        for ([_]u21{ 0x09, 0x0A, 0x0B, 0x0C, 0x0D }) |cp| try std.testing.expect(try holdsCp(&pr, cp));
        try std.testing.expect(!try holdsCp(&pr, '-')); // the dash was the operator
        try std.testing.expect(!try holdsCp(&pr, 0x0E));
    }
}

test "syntax/class: -i complements the FOLDED members (rg parity)" {
    // Folding after the complement would re-admit the excluded letter's twin:
    // `[^k]` keeps `K`, and folding that set hands `k` straight back. rg's
    // `(?i)[^k]` rejects both cases, so the fold must precede the negation.
    inline for (.{ "[^k]", "[^k-k]", "[^[:lower:]x]" }) |pat| {
        var pr = try parseMode(pat, true, false);
        defer pr.deinit();
        const s = try classOf(&pr);
        try std.testing.expect(!s.has('k') and !s.has('K'));
    }
    // Unicode mode excludes the whole fold orbit — `k`, `K`, and KELVIN SIGN.
    var pr = try parseMode("[^k]", true, true);
    defer pr.deinit();
    for ([_]u21{ 'k', 'K', 0x212A }) |cp| try std.testing.expect(!try holdsCp(&pr, cp));
    try std.testing.expect(try holdsCp(&pr, 'a') and try holdsCp(&pr, 'A'));
    // The inner-negated POSIX spelling takes the same route.
    var ip = try parseMode("[[:^lower:]]", true, false);
    defer ip.deinit();
    const is = try classOf(&ip);
    try std.testing.expect(!is.has('a') and !is.has('A') and is.has('0'));
}

test "syntax/class: [[:^name:]] complements in the mode's own universe" {
    // Unicode mode complements over the WHOLE scalar space, so a CJK codepoint is
    // a non-lowercase character (rg emits 日 for `[[:^lower:]]`). Complementing
    // the 256-byte set instead would silently stop at U+00FF.
    var uni = try parseMode("[[:^lower:]]", false, true);
    defer uni.deinit();
    for ([_]u21{ 'A', '0', ' ', 0x65E5, 0x10FFFF }) |cp| try std.testing.expect(try holdsCp(&uni, cp));
    try std.testing.expect(!try holdsCp(&uni, 'a') and !try holdsCp(&uni, 'z'));
    try std.testing.expect(!try holdsCp(&uni, '\n')); // still never crosses a line

    // `(?-u)` is the byte engine, where the byte universe IS the right one.
    var byt = try parseMode("[[:^lower:]]", false, false);
    defer byt.deinit();
    const s = try classOf(&byt);
    try std.testing.expect(s.has('A') and s.has(0xFF) and !s.has('a') and !s.has('\n'));
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

test "syntax/flags: (?i:…) folds its own body and leaves the rest alone" {
    var p = try parse("(?i:k)k");
    defer p.deinit();
    // `k` under the fold picks up `K`; the `k` after the group must not.
    const kids = p.node.concat;
    try std.testing.expect(kids[0].class.has('k') and kids[0].class.has('K'));
    try std.testing.expect(kids[1].class.has('k') and !kids[1].class.has('K'));
}

test "syntax/flags: (?u:…) turns Unicode on for one group only" {
    var p = try parse("(?u:\\x{00ac})");
    defer p.deinit();
    // A non-ASCII scalar can only be carried by a `uclass`, which is what the
    // scoped flag bought - byte mode would have refused the codepoint.
    try std.testing.expectEqual(@as(u21, 0x00ac), p.node.uclass[0][0]);
}

test "syntax/flags: the flags this engine spells differently refuse" {
    // `m` is whole-buffer here and line-anchored in JavaScript, and a bare
    // `(?i)` scopes to the enclosing group - each is a wrong answer rather than
    // a missing one, so none of them parse.
    for ([_][]const u8{ "(?m:a)", "(?i)a", "(?-i:a)" }) |src| {
        try std.testing.expectError(ParseError.BadPattern, parse(src));
    }
}

/// Parse under verbose mode — `(?x)` / Python's `re.VERBOSE`.
fn parseVerbose(src: []const u8) ParseError!Parsed {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    var p = syn.Parser{ .src = src, .arena = arena.allocator(), .verbose = true };
    const n = try p.parseAlt();
    if (p.pos != src.len) return ParseError.BadPattern;
    return .{ .arena = arena, .node = n };
}

test "syntax/verbose: trivia between tokens vanishes, trivia inside one does not" {
    const t = std.testing;
    // Whitespace and `#` comments between tokens leave a two-atom concat — the
    // same tree `ab` produces. Every byte CPython skips is covered.
    for ([_][]const u8{
        "a b",         "a\tb",
        "a\nb",        "a\rb",
        "a\x0bb",      "a\x0cb",
        "a   \t\n  b", "a # the b follows\nb",
        "a#tight\nb",  "#lead\na b # trail",
        "a(?#why)b",   " a b ",
    }) |src| {
        var pr = try parseVerbose(src);
        defer pr.deinit();
        try t.expect(pr.node.* == .concat);
        try t.expect(pr.node.concat[0].class.has('a'));
        try t.expect(pr.node.concat[1].class.has('b'));
    }

    // Inside a class the space is a member, and an escaped one is a literal —
    // both are `re`'s reading too, and both would be silently deleted by a
    // pre-pass that stripped whitespace from the source text.
    var cls = try parseVerbose("[ a]");
    defer cls.deinit();
    try t.expect(cls.node.class.has(' ') and cls.node.class.has('a'));
    var esc = try parseVerbose("a\\ b");
    defer esc.deinit();
    try t.expect(esc.node.concat[0].concat[1].class.has(' '));
}

test "syntax/verbose: a detached quantifier still binds its atom" {
    const t = std.testing;
    // `a *` is a star over `a`, not a literal star — the quantifier loop skips
    // trivia at its own top, exactly where CPython's does.
    for ([_][]const u8{ "a *", "a  \t*", "a # note\n*", "a(?#note)*" }) |src| {
        var pr = try parseVerbose(src);
        defer pr.deinit();
        try t.expect(pr.node.* == .star);
        try t.expect(!pr.node.star.lazy);
    }
    // The laziness `?` is read WITHOUT skipping first, so `a *?` is one lazy
    // star and `a{1, 2}` is not a bound at all (it opens no valid one, which is
    // rust-regex's refusal rather than `re`'s literal reading).
    var lazy = try parseVerbose("a *?");
    defer lazy.deinit();
    try t.expect(lazy.node.star.lazy);
    try t.expectError(ParseError.BadPattern, parseVerbose("a{1, 2}"));
}

test "syntax/verbose: an inline comment is trivia in every mode" {
    const t = std.testing;
    // `(?#…)` is not a verbose feature in `re` either, so it must work with the
    // mode off — and an unterminated one is an error, not a comment that eats
    // the rest of the pattern.
    var plain = try parse("a(?#why)b");
    defer plain.deinit();
    try t.expect(plain.node.concat[0].class.has('a') and plain.node.concat[1].class.has('b'));
    var quant = try parse("a(?#why)*");
    defer quant.deinit();
    try t.expect(quant.node.* == .star);
    try t.expectError(ParseError.BadPattern, parse("a(?#never closed"));
    // A `(` that only starts like one is left to the group parser.
    try t.expectError(ParseError.BadPattern, parse("a(?#"));
}

test "syntax/verbose: the scoped form holds for its body and nothing after it" {
    const t = std.testing;
    var pr = try parse("(?x: a b )c d");
    defer pr.deinit();
    // Body: `ab`. After the group verbose is off again, so ` `, `c`, ` `, `d`
    // are four atoms — five children in all under the left fold.
    var n = pr.node;
    var atoms: usize = 0;
    while (n.* == .concat) : (n = n.concat[0]) atoms += 1;
    try t.expectEqual(@as(usize, 4), atoms);
    // And verbose can be turned back off inside a verbose region.
    var off = try parseVerbose("a (?-x:b c) d");
    defer off.deinit();
    try t.expect(off.node.* == .concat);
}

test "syntax/verbose: \\Z is Python's absolute end, not an unknown escape" {
    const t = std.testing;
    var pr = try parse("a\\Z");
    defer pr.deinit();
    // Per-line default: the haystack IS the line, so `\Z` and `\z` both resolve
    // to the same end anchor `$` does.
    try t.expect(pr.node.concat[1].* == .anchor_end);
    // Inside a class it stays an invalid escape, as `\z` and `\A` do.
    try t.expectError(ParseError.BadPattern, parse("[\\Z]"));
}

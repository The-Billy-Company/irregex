//! irregex — what a backslash escape denotes, plus the POSIX class tables it is
//! defined in terms of.
//!
//! `\d` and `[[:digit:]]` are the same byte set spelled two ways, so the table
//! and the escape decoder live together: `parseEscape` reads `posix_classes`
//! directly, and `bracket.zig` reaches back here for both. Every function is a
//! *terminal* decode — it consumes bytes and answers with a set, a byte, or a
//! codepoint, and never re-enters the grammar. That is what keeps this file below
//! the recursive descent rather than tangled into it.
//!
//! Two families live here. **Class escapes** (`\d \w \s` and their negations)
//! answer with a set. **By-value escapes** (`\xNN`, `\x{H..H}`, `\uHHHH`,
//! `\u{H..H}`, `\UHHHHHHHH`, `\U{H..H}`, octal `\0oo` / `\ooo`) answer with one
//! character, and `valueCp` is the single decode for all four positions the
//! grammar reaches them from — atom and class body, byte mode and Unicode mode.
//! Collapsing those four into one is the point: a character's value cannot
//! depend on where it was written, and the previous shape (a `\x`-shaped prong
//! repeated at each site) is why `\u` was missing from all four at once.

const std = @import("std");
const names = @import("../unicode/names.zig");
const tree = @import("tree.zig");
const Parser = @import("parser.zig").Parser;

const ByteSet = tree.ByteSet;
const ParseError = tree.ParseError;

/// Each POSIX class's ASCII members as inclusive byte ranges (rg's `(?-u)`
/// byte sets; singletons are lo==hi — `\t`–`\r` is the contiguous whitespace
/// run `\t \n \v \f \r`).
const posix_classes = std.StaticStringMap([]const [2]u8).initComptime(.{
    .{ "alnum", &[_][2]u8{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ 'a', 'z' } } },
    .{ "alpha", &[_][2]u8{ .{ 'A', 'Z' }, .{ 'a', 'z' } } },
    .{ "ascii", &[_][2]u8{.{ 0, 0x7F }} },
    .{ "blank", &[_][2]u8{ .{ '\t', '\t' }, .{ ' ', ' ' } } },
    .{ "cntrl", &[_][2]u8{ .{ 0, 0x1F }, .{ 0x7F, 0x7F } } },
    .{ "digit", &[_][2]u8{.{ '0', '9' }} },
    .{ "graph", &[_][2]u8{.{ 0x21, 0x7E }} },
    .{ "lower", &[_][2]u8{.{ 'a', 'z' }} },
    .{ "print", &[_][2]u8{.{ 0x20, 0x7E }} },
    .{ "punct", &[_][2]u8{ .{ 0x21, 0x2F }, .{ 0x3A, 0x40 }, .{ 0x5B, 0x60 }, .{ 0x7B, 0x7E } } },
    .{ "space", &[_][2]u8{ .{ '\t', '\r' }, .{ ' ', ' ' } } },
    .{ "upper", &[_][2]u8{.{ 'A', 'Z' }} },
    .{ "word", &[_][2]u8{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ 'a', 'z' }, .{ '_', '_' } } },
    .{ "xdigit", &[_][2]u8{ .{ '0', '9' }, .{ 'A', 'F' }, .{ 'a', 'f' } } },
});

/// Fill `s` with a POSIX class's ASCII members (rg's `(?-u)` byte sets).
/// Returns false for an unknown name so the caller raises BadPattern.
pub fn fillPosix(s: *ByteSet, name: []const u8) bool {
    const ranges = posix_classes.get(name) orelse return false;
    for (ranges) |r| s.setRange(r[0], r[1]);
    return true;
}

/// The control byte a single-letter escape denotes (`\t \n \r \f \v \a`) —
/// the one decode shared by atom position (`parseEscape`) and class bodies
/// (`readClassAtom`), whose value is byte == codepoint in both modes.
pub fn ctrlByte(e: u8) u8 {
    return switch (e) {
        't' => '\t',
        'n' => '\n',
        'r' => '\r',
        'f' => 0x0C,
        'v' => 0x0B,
        else => 0x07, // 'a'
    };
}

/// Scan the digits of a by-value escape (the introducer already consumed):
/// exactly `exact` hex digits, or a braced run `{H..H}`. `exact` is what the
/// spelling promises — 2 for `\xNN`, 4 for `\uHHHH`, 8 for `\UHHHHHHHH` — and a
/// short run is BadPattern rather than a shorter character, because `\u00` is a
/// typo and reading it as U+0000 would match something the author never wrote.
/// `mid_cap` rejects a *braced* value the moment it exceeds the cap, which is
/// what guards u32 overflow on an arbitrarily long run.
fn hexScan(p: *Parser, comptime exact: usize, comptime mid_cap: ?u32) ParseError!u32 {
    var val: u32 = 0;
    if (p.eat('{')) {
        var got = false;
        while (p.peek()) |h| : (got = true) {
            if (h == '}') break;
            val = val * 16 + (std.fmt.charToDigit(h, 16) catch return ParseError.BadPattern);
            if (mid_cap) |cap| if (val > cap) return ParseError.BadPattern;
            _ = p.take();
        }
        if (!got or !p.eat('}')) return ParseError.BadPattern;
    } else {
        for (0..exact) |_| {
            const h = p.peek() orelse return ParseError.BadPattern;
            val = val * 16 + (std.fmt.charToDigit(h, 16) catch return ParseError.BadPattern);
            _ = p.take();
        }
    }
    return val;
}

/// The largest value an octal escape may denote (`re`'s cap, and the largest a
/// single byte holds — `\400` is an error on both sides, not U+0100).
const octal_max = 0o377;

/// What a spelling PROMISES about its width. Irrelevant in Unicode mode, where
/// every atom is a scalar value; under `(?-u)` it is the whole question, and rg
/// draws the line in the same place:
///
///   * `.byte` — a bare `\xNN` or an octal escape. Neither can denote more than
///     0xFF, and both are byte syntax, so `(?-u)\xe9` is the raw byte 0xE9.
///   * `.scalar` — every other spelling (`\x{…}`, `\u`, `\U`, braced or counted,
///     and `\N{…}`). It names a CHARACTER, so under `(?-u)` it is that
///     character's UTF-8 sequence rather than a truncation of it: `(?-u)\u00e9`
///     matches the two bytes 0xC3 0xA9, exactly as `(?-u)é` does. Disabling
///     Unicode changes what a CLASS, a fold, and a boundary mean; it cannot
///     change what a scalar value IS.
pub const Width = enum { byte, scalar };

pub const Value = struct { cp: u21, width: Width };

/// Decode `\N{NAME}` — a character named rather than numbered (the `N` already
/// consumed). The name goes to the Unicode database verbatim; an unknown one is
/// BadPattern, because the alternative is matching some *other* character.
///
/// This is the one escape neither incumbent can be deferred to: rg refuses it
/// ("unrecognized escape sequence"), and `re` answers it only because CPython
/// carries `unicodedata`. See `unicode/names.zig` for what is stored and what is
/// derived.
fn nameCp(p: *Parser) ParseError!u32 {
    if (!p.eat('{')) return ParseError.BadPattern;
    const start = p.pos;
    while (p.peek()) |c| {
        if (c == '}') break;
        _ = p.take();
    }
    const raw = p.src[start..p.pos];
    if (!p.eat('}')) return ParseError.BadPattern; // unterminated
    return names.lookup(raw) orelse ParseError.BadPattern;
}

/// Scan an octal escape, `first` being the already-consumed leading digit: up to
/// three octal digits total. Answers null when these bytes are not an octal
/// escape after all, leaving `p` where it started so the caller can raise the
/// error that fits its position.
///
/// `in_class` is the whole disagreement between the two positions, and it is
/// `re`'s, not ours: inside `[…]` every numeric escape is octal (`[\1]` is
/// U+0001), while at atom position `\1` and `\12` are *group references* — which
/// a linear-time engine has no way to honor — so only a leading `0` or a full
/// three digits commits to octal there.
fn octalScan(p: *Parser, first: u8, in_class: bool) ?u32 {
    if (first > '7') return null; // `\8`/`\9` are not octal at all
    const save = p.pos;
    var val: u32 = first - '0';
    var digits: usize = 1;
    while (digits < 3) : (digits += 1) {
        const d = p.peek() orelse break;
        if (d < '0' or d > '7') break;
        val = val * 8 + (d - '0');
        _ = p.take();
    }
    if (!in_class and first != '0' and digits < 3) {
        p.pos = save; // a backreference, not a character
        return null;
    }
    return val;
}

/// Decode an escape that denotes ONE character: `\xNN`, `\x{H..H}`, `\uHHHH`,
/// `\u{H..H}`, `\UHHHHHHHH`, `\U{H..H}`, the octal `\0oo` / `\ooo`, and the named
/// `\N{NAME}`. `e` is the already-consumed introducer.
///
/// One decode for all four positions the grammar reaches it from — atom and
/// class body, byte mode and Unicode mode — because what a character's *value*
/// is cannot depend on where it was written. The positions differ in exactly two
/// ways, and both are visible here: `in_class` (above), and `Width`, which says
/// what the caller may do with the answer under `(?-u)`. Surrogates and values
/// past U+10FFFF are BadPattern, matching rg — this engine emits well-formed
/// UTF-8 or nothing.
///
/// The counted `\u`/`\U` spellings are `re`'s and rg's alike; the braced ones are
/// rg's alone; octal is `re`'s alone (rg reports it as "backreferences are not
/// supported" and points you at PCRE2). Accepting all of them is additive: every
/// form rg *accepts* keeps rg's meaning, and the forms only `re` accepts are ones
/// rg refuses to compile, so no pattern that works today reads differently now.
pub fn value(p: *Parser, e: u8, in_class: bool) ParseError!Value {
    var width: Width = .scalar;
    const val: u32 = switch (e) {
        // The only spelling whose width depends on how it was written: bare
        // `\xNN` names a byte, braced `\x{…}` names a scalar value.
        'x' => blk: {
            if (p.peek() != '{') width = .byte;
            break :blk try hexScan(p, 2, 0x10FFFF);
        },
        'u' => try hexScan(p, 4, 0x10FFFF),
        'U' => try hexScan(p, 8, 0x10FFFF),
        'N' => try nameCp(p),
        // Never declines: a numeric escape this arm cannot read as a character
        // is an error, not a literal digit.
        '0'...'9' => blk: {
            const v = octalScan(p, e, in_class) orelse return ParseError.BadPattern;
            if (v > octal_max) return ParseError.BadPattern;
            width = .byte;
            break :blk v;
        },
        else => unreachable, // callers switch on the same prongs
    };
    if (val > 0x10FFFF or (val >= 0xD800 and val <= 0xDFFF)) return ParseError.BadPattern;
    return .{ .cp = @intCast(val), .width = width };
}

/// The same decode where the width cannot matter — Unicode mode, whose atoms are
/// scalar values whichever way they were spelled.
pub fn valueCp(p: *Parser, e: u8, in_class: bool) ParseError!u21 {
    return (try value(p, e, in_class)).cp;
}

pub fn parseEscape(p: *Parser, in_class: bool) ParseError!ByteSet {
    const e = if (p.pos < p.src.len) p.take() else return ParseError.BadPattern;
    var s = ByteSet{};
    // The uppercase form of each class is its lowercase set, negated.
    switch (e) {
        // `\d \w \s` are byte-for-byte the POSIX `digit`/`word`/`space` sets.
        'd', 'D', 'w', 'W', 's', 'S' => {
            _ = fillPosix(&s, switch (std.ascii.toLower(e)) {
                'd' => "digit",
                'w' => "word",
                else => "space",
            });
            if (std.ascii.isUpper(e)) s.negate();
        },
        't', 'n', 'r', 'f', 'v', 'a' => s.set(ctrlByte(e)),
        // The by-value family inside a byte-mode `[…]`. A byte class holds single
        // bytes, so a spelling that names a character above ASCII names something
        // this set cannot express — and rg refuses the same pattern outright
        // (`(?-u)[\u00e9]` is a parse error there) rather than matching one byte
        // of the sequence, which is the only other option and a wrong answer.
        // `\1`/`\12` at atom position stay BadPattern (backreference syntax, which
        // this engine has no way to honor), while inside `[…]` they are octal —
        // `value` owns that distinction so every decode site reads it from one
        // place.
        'x', 'u', 'U', 'N', '0'...'9' => {
            const v = try value(p, e, in_class);
            if (v.width == .scalar and v.cp > 0x7F) return ParseError.BadPattern;
            s.set(@intCast(v.cp)); // ≤ 0xFF: a `.byte` spelling cannot exceed it
        },
        // `\<`/`\>` reach here only from inside a class (atom position is
        // intercepted in `parseAtom`): an assertion escape is invalid in a
        // class — rg exits 2, so a silent literal `<`/`>` would be a lie.
        '<', '>' => return ParseError.BadPattern,
        else => {
            // Any OTHER escaped ASCII letter is unrecognized (`\q`, `\e`,
            // `\h`, …) — rg exits 2 ("unrecognized escape sequence"),
            // and this also catches the assertion letters `b B A z Z` inside a
            // class (atom position intercepts them first). Escaped
            // punctuation / non-alphanumeric bytes stay literal (rg allows
            // `\-`, `\_`, `\.`, `\/`, `\ `, …).
            if (std.ascii.isAlphabetic(e)) return ParseError.BadPattern;
            s.set(e);
        },
    }
    return s;
}

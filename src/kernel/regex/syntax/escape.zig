//! gist — what a backslash escape denotes, plus the POSIX class tables it is
//! defined in terms of.
//!
//! `\d` and `[[:digit:]]` are the same byte set spelled two ways, so the table
//! and the escape decoder live together: `parseEscape` reads `posix_classes`
//! directly, and `bracket.zig` reaches back here for both. Every function is a
//! *terminal* decode — it consumes bytes and answers with a set, a byte, or a
//! codepoint, and never re-enters the grammar. That is what keeps this file below
//! the recursive descent rather than tangled into it.

const std = @import("std");
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

/// Scan the digits of a `\x` escape (the `x` already consumed): two hex
/// digits `\xNN`, or a braced run `\x{H..H}`. `mid_cap`, when set, rejects a
/// braced value the moment it exceeds the cap (guarding u32 overflow on long
/// runs); the caller applies its own final range check either way.
fn hexScan(p: *Parser, comptime mid_cap: ?u32) ParseError!u32 {
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
        for (0..2) |_| {
            const h = p.peek() orelse return ParseError.BadPattern;
            val = val * 16 + (std.fmt.charToDigit(h, 16) catch return ParseError.BadPattern);
            _ = p.take();
        }
    }
    return val;
}

/// Decode a `\x` escape as a Unicode codepoint (the `x` already consumed):
/// `\xNN` or `\x{H..H}`. In Unicode mode `\xNN` is codepoint U+00NN (encoded as
/// UTF-8), not the raw byte. Rejects surrogates and values past U+10FFFF.
pub fn hexCp(p: *Parser) ParseError!u21 {
    const val = try hexScan(p, 0x10FFFF);
    if (val > 0x10FFFF or (val >= 0xD800 and val <= 0xDFFF)) return ParseError.BadPattern;
    return @intCast(val);
}

/// Decode a `\x` escape at the current position (the `x` already consumed):
/// two hex digits `\xNN`, or a braced codepoint `\x{H..H}`. gist is a byte
/// engine, so a value > 0xFF is BadPattern (rg's `(?-u)` byte mode).
fn hexByte(p: *Parser) ParseError!u8 {
    const val = try hexScan(p, null);
    if (val > 0xFF) return ParseError.BadPattern;
    return @intCast(val);
}

pub fn parseEscape(p: *Parser) ParseError!ByteSet {
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
        'x' => s.set(try hexByte(p)), // \xNN or \x{H..H}
        // `\0`–`\9` are backreference syntax — unsupported in a linear-time
        // engine and rejected by rg too ("backreferences are not supported",
        // exit 2), in atom position AND inside `[...]`. NUL is spelled `\x00`.
        '0'...'9' => return ParseError.BadPattern,
        // `\<`/`\>` reach here only from inside a class (atom position is
        // intercepted in `parseAtom`): an assertion escape is invalid in a
        // class — rg exits 2, so a silent literal `<`/`>` would be a lie.
        '<', '>' => return ParseError.BadPattern,
        else => {
            // Any OTHER escaped ASCII letter is unrecognized (`\q`, `\e`,
            // `\Z`, `\h`, …) — rg exits 2 ("unrecognized escape sequence"),
            // and this also catches the assertion letters `b B A z` inside a
            // class (atom position intercepts them first). Escaped
            // punctuation / non-alphanumeric bytes stay literal (rg allows
            // `\-`, `\_`, `\.`, `\/`, `\ `, …).
            if (std.ascii.isAlphabetic(e)) return ParseError.BadPattern;
            s.set(e);
        },
    }
    return s;
}

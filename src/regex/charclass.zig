//! gist — regex character-class & escape sub-grammar: the `[...]` / `[^...]`
//! bracket parser, POSIX bracket classes `[[:alpha:]]`, and every escape that
//! lowers to a byte set (`\d \w \s \xNN \x{H..H}` + escaped punctuation). Split
//! from `syntax.zig` (the structural alt/concat/repeat/atom parser), which drives
//! these as free functions over its own `Parser` — atom position hands `[` to
//! `parseClass` and a class-producing `\` to `parseEscape`. The zero-width
//! assertion escapes (`\b \B \< \> \A \z`) stay in `syntax.parseAtom`: they
//! lower to nodes, not byte sets, and inside a class each is BadPattern (rg's
//! "invalid escape sequence found in character class") — enforced below.

const std = @import("std");
const syntax = @import("syntax.zig");
const ByteSet = syntax.ByteSet;
const Node = syntax.Node;
const Parser = syntax.Parser;
const ParseError = syntax.ParseError;

pub fn parseEscape(p: *Parser) ParseError!ByteSet {
    const e = if (p.pos < p.src.len) p.take() else return ParseError.BadPattern;
    var s = ByteSet{};
    // The uppercase form of each class is its lowercase set, negated.
    switch (e) {
        'd', 'D' => {
            s.setRange('0', '9');
            if (e == 'D') s.negate();
        },
        'w', 'W' => {
            s.setRange('0', '9');
            s.setRange('A', 'Z');
            s.setRange('a', 'z');
            s.set('_');
            if (e == 'W') s.negate();
        },
        's', 'S' => {
            for ([_]u8{ '\t', '\n', 0x0B, 0x0C, '\r', ' ' }) |b| s.set(b);
            if (e == 'S') s.negate();
        },
        't' => s.set('\t'),
        'n' => s.set('\n'),
        'r' => s.set('\r'),
        'f' => s.set(0x0C),
        'v' => s.set(0x0B),
        'a' => s.set(0x07),
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

/// Decode a `\x` escape at the current position (the `x` already consumed):
/// two hex digits `\xNN`, or a braced codepoint `\x{H..H}`. gist is a byte
/// engine, so a value > 0xFF is BadPattern (rg's `(?-u)` byte mode).
fn hexByte(p: *Parser) ParseError!u8 {
    var val: u32 = 0;
    if (p.peek() == '{') {
        _ = p.take();
        var got = false;
        while (p.peek()) |h| : (got = true) {
            if (h == '}') break;
            val = val * 16 + @as(u32, hexVal(h) orelse return ParseError.BadPattern);
            _ = p.take();
        }
        if (!got or p.peek() != '}') return ParseError.BadPattern;
        _ = p.take();
    } else {
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            const h = p.peek() orelse return ParseError.BadPattern;
            val = val * 16 + @as(u32, hexVal(h) orelse return ParseError.BadPattern);
            _ = p.take();
        }
    }
    if (val > 0xFF) return ParseError.BadPattern;
    return @intCast(val);
}

/// A single hex digit's value, or null if `c` is not `[0-9A-Fa-f]`.
fn hexVal(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// Fill `s` with a POSIX class's ASCII members (rg's `(?-u)` byte sets).
/// Returns false for an unknown name so the caller raises BadPattern.
fn fillPosix(s: *ByteSet, name: []const u8) bool {
    const eq = std.mem.eql;
    if (eq(u8, name, "alnum")) {
        s.setRange('0', '9');
        s.setRange('A', 'Z');
        s.setRange('a', 'z');
    } else if (eq(u8, name, "alpha")) {
        s.setRange('A', 'Z');
        s.setRange('a', 'z');
    } else if (eq(u8, name, "ascii")) {
        s.setRange(0, 0x7F);
    } else if (eq(u8, name, "blank")) {
        s.set('\t');
        s.set(' ');
    } else if (eq(u8, name, "cntrl")) {
        s.setRange(0, 0x1F);
        s.set(0x7F);
    } else if (eq(u8, name, "digit")) {
        s.setRange('0', '9');
    } else if (eq(u8, name, "graph")) {
        s.setRange(0x21, 0x7E);
    } else if (eq(u8, name, "lower")) {
        s.setRange('a', 'z');
    } else if (eq(u8, name, "print")) {
        s.setRange(0x20, 0x7E);
    } else if (eq(u8, name, "punct")) {
        s.setRange(0x21, 0x2F);
        s.setRange(0x3A, 0x40);
        s.setRange(0x5B, 0x60);
        s.setRange(0x7B, 0x7E);
    } else if (eq(u8, name, "space")) {
        for ([_]u8{ '\t', '\n', 0x0B, 0x0C, '\r', ' ' }) |b| s.set(b);
    } else if (eq(u8, name, "upper")) {
        s.setRange('A', 'Z');
    } else if (eq(u8, name, "word")) {
        s.setRange('0', '9');
        s.setRange('A', 'Z');
        s.setRange('a', 'z');
        s.set('_');
    } else if (eq(u8, name, "xdigit")) {
        s.setRange('0', '9');
        s.setRange('A', 'F');
        s.setRange('a', 'f');
    } else return false;
    return true;
}

/// Try to consume a POSIX bracket expression `[:name:]` / `[:^name:]` at the
/// current position (the outer class `[` already consumed; `p.peek()` is the
/// inner `[`), unioning its bytes into `s`. Returns false without advancing
/// when the `[` doesn't open a `[:…:]`, so the caller treats it literally
/// (rg: a bare `[` inside a class is a literal byte). An unknown class name
/// inside a well-formed `[:…:]` is BadPattern — rg rejects it too.
fn tryPosixClass(p: *Parser, s: *ByteSet) ParseError!bool {
    if (p.pos + 1 >= p.src.len or p.src[p.pos] != '[' or p.src[p.pos + 1] != ':') return false;
    const save = p.pos;
    p.pos += 2; // consume `[:`
    var negate = false;
    if (p.peek() == '^') {
        _ = p.take();
        negate = true;
    }
    const ns = p.pos;
    while (p.peek()) |ch| {
        if (ch == ':') break;
        _ = p.take();
    }
    // A well-formed POSIX class closes with `:]`; otherwise the leading `[`
    // was a literal — rewind and let the caller consume it as a byte.
    if (p.peek() != ':' or p.pos + 1 >= p.src.len or p.src[p.pos + 1] != ']') {
        p.pos = save;
        return false;
    }
    const name = p.src[ns..p.pos];
    _ = p.take(); // ':'
    _ = p.take(); // ']'
    var cls = ByteSet{};
    if (!fillPosix(&cls, name)) return ParseError.BadPattern;
    if (negate) {
        cls.negate();
        // Same invariant the outer negated class enforces: in the per-line
        // default a negated set must not carry `\n`, else a thread would
        // consume it and bleed across lines in the fused DFA scan. Whole-
        // buffer (`multiline`) mode keeps `\n`.
        if (!p.multiline) cls.bits[0] &= ~(@as(u64, 1) << '\n');
    }
    s.unionWith(cls);
    return true;
}

pub fn parseClass(p: *Parser) ParseError!*Node {
    _ = p.take(); // '['
    var s = ByteSet{};
    var neg = false;
    if (p.peek() == '^') {
        _ = p.take();
        neg = true;
    }
    var first = true;
    while (p.peek()) |c| {
        if (c == ']' and !first) {
            _ = p.take();
            if (neg) {
                s.negate();
                // Per-line default: a negated class must not carry `\n`, else a
                // thread would consume it and bleed across lines in the fused
                // DFA scan. Whole-buffer (`multiline`) mode keeps `\n` — rg
                // treats only `.` as newline-special, so `[^x]` matches `\n`.
                if (!p.multiline) s.bits[0] &= ~(@as(u64, 1) << '\n');
            }
            return p.node(.{ .class = s });
        }
        // POSIX bracket class `[:name:]` inside the outer `[...]` (rg byte
        // mode). Consumes the whole `[:…:]`; a `[` that doesn't open one
        // falls through to the literal-byte path below.
        if (c == '[' and try tryPosixClass(p, &s)) {
            first = false;
            continue;
        }
        first = false;
        if (c == '\\') {
            _ = p.take();
            s.unionWith(try parseEscape(p));
            continue;
        }
        const lo = p.take();
        if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
            _ = p.take(); // '-'
            const hi = p.take();
            if (hi < lo) return ParseError.BadPattern; // reversed range, e.g. `[z-a]`
            s.setRange(lo, hi);
        } else {
            s.set(lo);
        }
    }
    return ParseError.BadPattern; // unterminated class
}

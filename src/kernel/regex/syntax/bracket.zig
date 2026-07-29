//! gist — what a `[...]` body denotes, in both engine modes.
//!
//! Two entry points, because a bracket means two different things depending on
//! the mode: `parseClass` accumulates a 256-bit `ByteSet` for the byte engine
//! (`(?-u)`), and `parseClassU` accumulates codepoint ranges for Unicode mode.
//! They deliberately stay separate rather than one function with a flag — the
//! byte path is the hot one and pays nothing for the Unicode path's machinery.
//!
//! The shorthand unioners (`\d`, `\p{…}` and their negations) live here too,
//! because a class body is where they compose: `[\w\p{Greek}-]` is three of them
//! into one set. `parseAtom` reaches back for the same three when a shorthand
//! stands alone.

const std = @import("std");
const uni = @import("../unicode/tables.zig");
const tree = @import("tree.zig");
const scalars = @import("scalars.zig");
const escape = @import("escape.zig");
const Parser = @import("parser.zig").Parser;

const ByteSet = tree.ByteSet;
const Node = tree.Node;
const ParseError = tree.ParseError;
const ScalarSet = scalars.ScalarSet;

/// Fold, complement, and union a scratch set into `ss` — the shared negated tail
/// of `\D \W \S`, `\P{…}`, and `[[:^name:]]`. The caller seeds `tmp` with the
/// POSITIVE members; the ordering (fold BEFORE complement, or `-i` re-admits the
/// excluded letter's twin) lives here so no negation path can get it wrong.
fn addComplement(p: *Parser, ss: *ScalarSet, tmp: *ScalarSet) ParseError!void {
    if (p.caseless) try tmp.foldExpand();
    try tmp.complement(p.multiline);
    try ss.addTable(tmp.list.items);
}

/// Union `table`'s negated-class complement into `ss` — `\D \W \S` and `\P{…}`.
fn addNegated(p: *Parser, ss: *ScalarSet, table: []const [2]u21) ParseError!void {
    var tmp = ScalarSet{ .gpa = p.arena };
    try tmp.addTable(table);
    return addComplement(p, ss, &tmp);
}

/// Union a Perl class (`\d \w \s`, or its negation `\D \W \S`) into `ss` from
/// the Unicode tables; an uppercase spelling routes through `addNegated`.
pub fn addPerl(p: *Parser, ss: *ScalarSet, e: u8) ParseError!void {
    const table = switch (std.ascii.toLower(e)) {
        'd' => uni.digit,
        'w' => uni.word,
        's' => uni.space,
        else => unreachable,
    };
    return if (std.ascii.isUpper(e)) addNegated(p, ss, table) else ss.addTable(table);
}

/// Parse a `\p{…}` / `\pL` property body and union its ranges into `ss`; `\P…`
/// unions the complement. Unknown property ⇒ BadPattern (rg rejects too).
pub fn addProp(p: *Parser, ss: *ScalarSet, negated: bool) ParseError!void {
    var name: []const u8 = undefined;
    if (p.eat('{')) {
        const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, '}') orelse return ParseError.BadPattern;
        name = p.src[p.pos..end];
        p.pos = end + 1;
    } else {
        // Single-letter form `\pL`, `\pN` (one ASCII category letter).
        const ch = p.peek() orelse return ParseError.BadPattern;
        if (!std.ascii.isAlphabetic(ch)) return ParseError.BadPattern;
        name = p.src[p.pos .. p.pos + 1];
        _ = p.take();
    }
    const ranges = uni.property(name) orelse return ParseError.BadPattern;
    return if (negated) addNegated(p, ss, ranges) else ss.addTable(ranges);
}

/// A consumed POSIX bracket expression: the class's ASCII members, and whether
/// `[:^name:]` asked for a complement. The complement is deliberately NOT applied
/// here — each mode must take it in its own universe (256 bytes for `(?-u)`, the
/// whole scalar space in Unicode mode, where rg's `[[:^lower:]]` admits 日 too).
const PosixClass = struct { bytes: ByteSet, negated: bool };

/// Try to consume a POSIX bracket expression `[:name:]` / `[:^name:]` at the
/// current position (the outer class `[` already consumed; `p.peek()` is the
/// inner `[`). Returns null without advancing when the `[` doesn't open a
/// `[:…:]`, so the caller treats it literally (rg: a bare `[` inside a class is a
/// literal byte). An unknown class name inside a well-formed `[:…:]` is
/// BadPattern — rg rejects it too.
fn tryPosixClass(p: *Parser) ParseError!?PosixClass {
    if (p.pos + 1 >= p.src.len or p.src[p.pos] != '[' or p.src[p.pos + 1] != ':') return null;
    const save = p.pos;
    p.pos += 2; // consume `[:`
    const negated = p.eat('^');
    // A well-formed POSIX class closes with `:]`; otherwise the leading `[`
    // was a literal — rewind and let the caller consume it as a byte.
    const colon = std.mem.indexOfScalarPos(u8, p.src, p.pos, ':') orelse {
        p.pos = save;
        return null;
    };
    if (colon + 1 >= p.src.len or p.src[colon + 1] != ']') {
        p.pos = save;
        return null;
    }
    const name = p.src[p.pos..colon];
    p.pos = colon + 2; // past `:]`
    var bytes = ByteSet{};
    if (!escape.fillPosix(&bytes, name)) return ParseError.BadPattern;
    return .{ .bytes = bytes, .negated = negated };
}

/// A single scalar codepoint. `.cp` may begin a `-` range in a class; `.class`
/// is a shorthand already unioned into the set (never a range endpoint).
const ClassAtom = union(enum) { cp: u21, class };

/// Read one class atom in Unicode mode: a shorthand escape (`\d \w \s \p{…}`,
/// unioned into `ss` in place) or a single codepoint (literal / `\t` / `\xNN`).
fn readClassAtom(p: *Parser, ss: *ScalarSet) ParseError!ClassAtom {
    const c = p.peek().?;
    if (c != '\\') {
        if (c >= 0x80) {
            if (p.decodeCp()) |cp| return .{ .cp = cp };
            _ = p.take(); // ill-formed byte → literal byte
            return .{ .cp = c };
        }
        _ = p.take();
        return .{ .cp = c };
    }
    _ = p.take(); // '\'
    const e = if (p.pos < p.src.len) p.take() else return ParseError.BadPattern;
    switch (e) {
        'd', 'D', 'w', 'W', 's', 'S' => {
            try addPerl(p, ss, e);
            return .class;
        },
        'p', 'P' => {
            try addProp(p, ss, e == 'P');
            return .class;
        },
        'x' => return .{ .cp = try escape.hexCp(p) },
        't', 'n', 'r', 'f', 'v', 'a' => return .{ .cp = escape.ctrlByte(e) },
        // Backrefs (`\0`–`\9`) and assertion escapes (`\b \B \A \z \< \>`,
        // all alphabetic/`<`/`>`) are invalid inside a class — rg rejects them.
        '0'...'9', '<', '>' => return ParseError.BadPattern,
        else => {
            if (std.ascii.isAlphabetic(e)) return ParseError.BadPattern;
            return .{ .cp = e }; // escaped punctuation → the literal codepoint
        },
    }
}

/// Unicode-mode `[...]`: accumulate scalar ranges (ASCII, non-ASCII literals,
/// `a-z` ranges over codepoints, shorthands, `\p{…}`, POSIX bracket classes),
/// then `finish` to a `class` (all-ASCII) or `uclass`. The byte-oriented
/// `parseClass` serves the `(?-u)` path unchanged.
pub fn parseClassU(p: *Parser) ParseError!*Node {
    _ = p.take(); // '['
    var ss = ScalarSet{ .gpa = p.arena };
    const neg = p.eat('^');
    var first = true;
    while (p.peek()) |c| {
        if (c == ']' and !first) {
            _ = p.take();
            if (neg) {
                if (p.caseless) try ss.foldExpand(); // fold the members, THEN complement
                try ss.complement(p.multiline);
            }
            return ss.finish(p.arena);
        }
        // POSIX bracket class `[:name:]` — an ASCII set even here, but `[:^name:]`
        // complements over the WHOLE scalar space (rg admits 日 for `[[:^lower:]]`).
        if (c == '[') {
            if (try tryPosixClass(p)) |pc| {
                if (pc.negated) {
                    var tmp = ScalarSet{ .gpa = p.arena };
                    try tmp.addByteSet(&pc.bytes);
                    try addComplement(p, &ss, &tmp);
                } else try ss.addByteSet(&pc.bytes);
                first = false;
                continue;
            }
        }
        first = false;
        switch (try readClassAtom(p, &ss)) {
            // A shorthand is already unioned in, and may not bound a range:
            // `[\d-a]` is BadPattern (rg: "invalid range boundary, must be a
            // literal"), while a trailing `[\d-]` keeps the `-` literal.
            .class => if (p.rangeDash()) return ParseError.BadPattern,
            .cp => |lo_cp| {
                // `a-b` range — but a trailing `-` (before `]`) is literal.
                if (p.rangeDash()) {
                    _ = p.take(); // '-'
                    switch (try readClassAtom(p, &ss)) {
                        .cp => |hi_cp| {
                            if (hi_cp < lo_cp) return ParseError.BadPattern;
                            try ss.addRange(lo_cp, hi_cp);
                        },
                        // `[a-\d]` — the other boundary, same rejection.
                        .class => return ParseError.BadPattern,
                    }
                } else try ss.addRange(lo_cp, lo_cp);
            },
        }
    }
    return ParseError.BadPattern; // unterminated class
}

/// Read one atom of a byte-mode class: the single byte it denotes, or null when it
/// was a shorthand set (`\d \w \s` and their negations), which is unioned into `s`
/// in place. The byte twin of `readClassAtom`'s literal/class split — and the
/// reason `[\t-\r]` is a range while `[a-\d]` is an error: a shorthand is the only
/// escape here whose set isn't a singleton.
fn readByteAtom(p: *Parser, s: *ByteSet) ParseError!?u8 {
    if (!p.eat('\\')) return p.take();
    const esc = try escape.parseEscape(p);
    if (esc.only()) |b| return b;
    s.unionWith(esc);
    return null;
}

pub fn parseClass(p: *Parser) ParseError!*Node {
    _ = p.take(); // '['
    var s = ByteSet{};
    const neg = p.eat('^');
    var first = true;
    while (p.peek()) |c| {
        if (c == ']' and !first) {
            _ = p.take();
            if (neg) {
                if (p.caseless) s.foldCase(); // fold the members, THEN negate
                s.negate();
                // Per-line default: a negated class must not carry `\n`, else a
                // thread would consume it and bleed across lines in the fused
                // DFA scan. Whole-buffer (`multiline`) mode keeps `\n` — rg
                // treats only `.` as newline-special, so `[^x]` matches `\n`.
                if (!p.multiline) s.remove('\n');
            }
            return p.node(.{ .class = s });
        }
        // POSIX bracket class `[:name:]` inside the outer `[...]` (rg byte
        // mode). Consumes the whole `[:…:]`; a `[` that doesn't open one
        // falls through to the literal-byte path below.
        if (c == '[') {
            if (try tryPosixClass(p)) |pc| {
                var cls = pc.bytes;
                if (pc.negated) {
                    if (p.caseless) cls.foldCase(); // fold the members, THEN negate
                    cls.negate(); // the byte universe is the right one under `(?-u)`
                    // Same invariant the outer negated class enforces: in the
                    // per-line default a negated set must not carry `\n`, else a
                    // thread would consume it and bleed across lines in the fused
                    // DFA scan. Whole-buffer (`multiline`) mode keeps `\n`.
                    if (!p.multiline) cls.remove('\n');
                }
                s.unionWith(cls);
                first = false;
                continue;
            }
        }
        first = false;
        const lo = (try readByteAtom(p, &s)) orelse {
            // A shorthand may not bound a range (rg: "invalid range boundary,
            // must be a literal"); a trailing `[\d-]` keeps the `-` literal.
            if (p.rangeDash()) return ParseError.BadPattern;
            continue;
        };
        if (p.rangeDash()) {
            _ = p.take(); // '-'
            const hi = (try readByteAtom(p, &s)) orelse return ParseError.BadPattern;
            if (hi < lo) return ParseError.BadPattern; // reversed range, e.g. `[z-a]`
            s.setRange(lo, hi);
        } else {
            s.set(lo);
        }
    }
    return ParseError.BadPattern; // unterminated class
}

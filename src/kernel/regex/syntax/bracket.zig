//! irregex — what a `[...]` body denotes, in both engine modes.
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

/// The operator between two class-set operands: `[a-z&&\p{Greek}]`.
///
/// A bracket body is not a flat list of members - it is `operand (op operand)*`
/// over the three set operators, which is how a grammar spells "an identifier
/// may start with an emoji, but not with a digit" (swift), since `\p{Emoji}`
/// carries `0-9`, `#` and `*` for the keycap sequences. All three bind equally
/// and associate left, which is a fact measured against rg rather than assumed:
/// `[a-e--b-d&&c]` is empty (left-assoc) and not `a b d e` (`&&` tighter).
const SetOp = enum { intersect, difference, symmetric };

/// The operator opening at `p.pos`, consumed - or null, leaving the position
/// alone so a lone `&`, `-` or `~` stays the literal it has always been.
///
/// A `-` is only an operator DOUBLED. That is what keeps `[a-z]` a range and
/// `[a-]` a trailing literal while `[a--b]` is a difference, and it is why this
/// is asked before `readClassAtom` rather than inside the range branch.
fn eatSetOp(p: *Parser) ?SetOp {
    if (p.pos + 1 >= p.src.len) return null;
    const op: SetOp = switch (p.src[p.pos]) {
        '&' => .intersect,
        '-' => .difference,
        '~' => .symmetric,
        else => return null,
    };
    if (p.src[p.pos + 1] != p.src[p.pos]) return null;
    p.pos += 2;
    return op;
}

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
        // The by-value family — one codepoint, so it can also bound a range
        // (`[\u00ab-\u00bb]`). Inside a class every numeric escape is octal, which
        // is `re`'s reading and the `true` here; rg refuses them outright.
        'x', 'u', 'U', 'N', '0'...'9' => return .{ .cp = try escape.valueCp(p, e, true) },
        't', 'n', 'r', 'f', 'v', 'a' => return .{ .cp = escape.ctrlByte(e) },
        // Assertion escapes (`\b \B \A \z \< \>`, all alphabetic/`<`/`>`) are
        // invalid inside a class — rg rejects them.
        '<', '>' => return ParseError.BadPattern,
        else => {
            if (std.ascii.isAlphabetic(e)) return ParseError.BadPattern;
            return .{ .cp = e }; // escaped punctuation → the literal codepoint
        },
    }
}

/// Unicode-mode `[...]`: the whole bracket body, operators and all.
///
/// One operand accumulates ASCII and non-ASCII literals, `a-z` ranges over
/// codepoints, shorthands, `\p{…}`, POSIX bracket classes and nested `[…]`;
/// `&&`, `--` and `~~` close the operand and fold it left into what came
/// before. The `[` is already consumed and the matching `]` is consumed here,
/// so a nested class is this same function called again.
fn classSetU(p: *Parser) ParseError!ScalarSet {
    var acc = ScalarSet{ .gpa = p.arena };
    var ss = ScalarSet{ .gpa = p.arena };
    var pending: ?SetOp = null;
    const neg = p.eat('^');
    var first = true;
    while (p.peek()) |c| {
        if (c == ']' and !first) {
            _ = p.take();
            try fold(&acc, &ss, pending);
            if (neg) {
                if (p.caseless) try acc.foldExpand(); // fold the members, THEN complement
                try acc.complement(p.multiline);
            }
            return acc;
        }
        // Asked before anything can read `-` as a range bound, and before a
        // literal `&`/`~`. An operator never opens a body, so `[&&a]` keeps an
        // empty left operand and lands on the empty set - which is rg's answer.
        if (eatSetOp(p)) |op| {
            try fold(&acc, &ss, pending);
            pending = op;
            ss = .{ .gpa = p.arena };
            first = false;
            continue;
        }
        if (c == '[') {
            // POSIX bracket class `[:name:]` — an ASCII set even here, but
            // `[:^name:]` complements over the WHOLE scalar space (rg admits 日
            // for `[[:^lower:]]`).
            if (try tryPosixClass(p)) |pc| {
                if (pc.negated) {
                    var tmp = ScalarSet{ .gpa = p.arena };
                    try tmp.addByteSet(&pc.bytes);
                    try addComplement(p, &ss, &tmp);
                } else try ss.addByteSet(&pc.bytes);
                first = false;
                continue;
            }
            // Otherwise it opens a nested class, and it is not a literal `[`.
            // rg reads `[a[b]` as unclosed rather than as `a`, `[`, `b`, and a
            // comment here used to claim the opposite - which is the difference
            // between `[\w&&[a-c]]` meaning three letters and meaning nothing.
            _ = p.take();
            const inner = try classSetU(p);
            try ss.addTable(inner.list.items);
            first = false;
            continue;
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

/// Close the operand in `ss` onto `acc` under the operator that opened it.
/// No operator means this is the first operand, so it simply becomes `acc`;
/// everything else is a union, which is what juxtaposition has always meant.
fn fold(acc: *ScalarSet, ss: *ScalarSet, op: ?SetOp) ParseError!void {
    switch (op orelse return acc.addTable(ss.list.items)) {
        .intersect => try acc.intersect(ss),
        .difference => try acc.subtract(ss),
        .symmetric => try acc.symmetric(ss),
    }
}

/// Unicode-mode `[...]`, lowered: `finish` picks a `class` (all-ASCII) or a
/// `uclass`. The byte-oriented `parseClass` serves the `(?-u)` path.
pub fn parseClassU(p: *Parser) ParseError!*Node {
    _ = p.take(); // '['
    var ss = try classSetU(p);
    return ss.finish(p.arena);
}

/// Read one atom of a byte-mode class: the single byte it denotes, or null when it
/// was a shorthand set (`\d \w \s` and their negations), which is unioned into `s`
/// in place. The byte twin of `readClassAtom`'s literal/class split — and the
/// reason `[\t-\r]` is a range while `[a-\d]` is an error: a shorthand is the only
/// escape here whose set isn't a singleton.
fn readByteAtom(p: *Parser, s: *ByteSet) ParseError!?u8 {
    if (!p.eat('\\')) return p.take();
    const esc = try escape.parseEscape(p, true);
    if (esc.only()) |b| return b;
    s.unionWith(esc);
    return null;
}

/// Byte-mode `[...]`, the `(?-u)` twin of `classSetU` - the same operand/operator
/// grammar over a 256-bit universe. Two functions rather than one with a flag,
/// for the reason at the top of the file: the byte path is the hot one.
fn classSet(p: *Parser) ParseError!ByteSet {
    var acc = ByteSet{};
    var s = ByteSet{};
    var pending: ?SetOp = null;
    const neg = p.eat('^');
    var first = true;
    while (p.peek()) |c| {
        if (c == ']' and !first) {
            _ = p.take();
            foldBytes(&acc, s, pending);
            if (neg) {
                if (p.caseless) acc.foldCase(); // fold the members, THEN negate
                acc.negate();
                // Per-line default: a negated class must not carry `\n`, else a
                // thread would consume it and bleed across lines in the fused
                // DFA scan. Whole-buffer (`multiline`) mode keeps `\n` — rg
                // treats only `.` as newline-special, so `[^x]` matches `\n`.
                if (!p.multiline) acc.remove('\n');
            }
            return acc;
        }
        if (eatSetOp(p)) |op| {
            foldBytes(&acc, s, pending);
            pending = op;
            s = .{};
            first = false;
            continue;
        }
        // POSIX bracket class `[:name:]` inside the outer `[...]` (rg byte
        // mode). Consumes the whole `[:…:]`; a `[` that doesn't open one opens
        // a nested class, exactly as it does in Unicode mode.
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
            _ = p.take();
            s.unionWith(try classSet(p));
            first = false;
            continue;
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

fn foldBytes(acc: *ByteSet, s: ByteSet, op: ?SetOp) void {
    switch (op orelse return acc.unionWith(s)) {
        .intersect => acc.intersectWith(s),
        .difference => acc.subtract(s),
        .symmetric => acc.symmetricWith(s),
    }
}

pub fn parseClass(p: *Parser) ParseError!*Node {
    _ = p.take(); // '['
    return p.node(.{ .class = try classSet(p) });
}

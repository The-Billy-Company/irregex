//! gist — regex *syntax*: byte classes, the AST, the compiled NFA instruction,
//! and a recursive-descent parser for the supported subset. The sound AST
//! analyses that feed the prefilter (required-literal extraction, anchored-start
//! detection) live in `analysis.zig`; the execution half (Thompson NFA compile +
//! Pike simulation) lives in `core.zig`. Both import this module.
//!
//! Supported (ASCII / byte-oriented, matching ripgrep's `(?-u)` mode):
//!   literals · `.` (any byte but '\n') · `[...]` / `[^...]` with `a-z` ranges
//!   · `*` `+` `?` · `{n}` `{n,}` `{n,m}` counted repetition · `|` · `(...)`
//!   grouping · line anchors `^` `$` · escapes
//!   `\. \* \+ \? \( \) \[ \] \^ \$ \\ \| \/ \t \n \r \d \D \w \W \s \S`.
//! Like rust-regex, an unescaped `{` must begin a valid count (else BadPattern;
//! a literal brace is `\{`); a stray `}` is literal.

const std = @import("std");

/// 256-bit byte class (which bytes a consuming state accepts).
pub const ByteSet = struct {
    bits: [4]u64 = @splat(0),

    pub fn set(self: *ByteSet, b: u8) void {
        self.bits[b >> 6] |= @as(u64, 1) << @intCast(b & 63);
    }
    pub fn setRange(self: *ByteSet, lo: u8, hi: u8) void {
        var c: usize = lo;
        while (c <= hi) : (c += 1) self.set(@intCast(c));
    }
    pub fn has(self: *const ByteSet, b: u8) bool {
        return (self.bits[b >> 6] >> @intCast(b & 63)) & 1 != 0;
    }
    pub fn negate(self: *ByteSet) void {
        for (&self.bits) |*w| w.* = ~w.*;
    }
    pub fn unionWith(self: *ByteSet, o: ByteSet) void {
        for (&self.bits, o.bits) |*w, ow| w.* |= ow;
    }
    pub fn count(self: *const ByteSet) usize {
        var n: usize = 0;
        for (self.bits) |w| n += @popCount(w);
        return n;
    }
    /// The sole member when the set is a singleton (drives the SIMD `memchr`
    /// skip in the regex scanner); null for empty or multi-byte sets.
    pub fn only(self: *const ByteSet) ?u8 {
        if (self.count() != 1) return null;
        for (self.bits, 0..) |w, wi| if (w != 0) return @intCast(wi * 64 + @ctz(w));
        return null;
    }
};

pub const Node = union(enum) {
    empty,
    class: ByteSet, // a single consuming step (literal byte, ., \d, [..])
    anchor_start, // `^` — zero-width, asserts start of line
    anchor_end, // `$` — zero-width, asserts end of line
    concat: [2]*Node,
    alt: [2]*Node,
    star: *Node,
    plus: *Node,
    quest: *Node,
};

/// A compiled Thompson-NFA instruction (the flat program `core.zig`'s compiler
/// emits and both the Pike VM and the lazy DFA execute). Lives here, beside the
/// AST it lowers from, so `dfa.zig` can determinize over it without an
/// import cycle through `core.zig`.
pub const State = union(enum) {
    consume: struct { set: ByteSet, out: u32 },
    split: struct { a: u32, b: u32 },
    assert_start: u32, // zero-width `^`: pass to `out` only at line start
    assert_end: u32, // zero-width `$`: pass to `out` only at line end
    match,
};

pub const ParseError = error{ BadPattern, OutOfMemory };

pub const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }
    fn take(p: *Parser) u8 {
        const c = p.src[p.pos];
        p.pos += 1;
        return c;
    }
    fn node(p: *Parser, v: Node) ParseError!*Node {
        const n = try p.arena.create(Node);
        n.* = v;
        return n;
    }
    /// Concat `n` onto `acc`, or return `n` when `acc` is empty — the left-fold
    /// shared by concat sequencing and `{n,m}` expansion.
    fn chain(p: *Parser, acc: ?*Node, n: *Node) ParseError!*Node {
        return if (acc) |a| try p.node(.{ .concat = .{ a, n } }) else n;
    }
    /// Parse a run of ASCII digits at `pos` as a decimal `usize`; null (without
    /// advancing) when the next byte isn't a digit.
    fn digits(p: *Parser) ?usize {
        var v: usize = 0;
        var got = false;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            _ = p.take();
            got = true;
            // Saturate past the repeat cap: a larger bound is BadPattern anyway
            // (see `expand`), and pinning here avoids usize overflow on `a{9…9}`.
            v = if (v > max_repeat) v else v * 10 + (c - '0');
        }
        return if (got) v else null;
    }

    // alt := concat ('|' concat)*
    pub fn parseAlt(p: *Parser) ParseError!*Node {
        var left = try p.parseConcat();
        while (p.peek() == '|') {
            _ = p.take();
            const right = try p.parseConcat();
            left = try p.node(.{ .alt = .{ left, right } });
        }
        return left;
    }

    // concat := repeat*
    fn parseConcat(p: *Parser) ParseError!*Node {
        var acc: ?*Node = null;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            acc = try p.chain(acc, try p.parseRepeat());
        }
        return acc orelse try p.node(.empty);
    }

    // repeat := atom ('*'|'+'|'?'|'{'n[,m]'}')*
    fn parseRepeat(p: *Parser) ParseError!*Node {
        var a = try p.parseAtom();
        while (p.peek()) |c| {
            switch (c) {
                '*', '+', '?' => a = try p.node(switch (p.take()) {
                    '*' => .{ .star = a },
                    '+' => .{ .plus = a },
                    else => .{ .quest = a },
                }),
                '{' => {
                    // An unescaped `{` MUST begin a valid `{n}`/`{n,}`/`{n,m}`
                    // spec — rust-regex (ripgrep) errors otherwise, so we mirror
                    // it (a literal brace is `\{`). `tryBound` restores `pos` on
                    // failure; here that just precedes the error.
                    const b = p.tryBound() orelse return ParseError.BadPattern;
                    a = try p.expand(a, b);
                },
                else => break,
            }
        }
        return a;
    }

    /// `{n}` exact · `{n,}` n-or-more · `{n,m}` range. `n` is required; `max` is
    /// null when unbounded. RE2/rust-regex-shaped bounds.
    const Bound = struct { min: usize, max: ?usize };

    /// Cap on a single `{n,m}` expansion (RE2 caps repetition similarly) — guards
    /// against `a{999999}` blowing up the NFA. Exceeding it ⇒ BadPattern.
    const max_repeat: usize = 1000;

    /// Parse a `{n[,[m]]}` spec at the current `{`. On any malformation, restore
    /// `pos` and return null so the caller treats `{` as a literal byte.
    fn tryBound(p: *Parser) ?Bound {
        const save = p.pos;
        _ = p.take(); // '{'
        const min = p.digits() orelse {
            p.pos = save;
            return null;
        };
        var max: ?usize = min; // `{n}` ⇒ exactly n
        if (p.peek() == ',') {
            _ = p.take();
            max = p.digits(); // digits ⇒ `{n,m}`; none ⇒ `{n,}` unbounded
        }
        if (p.peek() != '}') {
            p.pos = save;
            return null;
        }
        _ = p.take(); // '}'
        return .{ .min = min, .max = max };
    }

    /// Desugar `atom{min,max}` into the existing node vocabulary: `min` mandatory
    /// copies, then either `(max-min)` optional copies (`a?`) or a trailing `a*`
    /// when unbounded. The `atom` pointer is shared across copies — the AST is a
    /// DAG, sound because every visitor (compile, literalInfo) only reads it.
    fn expand(p: *Parser, atom: *Node, b: Bound) ParseError!*Node {
        if (b.min > max_repeat or (b.max orelse 0) > max_repeat) return ParseError.BadPattern;
        if (b.max) |mx| if (mx < b.min) return ParseError.BadPattern;

        var result: ?*Node = null;
        var i: usize = 0;
        while (i < b.min) : (i += 1) result = try p.chain(result, atom);

        if (b.max) |mx| {
            var k = b.min;
            while (k < mx) : (k += 1) result = try p.chain(result, try p.node(.{ .quest = atom }));
        } else {
            result = try p.chain(result, try p.node(.{ .star = atom }));
        }
        return result orelse p.node(.empty);
    }

    fn parseAtom(p: *Parser) ParseError!*Node {
        const c = p.peek() orelse return ParseError.BadPattern;
        switch (c) {
            '(' => {
                _ = p.take();
                const inner = try p.parseAlt();
                if (p.peek() != ')') return ParseError.BadPattern;
                _ = p.take();
                return inner;
            },
            '[' => return p.parseClass(),
            '.' => {
                _ = p.take();
                var s = ByteSet{};
                s.bits = @splat(~@as(u64, 0));
                s.bits[0] &= ~(@as(u64, 1) << '\n'); // any byte except newline
                return p.node(.{ .class = s });
            },
            '\\' => {
                _ = p.take();
                return p.node(.{ .class = try p.parseEscape() });
            },
            '^', '$' => {
                _ = p.take();
                return p.node(if (c == '^') .anchor_start else .anchor_end);
            },
            '*', '+', '?', '{' => return ParseError.BadPattern, // repeat op w/o expression
            ')', '|' => return ParseError.BadPattern,
            else => {
                _ = p.take();
                var s = ByteSet{};
                s.set(c);
                return p.node(.{ .class = s });
            },
        }
    }

    fn parseEscape(p: *Parser) ParseError!ByteSet {
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
            else => s.set(e), // \. \* \\ \/ … → literal
        }
        return s;
    }

    fn parseClass(p: *Parser) ParseError!*Node {
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
                    s.bits[0] &= ~(@as(u64, 1) << '\n'); // negated class still excludes newline
                }
                return p.node(.{ .class = s });
            }
            first = false;
            if (c == '\\') {
                _ = p.take();
                s.unionWith(try p.parseEscape());
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
};

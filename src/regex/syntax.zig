//! gist — regex *syntax*: byte classes, the AST, a recursive-descent parser for
//! the supported subset, and sound required-literal extraction. The execution
//! half (Thompson NFA compile + Pike simulation) lives in `core.zig`, which
//! imports this module. Split out purely to keep each file under the shape cap.
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
    bits: [4]u64 = .{ 0, 0, 0, 0 },

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
            const r = try p.parseRepeat();
            acc = if (acc) |a| try p.node(.{ .concat = .{ a, r } }) else r;
        }
        return acc orelse try p.node(.empty);
    }

    // repeat := atom ('*'|'+'|'?'|'{'n[,m]'}')*
    fn parseRepeat(p: *Parser) ParseError!*Node {
        var a = try p.parseAtom();
        while (p.peek()) |c| {
            switch (c) {
                '*' => {
                    _ = p.take();
                    a = try p.node(.{ .star = a });
                },
                '+' => {
                    _ = p.take();
                    a = try p.node(.{ .plus = a });
                },
                '?' => {
                    _ = p.take();
                    a = try p.node(.{ .quest = a });
                },
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
        var min: usize = 0;
        var got_min = false;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            min = min * 10 + (c - '0');
            got_min = true;
            _ = p.take();
        }
        if (!got_min) {
            p.pos = save;
            return null;
        }
        var max: ?usize = min; // `{n}` ⇒ exactly n
        if (p.peek() == ',') {
            _ = p.take();
            var m: usize = 0;
            var got_max = false;
            while (p.peek()) |c| {
                if (c < '0' or c > '9') break;
                m = m * 10 + (c - '0');
                got_max = true;
                _ = p.take();
            }
            max = if (got_max) m else null; // `{n,}` ⇒ unbounded
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
        while (i < b.min) : (i += 1)
            result = if (result) |r| try p.node(.{ .concat = .{ r, atom } }) else atom;

        if (b.max) |mx| {
            var k = b.min;
            while (k < mx) : (k += 1) {
                const opt = try p.node(.{ .quest = atom });
                result = if (result) |r| try p.node(.{ .concat = .{ r, opt } }) else opt;
            }
        } else {
            const st = try p.node(.{ .star = atom });
            result = if (result) |r| try p.node(.{ .concat = .{ r, st } }) else st;
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
                s.bits = .{ ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0) };
                s.bits[0] &= ~(@as(u64, 1) << '\n'); // any byte except newline
                return p.node(.{ .class = s });
            },
            '\\' => {
                _ = p.take();
                return p.node(.{ .class = try p.parseEscape() });
            },
            '^' => {
                _ = p.take();
                return p.node(.anchor_start);
            },
            '$' => {
                _ = p.take();
                return p.node(.anchor_end);
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
        switch (e) {
            'd' => s.setRange('0', '9'),
            'D' => {
                s.setRange('0', '9');
                s.negate();
            },
            'w' => {
                s.setRange('0', '9');
                s.setRange('A', 'Z');
                s.setRange('a', 'z');
                s.set('_');
            },
            'W' => {
                s.setRange('0', '9');
                s.setRange('A', 'Z');
                s.setRange('a', 'z');
                s.set('_');
                s.negate();
            },
            's' => for ([_]u8{ '\t', '\n', 0x0B, 0x0C, '\r', ' ' }) |b| s.set(b),
            'S' => {
                for ([_]u8{ '\t', '\n', 0x0B, 0x0C, '\r', ' ' }) |b| s.set(b);
                s.negate();
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
                const esc = try p.parseEscape();
                for (0..256) |b| if (esc.has(@intCast(b))) s.set(@intCast(b));
                continue;
            }
            const lo = p.take();
            if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                _ = p.take(); // '-'
                const hi = p.take();
                s.setRange(lo, hi);
            } else {
                s.set(lo);
            }
        }
        return ParseError.BadPattern; // unterminated class
    }
};

// ── literal extraction (sound necessary-condition for the trigram prefilter) ─

pub const LitInfo = struct {
    exact: ?[]const u8, // node matches EXACTLY this literal and nothing else
    best: []const u8, // longest literal that MUST appear in every match
};

fn longer(a: []const u8, b: []const u8) []const u8 {
    return if (a.len >= b.len) a else b;
}

/// Compute a literal that must appear in every match (`best`). Sound: if it
/// can't prove one, `best` is "" (caller scans all docs). Mirrors the literal
/// half of Cox's regexp→trigram analysis, conservatively.
pub fn literalInfo(arena: std.mem.Allocator, node: *Node) ParseError!LitInfo {
    switch (node.*) {
        // Zero-width: matches the empty string at a position. exact="" lets a
        // mandatory literal run span the anchor (e.g. `^func` ⇒ required "func").
        .empty, .anchor_start, .anchor_end => return .{ .exact = "", .best = "" },
        .class => |set| {
            var count: usize = 0;
            var only: u8 = 0;
            for (0..256) |b| if (set.has(@intCast(b))) {
                count += 1;
                only = @intCast(b);
            };
            if (count == 1) {
                const lit = try arena.dupe(u8, &[_]u8{only});
                return .{ .exact = lit, .best = lit };
            }
            return .{ .exact = null, .best = "" };
        },
        .concat => |ab| {
            const x = try literalInfo(arena, ab[0]);
            const y = try literalInfo(arena, ab[1]);
            var exact: ?[]const u8 = null;
            if (x.exact != null and y.exact != null)
                exact = try std.mem.concat(arena, u8, &.{ x.exact.?, y.exact.? });
            // A mandatory run can span the boundary when x ends / y starts exact.
            var span: []const u8 = "";
            if (x.exact) |xe| if (y.exact) |ye| {
                span = try std.mem.concat(arena, u8, &.{ xe, ye });
            };
            const best = longer(longer(x.best, y.best), span);
            return .{ .exact = exact, .best = best };
        },
        .plus => |x| {
            const xi = try literalInfo(arena, x); // content occurs ≥ once
            return .{ .exact = null, .best = xi.best };
        },
        // Optional / alternation: nothing is guaranteed to appear.
        .star, .quest, .alt => return .{ .exact = null, .best = "" },
    }
}

/// True iff every match must begin at the start of a line — the pattern's first
/// consumable step is preceded by `^` on every alternation branch. Lets the
/// scanner seed only at line position 0 (no per-byte unanchored re-seed) and bail
/// the instant the thread list empties. Conservative: only the `^` node anchors,
/// so an un-anchored branch makes the whole alternation un-anchored.
pub fn startsAnchored(node: *Node) bool {
    return switch (node.*) {
        .anchor_start => true,
        .concat => |ab| startsAnchored(ab[0]),
        .alt => |ab| startsAnchored(ab[0]) and startsAnchored(ab[1]),
        .plus => |x| startsAnchored(x), // `(^x)+` still starts anchored
        else => false,
    };
}

/// Cap on an alternation cover-set — a huge `a|b|c|…` union would issue one
/// trigram query per branch; past this a full scan is cheaper, so we bail to it.
const max_cover: usize = 32;

/// A set of ≥3-byte literals such that EVERY match contains at least one of them
/// — so the UNION of their trigram-candidate sets is a sound superset (no false
/// negative). Returns null when none is provable (caller full-scans). This is the
/// multi-literal counterpart to `literalInfo.best`: where `best` needs ONE literal
/// mandatory across the whole pattern, this admits alternations — `foo|bar` ⇒
/// {foo, bar} — but only when EVERY branch yields a ≥3 literal (else that branch's
/// matches could carry none of the set, and filtering would wrongly drop them).
pub fn requiredAny(arena: std.mem.Allocator, node: *Node) ParseError!?[]const []const u8 {
    // A single mandatory ≥3 literal is the most selective filter — prefer it.
    const li = try literalInfo(arena, node);
    if (li.best.len >= 3) {
        const one = try arena.alloc([]const u8, 1);
        one[0] = li.best;
        return one;
    }
    switch (node.*) {
        .alt => |ab| {
            const sa = try requiredAny(arena, ab[0]) orelse return null;
            const sb = try requiredAny(arena, ab[1]) orelse return null;
            if (sa.len + sb.len > max_cover) return null;
            const out = try arena.alloc([]const u8, sa.len + sb.len);
            @memcpy(out[0..sa.len], sa);
            @memcpy(out[sa.len..], sb);
            return out;
        },
        // In a concat both sides are mandatory, so either side's cover set is
        // sound for the whole match — take the first side that yields one.
        .concat => |ab| {
            if (try requiredAny(arena, ab[0])) |sa| return sa;
            return try requiredAny(arena, ab[1]);
        },
        .plus => |x| return try requiredAny(arena, x),
        // multi-byte class, star, quest (match empty), empty, anchors ⇒ no cover.
        else => return null,
    }
}

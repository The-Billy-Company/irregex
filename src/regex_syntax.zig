//! gist — regex *syntax*: byte classes, the AST, a recursive-descent parser for
//! the supported subset, and sound required-literal extraction. The execution
//! half (Thompson NFA compile + Pike simulation) lives in `regex.zig`, which
//! imports this module. Split out purely to keep each file under the shape cap.
//!
//! Supported (ASCII / byte-oriented, matching ripgrep's `(?-u)` mode):
//!   literals · `.` (any byte but '\n') · `[...]` / `[^...]` with `a-z` ranges
//!   · `*` `+` `?` · `|` · `(...)` grouping · escapes `\. \* \+ \? \( \) \[ \]
//!   `\\ \| \/ \t \n \r \d \D \w \W \s \S`.

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
};

pub const Node = union(enum) {
    empty,
    class: ByteSet, // a single consuming step (literal byte, ., \d, [..])
    concat: [2]*Node,
    alt: [2]*Node,
    star: *Node,
    plus: *Node,
    quest: *Node,
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

    // repeat := atom ('*'|'+'|'?')*
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
                else => break,
            }
        }
        return a;
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
            '*', '+', '?' => return ParseError.BadPattern, // nothing to repeat
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
        .empty => return .{ .exact = "", .best = "" },
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

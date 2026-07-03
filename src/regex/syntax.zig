//! gist — regex *syntax*: byte classes, the AST, the compiled NFA instruction,
//! and a recursive-descent parser for the supported subset. The sound AST
//! analyses that feed the prefilter (required-literal extraction, anchored-start
//! detection) live in `analysis.zig`; the execution half (Thompson NFA compile +
//! Pike simulation) lives in `core.zig`. Both import this module.
//!
//! Supported (ASCII / byte-oriented, matching ripgrep's `(?-u)` mode):
//!   literals · `.` (any byte but '\n') · `[...]` / `[^...]` with `a-z` ranges
//!   and POSIX bracket classes `[[:alpha:]]` … `[[:^space:]]` (ASCII sets, the
//!   `(?-u)` twins rg accepts) · `*` `+` `?` · `{n}` `{n,}` `{n,m}` counted
//!   repetition · `|` · `(...)` grouping · line anchors `^` `$` · word
//!   boundaries `\b` `\B` (ASCII, the `[0-9A-Za-z_]` class — exactly rg
//!   `--no-unicode`) · escapes
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
    /// ASCII case-fold: for every letter present, also admit its opposite-case
    /// twin (`a`⇄`A`). Drives the `-i` flag — applied to every consuming class so
    /// a folded literal byte becomes a 2-member set, which `only` then reports as
    /// non-singleton, so `required`-literal extraction yields "" and the query
    /// soundly falls back to a full scan (trigrams are case-sensitive). Idempotent
    /// — safe to re-apply to a shared (DAG) node.
    pub fn foldCase(self: *ByteSet) void {
        var c: u8 = 'a';
        while (c <= 'z') : (c += 1) {
            const up = c - ('a' - 'A');
            if (self.has(c)) self.set(up);
            if (self.has(up)) self.set(c);
        }
    }
};

/// Recursively ASCII case-fold every consuming class in the AST so the compiled
/// engine (NFA · DFA · Pike alike) matches case-insensitively — the `-i` flag.
/// Zero-width assertions and structure are untouched. The AST is a DAG (`{n,m}`
/// shares its atom pointer across copies); `foldCase` is idempotent, so
/// re-visiting a shared node is harmless.
pub fn foldCaseAst(n: *Node) void {
    switch (n.*) {
        .class => |*s| s.foldCase(),
        .concat, .alt => |kids| {
            foldCaseAst(kids[0]);
            foldCaseAst(kids[1]);
        },
        .star, .plus, .quest => |r| foldCaseAst(r.node),
        .capture => |g| foldCaseAst(g.child),
        .empty, .anchor_start, .anchor_end, .word_boundary, .not_word_boundary => {},
    }
}

pub const Node = union(enum) {
    empty,
    class: ByteSet, // a single consuming step (literal byte, ., \d, [..])
    anchor_start, // `^` — zero-width, asserts start of line
    anchor_end, // `$` — zero-width, asserts end of line
    word_boundary, // `\b` — zero-width, asserts a word/non-word transition
    not_word_boundary, // `\B` — zero-width, asserts NO such transition
    concat: [2]*Node,
    alt: [2]*Node,
    // Quantifiers carry a `lazy` flag: greedy (`a*`) prefers to consume, lazy
    // (`a*?`) prefers to stop — this flips only the Thompson `split` PRIORITY, so
    // it changes which leftmost match is chosen (the span), never whether a match
    // exists (boolean/DFA semantics and the reachable-end oracle are laziness-
    // independent). RE2/rust-regex (ripgrep) non-greedy semantics.
    star: Rep,
    plus: Rep,
    quest: Rep,
    // A capturing group `(child)` tagged with its 1-based group index. STRUCTURALLY
    // TRANSPARENT to the match engine (the main compiler + every analysis lower it
    // exactly like its child, so the DFA/Pike boolean semantics are unchanged); the
    // idx is consumed only by the separate capture VM in `captures.zig`, which needs
    // group boundaries for `-r`/`--json`.
    capture: struct { idx: u32, child: *Node },

    /// A quantified sub-expression: the repeated `node` plus greedy/lazy priority.
    pub const Rep = struct { node: *Node, lazy: bool = false };
};

/// A `(?P<name>…)` / `(?<name>…)` group's name paired with its 1-based index —
/// recorded only when the parser is given a `names` sink (the capture VM), so the
/// hot main-engine parse allocates nothing extra.
pub const NamedCap = struct { name: []const u8, idx: u32 };

/// A compiled Thompson-NFA instruction (the flat program `core.zig`'s compiler
/// emits and both the Pike VM and the lazy DFA execute). Lives here, beside the
/// AST it lowers from, so `dfa.zig` can determinize over it without an
/// import cycle through `core.zig`.
pub const State = union(enum) {
    consume: struct { set: ByteSet, out: u32 },
    split: struct { a: u32, b: u32 },
    assert_start: u32, // zero-width `^`: pass to `out` only at line start
    assert_end: u32, // zero-width `$`: pass to `out` only at line end
    assert_word_b: u32, // zero-width `\b`: pass to `out` only at a word boundary
    assert_not_word_b: u32, // zero-width `\B`: pass to `out` only off a boundary
    match,
};

pub const ParseError = error{ BadPattern, OutOfMemory };

pub const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,
    /// Running count of capturing groups seen (assigns 1-based group indices in
    /// opening-paren order — PCRE/rust-regex numbering).
    ncaps: u32 = 0,
    /// Optional sink for `(?P<name>…)` / `(?<name>…)` names. Null on the main-engine
    /// parse (names are irrelevant there); set by the capture VM's parse.
    names: ?*std.ArrayList(NamedCap) = null,
    /// Dotall (`-s`/`(?s)`): `.` also matches `\n`. Only meaningful together with
    /// `multiline` (whole-buffer matching) — in the per-line default a line never
    /// contains `\n`, so it is inert. Default off (rg `.` excludes `\n`).
    dotall: bool = false,
    /// Multiline (`-U`/`--multiline`): the engine matches the WHOLE buffer as one
    /// haystack (a match may span `\n`), so a negated class `[^…]` must retain
    /// `\n` (rg semantics: only `.` is special about newlines). In the per-line
    /// default we strip `\n` from `.` and `[^…]` so no thread crosses a line
    /// boundary in the fused DFA scan. Default off.
    multiline: bool = false,

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

    // repeat := atom (('*'|'+'|'?'|'{'n[,m]'}') '?'?)*
    // A trailing `?` on any quantifier makes it LAZY (`a*?`, `a+?`, `a??`,
    // `a{2,5}?`) — RE2/rust-regex non-greedy. `lazyMark` consumes that optional `?`.
    fn parseRepeat(p: *Parser) ParseError!*Node {
        var a = try p.parseAtom();
        while (p.peek()) |c| {
            switch (c) {
                '*', '+', '?' => {
                    const op = p.take();
                    const lazy = p.lazyMark();
                    a = try p.node(switch (op) {
                        '*' => .{ .star = .{ .node = a, .lazy = lazy } },
                        '+' => .{ .plus = .{ .node = a, .lazy = lazy } },
                        else => .{ .quest = .{ .node = a, .lazy = lazy } },
                    });
                },
                '{' => {
                    // An unescaped `{` MUST begin a valid `{n}`/`{n,}`/`{n,m}`
                    // spec — rust-regex (ripgrep) errors otherwise, so we mirror
                    // it (a literal brace is `\{`). `tryBound` restores `pos` on
                    // failure; here that just precedes the error.
                    const b = p.tryBound() orelse return ParseError.BadPattern;
                    a = try p.expand(a, b, p.lazyMark());
                },
                else => break,
            }
        }
        return a;
    }

    /// Consume a trailing `?` laziness marker after a quantifier, if present.
    fn lazyMark(p: *Parser) bool {
        if (p.peek() == '?') {
            _ = p.take();
            return true;
        }
        return false;
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
    fn expand(p: *Parser, atom: *Node, b: Bound, lazy: bool) ParseError!*Node {
        if (b.min > max_repeat or (b.max orelse 0) > max_repeat) return ParseError.BadPattern;
        if (b.max) |mx| if (mx < b.min) return ParseError.BadPattern;

        var result: ?*Node = null;
        var i: usize = 0;
        while (i < b.min) : (i += 1) result = try p.chain(result, atom);

        // The optional tail carries the laziness: `a{2,5}?` prefers FEWER copies
        // (each optional copy is a lazy `quest`), `a{2,}?` a lazy trailing `star`.
        if (b.max) |mx| {
            var k = b.min;
            while (k < mx) : (k += 1) result = try p.chain(result, try p.node(.{ .quest = .{ .node = atom, .lazy = lazy } }));
        } else {
            result = try p.chain(result, try p.node(.{ .star = .{ .node = atom, .lazy = lazy } }));
        }
        return result orelse p.node(.empty);
    }

    /// Read a group name up to (and consuming) the closing `>` — the `<` already
    /// consumed. Returns the name slice into `src`.
    fn nameUntilGt(p: *Parser) ParseError![]const u8 {
        const s = p.pos;
        while (p.peek()) |ch| {
            if (ch == '>') {
                const nm = p.src[s..p.pos];
                _ = p.take();
                return nm;
            }
            _ = p.take();
        }
        return ParseError.BadPattern;
    }

    fn parseAtom(p: *Parser) ParseError!*Node {
        const c = p.peek() orelse return ParseError.BadPattern;
        switch (c) {
            '(' => {
                _ = p.take();
                // Group flavor: a plain `(…)` and named `(?P<n>…)`/`(?<n>…)` groups
                // CAPTURE (get a 1-based index, recorded structurally so the capture
                // VM can extract them); `(?:…)` is non-capturing. Lookaround
                // (`(?=`,`(?!`,`(?<=`,`(?<!`) needs backtracking gist's linear engine
                // can't do → BadPattern.
                var capturing = true;
                var name: ?[]const u8 = null;
                if (p.peek() == '?') {
                    _ = p.take();
                    switch (p.peek() orelse return ParseError.BadPattern) {
                        ':' => {
                            _ = p.take();
                            capturing = false;
                        },
                        'P' => { // (?P<name>…) or (?P=name) backref (unsupported)
                            _ = p.take();
                            if (p.peek() != '<') return ParseError.BadPattern;
                            _ = p.take();
                            name = try p.nameUntilGt();
                        },
                        '<' => { // (?<name>…) — but (?<= / (?<! are lookbehind
                            _ = p.take();
                            if (p.peek() == '=' or p.peek() == '!') return ParseError.BadPattern;
                            name = try p.nameUntilGt();
                        },
                        else => return ParseError.BadPattern, // (?=,(?!,inline flags
                    }
                }
                // Assign the group index BEFORE parsing the body so nested groups
                // number after their enclosing one (opening-paren order).
                var idx: u32 = 0;
                if (capturing) {
                    p.ncaps += 1;
                    idx = p.ncaps;
                    if (name) |nm| if (p.names) |lst| lst.append(p.arena, .{ .name = nm, .idx = idx }) catch return ParseError.OutOfMemory;
                }
                const inner = try p.parseAlt();
                if (p.peek() != ')') return ParseError.BadPattern;
                _ = p.take();
                if (!capturing) return inner;
                return p.node(.{ .capture = .{ .idx = idx, .child = inner } });
            },
            '[' => return p.parseClass(),
            '.' => {
                _ = p.take();
                var s = ByteSet{};
                s.bits = @splat(~@as(u64, 0));
                // `.` excludes `\n` (rg default) unless dotall is on for a
                // whole-buffer match; in the per-line model dotall is inert
                // (no line carries a `\n`), so gate it on `multiline` too.
                if (!(p.dotall and p.multiline)) s.bits[0] &= ~(@as(u64, 1) << '\n');
                return p.node(.{ .class = s });
            },
            '\\' => {
                _ = p.take(); // consume the backslash
                // `\b`/`\B` are zero-width word-boundary assertions — they don't
                // lower to a byte class, so they're resolved here in atom position
                // (mirroring `^`/`$`) rather than in `parseEscape`, which returns a
                // ByteSet. Inside a class `[...]` `\b` stays a literal byte (the
                // `parseClass`→`parseEscape` path is untouched), matching rg.
                if (p.peek()) |e| if (e == 'b' or e == 'B') {
                    _ = p.take();
                    return p.node(if (e == 'b') .word_boundary else .not_word_boundary);
                };
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
            'f' => s.set(0x0C),
            'v' => s.set(0x0B),
            'a' => s.set(0x07),
            '0' => s.set(0), // NUL (rg's `\0`)
            'x' => s.set(try p.hexByte()), // \xNN or \x{H..H}
            else => s.set(e), // \. \* \\ \/ … → literal
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
            if (c == '[' and try p.tryPosixClass(&s)) {
                first = false;
                continue;
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

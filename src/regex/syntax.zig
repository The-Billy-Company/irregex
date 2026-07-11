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
//!   repetition · `|` · `(...)` grouping · line anchors `^` `$` · haystack
//!   anchors `\A` `\z` (start/end of haystack — the line in the per-line
//!   default, the whole buffer under multiline) · word boundaries `\b` `\B`
//!   and the one-sided `\<` `\>` (word start/end; ASCII, the `[0-9A-Za-z_]`
//!   class — exactly rg `--no-unicode`) · escapes
//!   `\t \n \r \f \v \a \xNN \x{H..H} \d \D \w \W \s \S` plus any escaped
//!   ASCII punctuation (`\. \* \\ \/ \-` … → the literal byte).
//! rg-parity rejections (BadPattern, never a silent literal): `\0`–`\9`
//! (backreference syntax — unsupported in a linear-time engine; NUL is `\x00`),
//! any other escaped ASCII letter or digit (`\q`, `\e`, `\Z`, … — rg's
//! "unrecognized escape sequence"), and any assertion escape inside a class
//! (`[\b]`, `[\A]`, `[\z]`, `[\<]`, `[\>]` — rg's "invalid escape sequence
//! found in character class").
//! Like rust-regex, an unescaped `{` must begin a valid count (else BadPattern;
//! a literal brace is `\{`); a stray `}` is literal.

const std = @import("std");
const charclass = @import("charclass.zig");

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
        .empty, .anchor_start, .anchor_end, .anchor_buf_start, .anchor_buf_end, .word_boundary, .not_word_boundary, .word_start, .word_end => {},
    }
}

pub const Node = union(enum) {
    empty,
    class: ByteSet, // a single consuming step (literal byte, ., \d, [..])
    anchor_start, // `^` — zero-width, asserts start of line
    anchor_end, // `$` — zero-width, asserts end of line
    anchor_buf_start, // `\A` under multiline — zero-width, asserts start of BUFFER
    anchor_buf_end, // `\z` under multiline — zero-width, asserts end of BUFFER
    word_boundary, // `\b` — zero-width, asserts a word/non-word transition
    not_word_boundary, // `\B` — zero-width, asserts NO such transition
    word_start, // `\<` — zero-width, holds iff !word_before && word_after
    word_end, // `\>` — zero-width, holds iff word_before && !word_after
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
    assert_word_start: u32, // zero-width `\<`: only where a word BEGINS (¬word|word)
    assert_word_end: u32, // zero-width `\>`: only where a word ENDS (word|¬word)
    assert_buf_start: u32, // zero-width `\A` (multiline): pass only at buffer start
    assert_buf_end: u32, // zero-width `\z` (multiline): pass only at buffer end
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

    pub fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }
    pub fn take(p: *Parser) u8 {
        const c = p.src[p.pos];
        p.pos += 1;
        return c;
    }
    pub fn node(p: *Parser, v: Node) ParseError!*Node {
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
            '[' => return charclass.parseClass(p),
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
                // Zero-width assertion escapes don't lower to a byte class, so
                // they're resolved here in atom position (mirroring `^`/`$`)
                // rather than in `parseEscape`, which returns a ByteSet. They are
                // atom-position ONLY: inside a class `[...]` each of these is
                // BadPattern (rg: "invalid escape sequence found in character
                // class") — `parseEscape` enforces that.
                if (p.peek()) |e| switch (e) {
                    'b', 'B' => {
                        _ = p.take();
                        return p.node(if (e == 'b') .word_boundary else .not_word_boundary);
                    },
                    '<', '>' => { // rg's one-sided word boundaries (word start/end)
                        _ = p.take();
                        return p.node(if (e == '<') .word_start else .word_end);
                    },
                    // `\A`/`\z` anchor the HAYSTACK. In the per-line default the
                    // haystack is the line, so they coincide with `^`/`$` and
                    // lower to the existing nodes (zero engine changes); under
                    // multiline the haystack is the whole buffer — a distinct
                    // assertion from the line-boundary `^`/`$` — so they get
                    // their own nodes. (`\Z` is NOT rg syntax — it falls through
                    // to `parseEscape`'s unrecognized-letter rejection.)
                    'A', 'z' => {
                        _ = p.take();
                        if (e == 'A') return p.node(if (p.multiline) .anchor_buf_start else .anchor_start);
                        return p.node(if (p.multiline) .anchor_buf_end else .anchor_end);
                    },
                    else => {},
                };
                return p.node(.{ .class = try charclass.parseEscape(p) });
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
};

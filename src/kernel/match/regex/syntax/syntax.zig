// MONOLITHIC: regex syntax plane — ByteSet/ScalarSet classes, the AST, the recursive-descent parser, and NFA instruction lowering share one grammar; splitting forks the class/AST invariants the parser and compiler co-maintain
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
const uni = @import("../unicode/tables.zig");
const udec = @import("../unicode/decode.zig");
const bitsmod = @import("../../../primitives/bits.zig");

const B64 = bitsmod.Field(u64);

/// 256-bit byte class (which bytes a consuming state accepts).
pub const ByteSet = struct {
    bits: [4]u64 = @splat(0),

    pub fn set(self: *ByteSet, b: u8) void {
        B64.set(&self.bits, b);
    }
    /// Inclusive [lo, hi]; a reversed range adds nothing (parser contract).
    pub fn setRange(self: *ByteSet, lo: u8, hi: u8) void {
        if (lo > hi) return;
        B64.setRange(&self.bits, lo, hi); // word-masked: O(words), not O(hi−lo)
    }
    pub fn has(self: *const ByteSet, b: u8) bool {
        return B64.get(&self.bits, b);
    }
    pub fn remove(self: *ByteSet, b: u8) void {
        B64.clear(&self.bits, b);
    }
    pub fn negate(self: *ByteSet) void {
        for (&self.bits) |*w| w.* = ~w.*;
    }
    pub fn unionWith(self: *ByteSet, o: ByteSet) void {
        for (&self.bits, o.bits) |*w, ow| w.* |= ow;
    }
    pub fn count(self: *const ByteSet) usize {
        return B64.count(&self.bits);
    }
    /// The sole member when the set is a singleton (drives the SIMD `memchr`
    /// skip in the regex scanner); null for empty or multi-byte sets.
    pub fn only(self: *const ByteSet) ?u8 {
        if (self.count() != 1) return null;
        return @intCast(B64.first(&self.bits).?);
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

/// Recursively case-fold every consuming class in the AST so the compiled engine
/// (NFA · DFA · Pike alike) matches case-insensitively — the `-i` flag. Zero-width
/// assertions and structure are untouched. The AST is a DAG (`{n,m}` shares its
/// atom pointer across copies); every fold operation here is idempotent, so
/// re-visiting a shared node is harmless.
///
/// ASCII mode (`unicode=false`) is the fast in-place `a`⇄`A` fold on the `ByteSet`.
/// Unicode mode expands each codepoint to its full simple case-fold orbit — `k`
/// also matches `K` and KELVIN SIGN (U+212A), `é`⇄`É`, `ς`⇄`σ`⇄`Σ` — which can
/// promote an ASCII `class` to a `uclass` when the orbit escapes ASCII, exactly
/// rg's default `-i`. Allocation (only on a Unicode promotion) is on `gpa`.
pub fn foldCaseAst(gpa: std.mem.Allocator, n: *Node, unicode: bool) ParseError!void {
    switch (n.*) {
        .class => |*s| {
            if (!unicode) return s.foldCase();
            // Unicode fold: seed a scalar set with the present bytes, expand each
            // orbit, and rewrite the node (promoting to `uclass` if it leaves ASCII).
            var ss = ScalarSet{ .gpa = gpa };
            try ss.addByteSet(s);
            try ss.foldExpand();
            try ss.writeInto(gpa, n);
        },
        .uclass => |ranges| {
            var ss = ScalarSet{ .gpa = gpa };
            try ss.addTable(ranges);
            try ss.foldExpand();
            try ss.writeInto(gpa, n);
        },
        .concat, .alt => |kids| {
            try foldCaseAst(gpa, kids[0], unicode);
            try foldCaseAst(gpa, kids[1], unicode);
        },
        .star, .plus, .quest => |r| try foldCaseAst(gpa, r.node, unicode),
        .capture => |g| try foldCaseAst(gpa, g.child, unicode),
        .empty, .anchor_start, .anchor_end, .anchor_buf_start, .anchor_buf_end, .word_boundary, .not_word_boundary, .word_start, .word_end => {},
    }
}

/// The regex AST — what recursive descent (`Parser`) produces and every
/// downstream compiler/analysis consumes (`compile.zig`, `captures.zig`,
/// `analysis.zig`). Arena-allocated; nodes are never freed piecewise.
pub const Node = union(enum) {
    empty,
    class: ByteSet, // a single consuming step (literal byte, ., \d, [..])
    // A Unicode codepoint class: a sorted, coalesced list of inclusive scalar
    // ranges (`é`, `\w`, `\p{L}`, `[^a]` in Unicode mode, a fold orbit). Lowers to
    // a compact UTF-8 byte sub-automaton in `compile.zig`/`captures.zig`. An
    // all-ASCII set never becomes a `uclass` — it stays the fast single-byte
    // `class` — so a `uclass` always carries ≥1 non-ASCII (multi-byte) codepoint.
    uclass: []const [2]u21,
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

/// The one error set of the whole compile pipeline: a pattern the grammar
/// rejects, or allocation failure. Re-exported by every engine module.
pub const ParseError = error{ BadPattern, OutOfMemory };

/// A mutable set of Unicode scalar ranges, accumulated while parsing a class in
/// Unicode mode (`.`, a non-ASCII literal, `\w`/`\d`/`\s`, `\p{…}`, `[…]`). Ranges
/// are appended unsorted; `finish` coalesces once and lowers to the leanest node —
/// a fast single-byte `class` when the set is entirely ASCII, else a `uclass`.
/// All allocation is on the parser arena, so nothing is freed piecewise.
pub const ScalarSet = struct {
    list: std.ArrayList([2]u21) = .empty,
    gpa: std.mem.Allocator,

    fn addRange(self: *ScalarSet, lo: u21, hi: u21) ParseError!void {
        if (lo > hi) return; // empty/reversed contributes nothing
        try self.list.append(self.gpa, .{ lo, hi });
    }
    fn addTable(self: *ScalarSet, t: []const [2]u21) ParseError!void {
        for (t) |r| try self.addRange(r[0], r[1]);
    }
    /// Union the members of an (ASCII) byte set as coalesced runs — the bridge for
    /// POSIX bracket classes, which stay byte-defined even in Unicode mode.
    fn addByteSet(self: *ScalarSet, bs: *const ByteSet) ParseError!void {
        var b: u16 = 0;
        while (b <= 0xFF) {
            if (!bs.has(@intCast(b))) {
                b += 1;
                continue;
            }
            const lo = b;
            while (b <= 0xFF and bs.has(@intCast(b))) b += 1;
            try self.addRange(@intCast(lo), @intCast(b - 1));
        }
    }

    /// Sort by low bound and merge overlapping/adjacent ranges in place.
    fn coalesce(self: *ScalarSet) void {
        const items = self.list.items;
        std.mem.sort([2]u21, items, {}, struct {
            fn lt(_: void, a: [2]u21, b: [2]u21) bool {
                return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
            }
        }.lt);
        var w: usize = 0;
        for (items) |r| {
            // `+1` widened to u32: `hi` can be 0x10FFFF, whose successor overflows u21.
            if (w > 0 and r[0] <= @as(u32, items[w - 1][1]) + 1) {
                if (r[1] > items[w - 1][1]) items[w - 1][1] = r[1];
            } else {
                items[w] = r;
                w += 1;
            }
        }
        self.list.shrinkRetainingCapacity(w);
    }

    /// Complement within the whole scalar space `[0, 0x10FFFF]` (the surrogate gap
    /// needn't be excluded — `utf8seq` drops it on lowering).
    fn negate(self: *ScalarSet) ParseError!void {
        self.coalesce();
        var out: std.ArrayList([2]u21) = .empty;
        var next: u32 = 0;
        for (self.list.items) |r| {
            if (r[0] > next) try out.append(self.gpa, .{ @intCast(next), r[0] - 1 });
            next = @as(u32, r[1]) + 1;
        }
        if (next <= 0x10FFFF) try out.append(self.gpa, .{ @intCast(next), 0x10FFFF });
        self.list = out;
    }

    /// Remove a single codepoint, splitting the range that holds it — strips `\n`
    /// from `.` and negated classes in the per-line model (no thread may cross a
    /// line boundary in the fused doc scan).
    fn dropCp(self: *ScalarSet, cp: u21) ParseError!void {
        self.coalesce();
        var out: std.ArrayList([2]u21) = .empty;
        for (self.list.items) |r| {
            if (cp < r[0] or cp > r[1]) {
                try out.append(self.gpa, r);
                continue;
            }
            if (cp > r[0]) try out.append(self.gpa, .{ r[0], cp - 1 });
            if (cp < r[1]) try out.append(self.gpa, .{ cp + 1, r[1] });
        }
        self.list = out;
    }

    fn allAscii(self: *const ScalarSet) bool {
        for (self.list.items) |r| if (r[1] > 0x7F) return false;
        return true;
    }

    /// Expand every codepoint in the set to its simple case-fold orbit (the `-i`
    /// Unicode fold): `k` gains `K` and KELVIN SIGN, `é` gains `É`. Idempotent —
    /// re-applying adds only members already present.
    fn foldExpand(self: *ScalarSet) ParseError!void {
        self.coalesce();
        var members: std.ArrayList(u21) = .empty;
        try uni.foldMembers(self.list.items, self.gpa, &members);
        for (members.items) |cp| try self.addRange(cp, cp);
    }

    /// Write the coalesced set into an existing node as the leanest representation:
    /// a fast single-byte `class` when entirely ASCII (trigram extraction + byte
    /// DFA unchanged), else a `uclass`.
    fn writeInto(self: *ScalarSet, gpa: std.mem.Allocator, n: *Node) ParseError!void {
        self.coalesce();
        if (self.allAscii()) {
            var bs = ByteSet{};
            for (self.list.items) |r| bs.setRange(@intCast(r[0]), @intCast(r[1]));
            n.* = .{ .class = bs };
            return;
        }
        n.* = .{ .uclass = try gpa.dupe([2]u21, self.list.items) };
    }

    /// Lower to a fresh node (the parse-time entry point).
    fn finish(self: *ScalarSet, p: *Parser) ParseError!*Node {
        const n = try p.arena.create(Node);
        try self.writeInto(p.arena, n);
        return n;
    }
};

/// Recursive-descent parser over the rg-compatible pattern grammar. Entry point
/// is `parseAlt`; the caller checks `pos == src.len` for a full-input parse.
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
    /// Unicode mode (rg default; `(?-u)`/`--no-unicode` clears it). When set, the
    /// parser decodes UTF-8 codepoints: a non-ASCII literal, `.`, `\w`/`\d`/`\s`,
    /// `\p{…}`, and `[…]` with non-ASCII content lower to a `uclass` (a codepoint
    /// class → UTF-8 byte sub-automaton). Cleared, the parser stays a pure byte
    /// engine (today's `(?-u)` behavior, byte-for-byte). Defaults off until the
    /// engine-wide default flip; callers opt in via `Regex.Options.unicode`.
    unicode: bool = false,

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }
    /// Decode the UTF-8 codepoint at `pos`, advancing past it; null (no advance)
    /// on ill-formed UTF-8, so the caller can fall back to a single-byte literal.
    fn decodeCp(p: *Parser) ?u21 {
        const d = udec.decode(p.src[p.pos..]) orelse return null;
        p.pos += d.len;
        return d.cp;
    }
    fn take(p: *Parser) u8 {
        const c = p.src[p.pos];
        p.pos += 1;
        return c;
    }
    /// Consume the next byte iff it equals `c`; report whether it did.
    fn eat(p: *Parser, c: u8) bool {
        if (p.pos >= p.src.len or p.src[p.pos] != c) return false;
        p.pos += 1;
        return true;
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
    /// A single-codepoint node (Unicode mode): a byte `class` when ASCII, else a
    /// one-range `uclass`.
    fn cpNode(p: *Parser, cp: u21) ParseError!*Node {
        var ss = ScalarSet{ .gpa = p.arena };
        try ss.addRange(cp, cp);
        return ss.finish(p);
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
        while (p.eat('|')) left = try p.node(.{ .alt = .{ left, try p.parseConcat() } });
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
        return p.eat('?');
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
        if (p.eat(',')) max = p.digits(); // digits ⇒ `{n,m}`; none ⇒ `{n,}` unbounded
        if (!p.eat('}')) {
            p.pos = save;
            return null;
        }
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
        for (0..b.min) |_| result = try p.chain(result, atom);

        // The optional tail carries the laziness: `a{2,5}?` prefers FEWER copies
        // (each optional copy is a lazy `quest`), `a{2,}?` a lazy trailing `star`.
        if (b.max) |mx| {
            for (b.min..mx) |_| result = try p.chain(result, try p.node(.{ .quest = .{ .node = atom, .lazy = lazy } }));
        } else {
            result = try p.chain(result, try p.node(.{ .star = .{ .node = atom, .lazy = lazy } }));
        }
        return result orelse p.node(.empty);
    }

    /// Read a group name up to (and consuming) the closing `>` — the `<` already
    /// consumed. Returns the name slice into `src`.
    fn nameUntilGt(p: *Parser) ParseError![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, '>') orelse return ParseError.BadPattern;
        defer p.pos = end + 1;
        return p.src[p.pos..end];
    }

    // ─────────────────────────── Unicode-mode parsing ───────────────────────────

    /// Union `table`'s complement over the whole scalar space into `ss`, minus
    /// `\n` in the per-line model (so it can't bridge a line) — the shared
    /// negated-class tail of `\D \W \S` and `\P{…}`.
    fn addNegated(p: *Parser, ss: *ScalarSet, table: []const [2]u21) ParseError!void {
        var tmp = ScalarSet{ .gpa = p.arena };
        try tmp.addTable(table);
        try tmp.negate();
        if (!p.multiline) try tmp.dropCp('\n');
        try ss.addTable(tmp.list.items);
    }

    /// Union a Perl class (`\d \w \s`, or its negation `\D \W \S`) into `ss` using
    /// the Unicode tables. A negated class is the complement over the whole scalar
    /// space, minus `\n` in the per-line model (so it can't bridge a line).
    fn addPerl(p: *Parser, ss: *ScalarSet, e: u8) ParseError!void {
        const table = switch (std.ascii.toLower(e)) {
            'd' => uni.digit,
            'w' => uni.word,
            's' => uni.space,
            else => unreachable,
        };
        return if (std.ascii.isUpper(e)) p.addNegated(ss, table) else ss.addTable(table);
    }

    /// Parse a `\p{…}` / `\pL` property body and union its ranges into `ss`; `\P…`
    /// unions the complement. Unknown property ⇒ BadPattern (rg rejects too).
    fn addProp(p: *Parser, ss: *ScalarSet, negated: bool) ParseError!void {
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
        return if (negated) p.addNegated(ss, ranges) else ss.addTable(ranges);
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
    fn hexCp(p: *Parser) ParseError!u21 {
        const val = try p.hexScan(0x10FFFF);
        if (val > 0x10FFFF or (val >= 0xD800 and val <= 0xDFFF)) return ParseError.BadPattern;
        return @intCast(val);
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
                try p.addPerl(ss, e);
                return .class;
            },
            'p', 'P' => {
                try p.addProp(ss, e == 'P');
                return .class;
            },
            'x' => return .{ .cp = try p.hexCp() },
            't', 'n', 'r', 'f', 'v', 'a' => return .{ .cp = ctrlByte(e) },
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
    fn parseClassU(p: *Parser) ParseError!*Node {
        _ = p.take(); // '['
        var ss = ScalarSet{ .gpa = p.arena };
        const neg = p.eat('^');
        var first = true;
        while (p.peek()) |c| {
            if (c == ']' and !first) {
                _ = p.take();
                if (neg) {
                    try ss.negate();
                    if (!p.multiline) try ss.dropCp('\n');
                }
                return ss.finish(p);
            }
            // POSIX bracket class `[:name:]` (ASCII sets, even in Unicode mode).
            if (c == '[') {
                var bs = ByteSet{};
                if (try p.tryPosixClass(&bs)) {
                    try ss.addByteSet(&bs);
                    first = false;
                    continue;
                }
            }
            first = false;
            const lo = try p.readClassAtom(&ss);
            switch (lo) {
                .class => {}, // a shorthand: already unioned, cannot start a range
                .cp => |lo_cp| {
                    // `a-b` range — but a trailing `-` (before `]`) is literal.
                    if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                        _ = p.take(); // '-'
                        const hi = try p.readClassAtom(&ss);
                        switch (hi) {
                            .cp => |hi_cp| {
                                if (hi_cp < lo_cp) return ParseError.BadPattern;
                                try ss.addRange(lo_cp, hi_cp);
                            },
                            // `[a-\d]`: rg treats the `-` as a literal here.
                            .class => {
                                try ss.addRange(lo_cp, lo_cp);
                                try ss.addRange('-', '-');
                            },
                        }
                    } else try ss.addRange(lo_cp, lo_cp);
                },
            }
        }
        return ParseError.BadPattern; // unterminated class
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
                if (p.eat('?')) {
                    switch (p.peek() orelse return ParseError.BadPattern) {
                        ':' => {
                            _ = p.take();
                            capturing = false;
                        },
                        'P' => { // (?P<name>…) or (?P=name) backref (unsupported)
                            _ = p.take();
                            if (!p.eat('<')) return ParseError.BadPattern;
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
                    if (name) |nm| if (p.names) |lst| try lst.append(p.arena, .{ .name = nm, .idx = idx });
                }
                const inner = try p.parseAlt();
                if (!p.eat(')')) return ParseError.BadPattern;
                if (!capturing) return inner;
                return p.node(.{ .capture = .{ .idx = idx, .child = inner } });
            },
            '[' => return if (p.unicode) p.parseClassU() else p.parseClass(),
            '.' => {
                _ = p.take();
                // Unicode `.` is any scalar value (minus `\n` unless dotall) —
                // a codepoint class, not a single byte.
                if (p.unicode) {
                    var ss = ScalarSet{ .gpa = p.arena };
                    try ss.addRange(0, 0x10FFFF);
                    if (!(p.dotall and p.multiline)) try ss.dropCp('\n');
                    return ss.finish(p);
                }
                var s = ByteSet{ .bits = @splat(~@as(u64, 0)) };
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
                    'b', 'B', '<', '>', 'A', 'z' => {
                        _ = p.take();
                        return p.node(switch (e) {
                            'b' => .word_boundary,
                            'B' => .not_word_boundary,
                            // rg's one-sided word boundaries (word start/end)
                            '<' => .word_start,
                            '>' => .word_end,
                            // `\A`/`\z` anchor the HAYSTACK. In the per-line default the
                            // haystack is the line, so they coincide with `^`/`$` and
                            // lower to the existing nodes (zero engine changes); under
                            // multiline the haystack is the whole buffer — a distinct
                            // assertion from the line-boundary `^`/`$` — so they get
                            // their own nodes. (`\Z` is NOT rg syntax — it falls through
                            // to `parseEscape`'s unrecognized-letter rejection.)
                            'A' => if (p.multiline) .anchor_buf_start else .anchor_start,
                            else => if (p.multiline) .anchor_buf_end else .anchor_end,
                        });
                    },
                    else => {},
                };
                // Unicode mode: `\d \w \s` (+neg), `\p{…}`, and `\x`/`\x{…}` denote
                // codepoint classes; the byte escapes (`\t \n …`, punctuation) fall
                // through to the ASCII `parseEscape` (their UTF-8 == the byte).
                if (p.unicode) {
                    if (p.peek()) |e| switch (e) {
                        'd', 'D', 'w', 'W', 's', 'S', 'p', 'P' => {
                            _ = p.take();
                            var ss = ScalarSet{ .gpa = p.arena };
                            if (e == 'p' or e == 'P') try p.addProp(&ss, e == 'P') else try p.addPerl(&ss, e);
                            return ss.finish(p);
                        },
                        'x' => {
                            _ = p.take();
                            return p.cpNode(try p.hexCp());
                        },
                        else => {},
                    };
                }
                return p.node(.{ .class = try p.parseEscape() });
            },
            '^', '$' => {
                _ = p.take();
                return p.node(if (c == '^') .anchor_start else .anchor_end);
            },
            '*', '+', '?', '{' => return ParseError.BadPattern, // repeat op w/o expression
            ')', '|' => return ParseError.BadPattern,
            else => {
                // A non-ASCII literal is one codepoint (its multi-byte UTF-8
                // sequence), so `-i` can fold it and `.`/`[^…]` treat it atomically.
                if (p.unicode and c >= 0x80) {
                    if (p.decodeCp()) |cp| return p.cpNode(cp);
                }
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
            'x' => s.set(try p.hexByte()), // \xNN or \x{H..H}
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
        const val = try p.hexScan(null);
        if (val > 0xFF) return ParseError.BadPattern;
        return @intCast(val);
    }

    /// The control byte a single-letter escape denotes (`\t \n \r \f \v \a`) —
    /// the one decode shared by atom position (`parseEscape`) and class bodies
    /// (`readClassAtom`), whose value is byte == codepoint in both modes.
    fn ctrlByte(e: u8) u8 {
        return switch (e) {
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            'f' => 0x0C,
            'v' => 0x0B,
            else => 0x07, // 'a'
        };
    }

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
    fn fillPosix(s: *ByteSet, name: []const u8) bool {
        const ranges = posix_classes.get(name) orelse return false;
        for (ranges) |r| s.setRange(r[0], r[1]);
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
        const negate = p.eat('^');
        // A well-formed POSIX class closes with `:]`; otherwise the leading `[`
        // was a literal — rewind and let the caller consume it as a byte.
        const colon = std.mem.indexOfScalarPos(u8, p.src, p.pos, ':') orelse {
            p.pos = save;
            return false;
        };
        if (colon + 1 >= p.src.len or p.src[colon + 1] != ']') {
            p.pos = save;
            return false;
        }
        const name = p.src[p.pos..colon];
        p.pos = colon + 2; // past `:]`
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
        const neg = p.eat('^');
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

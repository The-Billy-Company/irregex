//! gist — the recursive descent itself: a cursor over the pattern, and the four
//! mutually-recursive grammar levels (`alt → concat → repeat → atom`).
//!
//! Only the levels that call each other live here. Everything a level *reaches
//! for* — an escape's byte set, a bracket body, the scalar accumulator — is a
//! sibling file, which is what lets this one stay the shape of the grammar
//! instead of the shape of the syntax. `Parser` carries the cursor primitives
//! those siblings need (`peek`/`take`/`eat`/`node`/`decodeCp`/`rangeDash`) plus the
//! four mode flags, so a sibling never re-derives parser state.

const std = @import("std");
const udec = @import("../unicode/decode.zig");
const tree = @import("tree.zig");
const scalars = @import("scalars.zig");
const assertion = @import("assertion.zig");
const escape = @import("escape.zig");
const bracket = @import("bracket.zig");

const ByteSet = tree.ByteSet;
const Node = tree.Node;
const NamedCap = tree.NamedCap;
const ParseError = tree.ParseError;
const ScalarSet = scalars.ScalarSet;
const Word = assertion.Word;

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
    /// Case-insensitive search (`-i`). The whole-AST fold still runs afterwards
    /// (`foldCaseAst`), so this flag exists for the one thing that pass cannot do
    /// retroactively: a *negated* class must be complemented over the ALREADY
    /// folded members, or the excluded letter's other case leaks back in — rg's
    /// `(?i)[^k]` rejects both `k` and `K`, and folding after the complement would
    /// re-admit `k`. Folding first leaves a fold-closed set, so the later pass is
    /// a no-op on it. Default off.
    caseless: bool = false,
    /// Unicode mode (rg default; `(?-u)`/`--no-unicode` clears it). When set, the
    /// parser decodes UTF-8 codepoints: a non-ASCII literal, `.`, `\w`/`\d`/`\s`,
    /// `\p{…}`, and `[…]` with non-ASCII content lower to a `uclass` (a codepoint
    /// class → UTF-8 byte sub-automaton). Cleared, the parser stays a pure byte
    /// engine (today's `(?-u)` behavior, byte-for-byte). Defaults off until the
    /// engine-wide default flip; callers opt in via `Regex.Options.unicode`.
    unicode: bool = false,

    pub fn peek(p: *const Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }
    /// Does a `-` at the cursor open an `a-z` range? Only when a byte other than
    /// the class terminator follows it — a trailing `-` (`[a-]`) is a literal
    /// member, as in rg. Both class loops ask this the same way.
    pub fn rangeDash(p: *const Parser) bool {
        return p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']';
    }
    /// Decode the UTF-8 codepoint at `pos`, advancing past it; null (no advance)
    /// on ill-formed UTF-8, so the caller can fall back to a single-byte literal.
    pub fn decodeCp(p: *Parser) ?u21 {
        const d = udec.decode(p.src[p.pos..]) orelse return null;
        p.pos += d.len;
        return d.cp;
    }
    pub fn take(p: *Parser) u8 {
        const c = p.src[p.pos];
        p.pos += 1;
        return c;
    }
    /// Consume the next byte iff it equals `c`; report whether it did.
    pub fn eat(p: *Parser, c: u8) bool {
        if (p.pos >= p.src.len or p.src[p.pos] != c) return false;
        p.pos += 1;
        return true;
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
    /// A single-codepoint node (Unicode mode): a byte `class` when ASCII, else a
    /// one-range `uclass`.
    fn cpNode(p: *Parser, cp: u21) ParseError!*Node {
        var ss = ScalarSet{ .gpa = p.arena };
        try ss.addRange(cp, cp);
        return ss.finish(p.arena);
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

    /// The assertion a `\b{…}` names, with the parser sitting on the `{`.
    ///
    /// A brace after `\b` is ambiguous: `\b{start}` is an assertion, `\b{2}` is a
    /// counted repetition of the plain boundary. rust-regex settles it on the first
    /// character — a name can only be `[A-Za-z-]` — so we rewind to the brace and
    /// answer `.boundary`, leaving the quantifier parser an untouched `{2}`. Once
    /// that first character HAS committed to a name, an unclosed or unknown one is
    /// an error rather than a silent reinterpretation: rg exits 2 there, and a
    /// `\b{stort}` quietly meaning `\b` would be a lie.
    fn specialWord(p: *Parser) ParseError!Word {
        const brace = p.pos;
        p.pos += 1;
        const from = p.pos;
        while (p.peek()) |c| : (p.pos += 1) if (!std.ascii.isAlphabetic(c) and c != '-') break;
        const name = p.src[from..p.pos];
        if (name.len == 0) {
            p.pos = brace;
            return .boundary;
        }
        if (!p.eat('}')) return ParseError.BadPattern;
        inline for (.{
            .{ "start", Word.start },           .{ "end", Word.end },
            .{ "start-half", Word.start_half }, .{ "end-half", Word.end_half },
        }) |known| if (std.mem.eql(u8, name, known[0])) return known[1];
        return ParseError.BadPattern;
    }

    /// `(?flags:…)`, entered with the cursor on the first flag letter. The flags
    /// hold for the body and for nothing after it, which is why they are put
    /// back rather than left on the parser.
    ///
    /// `i`, `s` and `u` are the three whose meaning here is the same as the
    /// caller's own option; `m` and `x` are not (this engine's `multiline` is
    /// whole-buffer matching rather than JavaScript's line-anchored `^`), so
    /// they refuse instead of quietly meaning something else. A bare `(?flags)`
    /// refuses for the same reason: its scope runs to the end of the enclosing
    /// group, and a flag that stops at the wrong paren is a wrong answer rather
    /// than a missing one.
    fn flagged(p: *Parser) ParseError!*Node {
        const was: struct { bool, bool, bool } = .{ p.caseless, p.dotall, p.unicode };
        var off = false;
        while (true) switch (p.peek() orelse return ParseError.BadPattern) {
            '-' => if (off) return ParseError.BadPattern else {
                _ = p.take();
                off = true;
            },
            // A caller-level `-i` folds the finished tree, and nothing can undo
            // that for one region, so only turning folding ON is expressible.
            'i' => if (off) return ParseError.BadPattern else {
                _ = p.take();
                p.caseless = true;
            },
            's' => {
                _ = p.take();
                p.dotall = !off;
            },
            'u' => {
                _ = p.take();
                p.unicode = !off;
            },
            ':' => {
                _ = p.take();
                break;
            },
            else => return ParseError.BadPattern,
        };
        const inner = try p.parseAlt();
        if (!p.eat(')')) return ParseError.BadPattern;
        // The caller's fold pass runs over the whole tree; a flag that holds for
        // this body alone has to fold its own, or it parses and then matches
        // case-sensitively, which is worse than refusing.
        if (p.caseless and !was[0]) try scalars.foldCaseAst(p.arena, inner, p.unicode);
        p.caseless, p.dotall, p.unicode = was;
        return inner;
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
                        'i', 's', 'u', '-' => return p.flagged(),
                        else => return ParseError.BadPattern, // (?=, (?!, (?m, (?x
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
            '[' => return if (p.unicode) bracket.parseClassU(p) else bracket.parseClass(p),
            '.' => {
                _ = p.take();
                // Unicode `.` is any scalar value (minus `\n` unless dotall) —
                // a codepoint class, not a single byte.
                if (p.unicode) {
                    var ss = ScalarSet{ .gpa = p.arena };
                    try ss.addRange(0, 0x10FFFF);
                    if (!(p.dotall and p.multiline)) try ss.dropCp('\n');
                    return ss.finish(p.arena);
                }
                var s = ByteSet{ .bits = @splat(~@as(u64, 0)) };
                // `.` excludes `\n` (rg default) unless dotall is on for a
                // whole-buffer match; in the per-line model dotall is inert
                // (no line carries a `\n`), so gate it on `multiline` too.
                if (!(p.dotall and p.multiline)) s.remove('\n');
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
                            // `\b` alone is the plain boundary; `\b{…}` names one of
                            // the four rust-regex spellings (`specialWord`).
                            'b' => .{ .word = if (p.peek() == '{') try p.specialWord() else .boundary },
                            'B' => .{ .word = .not_boundary },
                            // rg's one-sided word boundaries (word start/end)
                            '<' => .{ .word = .start },
                            '>' => .{ .word = .end },
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
                            if (e == 'p' or e == 'P') try bracket.addProp(p, &ss, e == 'P') else try bracket.addPerl(p, &ss, e);
                            return ss.finish(p.arena);
                        },
                        'x' => {
                            _ = p.take();
                            return p.cpNode(try escape.hexCp(p));
                        },
                        else => {},
                    };
                }
                return p.node(.{ .class = try escape.parseEscape(p) });
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
};

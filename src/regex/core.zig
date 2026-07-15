//! gist — T2 regex execution: a linear-time Thompson NFA over bytes (RE2 /
//! ripgrep philosophy — no backtracking, no catastrophic blowup), compiled from
//! the AST in `syntax.zig` and run with a Pike simulation. Plus the public
//! `Regex` handle carrying the required-literal that lets a regex reuse the T0
//! trigram prefilter.
//!
//! Grep semantics: a line matches if the pattern matches ANY substring of it
//! (unanchored). We never construct `.*pat.*`; the Pike simulation re-seeds the
//! start thread at every position — the standard linear search. Line anchors
//! `^` / `$` and word boundaries `\b` / `\B` are zero-width assertions resolved
//! during the epsilon-closure: `^`/`$` from the (start, end)-of-line flags at each
//! position, and `\b`/`\B` from the word-ness of the bytes straddling it (ASCII
//! `[0-9A-Za-z_]`, exactly rg `--no-unicode`). A `\b`/`\B` pattern keeps the Pike
//! VM (the byte-class DFA can't resolve word context without a separate
//! determinization, so `powerset.build` bails to null), yet still rides the
//! trigram prefilter on its bounded literal (`\bfunc\b` ⇒ "func"). Unicode classes
//! remain out of scope this tier. The equality oracle runs `rg (?-u)…` so
//! semantics coincide exactly.

const std = @import("std");
const syn = @import("syntax.zig");
const analysis = @import("analysis.zig");
const compile_mod = @import("compile.zig");
const prefilter = @import("prefilter.zig");
const dfa_mod = @import("dfa.zig");
const powerset = @import("powerset.zig");
const udec = @import("unicode/decode.zig");
const utables = @import("unicode/tables.zig");
const ByteSet = syn.ByteSet;
const Node = syn.Node;

pub const ParseError = syn.ParseError;

// The compiled Thompson-NFA instruction lives in `syntax.zig` (beside the AST it
// lowers from) so `dfa.zig` can determinize over it without an import cycle.
// Aliased here to keep the engine's references unchanged.
const State = syn.State;

/// A "word" byte for ASCII `\b`/`\B` (`(?-u)`): `[0-9A-Za-z_]` — exactly `\w`
/// and rg's `--no-unicode` word class.
fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}
/// Is the codepoint STARTING at gap-position `p` a word character? In Unicode
/// mode (rg default) the scalar straddling the gap is decoded forward and tested
/// against the full `\w` set (Alphabetic ∪ M ∪ Nd ∪ Pc ∪ Join_Control); an
/// ill-formed byte or line end is never a word char (rust-regex
/// `is_word_char::fwd`). ASCII mode is the single-byte fast path.
fn wordAt(unicode: bool, line: []const u8, p: usize) bool {
    if (p >= line.len) return false;
    if (!unicode or line[p] < 0x80) return isWordByte(line[p]);
    const d = udec.decode(line[p..]) orelse return false;
    return utables.isWord(d.cp);
}
/// Is the codepoint ending immediately BEFORE gap-position `p` a word character?
/// Unicode mode decodes the scalar backward (`decodeLast`); ASCII/`(?-u)` mode is
/// the single-byte test. False at BOL / on an ill-formed tail (rust-regex
/// `is_word_char::rev`).
fn wordBefore(unicode: bool, line: []const u8, p: usize) bool {
    if (p == 0) return false;
    if (!unicode or line[p - 1] < 0x80) return isWordByte(line[p - 1]);
    const d = udec.decodeLast(line[0..p]) orelse return false;
    return utables.isWord(d.cp);
}

pub const Regex = struct {
    states: []State,
    start: u32,
    required: []u8, // longest literal that must appear in every match ("" if none)
    // Alternation cover set: literals (each ≥3 B) whose UNION every match
    // intersects. Non-empty only when `required` is too short for a single-literal
    // prefilter but a `foo|bar`-style union is provable. Empty ⇒ unused.
    alts: []const []const u8,
    // Pure-literal EQUIVALENCE set: non-empty iff the whole pattern is exactly an
    // alternation of these literals (`panic|0x` ⇒ {panic, 0x}) — a line matches
    // ⟺ it contains one of them. Strictly stronger than `alts` (which is mere
    // containment): the boolean scan path may answer from SIMD `contains` alone,
    // with no regex engine run. Empty ⇒ unused. See `analysis.pureLiterals`.
    lits: []const []const u8,
    // Scan accelerators (verify-time, no effect on match semantics): `anchored` —
    // every match begins at line start (`^…`), seed only at pos 0; `first` — the
    // bytes that can BEGIN a match mid-line plus the precomputed skip strategy
    // (`prefilter.zig`), letting the scanner jump over dead spans instead of
    // re-seeding a closure every byte.
    anchored: bool,
    // True iff the start epsilon-reaches `match` at end-of-line (at_start=false,
    // at_end=true) — a nullable prefix then `$` (e.g. `\d*$`, `a*`, `x|$`). Such a
    // pattern matches the zero-width end of EVERY line, so `lineMatch`
    // short-circuits to true; also closes a latent Pike `.skip` soundness hole
    // (skip only seeds first-byte positions and would miss this EOL match).
    eol_empty: bool,
    // True iff the start epsilon-reaches `match` through a zero-width path that may
    // cross a word boundary (`\b{2,}$`, `\B{2}`, `x|\b$`) — a CONDITIONAL empty
    // match `eol_empty` can't see (it won't traverse `\b`/`\B`). The first-byte
    // `.skip` search would miss such a match (it only seeds before a first-byte,
    // never at a bare boundary / EOL), so these patterns take the `.plain` search.
    nullable: bool,
    first: prefilter.Prefilter,
    // T2 byte-class DFA (`dfa.zig`): the primary match engine — O(1)/byte, anchors
    // included, immutable + scratch-free, scanning a whole document in one fused
    // pass. Non-null unless the powerset blew past the cap, when the Pike VM serves
    // (the `first` prefilter accelerates that fallback's skip search).
    dfa: ?*dfa_mod.Dfa,
    // Multiline (`-U`): the pattern matches the WHOLE buffer as one haystack — a
    // match may span `\n`, and `^`/`$` anchor at every line boundary (rg's `-U`
    // default), resolved per-position against `\n` adjacency (content-dependent,
    // exactly like `\b`), so the eager `at_start`/`at_end` DFA can't serve it — a
    // multiline regex is matched by the Pike whole-buffer scan (`bufMatch`), never
    // the per-line `lineMatch`/`docMatch`. False ⇒ the per-line model, unchanged.
    multiline: bool,
    // Unicode mode (rg default; `(?-u)`/`--no-unicode` clears it). Drives the
    // word test behind `\b`/`\B`/`\<`/`\>` and `-w`: set, the codepoint straddling
    // a gap is decoded and tested against the full `\w` set; cleared, it's the
    // ASCII single-byte test (byte-for-byte today's behavior). Class/literal
    // Unicode is already baked into the compiled program at parse time; this flag
    // only reaches the content-dependent word-context assertions the Pike VM
    // resolves per position.
    unicode: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.states);
        self.allocator.free(self.required);
        freeAlts(self.allocator, self.alts);
        freeAlts(self.allocator, self.lits);
        if (self.dfa) |d| d.deinit();
        self.* = undefined;
    }

    /// Free an owned cover set (its members then its backing slice). No-op on the
    /// empty comptime literal, which has no heap backing.
    fn freeAlts(gpa: std.mem.Allocator, alts: []const []const u8) void {
        for (alts) |s| gpa.free(s);
        if (alts.len > 0) gpa.free(alts);
    }

    /// Compile-time knobs. `caseless` ASCII-folds every consuming class so the
    /// match is case-insensitive (the `-i` flag) — see `syn.foldCaseAst`.
    /// `multiline` (`-U`) matches the whole buffer as one haystack — a match may
    /// span `\n`, and `^`/`$` become line-boundary anchors (rg's `-U` default).
    /// `dotall` (`(?s)`) additionally lets `.` match `\n` (only meaningful with
    /// `multiline`). Both default off ⇒ the per-line model, byte-for-byte unchanged.
    /// `unicode` (rg default; `(?-u)`/`--no-unicode` clears it) makes the parser
    /// codepoint-aware: non-ASCII literals, `.`, `\w`/`\d`/`\s`, `\p{…}`, and
    /// non-ASCII `[…]` lower to a `uclass` (UTF-8 byte sub-automaton). Cleared, the
    /// engine is a pure byte matcher (today's `(?-u)` behavior, byte-for-byte).
    pub const Options = struct { caseless: bool = false, multiline: bool = false, dotall: bool = false, unicode: bool = false };

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) ParseError!Regex {
        return compileOpts(allocator, pattern, .{});
    }

    pub fn compileOpts(allocator: std.mem.Allocator, pattern: []const u8, opts: Options) ParseError!Regex {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var parser = syn.Parser{ .src = pattern, .arena = arena, .dotall = opts.dotall, .multiline = opts.multiline, .unicode = opts.unicode };
        const ast = try parser.parseAlt();
        if (parser.pos != pattern.len) return ParseError.BadPattern;
        // Fold BEFORE every downstream analysis (required-literal, cover, first-set,
        // DFA) so prefilter and match engines agree on the case-insensitive class.
        if (opts.caseless) try syn.foldCaseAst(arena, ast, opts.unicode);

        var c = compile_mod.Compiler{ .gpa = allocator };
        errdefer c.states.deinit(allocator);
        const match_idx = try c.push(.match);
        const start = try c.compileNode(ast, match_idx);

        const req = try analysis.literalInfo(arena, ast);
        const required = try allocator.dupe(u8, req.best);
        errdefer allocator.free(required);
        const alts = try dupeCover(allocator, arena, ast, req.best);
        errdefer freeAlts(allocator, alts);
        const lits = try dupeLits(allocator, arena, ast, opts.multiline);
        errdefer freeAlts(allocator, lits);

        const states = try c.states.toOwnedSlice(allocator);
        errdefer allocator.free(states);
        const anchored = analysis.startsAnchored(ast);
        const eol_empty = try analysis.reachesMatchEol(allocator, states, start);
        const nullable = try analysis.reachesMatchZeroWidth(allocator, states, start);
        var first_set: ByteSet = .{};
        if (!anchored) try analysis.analyzeFirst(allocator, states, start, &first_set);

        // Byte-class DFA, the primary engine: determinizes the Thompson program
        // (anchors and all); null only on powerset blow-up, when the Pike VM serves.
        // Multiline resolves `^`/`$` per-position against `\n` adjacency (a match
        // spans lines), which the eager BOL/EOL determinization can't encode — so a
        // multiline regex runs the Pike whole-buffer scan and needs no DFA. Skipping
        // the build also saves its compile cost for that (opt-in) surface.
        const dfa: ?*dfa_mod.Dfa = if (opts.multiline) null else try powerset.build(allocator, states, start, anchored);
        errdefer if (dfa) |d| d.deinit();

        return .{
            .states = states,
            .start = start,
            .required = required,
            .alts = alts,
            .lits = lits,
            .anchored = anchored,
            .eol_empty = eol_empty,
            .nullable = nullable,
            .first = prefilter.Prefilter.init(first_set),
            .dfa = dfa,
            .multiline = opts.multiline,
            .unicode = opts.unicode,
            .allocator = allocator,
        };
    }

    /// Own a copy of the alternation cover set (empty when a single-literal
    /// prefilter already applies, i.e. `best` ≥ 3, or none is provable).
    fn dupeCover(gpa: std.mem.Allocator, arena: std.mem.Allocator, ast: *Node, best: []const u8) ParseError![]const []const u8 {
        if (best.len >= 3) return &[_][]const u8{}; // single-literal prefilter wins
        const cover = (try analysis.requiredAny(arena, ast)) orelse return &[_][]const u8{};
        if (cover.len == 0) return &[_][]const u8{};
        const dst = try gpa.alloc([]const u8, cover.len);
        var n: usize = 0;
        errdefer {
            for (dst[0..n]) |s| gpa.free(s);
            gpa.free(dst);
        }
        for (cover) |s| {
            dst[n] = try gpa.dupe(u8, s);
            n += 1;
        }
        return dst;
    }

    /// Own a copy of the pure-literal equivalence set (`analysis.pureLiterals`),
    /// or empty. Multiline (`-U`) changes the match model (a match may cross
    /// `\n`), so the per-line equivalence claim doesn't hold there — skip it.
    fn dupeLits(gpa: std.mem.Allocator, arena: std.mem.Allocator, ast: *Node, multiline: bool) ParseError![]const []const u8 {
        if (multiline) return &[_][]const u8{};
        const lits = (try analysis.pureLiterals(arena, ast)) orelse return &[_][]const u8{};
        const dst = try gpa.alloc([]const u8, lits.len);
        var n: usize = 0;
        errdefer {
            for (dst[0..n]) |s| gpa.free(s);
            gpa.free(dst);
        }
        for (lits) |s| {
            dst[n] = try gpa.dupe(u8, s);
            n += 1;
        }
        return dst;
    }

    /// A run-list of active states: a program-sized fixed buffer plus a fill cursor (capacity bounded by `states.len` — `Sim.seen` dedup adds each state at most once per generation).
    const ThreadList = struct {
        buf: []u32,
        len: usize = 0,

        fn push(self: *ThreadList, s: u32) void {
            self.buf[self.len] = s;
            self.len += 1;
        }
        fn slice(self: ThreadList) []const u32 {
            return self.buf[0..self.len];
        }
    };

    /// Reusable Pike-simulation scratch (sized to the program once).
    pub const Sim = struct {
        cur: ThreadList,
        nxt: ThreadList,
        seen: []u32,
        gen: u32 = 0,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, re: *const Regex) ParseError!Sim {
            const n = re.states.len;
            const seen = try allocator.alloc(u32, n);
            @memset(seen, 0);
            return .{
                .cur = .{ .buf = try allocator.alloc(u32, n) },
                .nxt = .{ .buf = try allocator.alloc(u32, n) },
                .seen = seen,
                .allocator = allocator,
            };
        }
        pub fn deinit(self: *Sim) void {
            self.allocator.free(self.cur.buf);
            self.allocator.free(self.nxt.buf);
            self.allocator.free(self.seen);
            self.* = undefined;
        }
    };

    /// One epsilon-closure pass at a fixed input position; bundles the invariants (target `list`, per-pass `seen`/`gen` dedup, position flags) so the recursion carries only the varying state index.
    const Closure = struct {
        re: *const Regex,
        list: *ThreadList,
        seen: []u32,
        gen: u32,
        at_start: bool,
        at_end: bool,
        // Buffer-edge flags for `\A`/`\z` (multiline only — in the per-line
        // default the parser lowered them to `^`/`$`, so these states never
        // exist there and the flags are inert). Distinct from `at_start`/
        // `at_end`, which multiline resolves at every LINE boundary.
        at_buf_start: bool,
        at_buf_end: bool,
        // Word-ness of the bytes straddling this (fixed) position, for `\b`/`\B`.
        word_before: bool,
        word_after: bool,
        // Optional start-offset side-channel for `-o` span extraction: when
        // `starts` is set, every state pushed to `list` records where the thread
        // reaching it BEGAN (`cur_start`). Null on the hot boolean path (no cost).
        starts: ?[]usize = null,
        cur_start: usize = 0,

        /// Epsilon-closure of `s` into `list`; returns whether it reached the match state (so `lineMatch` answers without a second list scan). Zero-width assertions resolve against the position's flags — `^`/`$` against `at_start`/`at_end`, `\b`/`\B` against `word_before`/`word_after` (a boundary holds iff exactly one side is a word byte) — and a failed assertion just kills that branch (the position is fixed across one closure).
        fn add(c: Closure, s: u32) bool {
            if (c.seen[s] == c.gen) return false;
            c.seen[s] = c.gen;
            return switch (c.re.states[s]) {
                .split => |sp| blk: {
                    // Bind both arms first — `or` short-circuits, but both must close.
                    const a = c.add(sp.a);
                    break :blk a or c.add(sp.b);
                },
                .assert_start => |out| c.at_start and c.add(out),
                .assert_end => |out| c.at_end and c.add(out),
                .assert_buf_start => |out| c.at_buf_start and c.add(out),
                .assert_buf_end => |out| c.at_buf_end and c.add(out),
                .assert_word_b => |out| (c.word_before != c.word_after) and c.add(out),
                .assert_not_word_b => |out| (c.word_before == c.word_after) and c.add(out),
                .assert_word_start => |out| (!c.word_before and c.word_after) and c.add(out),
                .assert_word_end => |out| (c.word_before and !c.word_after) and c.add(out),
                else => blk: {
                    c.list.push(s);
                    if (c.starts) |st| st[s] = c.cur_start; // first (highest-priority) write wins
                    break :blk c.re.states[s] == .match;
                },
            };
        }
    };

    fn closure(re: *const Regex, sim: *Sim, list: *ThreadList, at_start: bool, at_end: bool, word_before: bool, word_after: bool) Closure {
        // Per-line callers: the line IS the haystack, so the buffer edges
        // coincide with `at_start`/`at_end` (and `\A`/`\z` were lowered to
        // `^`/`$` anyway). `closureBuf` overrides both for multiline.
        return .{ .re = re, .list = list, .seen = sim.seen, .gen = sim.gen, .at_start = at_start, .at_end = at_end, .at_buf_start = at_start, .at_buf_end = at_end, .word_before = word_before, .word_after = word_after };
    }

    const Scan = enum { anchored, skip, plain };

    /// Does the pattern match any substring of `line`? Linear in `line.len`.
    /// Dispatches to the cheapest sound strategy: `^…` seeds only at line start
    /// (`.anchored`); a known first-byte set drives a `memchr`-skip search
    /// (`.skip`); otherwise the plain re-seed-every-position search (`.plain`,
    /// e.g. a bare `$` whose first set is empty).
    pub fn lineMatch(re: *const Regex, sim: *Sim, line: []const u8) bool {
        // The byte-class DFA is the floor: one table lookup per byte, anchors and
        // all, regardless of match density — what the Pike skip path lost to rg on.
        // Present for every non-pathological pattern; only a powerset blow-up past
        // the cap leaves it null, and then the Pike VM (the proven oracle) serves.
        // Equivalence held by the rg oracle + the DFA-vs-Pike differential fuzz —
        // this is purely dispatch.
        if (re.eol_empty) return true; // matches every line's zero-width end (`\d*$`)
        if (re.dfa) |d| return d.match(line);
        return re.lineMatchPike(sim, line);
    }

    /// The Pike-VM-only dispatch (anchored fast path · first-byte skip · plain
    /// re-seed). The `lineMatch`/`docMatch` fallback when the powerset blew past
    /// the cap and no DFA was built, and the correctness reference the DFA's
    /// differential fuzz compares against (so the test can force the Pike path).
    pub fn lineMatchPike(re: *const Regex, sim: *Sim, line: []const u8) bool {
        if (re.eol_empty) return true; // see `eol_empty`: matches every line (`\d*$`)
        if (re.anchored) return re.search(sim, line, .anchored);
        // A conditionally-nullable pattern (`x|\b$`, `\B{2}`) can match zero-width
        // at a bare boundary / EOL the `.skip` search never seeds — it only jumps
        // to first-bytes. `.plain` re-seeds every position (EOL included), so it's
        // the sound path even when a first-set exists from another branch.
        if (re.nullable) return re.search(sim, line, .plain);
        if (re.first.count() != 0) return re.search(sim, line, .skip);
        return re.search(sim, line, .plain);
    }

    /// Unified Pike search, specialized at comptime by seeding policy:
    ///   `.anchored` — never re-seed; the instant the thread list drains, done
    ///                 (a match can only begin at line position 0).
    ///   `.skip`     — re-seed a start only where a byte could begin a match, and
    ///                 when the list empties jump to the next such byte (skipping
    ///                 dead spans the way rg's literal prefilter does). Equivalent
    ///                 to seeding every position — a start whose first byte isn't
    ///                 in `first` dies at once — minus the wasted closure work.
    ///   `.plain`    — re-seed the start at every position (first set empty).
    fn search(re: *const Regex, sim: *Sim, line: []const u8, comptime mode: Scan) bool {
        sim.gen += 1;
        sim.cur.len = 0;
        // Position 0: line start; also the end iff the line is empty. Answers any
        // empty/zero-width match (`a*`, `^$`) without scanning. `\b` here straddles
        // BOL (no byte before) and line[0].
        if (re.closure(sim, &sim.cur, true, line.len == 0, wordBefore(re.unicode, line, 0), wordAt(re.unicode, line, 0)).add(re.start)) return true;
        if (mode == .skip) sim.cur.len = 0; // drive purely by first-byte jumps
        var i: usize = 0;
        while (i < line.len) {
            if (sim.cur.len == 0) switch (mode) {
                .anchored => return false, // no live thread, no new start allowed
                .skip => {
                    i = re.first.nextStart(line, i) orelse return false;
                    sim.gen += 1;
                    sim.cur.len = 0;
                    if (re.closure(sim, &sim.cur, i == 0, i + 1 == line.len, wordBefore(re.unicode, line, i), wordAt(re.unicode, line, i)).add(re.start)) return true;
                },
                .plain => {},
            };
            const c = line[i];
            sim.nxt.len = 0;
            sim.gen += 1;
            // The next closure sits at the gap AFTER byte i (position i+1): the
            // word byte before it is line[i], the one after is line[i+1].
            const cl = re.closure(sim, &sim.nxt, false, i + 1 == line.len, wordBefore(re.unicode, line, i + 1), wordAt(re.unicode, line, i + 1));
            var matched = false;
            for (sim.cur.slice()) |s| switch (re.states[s]) {
                // `and` keeps `add` from firing on a non-matching byte; `or matched`
                // accumulates without clobbering an earlier hit this position.
                .consume => |cn| matched = (cn.set.has(c) and cl.add(cn.out)) or matched,
                else => {},
            };
            switch (mode) { // re-seed the next start per policy
                .anchored => {},
                .plain => matched = cl.add(re.start) or matched,
                .skip => matched = (i + 1 < line.len and re.first.has(line[i + 1]) and cl.add(re.start)) or matched,
            }
            std.mem.swap(ThreadList, &sim.cur, &sim.nxt);
            if (matched) return true;
            i += 1;
        }
        return false;
    }

    /// Does any line of `doc` match? rg `-l` line model: `\n` *terminates* a line, so a trailing newline yields no phantom empty final line (only a real blank line matches `^$`) — content after the last `\n` (no terminator) is still a line. (`splitScalar` would emit the phantom and over-match `^$`/`$` on every newline-terminated file vs ripgrep.)
    pub fn docMatch(re: *const Regex, sim: *Sim, doc: []const u8) bool {
        // `eol_empty` ⇒ every line matches at its zero-width end — but `docMatch`
        // asks whether SOME line matches, which for an empty doc (zero lines, not
        // one empty line) is false. rg agrees: an empty input never matches, even
        // `a*`. Conflating "every" with "some" here over-matched empty files.
        if (re.eol_empty) return doc.len > 0;
        // The DFA scans the whole buffer in one fused pass (one byte-touch); only a
        // powerset blow-up past the cap leaves it null, and then the Pike VM (proven
        // oracle) serves per line. Equivalence held by the doc-level differential fuzz.
        if (re.dfa) |d| return d.docMatch(doc);
        var rest = doc;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const end = nl orelse rest.len;
            if (re.lineMatchPike(sim, rest[0..end])) return true;
            if (nl == null) break;
            rest = rest[end + 1 ..];
        }
        return false;
    }

    // ─────────────────────── multiline (`-U`) whole-buffer match ───────────────────────
    //
    // In multiline mode the pattern is matched against the ENTIRE buffer as one
    // haystack — a match may cross `\n` — and `^`/`$` are line-boundary anchors
    // (they hold at the buffer ends AND around every `\n`, rg's `-U` default).
    // Those anchors are content-dependent (they look at the byte adjacent to the
    // position, exactly like `\b`), so the eager BOL/EOL DFA can't serve them and
    // `re.dfa` is null here; a whole-buffer Pike scan resolves them per-position.
    // `.` and negated classes already had their `\n` membership decided at parse
    // time from the multiline/dotall flags.

    /// A gap position `p` (0..=buf.len) is a line start iff it is the buffer start
    /// or immediately follows a `\n`; a line end iff it is the buffer end or a `\n`
    /// begins there. These are the multiline `^`/`$` predicates.
    fn lineStart(buf: []const u8, p: usize) bool {
        // BOF, or right after a `\n` that is NOT the final byte. A trailing final
        // `\n` terminates the last line — it does not open a phantom empty line at
        // `buf.len` (rg: `^$` matches "abc\n\n" at the real interior empty line but
        // NOT "abc\n"). `$` has no such exclusion (`\n$` matches "abc\n" at EOF).
        return p == 0 or (buf[p - 1] == '\n' and p < buf.len);
    }
    fn lineEnd(buf: []const u8, p: usize) bool {
        return p == buf.len or buf[p] == '\n';
    }

    /// `^`/`$` predicates at gap `p`: multiline resolves them against `\n`
    /// adjacency (a line boundary), the per-line default against the buffer ends.
    /// Shared by `matchSpan` so one span engine serves both modes.
    fn atStart(re: *const Regex, buf: []const u8, p: usize) bool {
        return if (re.multiline) lineStart(buf, p) else p == 0;
    }
    fn atEnd(re: *const Regex, buf: []const u8, p: usize) bool {
        return if (re.multiline) lineEnd(buf, p) else p == buf.len;
    }

    /// Epsilon-closure at a whole-buffer position `p`, resolving `^`/`$` against
    /// `\n` adjacency (multiline) rather than a single external BOL/EOL flag.
    /// `\A`/`\z` (assert_buf_*) resolve against the true buffer edges here — a
    /// line boundary is NOT a buffer edge under multiline.
    fn closureBuf(re: *const Regex, sim: *Sim, list: *ThreadList, buf: []const u8, p: usize) Closure {
        var c = re.closure(sim, list, lineStart(buf, p), lineEnd(buf, p), wordBefore(re.unicode, buf, p), wordAt(re.unicode, buf, p));
        c.at_buf_start = p == 0;
        c.at_buf_end = p == buf.len;
        return c;
    }

    /// Does the pattern match any substring of the WHOLE buffer under multiline
    /// semantics? Linear in `buf.len`: re-seed the start at every position (the
    /// plain unanchored search — a `^`-anchored branch simply dies wherever the
    /// per-position line-start assertion fails), threading `\n`-aware `^`/`$`.
    /// This is the multiline counterpart to `docMatch`; called only when
    /// `re.multiline` (the caller passes the whole file's bytes, never a split line).
    pub fn bufMatch(re: *const Regex, sim: *Sim, buf: []const u8) bool {
        // An empty document has zero lines, so it never matches — rg's line model
        // (`rg -U` on a zero-byte file reports no match for ANY pattern, even a
        // nullable `a*`/`^$`). This is the whole-buffer twin of `docMatch`'s
        // `doc.len > 0` guard; without it a nullable pattern would spuriously hit.
        if (buf.len == 0) return false;
        sim.gen += 1;
        sim.cur.len = 0;
        // Position 0 (buffer start ⇒ a line start; also a line end iff empty).
        if (re.closureBuf(sim, &sim.cur, buf, 0).add(re.start)) return true;
        var i: usize = 0;
        while (i < buf.len) : (i += 1) {
            const c = buf[i];
            sim.nxt.len = 0;
            sim.gen += 1;
            const cl = re.closureBuf(sim, &sim.nxt, buf, i + 1);
            var matched = false;
            for (sim.cur.slice()) |s| switch (re.states[s]) {
                .consume => |cn| matched = (cn.set.has(c) and cl.add(cn.out)) or matched,
                else => {},
            };
            // Plain re-seed a start at i+1 — EXCEPT at the phantom position after
            // a trailing final `\n`: that gap belongs to no line (rg's line model
            // opens no phantom empty last line), so no match may START there. A
            // bare `\z` therefore does NOT match "abc\n" while `\n\z` (a thread
            // started at the real last byte) does — both verified against rg -U.
            const phantom = i + 1 == buf.len and c == '\n';
            if (!phantom) matched = cl.add(re.start) or matched;
            std.mem.swap(ThreadList, &sim.cur, &sim.nxt);
            if (matched) return true;
        }
        return false;
    }

    // ─────────────────────── `-o` leftmost-first spans ───────────────────────
    //
    // `lineMatch`/`docMatch` answer *whether* a line matches; `-o`/--only-matching
    // needs *where* — each non-overlapping match's byte span, so gist can emit the
    // matched text alone (extraction: function names, idents, URLs, …) exactly as
    // ripgrep does. The DFA is boolean, so spans run the Pike VM with a per-state
    // start-offset map. Semantics are rg's `(?-u)`: leftmost start, then the
    // highest-priority thread wins the end — earlier alternation branches and
    // greedy quantifiers extend maximally (verified: `a|ab`→`a`, `a+`→greedy).

    /// A byte span `[start, end)` of one match within a line. `end == start` is a
    /// zero-width match (the `-o` caller advances past it to avoid looping).
    pub const Span = struct { start: usize, end: usize };

    /// Reusable Pike scratch for `matchSpan`, plus the per-state start-offset maps
    /// (`scur`/`snxt`, one entry per state id, valid for the list's generation).
    /// Kept apart from `Sim` so the hot boolean path never allocates the maps.
    pub const SpanSim = struct {
        cur: ThreadList,
        nxt: ThreadList,
        seen: []u32,
        scur: []usize,
        snxt: []usize,
        gen: u32 = 0,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, re: *const Regex) ParseError!SpanSim {
            const n = re.states.len;
            const seen = try allocator.alloc(u32, n);
            @memset(seen, 0);
            return .{
                .cur = .{ .buf = try allocator.alloc(u32, n) },
                .nxt = .{ .buf = try allocator.alloc(u32, n) },
                .seen = seen,
                .scur = try allocator.alloc(usize, n),
                .snxt = try allocator.alloc(usize, n),
                .allocator = allocator,
            };
        }
        pub fn deinit(self: *SpanSim) void {
            self.allocator.free(self.cur.buf);
            self.allocator.free(self.nxt.buf);
            self.allocator.free(self.seen);
            self.allocator.free(self.scur);
            self.allocator.free(self.snxt);
            self.* = undefined;
        }
    };

    /// The highest-priority match in a priority-ordered thread `list`: the first
    /// `.match` state and where its thread began (`starts`), paired with `end`.
    /// Also returns its list index (`cut`) so the caller drops every lower-priority
    /// thread — none can yield a preferred match. `null` ⇒ no match at this position.
    fn firstMatch(re: *const Regex, list: []const u32, starts: []const usize, end: usize) ?struct { span: Span, cut: usize } {
        for (list, 0..) |s, k| if (re.states[s] == .match)
            return .{ .span = .{ .start = starts[s], .end = end }, .cut = k };
        return null;
    }

    /// Leftmost-first match of the pattern within `line[from..]`, as a byte span,
    /// or null. Priority-ordered Pike VM: earlier starts win (leftmost), and among
    /// threads sharing a start the earliest alternation branch / greediest
    /// quantifier wins (rg `(?-u)` semantics). Once any thread matches we stop
    /// seeding new starts (leftmost) but keep strictly-higher-priority survivors
    /// running, so a greedy branch can still extend the end.
    pub fn matchSpan(re: *const Regex, sim: *SpanSim, line: []const u8, from: usize) ?Span {
        sim.gen += 1;
        sim.cur.len = 0;
        var cl = Closure{
            .re = re,
            .list = &sim.cur,
            .seen = sim.seen,
            .gen = sim.gen,
            .at_start = re.atStart(line, from),
            .at_end = re.atEnd(line, from),
            // `line` is the whole haystack handed to the span engine (a line in
            // the per-line default, the buffer under multiline), so its edges
            // ARE the `\A`/`\z` buffer edges in both modes.
            .at_buf_start = from == 0,
            .at_buf_end = from == line.len,
            .word_before = wordBefore(re.unicode, line, from),
            .word_after = wordAt(re.unicode, line, from),
            .starts = sim.scur,
            .cur_start = from,
        };
        _ = cl.add(re.start);

        var best: ?Span = null;
        var cut: usize = sim.cur.len;
        if (firstMatch(re, sim.cur.slice(), sim.scur, from)) |m| {
            best = m.span;
            cut = m.cut; // process only threads strictly higher-priority than the match
        }

        var i: usize = from;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            sim.nxt.len = 0;
            sim.gen += 1;
            const at_start = re.atStart(line, i + 1); // multiline: a `\n` at i makes i+1 a line start
            const at_end = re.atEnd(line, i + 1);
            const at_buf_end = i + 1 == line.len; // position i+1 ≥ 1 is never the buffer start
            const wb = wordBefore(re.unicode, line, i + 1);
            const wa = wordAt(re.unicode, line, i + 1);
            const slice = sim.cur.slice();
            for (slice[0..cut]) |s| switch (re.states[s]) {
                .consume => |cn| if (cn.set.has(c)) {
                    var nc = Closure{ .re = re, .list = &sim.nxt, .seen = sim.seen, .gen = sim.gen, .at_start = at_start, .at_end = at_end, .at_buf_start = false, .at_buf_end = at_buf_end, .word_before = wb, .word_after = wa, .starts = sim.snxt, .cur_start = sim.scur[s] };
                    _ = nc.add(cn.out);
                },
                else => {},
            };
            // Re-seed a fresh start at i+1 (lowest priority) only while unmatched.
            if (best == null) {
                var sc = Closure{ .re = re, .list = &sim.nxt, .seen = sim.seen, .gen = sim.gen, .at_start = at_start, .at_end = at_end, .at_buf_start = false, .at_buf_end = at_buf_end, .word_before = wb, .word_after = wa, .starts = sim.snxt, .cur_start = i + 1 };
                _ = sc.add(re.start);
            }
            std.mem.swap(ThreadList, &sim.cur, &sim.nxt);
            std.mem.swap([]usize, &sim.scur, &sim.snxt);
            cut = sim.cur.len;
            if (firstMatch(re, sim.cur.slice(), sim.scur, i + 1)) |m| {
                best = m.span; // a survivor (strictly higher priority) extends/overrides
                cut = m.cut;
            }
            if (best != null and cut == 0) break; // no higher-priority survivor left
        }
        return best;
    }
};

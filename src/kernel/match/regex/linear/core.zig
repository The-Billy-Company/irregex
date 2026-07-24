// MONOLITHIC: Pike-VM execution core — thread lists, generation-counted Sim scratch, literal analysis, and the match loop share one engine state; splitting breaks the linear-time execution contract
//! gist — T2 regex execution: a linear-time Thompson NFA over bytes (RE2 /
//! ripgrep philosophy — no backtracking, no catastrophic blowup), compiled from
//! the AST in `syntax.zig` and run with a Pike simulation. Plus the public
//! `Regex` handle carrying the required-literal that lets a regex reuse the T0
//! trigram prefilter.
//!
//! Grep semantics: a line matches if the pattern matches ANY substring of it
//! (unanchored). We never construct `.*pat.*`; the Pike simulation re-seeds the
//! start thread at every position — the standard linear search. Line anchors
//! `^` / `$` and word boundaries `\b` / `\B` / `\<` / `\>` are zero-width
//! assertions resolved during the epsilon-closure: `^`/`$` from the (start,
//! end)-of-line flags at each position, and the word boundaries from the word-ness
//! of the bytes straddling it (ASCII `[0-9A-Za-z_]`, exactly rg `--no-unicode`).
//! Word-boundary patterns are ALSO determinized: `powerset.build` refines byte
//! classes by ASCII word-ness and doubles the interior table so the DFA selects
//! the transition by the *next* byte's word-ness (`trans_in`/`trans_in_w`,
//! `start`/`start_w`) — resolving `\b`/`\B`/`\<`/`\>` at the DFA floor
//! (`dfa.matchWord`). Under Unicode a gap abutting a non-ASCII scalar is
//! undecidable by an ASCII-classed DFA, so `matchWord` QUITS and the Pike VM (the
//! oracle) resolves that line; a bounded literal still rides the trigram prefilter
//! (`\bfunc\b` ⇒ "func"). Broader Unicode word classes remain out of scope this
//! tier. The equality oracle runs `rg (?-u)…` so semantics coincide exactly.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const analysis = @import("../analysis/analysis.zig");
const compile_mod = @import("../compile/compile.zig");
const prefilter = @import("../analysis/prefilter.zig");
const dfa_mod = @import("dfa.zig");
const powerset = @import("powerset.zig");
const word = @import("../syntax/word.zig");
const simd = @import("../../scan/simd.zig");
const classrun_mod = @import("../../scan/classrun.zig");
const ByteSet = syn.ByteSet;
const Node = syn.Node;

pub const ParseError = syn.ParseError;

// The compiled Thompson-NFA instruction lives in `syntax.zig` (beside the AST it
// lowers from) so `dfa.zig` can determinize over it without an import cycle.
// Aliased here to keep the engine's references unchanged.
const State = syn.State;

// The shared `\b`/`\B`/`\<`/`\>` word test (`word.zig`) — one definition for
// this VM and the capture VM, so the two engines can never disagree.
const wordAt = word.wordAt;
const wordBefore = word.wordBefore;

/// A compiled pattern: the Thompson-NFA program plus every verify-time
/// accelerator the scanner consults (required literal, cover/equivalence sets,
/// first-byte prefilter, optional byte-class DFA). Immutable after compile;
/// per-thread scratch lives in `Sim`/`SpanSim`.
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
    // SIMD class-run kernel (`scan/classrun.zig`): non-null iff the pattern
    // provably reduces to "≥ min consecutive members of one byte set"
    // (`analysis.classRunShape` — the dense-class family: `\w+`, `[a-z]{3,}`,
    // `[0-9a-f]{8}`). Boolean dispatch consults it FIRST — it answers at load
    // bandwidth where the DFA's chained table walk pays load latency — and a
    // `.unproven` verdict (codepoint-class projection meeting a high byte)
    // falls through to the DFA/Pike engines unchanged. Boolean paths only;
    // `matchSpan` never consults it. Per-line compiles drop `\n` from the set
    // (a line never contains one), which licenses the whole-buffer `docMatch`
    // scan: runs then provably break at every line boundary.
    classrun: ?classrun_mod.ClassRun,
    // Multiline (`-U`): the pattern matches the WHOLE buffer as one haystack — a
    // match may span `\n`, and `^`/`$` anchor at every line boundary (rg's `-U`
    // default), resolved per-position against `\n` adjacency (content-dependent,
    // exactly like `\b`), so the eager `at_start`/`at_end` DFA can't serve an
    // assertion-BEARING multiline regex — it runs the Pike whole-buffer scan
    // (`bufMatch`). An assertion-FREE one (`assert_free`) has nothing positional
    // to resolve, so the DFA serves the whole buffer as one haystack at
    // O(1)/byte. False ⇒ the per-line model, unchanged.
    multiline: bool,
    // No zero-width assertion states in the compiled program (`^ $ \b \B \< \>
    // \A \z`): match validity then depends ONLY on the consumed bytes, which is
    // what licenses the multiline DFA above and makes any prefix-found match a
    // match of the full buffer (substring closure — see `bufMatch` callers).
    assert_free: bool,
    // The regex `m` flag, decoupled from `multiline` (the `-U` whole-buffer
    // search): true ⇒ `^`/`$` anchor at every `\n` (a line boundary), false ⇒
    // only at the buffer ends. Under `-U` it defaults true (rg's `m`-on default)
    // and `(?-m)` clears it — the buffer stays one haystack, but `^` holds only
    // at position 0. In the per-line model it tracks `multiline` (false), where a
    // line's own edges already are its anchors, so the distinction is inert.
    line_anchors: bool,
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
        if (self.classrun) |cr| if (cr.cp) |r| self.allocator.free(r);
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
    /// `line_anchors` decouples the regex `m` flag from `-U`: `^`/`$` anchor at
    /// every `\n` (true) or only the buffer ends (false). `null` inherits
    /// `multiline` — rg's `-U` default is `m` ON, and `(?-m)` clears it while the
    /// whole-buffer search stays live (`multiline` unchanged). Per-line mode
    /// (`multiline == false`) is unaffected: a single-line haystack's edges ARE
    /// its line boundaries either way.
    /// `force_dfa` builds the byte-class DFA even when a byte-exact class-run
    /// kernel makes it dead weight for every production path — the hook the
    /// determinizer's own proof harness (powerset/dfa tests) uses to keep
    /// exercising subset construction on class-shaped patterns.
    pub const Options = struct { caseless: bool = false, multiline: bool = false, dotall: bool = false, unicode: bool = false, line_anchors: ?bool = null, force_dfa: bool = false };

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) ParseError!Regex {
        return compileOpts(allocator, pattern, .{});
    }

    /// Can any match consume a `\n`? Mirrors rg's `multi_line_with_matcher`
    /// gate: under `-U` a pattern that can never match the line terminator is
    /// searched line-by-line (roll buffer, line-mode binary semantics), not as
    /// one slice — every consuming instruction is a `.consume` byte set, so a
    /// program-walk is a complete answer.
    pub fn canMatchNewline(self: *const Regex) bool {
        return self.canMatchByte('\n');
    }

    /// Can any match consume byte `b`? Walks the consuming instructions — a
    /// program-complete answer, since every byte a match eats is some `.consume`
    /// set.
    pub fn canMatchByte(self: *const Regex, b: u8) bool {
        for (self.states) |st| switch (st) {
            .consume => |c| if (c.set.has(b)) return true,
            else => {},
        };
        return false;
    }

    /// Does the pattern *require* byte `b` somewhere — i.e. is `b` a literal or a
    /// single-byte class? Backs rg's NUL policy (`crates/regex/src/ban.rs`): a
    /// byte is banned only when a sub-expression *must* match it, never when a
    /// broad class (`.`, `[^\x00]`, `[\x00a]`) incidentally includes it. A
    /// literal byte and a `[b]`-style singleton class each lower to a `.consume`
    /// whose set is exactly `{b}` (`only() == b`); wider classes are non-singleton
    /// and never ban. Walking every `.consume` covers all alternation branches,
    /// so `\x00|ab` bans while `[^\x00]` does not — matching rg's HIR walk.
    pub fn bansByte(self: *const Regex, b: u8) bool {
        for (self.states) |st| switch (st) {
            .consume => |c| if (c.set.only() == b) return true,
            else => {},
        };
        return false;
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
        // spans lines), which the eager BOL/EOL determinization can't encode — so an
        // assertion-BEARING multiline regex runs the Pike whole-buffer scan and
        // needs no DFA. An assertion-FREE multiline pattern (`import \([\s\S]*?\)`,
        // the whole `-U` bench class) has no positional predicate at all: its
        // determinization is exact over any haystack, so `bufMatch` gets the same
        // O(1)/byte floor the per-line model enjoys instead of the O(states)/byte
        // Pike re-seed rg's lazy DFA was beating.
        const assert_free = assertFree(states);

        // SIMD class-run reduction (post-fold, so `-i` classes are final). In
        // the per-line model a haystack line never contains `\n`, so dropping
        // it from the set is an identity there — and it makes every run
        // provably line-local, licensing the one-pass whole-buffer `docMatch`.
        // Multiline keeps the set verbatim: the buffer IS the haystack.
        // A codepoint class whose full ranges survived the AST algebra hands
        // them (gpa-duped; the arena dies with this frame) to the kernel,
        // whose scalar UTF-8 resolver then settles high bytes itself.
        const cr: ?classrun_mod.ClassRun = if (analysis.classRunShape(ast)) |shape| blk: {
            var set = shape.set;
            if (!opts.multiline) set.remove('\n');
            const cp: ?[]const [2]u21 = if (shape.cp) |r|
                if (classrun_mod.ClassRun.cpResolvable(r)) try allocator.dupe([2]u21, r) else null
            else
                null;
            var run = classrun_mod.ClassRun.build(set.bits, shape.min, shape.exact, cp) orelse {
                if (cp) |r| allocator.free(r);
                break :blk null;
            };
            // Span-exactness is a strictly stronger recognizer (window rule,
            // not just existence) — when it accepts, its leaves are the same
            // ones the boolean algebra folded, so set/min/exact agree; the
            // guard is pure paranoia. `max`/`lazy` arm `nextSpan`'s chunking.
            if (analysis.classSpanShape(ast)) |sp| {
                if (sp.min == shape.min and sp.exact == shape.exact and std.mem.eql(u64, &sp.set.bits, &shape.set.bits)) {
                    run.span = true;
                    run.max = sp.max;
                    run.lazy = sp.lazy;
                }
            }
            break :blk run;
        } else null;
        errdefer if (cr) |run| if (run.cp) |r| allocator.free(r);

        // A byte-exact class run — or a codepoint one whose full ranges the
        // kernel holds — answers every boolean entry point finally (the
        // kernel never defers), and the span path is the kernel window walk
        // (span-exact shapes) or the Pike VM (the rest) — never the DFA, so
        // it would be dead weight. Skipping determinization here is a pure
        // compile-time win: measured 77–178 ms on `(?-u)\w{3}`…`\w{3,8}`
        // (the `{n,m}` expansion clones the class sub-automaton per copy),
        // and ~168 ms on Unicode `\w{3,8}`, whose codepoint lowering makes
        // the powerset step the whole cost of compilation. Only a projection
        // WITHOUT carried ranges keeps the DFA: its `.unproven` verdicts on
        // high-byte haystacks land there.
        const kernel_final = if (cr) |run| run.exact or run.cp != null else false;
        const dfa: ?*dfa_mod.Dfa = if (opts.multiline and !assert_free)
            null
        else if (kernel_final and !opts.force_dfa)
            null
        else
            try powerset.build(allocator, states, start, anchored, opts.unicode);
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
            .classrun = cr,
            .assert_free = assert_free,
            .multiline = opts.multiline,
            .line_anchors = opts.line_anchors orelse opts.multiline,
            .unicode = opts.unicode,
            .allocator = allocator,
        };
    }

    /// No zero-width assertion instruction anywhere in the program — the
    /// compiled-program (not AST) answer, so every lowering (case fold, uclass
    /// expansion) is already reflected. Powers the multiline DFA admission.
    fn assertFree(states: []const State) bool {
        for (states) |st| switch (st) {
            .consume, .split, .match => {},
            else => return false,
        };
        return true;
    }

    /// Own a copy of the alternation cover set (empty when a single-literal
    /// prefilter already applies, i.e. `best` ≥ 3, or none is provable).
    fn dupeCover(gpa: std.mem.Allocator, arena: std.mem.Allocator, ast: *Node, best: []const u8) ParseError![]const []const u8 {
        if (best.len >= 3) return &.{}; // single-literal prefilter wins
        const cover = (try analysis.requiredAny(arena, ast)) orelse return &.{};
        return dupeAll(gpa, cover);
    }

    /// Own a copy of the pure-literal equivalence set (`analysis.pureLiterals`),
    /// or empty. Multiline (`-U`) changes the match model (a match may cross
    /// `\n`), so the per-line equivalence claim doesn't hold there — skip it.
    fn dupeLits(gpa: std.mem.Allocator, arena: std.mem.Allocator, ast: *Node, multiline: bool) ParseError![]const []const u8 {
        if (multiline) return &.{};
        const lits = (try analysis.pureLiterals(arena, ast)) orelse return &.{};
        return dupeAll(gpa, lits);
    }

    /// Own a heap copy of an arena-backed literal set (shared by the two above).
    fn dupeAll(gpa: std.mem.Allocator, src: []const []const u8) ParseError![]const []const u8 {
        if (src.len == 0) return &.{};
        const dst = try gpa.alloc([]const u8, src.len);
        var n: usize = 0;
        errdefer {
            for (dst[0..n]) |s| gpa.free(s);
            gpa.free(dst);
        }
        for (src) |s| {
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
    pub const Sim = PikeScratch(false);

    /// One shape for both Pike scratch grains: `spans=true` adds the per-state
    /// start-offset maps `matchSpan` threads through its closures; `false` leaves
    /// them empty slices (never allocated — the hot boolean path stays map-free).
    fn PikeScratch(comptime spans: bool) type {
        return struct {
            cur: ThreadList,
            nxt: ThreadList,
            seen: []u32,
            scur: []usize = &.{},
            snxt: []usize = &.{},
            gen: u32 = 0,
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator, re: *const Regex) ParseError!@This() {
                const n = re.states.len;
                const seen = try allocator.alloc(u32, n);
                @memset(seen, 0);
                return .{
                    .cur = .{ .buf = try allocator.alloc(u32, n) },
                    .nxt = .{ .buf = try allocator.alloc(u32, n) },
                    .seen = seen,
                    .scur = if (spans) try allocator.alloc(usize, n) else &.{},
                    .snxt = if (spans) try allocator.alloc(usize, n) else &.{},
                    .allocator = allocator,
                };
            }
            pub fn deinit(self: *@This()) void {
                self.allocator.free(self.cur.buf);
                self.allocator.free(self.nxt.buf);
                self.allocator.free(self.seen);
                self.allocator.free(self.scur); // frees nothing when `spans` is off
                self.allocator.free(self.snxt);
                self.* = undefined;
            }
        };
    }

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

    // `sim` is either Pike scratch grain (`Sim`/`SpanSim` — only `seen`/`gen` are read).
    fn closure(re: *const Regex, sim: anytype, list: *ThreadList, at_start: bool, at_end: bool, word_before: bool, word_after: bool) Closure {
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
        // Class-run patterns skip the automaton entirely: SIMD membership +
        // word-trick run detection at load bandwidth. `.unproven` (codepoint
        // projection met a high byte) falls through to the engines below.
        if (re.classrun) |*cr| switch (cr.scan(line)) {
            .hit => return true,
            .miss => return false,
            .unproven => {},
        };
        if (re.dfa) |d| {
            // Word-boundary DFA (`\b`/`\B`/`\<`/`\>`): resolves word context at the
            // DFA floor, but under Unicode QUITS (null) on a non-ASCII gap — the
            // Pike VM (the oracle) then resolves that line. `(?-u)` never quits.
            if (d.word_ctx) return d.matchWord(line) orelse re.lineMatchPike(sim, line);
            return d.match(line);
        }
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
        // One SIMD pass over the raw buffer: per-line compiles removed `\n`
        // from the set (`nl_free`), so a run can never cross a line boundary —
        // "some line holds a run" ≡ "the buffer holds a run", newlines and the
        // no-phantom-final-line rule included (min ≥ 1 needs real bytes).
        if (re.classrun) |*cr| if (cr.nl_free) switch (cr.scan(doc)) {
            .hit => return true,
            .miss => return false,
            .unproven => {},
        };
        // The DFA scans the whole buffer in one fused pass (one byte-touch); only a
        // powerset blow-up past the cap leaves it null, and then the Pike VM (proven
        // oracle) serves per line. Equivalence held by the doc-level differential fuzz.
        // A word-boundary DFA has no fused doc scan this rung (`word_ctx`); it runs
        // per line through `lineMatch` (the DFA floor, Pike on a Unicode quit).
        if (re.dfa) |d| if (!d.word_ctx) return d.docMatch(doc);
        var i: usize = 0;
        while (i < doc.len) {
            const end = std.mem.indexOfScalarPos(u8, doc, i, '\n') orelse doc.len;
            if (re.lineMatch(sim, doc[i..end])) return true;
            i = end + 1;
        }
        return false;
    }

    /// Is `docMatch` a single fused whole-buffer pass (class-run kernel or
    /// DFA) rather than the per-line Pike fallback? Callers with their own
    /// gated per-line loops (the `-l` emit path) use this to prefer one
    /// whole-buffer boolean only when it is actually the faster machine.
    pub fn docMatchFused(re: *const Regex) bool {
        if (re.eol_empty) return true;
        if (re.classrun) |*cr| if (cr.nl_free and (cr.exact or cr.cp != null)) return true;
        // A word-boundary DFA runs per line (no fused doc scan this rung), so it
        // is not a whole-buffer machine — callers keep their per-line loop.
        if (re.dfa) |d| return !d.word_ctx;
        return false;
    }

    /// Can `countRunLines` settle this pattern's `-c` tally? True exactly for
    /// a `\n`-free class run the kernel decides FINALLY — byte-exact, or a
    /// codepoint class whose full ranges it holds. A bare projection defers
    /// on high bytes and a `\n`-bearing set's runs cross lines, so both
    /// decline. The emit layers consult this BEFORE paying the line split.
    pub fn countRunFused(re: *const Regex) bool {
        if (re.eol_empty) return false;
        if (re.classrun) |*cr| return (cr.exact or cr.cp != null) and cr.nl_free;
        return false;
    }

    /// Count matching lines of `doc` (rg `-c` line model) in ONE hit-jumping
    /// whole-buffer class-run pass, or null when the reduction cannot settle
    /// counts (`!countRunFused`). Exactly the per-line `lineMatch` tally —
    /// held by the differential fuzz — minus the line split and per-line
    /// dispatch.
    pub fn countRunLines(re: *const Regex, doc: []const u8) ?u64 {
        if (!re.countRunFused()) return null;
        return re.classrun.?.countLines(doc);
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
        return if (re.line_anchors) lineStart(buf, p) else p == 0;
    }
    fn atEnd(re: *const Regex, buf: []const u8, p: usize) bool {
        return if (re.line_anchors) lineEnd(buf, p) else p == buf.len;
    }

    /// Epsilon-closure at a whole-buffer position `p`, resolving `^`/`$` against
    /// `\n` adjacency (multiline) rather than a single external BOL/EOL flag.
    /// `\A`/`\z` (assert_buf_*) resolve against the true buffer edges here — a
    /// line boundary is NOT a buffer edge under multiline.
    fn closureBuf(re: *const Regex, sim: *Sim, list: *ThreadList, buf: []const u8, p: usize) Closure {
        // `^`/`$` resolve against `\n` adjacency when the `m` flag is live, else
        // only the true buffer ends (`(?-m)` under `-U`).
        const at_start = if (re.line_anchors) lineStart(buf, p) else p == 0;
        const at_end = if (re.line_anchors) lineEnd(buf, p) else p == buf.len;
        var c = re.closure(sim, list, at_start, at_end, wordBefore(re.unicode, buf, p), wordAt(re.unicode, buf, p));
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
        // Class-run existence is position-independent, so it holds under `-U`
        // exactly as written: the buffer is the haystack, `\n` stayed in the
        // set if the pattern admits it. Sound even when the program carries
        // assertions (a nullable wrapper can hide `^`/`\b` without weakening
        // the reduction — see `analysis.classRunShape`), which also rescues
        // patterns the multiline DFA refused.
        if (re.classrun) |*cr| switch (cr.scan(buf)) {
            .hit => return true,
            .miss => return false,
            .unproven => {},
        };
        // Assertion-free multiline: the DFA is exact over the whole buffer as one
        // haystack (no `^`/`$`/`\b` to resolve; `trans_fin` ≡ `trans_in` when no
        // assert_end exists, so the last-byte table is inert) — one table lookup
        // per byte instead of a Pike closure per byte. Equivalence held by the
        // multiline differential fuzz in `dfa_test.zig`.
        if (re.assert_free) if (re.dfa) |d| return d.match(buf);
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
    pub const SpanSim = PikeScratch(true);

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
    /// Leftmost-first span of a PURE-LITERAL pattern (`re.lits` non-empty), found
    /// by SIMD substring scan instead of the Pike VM — the code-search common
    /// case (`TODO`, `func`, `panic|0x`, symbol names). `re.lits` is set only for
    /// an assertion-free alternation of pure literals (`analysis.pureLiterals`,
    /// per-line only), so the match span IS a literal occurrence: leftmost START
    /// dominates branch priority, and at a shared start the lowest branch index
    /// (pattern order) wins — exactly the Pike-VM `matchSpan` result. Iterating
    /// `re.lits` in order and taking the strictly-earliest occurrence (keeping the
    /// first on a positional tie) yields that lowest-index-at-leftmost-start rule,
    /// because no literal occurring at the winning position `p` can have its own
    /// leftmost occurrence before `p`. One SIMD `indexOfPos` per literal (≤ 8)
    /// replaces per-byte closure work — the 6–15× loss on literal/alternation
    /// queries vs ripgrep's memmem/Teddy prefilters.
    fn litSpan(re: *const Regex, line: []const u8, from: usize) ?Span {
        var best: usize = std.math.maxInt(usize);
        var end: usize = 0;
        for (re.lits) |lit| {
            const q = simd.indexOfPos(line, from, lit) orelse continue;
            if (q < best) {
                best = q;
                end = q + lit.len;
                if (q == from) break; // can't beat a hit at the search origin
            }
        }
        if (best == std.math.maxInt(usize)) return null;
        return .{ .start = best, .end = end };
    }

    pub fn matchSpan(re: *const Regex, sim: *SpanSim, line: []const u8, from: usize) ?Span {
        // Pure-literal fast path: SIMD substring scan, no Pike VM (see `litSpan`).
        if (re.lits.len > 0) return re.litSpan(line, from);
        // Span-exact class run (`\w+`, `[a-z]{3,8}` — `analysis.classSpanShape`):
        // the SIMD window kernel chunks member runs directly, no thread
        // closures. Final only when the kernel settles high bytes itself
        // (byte-exact set, or the full codepoint class in hand).
        if (re.classrun) |*cr| if (cr.span and (cr.exact or cr.cp != null)) {
            const sp = cr.nextSpan(line, from) orelse return null;
            return .{ .start = sp.start, .end = sp.end };
        };
        sim.gen += 1;
        sim.cur.len = 0;
        var cl = re.closure(sim, &sim.cur, re.atStart(line, from), re.atEnd(line, from), wordBefore(re.unicode, line, from), wordAt(re.unicode, line, from));
        // `line` is the whole haystack handed to the span engine (a line in
        // the per-line default, the buffer under multiline), so its edges
        // ARE the `\A`/`\z` buffer edges in both modes.
        cl.at_buf_start = from == 0;
        cl.at_buf_end = from == line.len;
        cl.starts = sim.scur;
        cl.cur_start = from;
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

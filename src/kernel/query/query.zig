//! gist search core — the compiled, transport-neutral query.
//!
//! One deep module owns "a search intent, compiled". A `(pattern, fixed,
//! ignore_case, pcre, mode)` spec — the whole shape the unified search contract
//! admits — lowers into an immutable matcher: a bare literal for the `-F`
//! no-fold fast path (SIMD substring), else the regex behind the engine-neutral
//! `Matcher` seam — the linear-time default (a `-F -i` literal is escaped so the
//! engine does the ASCII case fold), or the vendored PCRE2 backend under `-P`.
//! From that one compiled form every face draws the two things it needs — the
//! sound TRIGRAM PREFILTER that prunes index candidates, and the per-doc MATCH
//! / line-COUNT decision — WITHOUT knowing which engine backs the query.
//!
//! Two invariants make this the shared core the CLI, the resident daemon, and
//! (later) the C FFI can all execute through instead of forking the logic:
//!
//!   • Fail-closed, never fatal. Every entry point RETURNS a typed error — a
//!     pattern outside the linear-time syntax is `error.Unsupported`, an
//!     allocation failure is `error.OutOfMemory` — so a bad query can never
//!     `die()`/exit an embedding host (the exact hazard that keeps the FFI
//!     surface honest). The CLI's cold path keeps its own `die()` shell; this core does not.
//!   • Thread-safe for the parallel walk. A `CompiledQuery` is immutable after
//!     `compile`; the only per-query mutable state — the regex Pike-VM
//!     simulation — is a caller-owned `Scratch`, one per worker, threaded into
//!     the match primitives. N workers share one compiled query with N scratches.
//!
//! Before this module, the warm engine (`exec/session/warm/resident.zig`) and the cold
//! engine (`exec/cold/`) each re-derived the required-literal-vs-alts
//! prefilter and re-implemented literal/regex verification; the two "cannot
//! drift" only because they now compile and match through the same code here.

const std = @import("std");
const simd = @import("../scan/simd.zig");
const Regex = @import("../regex/regex.zig").Regex;
// The engine-neutral match seam (`linear` | `pcre`). The regex body compiles
// into one `Matcher`, so the shared core dispatches ONCE per line/span to
// whichever engine backs the query — the linear-time default, or (for `-P`)
// the PCRE2 backend, whose `Pcre` mirrors `Regex`'s primitives behind the seam.
const matcher_mod = @import("../regex/regex.zig");
const Matcher = matcher_mod.Matcher;
const Pcre = matcher_mod.Pcre;
// Two private sub-modules of the compiled query (same folder, imported only
// here): the index-pruning SOUNDNESS derivation (`prefilter.zig`) and the rg
// `-w` word-boundary rule (`word.zig`), re-exported below to keep `query.<name>`.
const pf = @import("prefilter.zig");
const cover = @import("cover.zig");
const word = @import("word.zig");

/// The three mode shapes the shared core answers: `files` (any line matches),
/// `count` (how many lines match), and `lines` (the default `path:text` match
/// lines — rendered by the warm session through the cold `Emitter` itself, so
/// the presentation cannot drift). Richer cold-only presentations (context,
/// JSON, replace, --only-matching) stay in `exec/cold/` — they consume
/// the same match decision but shape their own output.
pub const Mode = enum(u8) { files = 0, count = 1, lines = 2 };

/// A search intent before compilation. Mirrors the resident classifier's
/// `Request` fields (`exec/session/answer/request.zig`) — the transport-neutral subset of
/// the contract's request options.
pub const Spec = struct {
    /// The search pattern. For a `literal` body it is aliased, not copied — the
    /// caller keeps it alive for the query's lifetime.
    pattern: []const u8,
    mode: Mode = .files,
    /// `-F`: treat the pattern as a fixed string, not a regex.
    fixed: bool = false,
    /// `-i`: case-insensitive (Unicode fold when `unicode`, else ASCII).
    ignore_case: bool = false,
    /// Unicode mode (rg default ON): full case-fold orbits and codepoint
    /// `\w`/`\d`/`\s`/`.`/`\p{…}`/`\b`. The daemon stays at this default; the
    /// in-process FFI may explicitly select ASCII through the same compile seam.
    unicode: bool = true,
    /// `-w`/`--word-regexp`: only word-bounded match spans count — a span `[s,e)`
    /// counts iff a non-word codepoint (or the line edge) bounds it on BOTH sides,
    /// so a punctuation-only match is still a valid word match. It is the HALF
    /// boundaries, not `\b(pat)\b`.
    ///
    /// A regex body carries that rule INSIDE the compiled program (rg's own
    /// rewrite — `syntax/scalars.zig::wordBoundedAst` for the linear arm, a
    /// lookaround wrap for PCRE2), so the engine settles on a word-bounded span by
    /// construction. The post-match `wordOk` vet (`word.zig`, sharing the `\b`
    /// oracle with `exec/cold/emit/output.zig::wordOk`) remains for the `.literal`
    /// body, where there is no program to rewrite and a single literal has exactly
    /// one span per offset for the vet to judge.
    word: bool = false,
    /// `-m N`/`--max-count`: cap matching lines PER FILE at N (`0` = unlimited).
    /// rg's explicit `-m0` (match nothing) is resolved at the session boundary
    /// before compilation (`exec/session/answer/request.zig::matchNothing`), so a compiled
    /// query never carries a zero cap that means "nothing".
    max_count: u64 = 0,
    /// `-P`/`--pcre2`: compile the regex body through the vendored PCRE2 JIT
    /// backend (lookaround, backreferences, Unicode properties) rather than the
    /// linear engine. Inert under `-F` (a fixed string needs no engine — fixed
    /// wins). The compiled query then dispatches through the same `Matcher`
    /// seam, so every face (`docMatches`/`countLines`/`collectSpans`) is
    /// byte-identical to the cold `-P` path it shares the engine with.
    pcre: bool = false,
};

pub const CompileError = error{
    /// The pattern is outside gist's linear-time regex syntax (e.g. a construct
    /// only PCRE would accept). The caller answers cold rather than approximating.
    Unsupported,
    OutOfMemory,
};

/// Per-query mutable match scratch — the regex simulation state, or nothing for
/// a literal query. One per thread; never shared. Made by `CompiledQuery.scratch`.
pub const Scratch = union(enum) {
    none,
    sim: Matcher.Sim,
    /// `-w` over a regex body. The boolean DFA cannot decide `-w` (it has no
    /// span), so a word query carries BOTH VMs: the boolean sim stays the
    /// cheap doc/line pre-gate (word only narrows the match set — a doc/line
    /// the plain engine rejects can never hold a word-valid span), and the
    /// span VM decides word validity per span. Only word queries pay for the
    /// extra scratch; the non-word variants and their hot loops are untouched.
    word: WordScratch,

    pub fn deinit(self: *Scratch) void {
        switch (self.*) {
            .sim => |*s| s.deinit(),
            .word => |*w| {
                w.sim.deinit();
                w.span.deinit();
            },
            .none => {},
        }
    }
};

/// The `-w` regex scratch pair (see `Scratch.word`). Owned by the `-w` rule
/// sub-module (`word.zig`); re-exported so the public shape is unchanged.
pub const WordScratch = word.WordScratch;

/// A matched byte span `[start, end)` within one line. Aliases the regex
/// engine's own span so the FFI reports the exact offsets the cold `--json`
/// submatch stream does.
pub const Span = Regex.Span;

/// Per-query span scratch for match-record emission (`collectSpans`) — the
/// slot-free span VM (`Matcher.SpanSim`) for a regex body, or nothing for a
/// literal (whose spans are plain `indexOf` occurrences). Kept apart from
/// `Scratch`: the boolean `docMatches`/`countLines` hot path never allocates
/// the span maps, and match emission never needs the cheaper boolean scratch.
/// One per thread; never shared. Made by `CompiledQuery.matchScratch`.
pub const MatchScratch = union(enum) {
    none,
    sim: Matcher.SpanSim,

    pub fn deinit(self: *MatchScratch) void {
        switch (self.*) {
            .sim => |*s| s.deinit(),
            .none => {},
        }
    }
};

/// A compiled, immutable search intent. Cheap to share across walk workers;
/// `deinit` releases the compiled regex and any escaped-literal buffer.
pub const CompiledQuery = struct {
    mode: Mode,
    /// `-i` was requested — recorded because it makes the trigram required-literal
    /// prefilter an UNsafe proxy for "can match" (the fold changes which bytes
    /// appear), so `prefilter` must decline for a caseless regex.
    caseless: bool,
    /// `-w` was requested: every match face routes through the word-valid span
    /// decision (`docMatchesWord`/`countLinesWord`/`collectSpans`). The
    /// trigram prefilter stays FULLY sound under `-w` (word only narrows the
    /// match set; the required literal is still required — cold's
    /// `trigramFilter` likewise keeps the index on), so `prefilter` ignores it.
    word: bool = false,
    /// Unicode mode for the word oracle (`Spec.unicode`; rg-parity default ON).
    unicode: bool = true,
    /// `-m N`: per-file matching-line cap (`0` = unlimited). Only the `count`
    /// face reads it (the `lines`/emit face caps through the cold `Emitter`'s
    /// `max_per_file`; `files` existence is cap-invariant for N≥1). `-m0` never
    /// reaches here — the session short-circuits it (`Request.matchNothing`).
    max_count: u64 = 0,
    body: union(enum) {
        /// `-F` no-fold: verified by `simd.contains`. Aliases `Spec.pattern`.
        literal: []const u8,
        /// The compiled regex behind the engine-neutral `Matcher` seam: the
        /// linear-time engine (plain regex, or an escaped `-F -i`), or the
        /// PCRE2 backend under `-P`. Every match face dispatches through it.
        engine: Matcher,
    },
    /// The literal body's anchor decision, priced ONCE at compile time.
    ///
    /// `simd.contains` used to price it per call, and `countGeneric` below calls
    /// `contains` once per LINE — measured at 24 ns of pure per-line overhead
    /// (`anchor.select` holds the six rarest offsets, then scores all fifteen
    /// pairs among them against the fitted digraph table). Over 5.2 M lines of a
    /// 213 MB tree that was 1.44x the whole scan. The decision depends only on
    /// the needle, and the needle is fixed for the life of a `CompiledQuery`, so
    /// it belongs here. Null for an engine body, and for a needle under 2 bytes
    /// (`indexOfPos` answers those with `memchr` and never consults a pair).
    plan: ?simd.Plan = null,
    /// Owns the escaped-literal buffer for the `-F -i` path (regex over a fixed
    /// string); null otherwise. Freed by `deinit`.
    escaped: ?[]u8 = null,
    /// ASCII-caseless SIMD gate for a caseless body: the raw (unfolded)
    /// required literal, pre-folded to lowercase. Sound because `foldClosedWindow`
    /// proved every byte's simple-fold orbit ASCII-closed, so every caseless
    /// match contains these bytes in SOME ASCII case spelling. Owned.
    gate: ?[]u8 = null,
    /// Caseless trigram prefilter variants (`caselessVariants` over one window
    /// of the raw required literal) — the warm twin of cold `caselessFilter`,
    /// so a caseless query prunes index candidates instead of scanning the
    /// whole corpus. Owned (each variant + the slice).
    variants: ?[]const []const u8 = null,
    /// The EFFECTIVE regex source this query's engine compiled, for a caller
    /// that wants a further analysis off the same AST (`winnow` — the cover plan
    /// and the crest swell, which need the parse tree rather than the compiled
    /// program). Aliased, never owned: it is either `Spec.pattern` or this
    /// query's own `escaped` buffer.
    ///
    /// Null is the standing "do not re-parse" signal, and it is null in exactly
    /// the two cases where re-parsing would be wrong rather than merely useless:
    /// a `.literal` body, whose fixed string is not regex source at all
    /// (`foo(bar)` would parse as a group), and a PCRE2 body, which denotes the
    /// pattern under a grammar this parser does not implement. So a non-null
    /// `source` also certifies "the linear arm compiled this" — the one
    /// condition every AST-derived pruning needs.
    source: ?[]const u8 = null,

    /// Lower a spec into a compiled query. `-F` without `-i` becomes a literal
    /// (the SIMD fast path); everything else compiles to the regex engine, with
    /// a fixed `-F -i` string escaped first so the engine, not a raw substring
    /// scan, applies the case fold.
    pub fn compile(gpa: std.mem.Allocator, spec: Spec) CompileError!CompiledQuery {
        if (spec.fixed and !spec.ignore_case)
            return .{ .mode = spec.mode, .caseless = false, .word = spec.word, .unicode = spec.unicode, .max_count = spec.max_count, .body = .{ .literal = spec.pattern }, .plan = simd.planFor(spec.pattern) };

        // `-P`: the PCRE2 backend, behind the same seam (fixed wins over `-P`,
        // so this never runs under `-F`). A pattern PCRE2 rejects (or a backend
        // built without it) is `Unsupported` — the caller answers cold, which
        // diagnoses it. The caseless SIMD gate/variants are a linear-only
        // acceleration; PCRE2 folds inside the program and mines its own
        // required literal, so a `-P` body skips them (its prefilter reads the
        // backend's `required`/`alts` directly — see `prefilter`).
        if (spec.pcre and !spec.fixed) {
            const p = Pcre.compileOpts(gpa, spec.pattern, .{ .caseless = spec.ignore_case, .unicode = spec.unicode, .word = spec.word }) catch |e|
                return if (e == error.OutOfMemory) CompileError.OutOfMemory else CompileError.Unsupported;
            return .{ .mode = spec.mode, .caseless = spec.ignore_case, .word = spec.word, .unicode = spec.unicode, .max_count = spec.max_count, .body = .{ .engine = .{ .pcre = p } } };
        }

        const escaped: ?[]u8 = if (spec.fixed) try escapeLiteral(gpa, spec.pattern) else null;
        errdefer if (escaped) |e| gpa.free(e);

        const re = Regex.compileOpts(gpa, escaped orelse spec.pattern, .{ .caseless = spec.ignore_case, .unicode = spec.unicode, .word = spec.word }) catch
            return CompileError.Unsupported;
        const source = escaped orelse spec.pattern;
        var q = CompiledQuery{ .mode = spec.mode, .caseless = spec.ignore_case, .word = spec.word, .unicode = spec.unicode, .max_count = spec.max_count, .body = .{ .engine = .{ .linear = re } }, .escaped = escaped, .source = source };
        if (spec.ignore_case) q.mineCaselessGate(gpa, source);
        return q;
    }

    /// The caseless acceleration pair, mined from the raw (unfolded) twin of the
    /// pattern: the whole-literal SIMD `gate` when the fold is ASCII-closed, and
    /// the trigram `variants` of one window. Both are pure accelerations — every
    /// decline just leaves the caseless query on the engine-only path it always ran.
    fn mineCaselessGate(self: *CompiledQuery, gpa: std.mem.Allocator, pattern: []const u8) void {
        var raw = Regex.compileOpts(gpa, pattern, .{ .unicode = self.unicode }) catch return;
        defer raw.deinit();
        if (raw.required.len == 0) return;
        if (pf.foldClosedWindow(raw.required, self.unicode)) |win| {
            const low = gpa.dupe(u8, win) catch return;
            for (low) |*b| b.* = std.ascii.toLower(b.*);
            self.gate = low;
        }
        self.variants = pf.caselessVariants(gpa, raw.required, self.unicode) catch null orelse null;
    }

    pub fn deinit(self: *CompiledQuery, gpa: std.mem.Allocator) void {
        switch (self.body) {
            .engine => |*m| m.deinit(),
            .literal => {},
        }
        if (self.escaped) |e| gpa.free(e);
        if (self.gate) |g| gpa.free(g);
        if (self.variants) |vs| {
            for (vs) |v| gpa.free(v);
            gpa.free(vs);
        }
    }

    /// A fresh per-thread match scratch: the regex simulation for a regex body
    /// (plus the span VM under `-w` — see `Scratch.word`), or `.none` for a
    /// literal (SIMD substring / `indexOf` occurrence scans need no state).
    pub fn scratch(self: *const CompiledQuery, gpa: std.mem.Allocator) CompileError!Scratch {
        switch (self.body) {
            .literal => return .none,
            .engine => |*m| {
                var sim = Matcher.Sim.init(gpa, m) catch return CompileError.OutOfMemory;
                if (!self.word) return .{ .sim = sim };
                const span = Matcher.SpanSim.init(gpa, m) catch {
                    sim.deinit();
                    return CompileError.OutOfMemory;
                };
                return .{ .word = .{ .sim = sim, .span = span } };
            },
        }
    }

    /// The sound trigram prefilter literals for pruning index candidates, or
    /// empty when none apply. A caseless query declines (the fold makes a raw
    /// literal an unsafe proxy). A literal body yields the needle itself (≥3
    /// bytes — a trigram needs three); a regex yields its guaranteed required
    /// literal (≥3), else its per-branch alternation cover (`foo|bar` ⇒
    /// {foo,bar}), both of which the index treats as sound supersets. `one`
    /// backs the single-literal return so the callee allocates nothing.
    pub fn prefilter(self: *const CompiledQuery, one: *[1][]const u8) []const []const u8 {
        switch (self.body) {
            .literal => |needle| {
                if (self.caseless or needle.len < 3) return &.{};
                one[0] = needle;
                return one[0..1];
            },
            .engine => |*m| {
                // Caseless: the linear arm prunes by the mined case-variant
                // OR-set (`caselessVariants`); the PCRE2 arm soundly DECLINES
                // (empty ⇒ full warm scan — the same match set cold's
                // `caselessFilter` yields, just unpruned; its variant-mining is
                // deferred). Non-caseless: both arms use the seam's guaranteed
                // required literal / alternation cover — cold's exact
                // non-caseless rule (`serial.zig::trigramFilter`).
                if (self.caseless) return if (m.* == .linear) (self.variants orelse &.{}) else &.{};
                return pf.matcherPrefilter(m, one);
            },
        }
    }

    /// The literals whose presence is EQUIVALENT to this query matching — empty
    /// unless the whole pattern is exactly an alternation of them (`panic|0x`).
    ///
    /// Strictly stronger than `prefilter`, and the difference is the whole point:
    /// a prefilter literal only NOMINATES (a hit still has to be confirmed by an
    /// engine), where one of these DECIDES. The single-pattern scanner has spent
    /// this for a while — `lower.zig::literalEngine` builds its `LiteralSet` at
    /// `.exact` authority from the same set — and this is the accessor that lets
    /// a pattern SLATE spend it too, in `slate/muster.zig`.
    ///
    /// The equivalence is per LINE, which is the model every caller here shares:
    /// `analysis.pureLiterals` refuses a literal containing `\n`, and `-U` (where
    /// a match may cross one) yields empty. `-w` and `-i` yield empty too, since
    /// containment is then not the question being asked.
    pub fn equivalence(self: *const CompiledQuery) []const []const u8 {
        if (self.caseless or self.word) return &.{};
        return switch (self.body) {
            .literal => &.{}, // the body IS the needle; `prefilter` already says so
            .engine => |*m| m.lits(),
        };
    }

    /// The literal body's two scans, each against the compile-time `plan` — the
    /// ONE place that chooses planned-vs-static, so no call site can silently
    /// drift back onto the per-call anchor pricing.
    ///
    /// `litIndexOf` is deliberately `simd` and not `std.mem.indexOfPos`. For a
    /// 5+-byte needle in a >= 52-byte haystack std builds a 256-entry
    /// Boyer-Moore-Horspool skip table PER CALL — a ~2 KiB store burst — which
    /// `simd.zig`'s own tail records having removed for exactly that reason. The
    /// span loops below call it once per match per line, so that table was being
    /// rebuilt per match on the emit path.
    inline fn litContains(bytes: []const u8, needle: []const u8, plan: ?simd.Plan) bool {
        return if (plan) |p| simd.containsWith(bytes, needle, p) else simd.contains(bytes, needle);
    }

    inline fn litIndexOf(line: []const u8, from: usize, needle: []const u8, plan: ?simd.Plan) ?usize {
        return if (plan) |p| simd.indexOfPosWith(line, from, needle, p) else simd.indexOfPos(line, from, needle);
    }

    /// The plan to use for ONE document: `self.plan`'s static choice, refined
    /// against this document's own bytes when it is big enough to amortize the
    /// sampling (`simd.planOn`). A document is the right grain because the size
    /// gate is a claim about the scan the sampling amortizes against, and because
    /// the pair must not change part-way through a document's lines.
    ///
    /// Only a literal body has a needle to plan for; a regex body's literals are
    /// the engine's business.
    fn docPlan(self: *const CompiledQuery, bytes: []const u8) ?simd.Plan {
        return switch (self.body) {
            .literal => |needle| simd.planOn(bytes, needle),
            .engine => self.plan,
        };
    }

    /// Does any line of `bytes` match? (rg `-l` semantics.) Literal → substring
    /// presence; regex → whole-doc match over the caller's `scratch`. Under
    /// `-w` the decision routes through the word-valid span scan — one branch
    /// HERE, so the non-word bodies below stay byte-for-byte the hot path they
    /// were (the perf guard for the existing warm slate).
    pub fn docMatches(self: *const CompiledQuery, bytes: []const u8, sc: *Scratch) bool {
        // Caseless SIMD pre-gate: every caseless match contains the raw
        // required literal in some ASCII case spelling (`gate` soundness), so
        // a gate-free doc is rejected without an engine run. Sound under `-w`
        // too (word only narrows the match set).
        if (self.gate) |g| if (!simd.containsCaseless(bytes, g)) return false;
        if (self.word) return self.docMatchesWord(bytes, sc);
        return switch (self.body) {
            .literal => |needle| litContains(bytes, needle, self.docPlan(bytes)),
            .engine => |*m| m.docMatch(&sc.sim, bytes),
        };
    }

    /// The `-w` doc gate: does any WORD-VALID span exist anywhere in `bytes`?
    /// A literal body scans whole-doc occurrences directly — the pattern never
    /// carries a newline (session-classifier guarantee) and `\n` is a non-word
    /// byte, so a word neighbor checked against doc bytes is exactly the
    /// per-line rule (`\n` and the line edge are both "not a word char"), and
    /// occurrences in different lines can never overlap. A regex body pre-gates
    /// with the cheap boolean `docMatch` (sound: word only NARROWS the match
    /// set) and then span-scans line by line until one word-valid span appears.
    fn docMatchesWord(self: *const CompiledQuery, bytes: []const u8, sc: *Scratch) bool {
        switch (self.body) {
            .literal => |needle| return word.firstWordHit(self.unicode, bytes, needle) != null,
            .engine => |*m| {
                if (!m.docMatch(&sc.word.sim, bytes)) return false;
                var rest = bytes;
                while (rest.len > 0) {
                    const nl = std.mem.indexOfScalar(u8, rest, '\n');
                    const end = nl orelse rest.len;
                    if (word.lineHasWordMatch(self.unicode, m, rest[0..end], &sc.word)) return true;
                    if (nl == null) break;
                    rest = rest[end + 1 ..];
                }
                return false;
            },
        }
    }

    /// Count matching LINES in `bytes` (rg `-c` semantics), over rg's line model
    /// (`\n` terminates; no phantom final line). Two orthogonal knobs are lifted
    /// to `comptime` here and dispatched ONCE at the top — `-w` (the word-valid
    /// span twin) and `-m N` (the per-file cap: stop scanning this file after
    /// N hits, so `-c` reports min(actual, N)). Every branch is compiled out of
    /// the plain, uncapped loop, keeping it byte-identical to the warm slate.
    pub fn countLines(self: *const CompiledQuery, bytes: []const u8, sc: *Scratch) u64 {
        // Same caseless SIMD pre-gate as `docMatches`: no gate hit ⇒ 0 lines.
        if (self.gate) |g| if (!simd.containsCaseless(bytes, g)) return 0;
        // Class-run fused count: one hit-jumping whole-buffer pass replaces
        // the line split + per-line engine below (non-null only when exact —
        // a byte-exact `\n`-free class run; `-m` reports min(actual, N)).
        if (!self.word) switch (self.body) {
            .engine => |*m| if (m.countRunLines(bytes)) |n|
                return if (self.max_count != 0) @min(n, self.max_count) else n,
            else => {},
        };
        const capped = self.max_count != 0;
        if (self.word) return if (capped) self.countGeneric(true, true, bytes, sc) else self.countGeneric(true, false, bytes, sc);
        return if (capped) self.countGeneric(false, true, bytes, sc) else self.countGeneric(false, false, bytes, sc);
    }

    /// The one count loop, specialized at `comptime` on `word_mode`/`capped`.
    /// The word variant counts a line iff it holds ≥1 word-valid NON-EMPTY span
    /// (cold's `lineHitWord`); the capped variant halts the file at `max_count`.
    inline fn countGeneric(self: *const CompiledQuery, comptime word_mode: bool, comptime capped: bool, bytes: []const u8, sc: *Scratch) u64 {
        var n: u64 = 0;
        var rest = bytes;
        // Once per DOCUMENT, outside the line loop — the whole point of the seam.
        const plan = self.docPlan(bytes);
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const end = nl orelse rest.len;
            const line = rest[0..end];
            // Per-line twin of the caseless doc gate: a gate-free line cannot
            // match, so the engine run is skipped (the dominant case even
            // inside a doc the whole-doc gate admitted).
            const gated = if (self.gate) |g| simd.containsCaseless(line, g) else true;
            const hit = gated and if (word_mode) switch (self.body) {
                .literal => |needle| word.firstWordHit(self.unicode, line, needle) != null,
                .engine => |*m| word.lineHasWordMatch(self.unicode, m, line, &sc.word),
            } else switch (self.body) {
                // `plan` is loop-invariant, so this test hoists; what it saves is
                // the per-line anchor pricing described at the field.
                .literal => |needle| litContains(line, needle, plan),
                .engine => |*m| m.lineMatch(&sc.sim, line),
            };
            if (hit) {
                n += 1;
                if (capped and n >= self.max_count) break;
            }
            if (nl == null) break;
            rest = rest[end + 1 ..];
        }
        return n;
    }

    /// A fresh per-thread SPAN scratch for `collectSpans`: the slot-free span VM
    /// for a regex body, or `.none` for a literal (whose spans are `indexOf`
    /// occurrences, needing no state).
    pub fn matchScratch(self: *const CompiledQuery, gpa: std.mem.Allocator) CompileError!MatchScratch {
        return switch (self.body) {
            .literal => .none,
            .engine => |*m| .{ .sim = Matcher.SpanSim.init(gpa, m) catch return CompileError.OutOfMemory },
        };
    }

    /// The one walk over `line`'s match spans — leftmost, non-overlapping,
    /// zero-width spans included where rg reports them. `terminated` says
    /// whether the line carried a newline in the file, which decides whether the
    /// zero-width match at end-of-content exists.
    ///
    /// Two callers need this answer at different lengths: the whole span list,
    /// and the bare "does this line match at all" a predicate wants. They share
    /// a walk rather than each writing one, because the rules below are subtle
    /// enough that a second hand-written version is how a predicate starts
    /// disagreeing with the list it is supposed to summarize — which is exactly
    /// what the C ABI's `is_match` did while it answered a document-shaped
    /// question instead of this one.
    ///
    /// `out` carries that difference and nothing else: null asks only whether a
    /// span exists and returns at the first one. It is a runtime-looking
    /// parameter that is always comptime-known at the call site, and the
    /// function is `inline`, so each caller compiles to a single tight loop with
    /// the check folded away. That is load-bearing rather than fussy — an
    /// iterator here, which splits this into an inner and an outer loop, cost a
    /// measured 2.5% on short matches, and 3.8% on a nullable pattern when
    /// inlined to get the first back.
    inline fn walk(self: *const CompiledQuery, line: []const u8, terminated: bool, sc: *MatchScratch, a: std.mem.Allocator, out: ?*std.ArrayList(Span)) error{OutOfMemory}!bool {
        var any = false;
        switch (self.body) {
            .literal => |needle| {
                if (needle.len == 0) return false;
                var from: usize = 0;
                // A span scan is handed ONE line, so there is no document to
                // calibrate against here; the static plan is the right choice and
                // `docPlan`'s size gate would decline on a line anyway. A non-empty
                // needle can never match empty, so the nullable rules below are
                // vacuous on this body and the plain leftmost walk stands.
                while (litIndexOf(line, from, needle, self.plan)) |i| {
                    from = i + needle.len; // non-overlapping, like rg's leftmost scan
                    if (self.word and !word.wordOk(self.unicode, line, i, i + needle.len)) continue;
                    const o = out orelse return true;
                    try o.append(a, .{ .start = i, .end = i + needle.len });
                    any = true;
                }
            },
            .engine => |*m| {
                // Cold's `output.zig::Rows`, which is the iterator `json.zig`'s
                // `matchSpans` actually drives. Its sibling `nextSpan` drops every
                // zero-width span because ITS consumers (`-o`, `--column`,
                // highlighting) need bytes to point at — but the record stream is
                // not one of them: rg reports zero-width submatches, so `rg -w
                // 'x*'` paints `('', 10, 10)` on a line with no `x` in it, and a
                // stream mirroring `nextSpan` reported that line as no match at all.
                //
                // Three rules make an empty span real: the pattern must be nullable,
                // it must not sit exactly at the previous match's end (rg's progress
                // rule — `a*` over "aa" is one row, not two), and at end-of-content
                // it exists only on a TERMINATED line, where it sits before the
                // newline. A word-rejected candidate retries one byte on rather than
                // consuming the region it covered, because rg compiles `-w` into the
                // pattern and a rejected candidate never consumed anything.
                var from: usize = 0;
                var last_end: ?usize = null;
                while (from <= line.len) {
                    const sp = m.matchSpan(&sc.sim, line, from) orelse break;
                    const empty = sp.end == sp.start;
                    const word_bad = self.word and !word.wordOk(self.unicode, line, sp.start, sp.end);
                    from = if (empty or word_bad) sp.start + 1 else sp.end;
                    const adjacent = empty and last_end != null and sp.start == last_end.?;
                    if ((empty and !m.nullable()) or adjacent or
                        (empty and !terminated and sp.start == line.len) or word_bad) continue;
                    last_end = sp.end;
                    const o = out orelse return true;
                    try o.append(a, sp);
                    any = true;
                }
            },
        }
        return any;
    }

    /// Append every match span in `line` to `out`. A literal body walks
    /// successive `indexOf` occurrences; a regex body reproduces the iterator the
    /// cold `--json` stream is built on (`exec/cold/emit/output.zig::Rows`,
    /// driven by `json.zig::matchSpans`), so a record emitted here carries
    /// byte-identical submatch offsets to the subprocess stream. `-r`
    /// replacement stays cold-only.
    pub fn collectSpans(self: *const CompiledQuery, a: std.mem.Allocator, line: []const u8, terminated: bool, sc: *MatchScratch, out: *std.ArrayList(Span)) error{OutOfMemory}!void {
        _ = try self.walk(line, terminated, sc, a, out);
    }

    /// Whether `line` holds at least one span `collectSpans` would report.
    ///
    /// The line-scoped counterpart to `docMatches`, which asks the same question
    /// of a whole document and splits it into lines to do so. A caller holding
    /// ONE unit — the C ABI's regex plane, where the buffer is the line and `^`
    /// and `$` are its ends — has to ask this one, or its predicate and its span
    /// list will disagree about every anchored pattern.
    pub fn holds(self: *const CompiledQuery, line: []const u8, terminated: bool, sc: *MatchScratch) bool {
        // Allocation is unreachable with no sink to append to, so the walk's
        // `OutOfMemory` cannot arise on this path.
        return self.walk(line, terminated, sc, undefined, null) catch false;
    }
};

// Pub surface of the two private sub-modules, re-exported so the `query.<name>`
// public shape (consumed verbatim by cold `serial`/`ranked`) is unchanged.
pub const wordOk = word.wordOk;
pub const regexPrefilter = pf.regexPrefilter;
pub const matcherPrefilter = pf.matcherPrefilter;
// The conjunctive cover (`cover.zig`) — the multi-clause counterpart to the
// single-literal `regexPrefilter`, for callers holding a trigram index that can
// evaluate a boolean plan (`trigram.Index.queryPlan`).
pub const CoverPlan = cover.Clause;
pub const CoverLimits = cover.Limits;
pub const coverPlan = cover.plan;
pub const coverPlanSource = cover.planSource;
// Both index-prunings a pattern forces, off ONE parse — what cold's `Writ` and
// warm's `ResidentSession` each compile once and then prune a corpus by.
pub const Winnow = pf.Winnow;
pub const winnow = pf.winnow;
pub const foldClosedWindow = pf.foldClosedWindow;
pub const caselessVariants = pf.caselessVariants;
pub const escapeLiteral = pf.escapeLiteral;

test {
    // Wire the private sub-modules' inline tests (`prefilter.zig` owns the
    // caseless soundness suite) into this file's test set, per root.zig's
    // explicit-wiring convention, without editing root.zig.
    _ = @import("prefilter.zig");
    _ = @import("word.zig");
    _ = @import("cover.zig");
    _ = @import("cover_test.zig");
}

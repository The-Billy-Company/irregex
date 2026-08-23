//! irregex — compilation: pattern text ⇒ the immutable `Regex` handle. Parse to
//! an AST (`regex/syntax/`), case-fold it if `-i`, lower it to a Thompson NFA
//! (`regex/compile/`), then run every verify-time analysis the scanner will consult
//! — required literal, alternation cover, pure-literal equivalence, first-byte
//! prefilter, zero-width reachability — and choose which engines to build: the
//! SIMD class-run kernel, and the byte-class DFA unless a stronger reduction
//! already answers finally or the powerset blows past its cap.
//!
//! Order is load-bearing: folding happens BEFORE any analysis so prefilter and
//! match engines agree on the same classes, and everything an analysis needs
//! lives in an arena that dies with this frame — only the owned copies survive
//! into the handle (`freeAlts` is the other half of that contract, called by
//! `Regex.deinit`).

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const analysis = @import("../../analysis/analysis.zig");
const ast_mod = @import("../../ast/ast.zig");
const compile_mod = @import("../../compile/compile.zig");
const prefilter = @import("../../analysis/prefilter.zig");
const dfa_mod = @import("../dfa/dfa.zig");
const caliper_mod = @import("../caliper/caliper.zig");
const powerset = @import("../dfa/powerset.zig");
const lazy_mod = @import("../dfa/lazy.zig");
const rungs_mod = @import("../ladder/rungs.zig");
const symbolic = @import("../symbolic/symbolic.zig");
const classrun_mod = @import("../../../scan/classrun.zig");
const literal_set = @import("../../../scan/literal_set.zig");
const simd = @import("../../../scan/simd.zig");
const crest = @import("../../../math/crest.zig");
const core = @import("core.zig");

const ByteSet = syn.ByteSet;
const Node = syn.Node;
const State = syn.State;
const ParseError = syn.ParseError;
const Regex = core.Regex;

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
/// `word` (`-w`/`--word-regexp`) makes the word boundary part of the LANGUAGE,
/// by wrapping the parse in `\b{start-half}` … `\b{end-half}` — rg's own rewrite
/// (`grep-regex`'s `word` config), and the reason its engine settles on the
/// SHORTER admissible arm of an alternation at a start offset instead of vetting
/// the greedy one and moving on. See `syn.wordBoundedAst`.
/// `crlf` (`--crlf`) strips `\r` from every consuming class, so no thread may
/// consume the CR of a `\r\n` terminator — rg's `strip_from_match`. See
/// `syn.stripCpAst`.
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
/// `symbolic` picks which determinization discovers that DFA. `.auto` offers a
/// codepoint-class pattern to `../symbolic/` first (predicate alphabet, then a
/// product with a UTF-8 decoder — same table, discovered for a fraction of the
/// visits); `.off` pins the byte-trie powerset. Both produce the same language,
/// so this is a cost knob — and the hook the symbolic path's own differential
/// uses to hold itself against the construction it replaces.
pub const Options = struct {
    caseless: bool = false,
    multiline: bool = false,
    dotall: bool = false,
    unicode: bool = false,
    word: bool = false,
    crlf: bool = false,
    line_anchors: ?bool = null,
    force_dfa: bool = false,
    symbolic: Symbolic = .auto,

    pub const Symbolic = enum { auto, off };
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) ParseError!Regex {
    return compileOpts(allocator, pattern, .{});
}

/// Pattern text ⇒ the AST every downstream consumer reads, arena-allocated and
/// already case-folded. THE only parse: `compileOpts` lowers what this returns
/// and `forcedSwell` sieves by it, so no analysis can disagree with the matcher
/// about what a construct means (see `../../analysis/swell.zig`).
pub fn parse(arena: std.mem.Allocator, pattern: []const u8, opts: Options) ParseError!*Node {
    var parser = syn.Parser{ .src = pattern, .arena = arena, .dotall = opts.dotall, .multiline = opts.multiline, .unicode = opts.unicode, .caseless = opts.caseless };
    const ast = try parser.parseAlt();
    if (parser.pos != pattern.len) return ParseError.BadPattern;
    // Fold BEFORE every downstream analysis (required-literal, cover, first-set,
    // DFA, forced crest) so prefilter and match engines agree on the same classes.
    if (opts.caseless) try syn.foldCaseAst(arena, ast, opts.unicode);
    // `--crlf`: no consuming class may hold `\r`. After the fold, so a promoted
    // `uclass` is stripped too.
    if (opts.crlf) try syn.stripCpAst(arena, ast, '\r');
    return if (opts.word) try syn.wordBoundedAst(arena, ast) else ast;
}

/// The crest sieve's forced swell — ĝ per top-level alternative — for `pattern`
/// under the options the matcher itself was compiled with
/// (`math/crest.zig`, `analysis/swell.zig`). The empty swell, which prunes
/// nothing, whenever the pattern does not parse: an unsupported construct can
/// only cost pruning, never a match.
pub fn forcedSwell(allocator: std.mem.Allocator, pattern: []const u8, opts: Options) crest.Swell {
    return forcedRankedSwell(allocator, pattern, opts, crest.default_budget, crest.default_rank).projectQ1();
}

pub fn forcedRankedSwell(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    opts: Options,
    budget: u8,
    rank: u8,
) crest.RankedSwell {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const ast = parse(arena_state.allocator(), pattern, opts) catch return .{};
    return analysis.forcedRanked(
        arena_state.allocator(),
        ast,
        budget,
        rank,
    ) catch .{};
}

pub fn compileOpts(allocator: std.mem.Allocator, pattern: []const u8, opts: Options) ParseError!Regex {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ast = try parse(arena, pattern, opts);

    var c = compile_mod.Compiler{ .gpa = allocator };
    errdefer c.states.deinit(allocator);
    const match_idx = try c.push(.match);
    const start = try c.compileNode(ast, match_idx);

    // One interned graph, three answers. Each of these used to be its own
    // recursion over `ast`, and `requiredAny` was quadratic — it recomputed
    // `literalInfo` at every node it descended through. Built in this arena
    // (not the gpa) because its lifetime is exactly this compile's, which is
    // what makes the shared build cheaper than the walks it replaces; the
    // `bench/rungs/sweep/` rung is where that trade is measured, and it is a
    // BUNDLE trade — no one of these three pays for the graph alone.
    var facts = try ast_mod.analyze(arena, arena, ast, .{});
    const req = facts.root().lit;
    const required = try allocator.dupe(u8, req.best);
    errdefer allocator.free(required);
    const alts = try dupeCover(allocator, arena, &facts, req.best);
    errdefer freeAlts(allocator, alts);
    const lits = try dupeLits(allocator, arena, ast, opts.multiline);
    errdefer freeAlts(allocator, lits);
    // One authority-ranked literal engine over the strongest fact available:
    // a pure-literal EQUIVALENCE set decides presence outright (`.exact`); a
    // cover union or a single required literal can only NOMINATE, pruning a line
    // on a miss and deferring a hit to the engines below (`.candidate`). Built
    // from the owned copies, so it borrows storage that outlives it — and freed
    // first in `deinit`, before that storage. A set too large to compile simply
    // is not built (the DFA/Pike still serve); only a true OOM propagates.
    var literal_scan: ?literal_set.LiteralSet = literalEngine(allocator, lits, alts, required) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    errdefer if (literal_scan) |*set| set.deinit();

    // The presence gate the span and whole-buffer paths reject on (`core.zig`'s
    // `gate`). Case-sensitive, it is `required` itself; caseless, it is mined
    // from the raw twin, because the fold above erased every literal before any
    // analysis ran. Owned bytes only in the caseless arm.
    const gate_bytes: ?[]u8 = if (opts.caseless) try caselessGateBytes(allocator, arena, pattern, opts) else null;
    errdefer if (gate_bytes) |g| allocator.free(g);
    const gate: ?simd.Gate = if (gate_bytes) |g|
        simd.Gate.caseless(g, false)
    else if (!opts.caseless and required.len != 0)
        simd.Gate.of(required)
    else
        null;

    const states = try c.states.toOwnedSlice(allocator);
    errdefer allocator.free(states);
    const anchored = facts.root().anchored;
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
    const wants_dfa = !(opts.multiline and !assert_free) and !(kernel_final and !opts.force_dfa);
    // Codepoint-class patterns are offered to the symbolic determinizer first:
    // it discovers the SAME automaton without re-walking a UTF-8 trie per
    // closure, which is the entire reason the byte driver's cost budget was
    // declining `\w`/`\p{…}` to the on-demand tier. Anything it cannot express
    // exactly declines, and the byte powerset below decides the pattern as it
    // always has — so this is a discovery-cost choice, never a semantic one.
    var sym_stats: symbolic.Stats = .{};
    const symbolic_dfa: ?*dfa_mod.Dfa = if (wants_dfa and opts.symbolic == .auto and opts.unicode and symbolic.eligible(ast))
        switch (try symbolic.build(allocator, ast, anchored, &sym_stats)) {
            .built => |d| d,
            .declined => null,
        }
    else
        null;
    // No cleanup hook here: the only fallible step between this point and the
    // `dfa` errdefer below is the powerset call, which is unreachable when the
    // symbolic path already built. One owner, one teardown.
    const outcome: powerset.Outcome = if (symbolic_dfa) |d|
        .{ .built = d }
    else if (wants_dfa)
        try powerset.build(allocator, states, start, anchored, opts.unicode, if (opts.force_dfa) .unbudgeted else .budgeted)
    else
        .{ .declined = .unsupported };
    const dfa: ?*dfa_mod.Dfa = switch (outcome) {
        .built => |d| d,
        .declined => null,
    };
    errdefer if (dfa) |d| d.deinit();

    // Both budget declines route here: the same automaton is still the right
    // machine, just discovered on demand rather than up front, so a declined
    // pattern goes to the DFA family instead of dropping to the Pike VM. Only
    // `.unsupported` (a buffer anchor, i.e. multiline) has no DFA of any kind.
    const lazy: ?*lazy_mod.Lazy = switch (outcome) {
        .declined => |why| switch (why) {
            .too_large, .too_costly => try lazy_mod.Lazy.build(allocator, states, start, anchored, opts.unicode),
            .unsupported => null,
        },
        .built => null,
    };
    errdefer if (lazy) |l| l.deinit();

    // The accelerator tier. This is the one site that holds everything a rung
    // needs to admit itself — the determinized program, the AST, and the census
    // of accelerators it would be competing with — so asking costs nothing that
    // was not already computed. Each rung declines by being absent; `rungs.zig`
    // owns the order and the at-most-one-decider policy.
    // ASSERTION-BEARING `-U` is withheld, on the same line as the DFA above and
    // for the same reason: multiline `^`/`$` are content-dependent line anchors
    // that eager determinization cannot encode, so the program `bufMatch` runs
    // is the Pike whole-buffer scan and there is no automaton for a rung to
    // lower. Assertion-FREE multiline keeps the tier, because there the DFA is
    // exact over the buffer as one haystack (`search.bufMatch`) — the rung's
    // question and `-U`'s coincide, and `Rungs.line` is where that is enforced:
    // the per-line rung must prove `sliceSafe` before it may answer.
    const bare_multiline = opts.multiline and !assert_free;
    const start_economics = if (dfa) |d|
        if (d.start_dwell) |exits| exits.economics else null
    else if (lazy) |l|
        if (l.start_dwell) |exits| exits.economics else null
    else
        null;
    var tier = if (bare_multiline) rungs_mod.Rungs.none else try rungs_mod.Rungs.build(allocator, .{
        .dfa = dfa,
        .ast = ast,
        .prefilter = start_economics,
        // WHICH walker a challenger is bidding against when `dfa` is null. Only
        // this site knows: the eager determinizer declining its budget and a
        // pattern having no automaton at all both arrive as `dfa == null`, and
        // they are a ~7× difference in what the incumbent costs per byte.
        .lazy = lazy != null,
        // `^…`: the fallback verifies a few bytes per line and hunts the next
        // terminator, so it is a per-line price rather than a per-byte one.
        .anchored = anchored,
        // Is anything left for the tier to answer? `verdict.zig` puts the literal
        // engine and the class-run kernel above it, and each of those can be
        // *authoritative* rather than merely a prefilter — an `.exact` literal set
        // IS the pattern, and a byte-exact newline-free class run decides any
        // buffer at classification bandwidth. Only this site holds both machines
        // and the tier's admission in the same frame, so only it can say so.
        // Order follows `verdict.zig`: the literal engine is consulted first, so
        // where both settle, it is the one that answers.
        .settled = settledBy(literal_scan, cr),
        .parabix_model = .{
            .grain = if (opts.multiline) .buffer else .lines,
            .unicode_words = opts.unicode,
        },
    });
    errdefer tier.deinit(allocator);

    // The span engine, built only where a span would otherwise reach the Pike
    // VM. A pure-literal alternation (`lits`) and a span-exact class run are
    // both strictly cheaper than any automaton and already pre-empt the VM in
    // `pike/span.zig`, so giving those patterns a caliper would buy nothing and
    // cost a reversal. Everything else — the multi-segment shapes that are the
    // entire reason `-o` costs more than the boolean pass — gets one. This is
    // O(program): the reversal is a graph walk and neither jaw determinizes
    // anything until a haystack asks.
    const span_reduced = lits.len > 0 or if (cr) |run| run.span and (run.exact or run.cp != null) else false;
    const cal: ?*caliper_mod.Caliper = if (!span_reduced and caliper_mod.eligible(states, opts.multiline))
        try caliper_mod.build(allocator, states, start, opts.unicode)
    else
        null;
    errdefer if (cal) |built| built.deinit();

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
        .lazy = lazy,
        .caliper = cal,
        .classrun = cr,
        .literal_scan = literal_scan,
        .gate = gate,
        .gate_bytes = gate_bytes,
        .rungs = tier,
        .assert_free = assert_free,
        .multiline = opts.multiline,
        .line_anchors = opts.line_anchors orelse opts.multiline,
        .unicode = opts.unicode,
        .allocator = allocator,
    };
}

/// Which kernel above the tier settles this pattern outright, if either does —
/// and at the grain the ladder prices it on, since a two-compare class and a
/// nibble-table class, or one needle and a bucket set, are different machines.
/// Each kernel states its own obligations (`decides`) and its own shape
/// (`backend`, `arity`); this only reads them.
///
/// Order follows `verdict.zig`: the literal engine is consulted first, so where
/// both could settle, it is the one that answers.
fn settledBy(
    set: ?literal_set.LiteralSet,
    cr: ?classrun_mod.ClassRun,
) ?rungs_mod.price.Settle {
    if (set) |s| if (s.authority == .exact) return switch (s.arity()) {
        .one => .literal_one,
        .many => .literal_many,
    };
    if (cr) |run| if (run.decides()) return switch (run.backend) {
        .ranges => .class_ranges,
        .nibbles => .class_nibbles,
    };
    return null;
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
fn dupeCover(gpa: std.mem.Allocator, arena: std.mem.Allocator, facts: *const ast_mod.Ast, best: []const u8) ParseError![]const []const u8 {
    if (best.len >= 3) return &.{}; // single-literal prefilter wins
    const cover = (try facts.cover(arena)) orelse return &.{};
    return dupeAll(gpa, cover);
}

/// Compile the strongest literal fact into one authority-ranked engine, or
/// null when none is provable. `&.{required}` is a stack slice, but the
/// one-needle strategy copies the inner `required` header (which the handle
/// owns), not the temporary outer slice.
fn literalEngine(gpa: std.mem.Allocator, lits: []const []const u8, alts: []const []const u8, required: []const u8) literal_set.BuildError!?literal_set.LiteralSet {
    if (lits.len != 0) return try literal_set.LiteralSet.build(gpa, lits, .exact);
    if (alts.len != 0) return try literal_set.LiteralSet.build(gpa, alts, .candidate);
    if (required.len != 0) return try literal_set.LiteralSet.build(gpa, &.{required}, .candidate);
    return null;
}

/// The ASCII-lowered fold-closed window of a CASELESS pattern's required
/// literal, owned — or null when the pattern yields none.
///
/// Under `-i` the fold runs before every analysis (`parse` above, deliberately:
/// prefilter and match engines must agree on the same classes), so by the time
/// the literal pass sees the AST, `ignore` is six classes and `required` is
/// empty. Every literal-derived acceleration therefore vanished for exactly the
/// patterns that need it most — a caseless pattern ran the automaton over every
/// byte of every haystack with no prefilter of any kind.
///
/// So mine the literal from the RAW twin: the same source parsed unfolded, whose
/// `required` is the literal the fold was about to erase. That twin is a
/// throwaway — only its literal outlives it — and this costs one extra parse per
/// caseless COMPILE to save a scan per haystack BYTE.
///
/// Soundness is `simd.foldClosedWindow`'s: it returns the longest window whose
/// every byte folds within its two ASCII spellings, so a caseless match must
/// contain that window in some case spelling and `simd.indexOfCaselessPos` finds
/// it. Non-ASCII bytes and the Kelvin/long-s orbits are excluded there. The
/// window may be a strict substring of the literal, which is why the gate is
/// built with `equiv = false`: a necessary condition only, never a decision.
///
/// Only the PARSE and the literal pass run on the twin — not a second program,
/// DFA, caliper or tier. The literal is a property of the AST, so lowering the
/// twin would be building an entire second engine to read one field off the
/// front of it. Both ASTs share this compile's arena and die with it.
///
/// Every failure declines to null, which is the engine exactly as it was — an
/// unparseable twin, no required literal, no fold-closed window, or OOM on the
/// dupe all leave the caseless pattern on the automaton-only path.
fn caselessGateBytes(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    pattern: []const u8,
    opts: Options,
) ParseError!?[]u8 {
    var raw_opts = opts;
    raw_opts.caseless = false;
    const raw_ast = parse(arena, pattern, raw_opts) catch return null;
    var raw = ast_mod.analyze(arena, arena, raw_ast, .{}) catch return null;
    const win = simd.foldClosedWindow(raw.root().lit.best, opts.unicode) orelse return null;
    const low = try gpa.dupe(u8, win);
    for (low) |*b| b.* = std.ascii.toLower(b.*);
    return low;
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

/// Free an owned cover set (its members then its backing slice). No-op on the
/// empty comptime literal, which has no heap backing.
pub fn freeAlts(gpa: std.mem.Allocator, alts: []const []const u8) void {
    for (alts) |s| gpa.free(s);
    if (alts.len > 0) gpa.free(alts);
}

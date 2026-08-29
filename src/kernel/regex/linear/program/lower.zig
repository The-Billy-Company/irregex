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
const dwell = @import("../automata/dwell.zig");
const rarity = @import("../../../scan/rarity.zig");
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
/// `records` (`--null-data`) is the OTHER way a haystack gets wider than a line,
/// and it is why `multiline` could not keep carrying both facts alone. Under a
/// NUL terminator the caller still splits its input and still calls `lineMatch`
/// per piece — so `multiline` is false, the emitter is unchanged — but a piece is
/// a NUL-delimited RECORD, and a record holds newlines. Every semantic this file
/// used to read off `multiline` is really a consequence of that one fact: whether
/// `^`/`$` are `\n`-boundary assertions or haystack edges, whether `(?s).` may
/// consume a `\n`, whether a class run may cross one, whether an eager anchored
/// determinization is even expressible. `wide` below is the union, and it is what
/// those decisions now ask. Both incumbents agree the anchors must move with it:
/// `rg --null-data '^zz'` and BSD `grep -z '^zz'` each match a `zz` sitting after
/// an interior newline, because `^` in a line-oriented tool asserts about
/// NEWLINES and choosing a different record separator does not retract that.
/// `line_anchors` decouples the regex `m` flag from the haystack's width: `^`/`$`
/// anchor at every `\n` (true) or only at the haystack's ends (false). `null`
/// inherits `wide` — rg's `-U` default is `m` ON, and `(?-m)` clears it while the
/// wide search stays live (`multiline`/`records` unchanged). A per-line haystack
/// is unaffected either way: a single line's edges ARE its line boundaries.
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
    records: bool = false,
    dotall: bool = false,
    unicode: bool = false,
    word: bool = false,
    crlf: bool = false,
    /// `(?x)` / Python `re.VERBOSE` — see `syntax.Parser.verbose`. It reaches the
    /// parser and stops there: no analysis downstream of `parse` can tell that
    /// the source had comments in it, because the AST it produced is the same one
    /// the un-commented spelling produces.
    verbose: bool = false,
    line_anchors: ?bool = null,
    force_dfa: bool = false,
    symbolic: Symbolic = .auto,

    pub const Symbolic = enum { auto, off };

    /// Can a haystack handed to this engine CONTAIN a `\n`? The single question
    /// behind anchor semantics, `(?s).`, class-run newline-freedom, and whether an
    /// eager anchored determinization is expressible at all — see `records`.
    pub fn wide(self: Options) bool {
        return self.multiline or self.records;
    }

    /// Do `^`/`$` assert about NEWLINES (true) or about the haystack's own edges
    /// (false)? `wide` by default; `(?m)`/`(?-m)` overrides either way.
    pub fn lineAnchors(self: Options) bool {
        return self.line_anchors orelse self.wide();
    }
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) ParseError!Regex {
    return compileOpts(allocator, pattern, .{});
}

/// Pattern text ⇒ the AST every downstream consumer reads, arena-allocated and
/// already case-folded. THE only parse: `compileOpts` lowers what this returns
/// and `forcedSwell` sieves by it, so no analysis can disagree with the matcher
/// about what a construct means (see `../../analysis/swell.zig`).
pub fn parse(arena: std.mem.Allocator, pattern: []const u8, opts: Options) ParseError!*Node {
    var parser = syn.Parser{ .src = pattern, .arena = arena, .dotall = opts.dotall, .multiline = opts.wide(), .unicode = opts.unicode, .caseless = opts.caseless, .verbose = opts.verbose };
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
    defer c.loom.deinit(allocator);
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
    const lits = try dupeLits(allocator, arena, ast);
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

    // The anchor seam (`core.zig`'s `seam`): the document-grain needle for a
    // `^…` pattern, which is its match-prefix with the `\n` that proves the
    // anchor glued on. Three refusals, each about soundness rather than profit:
    // an unanchored match need not sit at a line start; a WIDE haystack breaks
    // the mark→line map the sweep's caller relies on (`-U` lets one match cover
    // several emitted lines, and under `--null-data` a match at a record start
    // sits after a NUL, where no seam byte exists); and caseless folding erased
    // every literal before `facts` was built, so `prefix` is empty there anyway.
    const seam_bytes: ?[]u8 = if (anchored and !opts.wide() and !opts.caseless and req.prefix.len != 0)
        try std.mem.concat(allocator, u8, &.{ "\n", req.prefix })
    else
        null;
    errdefer if (seam_bytes) |s| allocator.free(s);
    const seam: ?simd.Gate = if (seam_bytes) |s| simd.Gate.of(s) else null;
    const eol_empty = try analysis.reachesMatchEol(allocator, states, start);
    const nullable = try analysis.reachesMatchZeroWidth(allocator, states, start);
    var first_set: ByteSet = .{};
    if (!anchored) try analysis.analyzeFirst(allocator, states, start, &first_set);

    // A RECORD IS A SEQUENCE OF LINES whenever the pattern cannot see across one
    // — and then everything below may treat this as the per-line model it always
    // was, because it is.
    //
    // This is the whole answer to what `--null-data` costs. A wide haystack
    // withholds the DFA and the accelerator tier from any assertion-bearing
    // program (see `wants_dfa` and `bare_wide` below, and the paragraphs above
    // them): `^`/`$` as `\n`-boundary predicates are content-dependent in a way
    // an eager BOL/EOL determinization cannot encode, so `^(?:alpha|beta|gamma)`
    // fell all the way to the Pike whole-record scan — O(states)/byte, and it
    // measured 290 ms of CPU against ripgrep's 38 ms on 50 MB even while winning
    // wall-clock on threads. Winning by spending seven times the machine is the
    // kind of win that loses on a busy laptop.
    //
    // But the content-dependence only exists while the haystack is wider than a
    // line. Split the record at its newlines and hand the pieces down one at a
    // time, and `^`/`$` are each piece's own edges — the exact case the eager
    // table encodes, so the DFA, the tier, the literal engine, and the class-run
    // kernel all become expressible again. `lineLocal` is the licence: no
    // consuming class admits a `\n`, so no match could have crossed one and the
    // decomposition loses no answer; and no `\A`/`\z` is present, since those
    // mean the RECORD's ends and a per-line walk would quietly demote them to
    // `^`/`$` (the same demotion rg's line searcher makes, which is why it
    // refuses `\A` by claiming the newline instead).
    //
    // `std.mem.splitScalar` is exactly the record line model, phantom included:
    // "ab\n" splits into "ab" and "", and that trailing empty piece IS the line
    // after the newline that `nl_terminates` opens for a record. So the two
    // models agree by construction rather than by a second rule.
    //
    // `!opts.multiline` is a statement about WHO SPLITS. Decomposition is the
    // engine handing itself smaller haystacks, which only works while the caller
    // is handing it one record at a time; a `-U` caller hands over the whole
    // buffer and expects whole-buffer spans, and every `Selection` on the
    // capture/`Pattern` plane forces `multiline = true` for exactly that reason
    // (`captures.Selection.lowerOptions`). Those planes run their own VMs and
    // would never see the flag, so a program compiled per-line and walked whole
    // would answer `^` at the buffer start only — a missing result, the failure
    // mode nothing downstream can notice. So they are excluded here rather than
    // taught to split.
    const split_lines = opts.records and !opts.multiline and
        opts.lineAnchors() and lineLocal(states);
    // What the gates below must ask, now that a record may be narrower than it
    // looks: `wide` is "a haystack reaching an engine can hold a `\n`", which a
    // decomposed record cannot, and `line_anchors` follows it down — a line's
    // edges ARE its line boundaries, so resolving `^` against the haystack end
    // is the same predicate for less work.
    const wide = opts.wide() and !split_lines;
    const line_anchors = opts.lineAnchors() and !split_lines;
    const line_sieve = split_lines and linesSieveable(gate);

    // Byte-class DFA, the primary engine: determinizes the Thompson program
    // (anchors and all); null only on powerset blow-up, when the Pike VM serves.
    // A wide haystack resolves `^`/`$` per-position against `\n` adjacency (a
    // match spans lines), which the eager BOL/EOL determinization can't encode —
    // so an assertion-BEARING wide regex runs the Pike whole-haystack scan and
    // needs no DFA. An assertion-FREE wide pattern (`import \([\s\S]*?\)`,
    // the whole `-U` bench class) has no positional predicate at all: its
    // determinization is exact over any haystack, so `bufMatch` gets the same
    // O(1)/byte floor the per-line model enjoys instead of the O(states)/byte
    // Pike re-seed rg's lazy DFA was beating.
    const assert_free = assertFree(states);
    // The buffer model's own admission, which is wider than `assert_free` — see
    // `bufExact`. Inert in the per-line model, where the DFA serves regardless.
    const buf_exact = bufExact(states, line_anchors, nullable, eol_empty);

    // SIMD class-run reduction (post-fold, so `-i` classes are final). In
    // the per-line model a haystack line never contains `\n`, so dropping
    // it from the set is an identity there — and it makes every run
    // provably line-local, licensing the one-pass whole-buffer `docMatch`.
    // A wide haystack keeps the set verbatim: it holds the `\n` itself.
    // A codepoint class whose full ranges survived the AST algebra hands
    // them (gpa-duped; the arena dies with this frame) to the kernel,
    // whose scalar UTF-8 resolver then settles high bytes itself.
    const cr: ?classrun_mod.ClassRun = if (analysis.classRunShape(ast)) |shape| blk: {
        var set = shape.set;
        if (!wide) set.remove('\n');
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
    const wants_dfa = !(wide and !buf_exact) and !(kernel_final and !opts.force_dfa);
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
    // Still `assert_free`, deliberately, where the DFA above is now `buf_exact`:
    // a per-line rung answers the SLICE question, which needs "no match crosses
    // a `\n`" — substring closure, which only assertion-freeness gives. A `\b`
    // pattern is exactly determinizable over the buffer and still not sliceable.
    const bare_wide = wide and !assert_free;
    const start_economics = if (dfa) |d|
        if (d.start_dwell) |exits| exits.economics else null
    else if (lazy) |l|
        if (l.start_dwell) |exits| exits.economics else null
    else
        null;
    var tier = if (bare_wide) rungs_mod.Rungs.none else try rungs_mod.Rungs.build(allocator, .{
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
            .grain = if (wide) .buffer else .lines,
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
    const cal: ?*caliper_mod.Caliper = if (!span_reduced and caliper_mod.eligible(states, wide, line_anchors))
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
        .seam = seam,
        .seam_bytes = seam_bytes,
        .rungs = tier,
        .assert_free = assert_free,
        .buf_exact = buf_exact,
        .multiline = opts.multiline,
        .line_anchors = line_anchors,
        .split_lines = split_lines,
        .line_sieve = line_sieve,
        .nl_terminates = !opts.records,
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
/// Can every match this program admits fit inside ONE line of its haystack —
/// so that splitting a record at its newlines throws no answer away?
///
/// Two obligations, and they are the only two. No consuming instruction may
/// admit a `\n`, or a match could straddle the split (`a\nz`, `[\s]+`, `(?s).`).
/// And no `\A`/`\z` may be present, because under the record model those are the
/// RECORD's ends; handing them a line each silently demotes them to `^`/`$`.
/// `^`/`$` themselves are welcome — they are precisely what a per-line walk
/// resolves for free — and so is `\b`, which reads the two bytes adjacent to a
/// position and gets the same verdict either way, since a `\n` is a non-word
/// byte and so is running off the end of a haystack.
///
/// Deliberately NOT `Regex.claimsNewline`, which is the same walk with a
/// different question: that one asks whether a pattern's answer can depend on a
/// newline AT ALL (so `-U` may keep the whole-buffer searcher), and it counts
/// `^`/`$` as a claim. Here they are the point.
/// May a decomposed record's span walk use the required-literal gate to skip
/// whole LINES — jumping between the needle's occurrences instead of walking
/// every line of the record?
///
/// Soundness is the gate's own, unchanged: every match contains the literal, so
/// a line holding no occurrence holds no match. What is new is the GRAIN, and
/// the grain is the point, because `span.matchWindow` cannot consult the gate on
/// the window a decomposed line arrives as. Splitting the record clears
/// `line_anchors`, so a `^…` line is buffer-anchored, and an anchored window
/// skips the gate deliberately: the walk is one bounded attempt, so sweeping the
/// line for a literal costs more than the attempt does. Across a record's eight
/// lines that reasoning inverts, and nobody upstream can repair it — the emit
/// layer's candidate mask is handed RECORDS, so it admits a 421-byte record
/// because one line holds the literal and then all eight pay a span walk.
/// Measured on 50 MB of records: `--count-matches '^\w+ mid'` 1099 → 466 ms CPU.
///
/// Two refusals, both about profit rather than truth:
///
///   1. A **caseless** gate rides a different kernel and prices differently;
///      excluded rather than reasoned about.
///   2. A needle the corpus prior expects every few bytes cannot skip a line, so
///      its sweep is pure overhead — the space required by `^[a-z]+ [a-z]+
///      [a-z]+` is the case that matters, and it measured +4% for zero skips.
///      Priced by the shipped rarity table through the same `beatsDense`
///      predicate every other skip in the engine is armed by, against the
///      RAREST byte of the needle: `P(needle here) ≤ min_i P(byte_i)`, so that
///      byte's stride is a bound on the needle's that no multi-byte needle can
///      be denser than.
fn linesSieveable(gate: ?simd.Gate) bool {
    const g = gate orelse return false;
    if (g.ci or g.equiv or g.bytes.len == 0) return false;
    var rarest: ByteSet = .{};
    var pick = g.bytes[0];
    for (g.bytes[1..]) |b| if (rarity.density[b] < rarity.density[pick]) {
        pick = b;
    };
    rarest.set(pick);
    return prefilter.estimate(rarest).beatsDense(dwell.min_profitable_stride);
}

fn lineLocal(states: []const State) bool {
    for (states) |st| switch (st) {
        .consume => |cn| if (cn.set.has('\n')) return false,
        .split, .match, .assert_word, .assert_start, .assert_end => {},
        else => return false, // `\A`/`\z` — the record's own ends, not a line's
    };
    return true;
}

fn assertFree(states: []const State) bool {
    for (states) |st| switch (st) {
        .consume, .split, .match => {},
        else => return false,
    };
    return true;
}

/// Whether the eager DFA is exact over the WHOLE buffer as one haystack — the
/// buffer model's admission, which `assertFree` is too coarse to be.
///
/// `assertFree` answers a stronger question than this site asks: "does match
/// validity depend on anything but the consumed bytes?". Using it here withheld
/// the DFA from every buffer-model program carrying ANY assertion, on a reason
/// that is only true of one of them — `^`/`$` under `(?m)`, which hold at every
/// `\n` and so are content-dependent in a way no eager BOL/EOL table can encode.
///
/// A word-context assertion is not that. `\b` reads the two bytes adjacent to a
/// position; it is haystack-local, identical in both models, and the powerset
/// already determinizes it — which the LINE model proves every day, since it
/// arms a DFA for exactly these programs. The buffer is just a longer haystack.
///
/// The cost of conflating them was not small, because the buffer model is the
/// ONLY model a language binding compiles under (`compile/captures.zig` forces
/// `.multiline = true`), and `\b` is in most real patterns. A 4 KB scan of one
/// catalogue pattern — seven verbs, a hinge, a trailing alternation, one `\b` —
/// ran 314 µs on the Pike VM where the same pattern with the `\b` deleted ran
/// 12 µs on the DFA. Same automaton, 26× the cost, for an assertion the
/// determinizer had never had trouble with.
///
/// **Zero-width matches are excluded, and that is not caution.** `bufMatch`
/// refuses to seed a thread at the phantom position after a trailing `\n`,
/// because rg's line model opens no empty last line there. A DFA has no such
/// rule, so a program that can reach `match` zero-width — `\B` over `"abc\n"`
/// is the whole case — would be answered yes by the table and no by the VM.
/// `nullable` and `eol_empty` are exactly those programs, already computed.
fn bufExact(states: []const State, line_anchors: bool, nullable: bool, eol_empty: bool) bool {
    // The class the buffer model already admitted, admitted on the same terms:
    // nothing positional to resolve, so nothing below can have an opinion on it.
    if (assertFree(states)) return true;
    if (nullable or eol_empty) return false;
    for (states) |st| switch (st) {
        .consume, .split, .match, .assert_word => {},
        // `^`/`$`: the haystack's own ends, until `(?m)` makes them per-line.
        .assert_start, .assert_end => if (line_anchors) return false,
        // `\A`/`\z` stay out. Under this model they ARE the buffer's ends, so
        // the table would be right about them — but `bufMatch` carries the
        // phantom-position rule above for the trailing `\n`, and that rule is
        // the VM's, not the automaton's. Admitting them needs the rule lifted
        // into the DFA first, which is a separate change with its own proof.
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
/// or empty.
///
/// **Not gated on the match model, and it used to be.** The reasoning for
/// skipping it under multiline was that a match may cross `\n` there, so a
/// per-line equivalence claim would not hold — but the claim `pureLiterals`
/// makes was never per-line. It rejects every assertion (`pureLit` takes only
/// bytes, codepoints, concatenation and transparent captures) and it rejects any
/// literal carrying `\n` outright, so what survives is a statement about the
/// AST: this pattern matches a text **iff** that text contains one of these
/// literals. A literal with no `\n` in it lies inside one line wherever it
/// occurs, so the buffer and the line read the claim identically.
///
/// The gate was therefore not conservative, it was lossy — and lossy on the one
/// face that always sets the flag. A `glean.Pattern` forces the buffer model as
/// an invariant, so every consumer of the C ABI compiled every pattern, a bare
/// literal string included, with an empty `lits`. That left `pike/span.zig`'s
/// literal fast path unreachable from every language binding and dropped their
/// spans onto the Pike VM.
fn dupeLits(gpa: std.mem.Allocator, arena: std.mem.Allocator, ast: *Node) ParseError![]const []const u8 {
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

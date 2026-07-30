//! gist — the prefilters: what the pattern proves we may skip.
//!
//! Every function here answers one question — given the compiled pattern, which
//! bytes can we decline to look at and still be certain the answer is
//! byte-identical? Three independent necessary conditions, weakest to
//! strongest: a required-literal SIMD gate (a line without the literal cannot
//! match), a trigram filter (a file without the trigrams cannot match), and the
//! crest sieve, which covers exactly the class the trigram filter concedes —
//! literal-free class repetitions like `[0-9a-f]{8}`.
//!
//! The soundness law: skipping is an ACCELERATION, never a semantic. Each gate
//! must be conservative in one direction only — it may admit a file that turns
//! out not to match, but it may NEVER reject one that would have. That is why
//! every one of these declines outright under `--invert`, and why the modes that
//! must observe every byte (`--stats`, `--json`, `--passthru`, `-v`) get no
//! whole-file gate at all: they emit or tally bytes a match-only gate would have
//! thrown away.

const std = @import("std");
const args = @import("../argv/args.zig");
const arm = @import("arm.zig");
const assay = @import("../../../assay/assay.zig");
const crest = @import("../../../kernel/math/crest.zig");
const query_mod = @import("../../../kernel/query/query.zig");
const simd = @import("../../../kernel/scan/simd.zig");

const Matcher = @import("../../../kernel/regex/regex.zig").Matcher;
const Opts = args.Opts;
const oom = @import("../../../surface/cli/outcome.zig").oom;
const Regex = @import("../../../kernel/regex/regex.zig").Regex;

// ─────────────────────── who may skip, and when ───────────────────────
//
// Three predicates, one owner each. Before these existed the same policy was
// re-spelled at five call sites, and the failure mode of forgetting one was
// silent: a new output mode would return a WRONG result with a clean exit code.
// Every caller now asks; none re-derives.

/// Does this run emit or tally bytes that do NOT match? `--stats` counts every
/// line it read, `--json` reports per-file summaries for files with no hit, and
/// `--passthru` prints non-matching lines verbatim. All three make "skip what
/// cannot match" a WRONG answer rather than a faster one, because the skipped
/// content is itself part of the output.
///
/// This is the load-bearing predicate of the tier: a new output mode that
/// observes non-matching content needs to be added HERE and nowhere else.
pub fn observesEveryByte(o: Opts) bool {
    return o.stats or o.mode == .json or o.passthru;
}

/// May a whole file be dropped UNREAD because a literal gate proves no line in
/// it can match? Beyond the modes that observe every byte:
/// `--files-without-match` reports exactly the files that don't match (so a
/// dropped file IS the answer, not a saving), and `--include-zero` must reach
/// the emitter to print its `path:0` row.
pub fn mayDropFileUnread(o: Opts) bool {
    return !observesEveryByte(o) and !o.mode.negated() and !o.include_zero;
}

/// May the persisted index prefilter and elide reads? The every-byte modes,
/// plus four conditions specific to reasoning from an on-disk artifact: `-v`
/// inverts the question the index answers, `--no-index` is the user forbidding
/// it outright, `--include-zero` needs even a provably non-matching file to
/// reach the emitter for its `path:0` row, and a TRANSFORMING run
/// (`-z`/`--pre`/`-E`) searches rewritten bytes the on-disk trigrams and crest
/// vectors were never computed over.
///
/// Deliberately NOT `mayDropFileUnread`: `--files-without-match` forbids the
/// whole-file literal gate but still permits index prefiltering, because the
/// index narrows which files are READ while the walk keeps reporting every file
/// it admitted. Folding the two predicates together would be a silent behavior
/// change, so they stay separate and each says why.
pub fn mayElideByIndex(o: Opts, transforming: bool) bool {
    return !observesEveryByte(o) and !o.invert and !o.no_index and !o.include_zero and !transforming;
}

pub fn requiredLiteralGate(a: std.mem.Allocator, o: Opts, eff: []const u8, re: *const Matcher) ?simd.Gate {
    if (o.invert) return null;
    if (o.caseless) return caselessGate(a, o, eff, re);
    const req = re.required();
    if (req.len == 0) return null;
    return simd.Gate.of(req);
}

/// The caseless twin of the required-literal gate: recompile the effective
/// pattern CASE-SENSITIVELY (the fold is what erases `required`, so the
/// unfolded twin still carries it), take the longest fold-closed WINDOW of
/// that raw literal (`query.zig::foldClosedWindow` — ASCII-only; Kelvin/long-s
/// orbits split the window under Unicode fold), and gate through
/// `simd.containsCaseless` against the lowered spelling. When the window IS
/// the whole literal and the raw twin IS one pure literal, the gate is a
/// match EQUIVALENCE (`.equiv`) — the caseless `-l` fast path may then emit
/// on a gate hit alone, no engine run at all. `a` is the run arena: the
/// lowered literal lives for the whole invocation.
pub fn caselessGate(a: std.mem.Allocator, o: Opts, eff: []const u8, re: *const Matcher) ?simd.Gate {
    switch (re.*) {
        .linear => {},
        .pcre => return null, // no raw-literal twin to mine (literal.zig declines caseless)
    }
    var raw = Regex.compileOpts(a, eff, .{ .unicode = o.unicode, .multiline = o.multiline }) catch return null;
    defer raw.deinit();
    const win = query_mod.foldClosedWindow(raw.required, o.unicode) orelse return null;
    const low = a.dupe(u8, win) catch oom();
    for (low) |*b| b.* = std.ascii.toLower(b.*);
    const whole = win.len == raw.required.len;
    const equiv = whole and raw.lits.len == 1 and std.mem.eql(u8, raw.lits[0], raw.required);
    return simd.Gate.caseless(low, equiv);
}

/// A line gate merely avoids a regex run. A whole-file gate drops the file, so
/// modes that emit/tally non-matching bytes must still read every body.
pub fn wholeFileLiteralGate(o: Opts, needle: ?simd.Gate) ?simd.Gate {
    if (!mayDropFileUnread(o)) return null;
    return needle;
}

pub fn trigramFilter(a: std.mem.Allocator, o: Opts, eff: []const u8, re: *const Matcher, one: *[1][]const u8, transforming: bool) []const []const u8 {
    if (!mayElideByIndex(o, transforming)) return &.{};
    if (o.caseless) return caselessFilter(a, o, eff, re);
    // The regex→sound-literals mapping is the shared search core's, so the cold
    // elision and the warm resident session prune by identical literals. The
    // PCRE2 arm has no gist AST, so it prunes through the engine-neutral seam —
    // the same function warm uses, rather than a second copy of the rule.
    return switch (re.*) {
        .linear => |*r| query_mod.regexPrefilter(r, one),
        .pcre => query_mod.matcherPrefilter(re, one),
    };
}

/// The caseless prefilter: recompile the effective pattern CASE-SENSITIVELY (a
/// throwaway parse — the fold is what erases `required`, so the unfolded twin
/// still carries it), then expand one window of that raw literal into its
/// case-variant OR-set (`query.zig::caselessVariants`, which owns the
/// soundness bounds: ASCII-only, Kelvin/long-s orbits excluded under Unicode
/// fold). Every decline returns the empty filter — exactly the old
/// "caseless ⇒ no elision" behavior. `a` is the run arena: the variant strings
/// live for the whole invocation, like every other filter source.
pub fn caselessFilter(a: std.mem.Allocator, o: Opts, eff: []const u8, re: *const Matcher) []const []const u8 {
    switch (re.*) {
        .linear => {},
        .pcre => return &.{}, // no raw-literal twin to mine (literal.zig declines caseless)
    }
    var raw = Regex.compileOpts(a, eff, .{ .unicode = o.unicode, .multiline = o.multiline }) catch return &.{};
    defer raw.deinit();
    if (raw.required.len < 3) return &.{};
    const vars = query_mod.caselessVariants(a, raw.required, o.unicode) catch return &.{};
    return vars orelse &.{};
}

/// Both index-prunings this invocation may claim — the conjunctive cover plan
/// and the crest sieve's forced swell — off ONE parse of the pattern
/// (`query.winnow`). Each is independently stood down here where it would be
/// unsound or unwanted, and each is independently declinable downstream:
/// `elide.assemble` falls back to `trigramFilter`'s flat OR when the plan is
/// null, and the empty swell prunes nothing. So every decline below costs
/// pruning and never a match.
///
/// `pattern` is the EFFECTIVE combined pattern the engine actually compiled
/// (post `-f` fold, `-F` escaping, and leading-flag strip), so neither can be
/// derived from fewer branches than the engine matches. Multi `-e` arrives as
/// `(?:a)|(?:b)`, which both halves are built to read: the swell keeps one ĝ per
/// alternative (a componentwise min across disjoint forced classes would be 0⃗,
/// which is how every multi-pattern search used to stand the sieve down by
/// construction), and `cover.branch` emits a clause only where BOTH sides force
/// one, so a single unplannable branch yields no plan for the whole run rather
/// than a set that under-admits the others.
///
/// The guards, and why each half has different ones:
///
///   * **`mayElideByIndex` bounds both.** Neither ever widens where index
///     elision is inadmissible; they only EXTEND the criterion where it runs.
///   * **PCRE2 gets neither.** Both are read off gist's AST while PCRE2 denotes
///     the pattern under its own grammar — the dual-parser hazard one level up,
///     worst exactly where `--engine auto` escalated *because* gist's grammar
///     could not express the pattern. `-P` runs keep `trigramFilter`'s
///     engine-neutral literals and lose only this extra pruning.
///   * **Caseless stands the PLAN down, not the sieve.** A folded AST would in
///     principle cross-product into the case-variant set for free, but
///     `caselessVariants` is the one place the Unicode-fold bounds (ASCII-only,
///     Kelvin/long-s orbits excluded) are stated, and a second spelling of that
///     reasoning is how a fold bug gets in — so `-i` keeps `caselessFilter`.
///     The sieve needs no such care: `-i` folds the AST before the calculus
///     reads it, so case-closed classes still force their runs while
///     `upper`/`lower` (and any Unicode orbit escaping ASCII) fold themselves
///     out of certification.
///
/// `GIST_NO_COVER` / `GIST_NO_CREST` (internal, undocumented — the
/// `GIST_NO_PARALLEL_LOAD` idiom) stand one half down each, leaving the run on
/// `trigramFilter`'s flat OR and/or no sieve. They are how each wired path is
/// measured against itself on ONE binary, so an A/B cannot be confounded by a
/// build difference; they are also the operational escape hatch if a plan ever
/// costs more posting decode than it saves.
pub fn winnow(a: std.mem.Allocator, o: Opts, pattern: []const u8, re: *const Matcher, transforming: bool) query_mod.Winnow {
    if (!mayElideByIndex(o, transforming)) return .{};
    switch (re.*) {
        .linear => {},
        .pcre => return .{},
    }
    const want_cover = !o.caseless and !assay.envFlag("GIST_NO_COVER");
    var w = query_mod.winnow(a, pattern, arm.linearOptions(o), if (want_cover) .{} else null);
    if (assay.envFlag("GIST_NO_CREST")) w.sieve = crest.no_sieve;
    return w;
}

test "required literal gate reuses sound regex analysis" {
    const t = std.testing;
    var decl = Matcher{ .linear = try Regex.compile(t.allocator, "func\\s+\\w+\\(") };
    defer decl.deinit();
    try t.expectEqualStrings("func", requiredLiteralGate(t.allocator, .{}, "func\\s+\\w+\\(", &decl).?.bytes);

    var short = Matcher{ .linear = try Regex.compile(t.allocator, "[0-9a-f]{8}-[0-9a-f]{4}") };
    defer short.deinit();
    try t.expectEqualStrings("-", requiredLiteralGate(t.allocator, .{}, "[0-9a-f]{8}-[0-9a-f]{4}", &short).?.bytes);

    var common = Matcher{ .linear = try Regex.compile(t.allocator, "(foo|bar)baz") };
    defer common.deinit();
    try t.expectEqualStrings("baz", requiredLiteralGate(t.allocator, .{}, "(foo|bar)baz", &common).?.bytes);

    var alternatives = Matcher{ .linear = try Regex.compile(t.allocator, "(?:foo)|(?:bar)") };
    defer alternatives.deinit();
    try t.expect(requiredLiteralGate(t.allocator, .{}, "(?:foo)|(?:bar)", &alternatives) == null);
}

test "caseless gate: fold-closed literal, lowered spelling, pure-literal equivalence" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A pure literal with an ASCII-closed fold: gate present, lowered, equiv.
    var lit = Matcher{ .linear = try Regex.compileOpts(a, "WalletProvider", .{ .caseless = true, .unicode = true }) };
    const g = requiredLiteralGate(a, .{ .caseless = true }, "WalletProvider", &lit).?;
    try t.expect(g.ci);
    try t.expect(g.equiv);
    try t.expectEqualStrings("walletprovider", g.bytes);

    // A regex body keeps the gate (fold-closed required literal) without equiv.
    var rex = Matcher{ .linear = try Regex.compileOpts(a, "provider\\d+", .{ .caseless = true, .unicode = true }) };
    const gr = requiredLiteralGate(a, .{ .caseless = true }, "provider\\d+", &rex).?;
    try t.expect(gr.ci and !gr.equiv);
    try t.expectEqualStrings("provider", gr.bytes);

    // Kelvin/long-s orbits split the window under Unicode fold: "task" gates
    // on its "ta" prefix (containment only, never equivalence)…
    var risky = Matcher{ .linear = try Regex.compileOpts(a, "task", .{ .caseless = true, .unicode = true }) };
    const gk = requiredLiteralGate(a, .{ .caseless = true }, "task", &risky).?;
    try t.expect(gk.ci and !gk.equiv);
    try t.expectEqualStrings("ta", gk.bytes);
    // …an all-escaping literal declines entirely…
    var sks = Matcher{ .linear = try Regex.compileOpts(a, "sks", .{ .caseless = true, .unicode = true }) };
    try t.expect(requiredLiteralGate(a, .{ .caseless = true }, "sks", &sks) == null);
    // …and ASCII fold admits the whole literal, equivalence included.
    var ascii = Matcher{ .linear = try Regex.compileOpts(a, "task", .{ .caseless = true, .unicode = false }) };
    const ga = requiredLiteralGate(a, .{ .caseless = true, .unicode = false }, "task", &ascii).?;
    try t.expect(ga.ci and ga.equiv);
    try t.expectEqualStrings("task", ga.bytes);
}

test "whole-file gate preserves all-byte modes" {
    const t = std.testing;
    const needle: ?simd.Gate = simd.Gate.of("func");
    try t.expectEqualStrings("func", wholeFileLiteralGate(.{}, needle).?.bytes);
    try t.expect(wholeFileLiteralGate(.{ .passthru = true }, needle) == null);
    try t.expect(wholeFileLiteralGate(.{ .stats = true }, needle) == null);
    try t.expect(wholeFileLiteralGate(.{ .mode = .json }, needle) == null);
    try t.expect(wholeFileLiteralGate(.{ .mode = .files_without_match }, needle) == null);
}

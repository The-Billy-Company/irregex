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
const crest = @import("../../../../kernel/primitives/crest.zig");
const query_mod = @import("../../../../kernel/match/query/query.zig");
const simd = @import("../../../../kernel/match/scan/simd.zig");

const Matcher = @import("../../../../kernel/match/regex/linear/ladder/matcher.zig").Matcher;
const Opts = args.Opts;
const oom = args.oom;
const Regex = @import("../../../../kernel/match/regex/linear/program/core.zig").Regex;

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
    return o.stats or o.json or o.passthru;
}

/// May a whole file be dropped UNREAD because a literal gate proves no line in
/// it can match? Beyond the modes that observe every byte:
/// `--files-without-match` reports exactly the files that don't match (so a
/// dropped file IS the answer, not a saving), and `--include-zero` must reach
/// the emitter to print its `path:0` row.
pub fn mayDropFileUnread(o: Opts) bool {
    return !observesEveryByte(o) and !o.files_without and !o.include_zero;
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
    return .{ .bytes = req };
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
    return .{ .bytes = low, .ci = true, .equiv = equiv };
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
    // PCRE2 arm has no gist AST, so it prunes by its required literal alone
    // (≥3 bytes to be trigram-usable) — the same soundness rule, conservatively.
    return switch (re.*) {
        .linear => |*r| query_mod.regexPrefilter(r, one),
        .pcre => blk: {
            const req = re.required();
            if (req.len >= 3) {
                one[0] = req;
                break :blk one[0..1];
            }
            break :blk re.alts();
        },
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

/// The crest sieve's forced-crest vector ĝ for this invocation, or 0⃗ (⇒ the
/// sieve never elides) under the same whole-file-scan / no-index guards as
/// `trigramFilter` — the sieve only ever EXTENDS the pruning criterion where
/// index elision is already admissible, it never widens where elision runs.
/// `pattern` is the EFFECTIVE combined pattern the engine actually compiled
/// (post `-f` fold, `-F` escaping, and leading-flag strip — multi `-e` arrives
/// as `(?:a)|(?:b)`, whose alternation the calculus min-folds natively), so ĝ
/// can never be derived from fewer branches than the engine matches.
/// Unlike `trigramFilter`, caseless does NOT stand the sieve down: the calculus
/// case-closes each atom so the case-closed classes still force runs (only the
/// linear engine, whose fold it is validated against — PCRE2 keeps declining).
/// The Unicode flag is the ACTIVE engine's (linear `-u` vs PCRE2's own), since
/// that is what decides `\d`/`\w` byte semantics (the Alphabet Contract).
pub fn crestSieve(o: Opts, pattern: []const u8, re: *const Matcher, transforming: bool) crest.Vector {
    if (!mayElideByIndex(o, transforming)) return crest.zero_vector;
    // Caseless still sieves the case-closed classes, but only for the linear
    // engine whose fold the calculus is validated against (ASCII a⇄A plus the
    // Unicode k/K/s/S escape guard); PCRE2's own fold keeps declining `-i`.
    if (o.caseless and re.* == .pcre) return crest.zero_vector;
    const uni = switch (re.*) {
        .linear => o.unicode,
        .pcre => o.pcre_unicode,
    };
    return crest.ghat(pattern, .{ .unicode = uni, .caseless = o.caseless });
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
    const needle: ?simd.Gate = .{ .bytes = "func" };
    try t.expectEqualStrings("func", wholeFileLiteralGate(.{}, needle).?.bytes);
    try t.expect(wholeFileLiteralGate(.{ .passthru = true }, needle) == null);
    try t.expect(wholeFileLiteralGate(.{ .stats = true }, needle) == null);
    try t.expect(wholeFileLiteralGate(.{ .json = true }, needle) == null);
    try t.expect(wholeFileLiteralGate(.{ .files_without = true }, needle) == null);
}

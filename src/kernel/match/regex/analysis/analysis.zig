//! gist — regex *literal analysis*: sound, read-only AST visitors over
//! `syntax.zig` that feed the scanner's accelerators. Every one is conservative
//! (a wrong "don't know" only costs a full scan, never a missed match):
//! required-literal extraction for the T0 trigram prefilter (the literal half of
//! Cox's regexp→trigram analysis), the alternation cover set, the pure-literal
//! match-equivalence set, and the anchored-start predicate that lets the scanner
//! seed only at line position 0.
//!
//! This file is also the public face of the analysis layer: the class-run/span
//! reductions (`runs.zig`) and the compiled-NFA reachability visitors
//! (`reach.zig`) are private siblings, re-exported at the bottom so callers use
//! one `analysis.<name>` surface. Split out from the parser so `syntax.zig` is
//! pure syntax (types + recursive descent) and `compile.zig` is pure lowering.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const Node = syn.Node;
const ParseError = syn.ParseError;

/// The literal facts provable about an AST node, feeding the trigram prefilter
/// and the pure-literal fast path. All fields are conservative under-claims.
pub const LitInfo = struct {
    exact: ?[]const u8, // node matches EXACTLY this literal and nothing else
    prefix: []const u8, // every match must START with this literal run
    suffix: []const u8, // every match must END with this literal run
    best: []const u8, // longest literal that MUST appear (contiguously) in every match

    /// Proves nothing (caller scans all docs).
    const unknown: LitInfo = .{ .exact = null, .prefix = "", .suffix = "", .best = "" };
    /// Matches exactly the empty string (zero-width nodes).
    const zero_width: LitInfo = .{ .exact = "", .prefix = "", .suffix = "", .best = "" };

    /// The node matches exactly `lit` and nothing else.
    fn exactly(lit: []const u8) LitInfo {
        return .{ .exact = lit, .prefix = lit, .suffix = lit, .best = lit };
    }
};

fn longer(a: []const u8, b: []const u8) []const u8 {
    return if (a.len >= b.len) a else b;
}

/// The UTF-8 bytes of a single-codepoint `uclass` (a non-ASCII literal), or null
/// for a wider codepoint class — so a `uclass` literal feeds the same prefilter /
/// pure-literal machinery as an ASCII `class` singleton.
fn uclassLiteral(arena: std.mem.Allocator, ranges: []const [2]u21) ParseError!?[]const u8 {
    if (ranges.len != 1 or ranges[0][0] != ranges[0][1]) return null;
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(ranges[0][0], &buf) catch return null;
    return try arena.dupe(u8, buf[0..n]);
}

/// Compute a literal that must appear in every match (`best`). Sound: if it
/// can't prove one, `best` is "" (caller scans all docs). Mirrors the literal
/// half of Cox's regexp→trigram analysis, conservatively.
pub fn literalInfo(arena: std.mem.Allocator, node: *Node) ParseError!LitInfo {
    switch (node.*) {
        // Zero-width: matches the empty string at a position. exact="" lets a
        // mandatory literal run span the anchor (e.g. `^func` ⇒ required "func",
        // `\bfunc\b` ⇒ "func" — the word boundaries are zero-width too).
        .empty, .anchor_start, .anchor_end, .anchor_buf_start, .anchor_buf_end, .word_boundary, .not_word_boundary, .word_start, .word_end => return .zero_width,
        .class => |set| {
            // A singleton class is an exact literal; anything wider proves nothing.
            const b = set.only() orelse return .unknown;
            return LitInfo.exactly(try arena.dupe(u8, &[_]u8{b}));
        },
        // A single-codepoint `uclass` (a non-ASCII literal) is exact — its UTF-8
        // bytes feed the trigram prefilter exactly like an ASCII literal. A wider
        // codepoint class (`\w`, `[é-ÿ]`) proves no literal.
        .uclass => |ranges| {
            const l = (try uclassLiteral(arena, ranges)) orelse return .unknown;
            return LitInfo.exactly(l);
        },
        .concat => |ab| {
            const x = try literalInfo(arena, ab[0]);
            const y = try literalInfo(arena, ab[1]);
            // Both sides exact ⇒ the concat is itself exact.
            var exact: ?[]const u8 = null;
            if (x.exact) |xe| if (y.exact) |ye| {
                exact = try std.mem.concat(arena, u8, &.{ xe, ye });
            };
            // A mandatory prefix run extends through x into y only when x is fully
            // exact; symmetrically the suffix extends back through y into x. The
            // boundary run — x's mandatory suffix immediately followed by y's
            // mandatory prefix — is itself mandatory AND contiguous. That span is
            // what recovers the trailing literal a non-exact prefix would
            // otherwise hide (`a*function` ⇒ "function", not "f").
            const prefix = if (x.exact) |xe| try std.mem.concat(arena, u8, &.{ xe, y.prefix }) else x.prefix;
            const suffix = if (y.exact) |ye| try std.mem.concat(arena, u8, &.{ x.suffix, ye }) else y.suffix;
            const span = try std.mem.concat(arena, u8, &.{ x.suffix, y.prefix });
            var best = longer(longer(x.best, y.best), span);
            if (exact) |e| best = longer(best, e);
            return .{ .exact = exact, .prefix = prefix, .suffix = suffix, .best = best };
        },
        .plus => |r| {
            // Content occurs ≥ once, so its prefix/suffix/best are mandatory; but
            // the minimum is a single iteration, so there is no cross-iteration
            // run and the whole is not exact.
            const xi = try literalInfo(arena, r.node);
            return .{ .exact = null, .prefix = xi.prefix, .suffix = xi.suffix, .best = xi.best };
        },
        // A capture is transparent — its literal info is exactly its child's.
        .capture => |g| return literalInfo(arena, g.child),
        // Optional / alternation: nothing is guaranteed to appear.
        .star, .quest, .alt => return .unknown,
    }
}

/// True iff every match must begin at the start of a line — the pattern's first
/// consumable step is preceded by `^` on every alternation branch. Lets the
/// scanner seed only at line position 0 (no per-byte unanchored re-seed) and bail
/// the instant the thread list empties. Conservative: only the `^` node anchors,
/// so an un-anchored branch makes the whole alternation un-anchored.
pub fn startsAnchored(node: *Node) bool {
    return switch (node.*) {
        .anchor_start => true,
        .concat => |ab| startsAnchored(ab[0]),
        .alt => |ab| startsAnchored(ab[0]) and startsAnchored(ab[1]),
        .plus => |r| startsAnchored(r.node), // `(^x)+` still starts anchored
        .capture => |g| startsAnchored(g.child), // transparent
        else => false,
    };
}

/// Cap on an alternation cover-set — a huge `a|b|c|…` union would issue one
/// trigram query per branch; past this a full scan is cheaper, so we bail to it.
const max_cover: usize = 32;

/// A set of ≥3-byte literals such that EVERY match contains at least one of them
/// — so the UNION of their trigram-candidate sets is a sound superset (no false
/// negative). Returns null when none is provable (caller full-scans). This is the
/// multi-literal counterpart to `literalInfo.best`: where `best` needs ONE literal
/// mandatory across the whole pattern, this admits alternations — `foo|bar` ⇒
/// {foo, bar} — but only when EVERY branch yields a ≥3 literal (else that branch's
/// matches could carry none of the set, and filtering would wrongly drop them).
pub fn requiredAny(arena: std.mem.Allocator, node: *Node) ParseError!?[]const []const u8 {
    // A single mandatory ≥3 literal is the most selective filter — prefer it.
    const li = try literalInfo(arena, node);
    if (li.best.len >= 3) return try arena.dupe([]const u8, &.{li.best});
    switch (node.*) {
        .alt => |ab| {
            const sa = try requiredAny(arena, ab[0]) orelse return null;
            const sb = try requiredAny(arena, ab[1]) orelse return null;
            if (sa.len + sb.len > max_cover) return null;
            return try std.mem.concat(arena, []const u8, &.{ sa, sb });
        },
        // In a concat both sides are mandatory, so either side's cover set is
        // sound for the whole match — take the first side that yields one.
        .concat => |ab| {
            if (try requiredAny(arena, ab[0])) |sa| return sa;
            return try requiredAny(arena, ab[1]);
        },
        .plus => |r| return try requiredAny(arena, r.node),
        .capture => |g| return try requiredAny(arena, g.child), // transparent
        // multi-byte class, star, quest (match empty), empty, anchors ⇒ no cover.
        else => return null,
    }
}

/// Cap on a pure-literal alternation set — each literal costs one SIMD
/// `contains` pass over the whole body, so past a handful the DFA scan wins.
const max_lits: usize = 8;

/// The EXACT literal this node matches — and nothing else — or null. Stricter
/// than `LitInfo.exact`: zero-width nodes (anchors, `\b`, `.empty`) are REJECTED
/// rather than treated as "", because the caller uses these literals as a
/// match-equivalence (not just containment): `pattern matches line` ⟺ `line
/// contains one of the literals`. An anchor would break that equivalence
/// (`^panic` contains-hits mid-line), so purity must exclude all assertions.
fn pureLit(arena: std.mem.Allocator, node: *Node) ParseError!?[]const u8 {
    switch (node.*) {
        .class => |set| {
            const b = set.only() orelse return null;
            return try arena.dupe(u8, &[_]u8{b});
        },
        .uclass => |ranges| return uclassLiteral(arena, ranges),
        .concat => |ab| {
            const x = (try pureLit(arena, ab[0])) orelse return null;
            const y = (try pureLit(arena, ab[1])) orelse return null;
            return try std.mem.concat(arena, u8, &.{ x, y });
        },
        .capture => |g| return pureLit(arena, g.child), // transparent
        else => return null,
    }
}

/// If the whole pattern is EXACTLY an alternation of pure literals (`panic|0x`,
/// `foo`, `a|b|c`), return them; else null. This is a match-EQUIVALENCE, not a
/// mere containment gate: a line matches ⟺ it contains one of the literals —
/// which lets `-l` answer a whole file with one SIMD `contains` per literal and
/// no regex engine run. Literals carrying `\n` (can't sit inside one line) or
/// NUL (binary semantics) are rejected; so is an empty literal (matches
/// everywhere — the `eol_empty` machinery owns that case).
pub fn pureLiterals(arena: std.mem.Allocator, node: *Node) ParseError!?[]const []const u8 {
    switch (node.*) {
        .alt => |ab| {
            const sa = (try pureLiterals(arena, ab[0])) orelse return null;
            const sb = (try pureLiterals(arena, ab[1])) orelse return null;
            if (sa.len + sb.len > max_lits) return null;
            return try std.mem.concat(arena, []const u8, &.{ sa, sb });
        },
        .capture => |g| return pureLiterals(arena, g.child), // transparent
        else => {
            const lit = (try pureLit(arena, node)) orelse return null;
            if (lit.len == 0 or std.mem.indexOfAny(u8, lit, "\n\x00") != null) return null;
            return try arena.dupe([]const u8, &.{lit});
        },
    }
}

// The class-run/span reductions, the forced-crest calculus, and the
// compiled-NFA reachability visitors are the analysis layer's other soundness
// contracts; they live in same-folder siblings and are re-exported here so
// `analysis.<name>` stays the single public face for every caller.
const runs = @import("runs.zig");
pub const ClassRunShape = runs.ClassRunShape;
pub const classRunShape = runs.classRunShape;
pub const ClassSpanShape = runs.ClassSpanShape;
pub const no_max = runs.no_max;
pub const classSpanShape = runs.classSpanShape;

const swell = @import("swell.zig");
pub const ForcedProfile = swell.Profile;
pub const forcedSwell = swell.forcedSwell;

const reach = @import("reach.zig");
pub const analyzeFirst = reach.analyzeFirst;
pub const reachesMatchEol = reach.reachesMatchEol;
pub const reachesMatchZeroWidth = reach.reachesMatchZeroWidth;

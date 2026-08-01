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
/// pure-literal machinery as an ASCII `class` singleton. Public because the DAG
/// sweep (`../ast/facts.zig`) answers the same question about the same node kind,
/// and two spellings of "is this codepoint class a literal" could disagree.
pub fn uclassLiteral(arena: std.mem.Allocator, ranges: []const [2]u21) ParseError!?[]const u8 {
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
        .empty, .anchor_start, .anchor_end, .anchor_buf_start, .anchor_buf_end, .word => return .zero_width,
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
pub const max_cover: usize = 64;

/// A set of literals such that EVERY match contains at least one of them — so
/// the UNION of their candidate sets is a sound superset (no false negative).
/// Returns null when none is provable (caller full-scans). This is the
/// multi-literal counterpart to `literalInfo.best`: where `best` needs ONE literal
/// mandatory across the whole pattern, this admits alternations — `foo|bar` ⇒
/// {foo, bar}. EVERY branch must still yield one, or that branch's matches could
/// carry none of the set and filtering would wrongly drop them.
///
/// A branch literal may be 1–2 bytes. It used to have to reach 3, because a
/// shorter one produces no trigram and the directory could not answer it — an
/// index-capability limit, never a soundness one, since `best` is mandatory in
/// every match at any length. The sliver tier
/// (`corpus/index/trigrams/sliver.zig`) answers those from the same directory,
/// so `panic|0x` now yields {panic, 0x} instead of nothing at all. Where a
/// branch is genuinely unfilterable the cover is still withheld whole.
pub fn requiredAny(arena: std.mem.Allocator, node: *Node) ParseError!?[]const []const u8 {
    // A single mandatory ≥3 literal is the most selective filter — prefer it.
    const li = try literalInfo(arena, node);
    if (li.best.len >= 3) return try arena.dupe([]const u8, &.{li.best});
    const nested: ?[]const []const u8 = switch (node.*) {
        .alt => |ab| blk: {
            const sa = try requiredAny(arena, ab[0]) orelse break :blk null;
            const sb = try requiredAny(arena, ab[1]) orelse break :blk null;
            if (sa.len + sb.len > max_cover) break :blk null;
            break :blk try std.mem.concat(arena, []const u8, &.{ sa, sb });
        },
        // In a concat both sides are mandatory, so EITHER side's cover is sound
        // for the whole match — so take the more selective of the two.
        .concat => |ab| thinner(try requiredAny(arena, ab[0]), try requiredAny(arena, ab[1])),
        .plus => |r| try requiredAny(arena, r.node),
        .capture => |g| try requiredAny(arena, g.child), // transparent
        // multi-byte class, star, quest (match empty), empty, anchors ⇒ no cover.
        else => null,
    };
    // A cover is only as selective as its weakest branch, so a descent is worth
    // taking only when even that branch out-reads this node's own literal —
    // otherwise `0x` would decay into the `0` its left child witnesses.
    if (nested) |s| if (weakest(s) > li.best.len) return s;
    // The sub-trigram floor: a 1–2 byte literal mandatory in every match of this
    // node is a sound one-element cover, and now a queryable one.
    if (li.best.len > 0) return try arena.dupe([]const u8, &.{li.best});
    return nested;
}

/// Length of a cover's shortest literal — what its selectivity is bounded by.
pub fn weakest(cover: []const []const u8) usize {
    var min: usize = std.math.maxInt(usize);
    for (cover) |lit| min = @min(min, lit.len);
    return if (cover.len == 0) 0 else min;
}

/// The more selective of two sound covers, either of which may be absent. This
/// and `weakest` are the cover calculus itself, not the walker's private
/// arithmetic: `../ast/ast.zig` builds the same cover the other way round (a
/// forward sweep over the interned DAG rather than a recursive descent) and has
/// to reach the identical verdict, so both read the selectivity rule from here.
pub fn thinner(a: ?[]const []const u8, b: ?[]const []const u8) ?[]const []const u8 {
    const sa = a orelse return b;
    const sb = b orelse return sa;
    return if (weakest(sb) > weakest(sa)) sb else sa;
}

/// Cap on a pure-literal alternation set — each literal costs one SIMD
/// `contains` pass over the whole body, so past a handful the DFA scan wins.
/// Exact literal alternations bypass automata entirely. The dispatcher owns the
/// 1 / 2–64 / >64 engine split, so analysis retains the full bounded set.
pub const max_lits: usize = 5000;

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
    // Iterative traversal avoids a 5000-branch left-folded alternation blowing
    // the call stack or repeatedly concatenating pointer slices.
    const stack = try arena.alloc(*Node, max_lits * 2);
    const lits = try arena.alloc([]const u8, max_lits);
    var top: usize = 1;
    var count: usize = 0;
    stack[0] = node;
    while (top > 0) {
        top -= 1;
        const n = stack[top];
        switch (n.*) {
            .alt => |ab| {
                if (top + 2 > stack.len) return null;
                stack[top] = ab[1];
                stack[top + 1] = ab[0];
                top += 2;
            },
            .capture => |g| {
                if (top == stack.len) return null;
                stack[top] = g.child;
                top += 1;
            },
            else => {
                if (count == max_lits) return null;
                const lit = (try pureLit(arena, n)) orelse return null;
                if (lit.len == 0 or std.mem.indexOfAny(u8, lit, "\n\x00") != null) return null;
                lits[count] = lit;
                count += 1;
            },
        }
    }
    return lits[0..count];
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

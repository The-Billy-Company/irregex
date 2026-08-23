//! Sound trigram-prefilter literal derivation for the compiled query.
//!
//! One concern: given a compiled body, which literal(s) may the trigram index
//! soundly AND together to prune candidate files WITHOUT ever dropping a true
//! match? This is index-pruning SOUNDNESS — a filter-correctness question,
//! orthogonal to the match VERIFICATION `query.zig`'s faces do. Every rule here
//! yields a NECESSARY condition ("a match must contain these bytes"), so the
//! index answer is always a sound superset the faces then verify against live
//! bytes.
//!
//!   • Non-caseless — the engine's guaranteed required literal (≥3 bytes,
//!     present in EVERY match), else its per-branch alternation cover
//!     (`foo|bar` ⇒ {foo,bar}). `regexPrefilter` reads a linear `Regex`
//!     directly; `matcherPrefilter` reads either engine through the seam.
//!   • Caseless — no case-folded index exists, so the raw (unfolded) required
//!     literal is either gated whole (`foldClosedWindow`, when its fold is
//!     ASCII-closed) or expanded into a ≤16-variant case OR-set of one window
//!     (`caselessVariants`).
//!
//! When caseless-fixed (`-F -i`), no prefilter is safe at all, so `escapeLiteral`
//! turns the fixed string into regex source and the engine applies the fold —
//! the same escaped form the cold `-F` path and the warm renderer compile.
//!
//! Cold's `exec/cold/engine/{serial,ranked}.zig` (and, for the escape,
//! `session/render.zig` · the composed face's change-radius module ·
//! `batch/patterns.zig`) import these verbatim, so warm and cold cannot drift
//! on which literals are safe to prune by. This is `query.zig`'s private
//! sub-module; it re-exports the surface.

const std = @import("std");
const cover = @import("cover.zig");
const crest = @import("../math/crest.zig");
const simd = @import("../scan/simd.zig");
const regex_mod = @import("../regex/regex.zig");
const Regex = regex_mod.Regex;
const Matcher = regex_mod.Matcher;
// The forced-crest calculus and THE parse both live with the engine on purpose
// (`../regex/analysis/swell.zig`, `../regex/linear/program/lower.zig`): an
// analysis that read the pattern under its own grammar could prune a file that
// matches. `winnow` below is the one place that reads both off a single AST.
const analysis = regex_mod.analysis;
const lower = regex_mod.lower;

/// The sound trigram prefilter for a compiled regex, independent of the
/// caseless/mode guards a specific face layers on top: the engine's guaranteed
/// required literal (present in EVERY match) when it is ≥3 bytes, else its
/// per-branch alternation cover (`re.alts`). Shared verbatim by the compiled
/// query and the cold CLI's `trigramFilter`, so warm and cold cannot drift
/// on which literals are safe to prune by.
pub fn regexPrefilter(re: *const Regex, one: *[1][]const u8) []const []const u8 {
    if (re.required.len >= 3) {
        one[0] = re.required;
        return one[0..1];
    }
    if (re.alts.len > 0) return re.alts;
    // Strictly additive last resort: a 1–2 byte required literal is present in
    // every match just as a longer one is, so pruning by it is equally sound —
    // it was withheld only because the trigram directory could not read it. The
    // sliver tier now can (`corpus/index/trigrams/sliver.zig`), and declines to
    // this same empty answer when it cannot pay. An alternation cover, when
    // there is one, still wins: it is the more selective filter.
    if (re.required.len > 0) {
        one[0] = re.required;
        return one[0..1];
    }
    return re.alts;
}

/// The engine-neutral twin of `regexPrefilter`, over the `Matcher` seam: the
/// guaranteed required literal (≥3 bytes) present in EVERY match, else the
/// per-branch alternation cover. The linear arm's `required`/`alts` are its AST
/// literals; the PCRE2 arm's are the library-derived required literal (`alts`
/// empty). Mirrors cold's NON-caseless `trigramFilter` arm for both engines, so
/// warm and cold prune a `-P` query by the identical, sound literal set.
pub fn matcherPrefilter(m: *const Matcher, one: *[1][]const u8) []const []const u8 {
    const req = m.required();
    if (req.len >= 3) {
        one[0] = req;
        return one[0..1];
    }
    const alts = m.alts();
    if (alts.len > 0) return alts;
    if (req.len > 0) { // sub-trigram required literal — see `regexPrefilter`
        one[0] = req;
        return one[0..1];
    }
    return alts;
}

/// The longest ASCII-fold-closed window of a literal — the soundness rule every
/// caseless gate is built through. It moved down beside `simd.Gate.caseless`,
/// the constructor it guards, so the regex engine can mine its own caseless gate
/// at compile time without importing this tier (`query` sits ABOVE `regex`).
/// Re-exported here because the caseless soundness suite below, cold's
/// `writ/gate.zig`, and `query.zig`'s public surface all name it at this address.
pub const foldClosedWindow = simd.foldClosedWindow;

/// The sound trigram prefilter for a CASELESS query: the OR-set of case
/// variants of one window of the pattern's raw (unfolded) required literal.
/// Every caseless match must contain the window's bytes in SOME case, so
/// "contains any variant" is a necessary condition the index can query —
/// the caseless prefilter gap closed without a case-folded index.
///
/// Soundness bounds the window:
///   • ASCII only — a non-ASCII byte's fold orbit is multi-byte and positional.
///   • Under Unicode fold (rg's `-i` default), a letter whose simple-fold
///     orbit escapes ASCII is inadmissible: `k`/`K` also match KELVIN SIGN
///     (U+212A) and `s`/`S` match LONG S (U+017F), so a `[kK]`-style variant
///     set would under-claim and elide a real match. ASCII fold (`(?-u)`)
///     admits them.
/// A window of `window_len` letters yields ≤2^4 = 16 variants — selective
/// enough for the index, cheap enough to enumerate. Null when no admissible
/// window ≥3 bytes exists (the caller declines, exactly the old behavior).
pub fn caselessVariants(a: std.mem.Allocator, lit: []const u8, unicode: bool) error{OutOfMemory}!?[]const []const u8 {
    const window_len = 4;
    if (lit.len < 3) return null;
    const w = @min(window_len, lit.len);

    // Choose the admissible window with the FEWEST letters (fewest variants);
    // leftmost wins ties.
    var best: ?usize = null;
    var best_letters: usize = window_len + 1;
    var start: usize = 0;
    while (start + w <= lit.len) : (start += 1) {
        var letters: usize = 0;
        const ok = for (lit[start .. start + w]) |b| {
            if (b >= 0x80) break false;
            if (std.ascii.isAlphabetic(b)) {
                if (unicode and (b == 'k' or b == 'K' or b == 's' or b == 'S')) break false;
                letters += 1;
            }
        } else true;
        if (ok and letters < best_letters) {
            best = start;
            best_letters = letters;
        }
    }
    const at = best orelse return null;
    const win = lit[at .. at + w];

    const n = @as(usize, 1) << @intCast(best_letters);
    const out = try a.alloc([]const u8, n);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |v| a.free(v);
        a.free(out);
    }
    for (0..n) |mask| {
        const v = try a.dupe(u8, win);
        var bit: usize = 0;
        for (v) |*b| {
            if (!std.ascii.isAlphabetic(b.*)) continue;
            b.* = if (mask >> @intCast(bit) & 1 != 0) std.ascii.toUpper(b.*) else std.ascii.toLower(b.*);
            bit += 1;
        }
        out[mask] = v;
        made += 1;
    }
    return out;
}

/// Escape a fixed string into regex source, for the caseless `-F -i` path where
/// the trigram prefilter is unsafe (see `foldClosedWindow`) and the regex engine
/// must apply the case fold. `pub` because the warm lines renderer
/// (`exec/session/facet/render.zig`) and the cold `-F` path both build their
/// emission `Matcher` from the SAME escaped form, so they cannot drift.
pub fn escapeLiteral(a: std.mem.Allocator, pat: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pat) |c| {
        if (std.mem.indexOfScalar(u8, ".^$*+?()[]{}|\\", c) != null) try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

/// Everything a pattern forces of a document, read off ONE parse: the
/// conjunctive cover plan an index can be asked, and the crest swell a
/// per-document density vector can be sieved against. Two independent
/// necessary conditions on the same AST — the plan proves a byte substring
/// must occur, the swell proves a character-class mass must occur — so a
/// caller may apply either, both, or neither and still see identical matches.
///
/// Both are `null`/empty when unprovable, and both degrade that way on a parse
/// failure: an unsupported construct may cost pruning, never a match.
pub const Winnow = struct {
    plan: ?[]const cover.Clause = null,
    sieve: crest.Swell = crest.no_sieve,

    /// Whether this winnow can prune anything at all — the caller's cue to skip
    /// the whole apparatus rather than walk a corpus proving nothing. A swell
    /// with one 0⃗ alternative admits every document, so `active` and not
    /// `len` is what decides.
    pub fn idle(self: *const Winnow) bool {
        return self.plan == null and !self.sieve.active();
    }
};

/// Derive both prefilters for `pattern` in a single `lower.parse`.
///
/// The parse is the expensive half (the plan and the swell are each a linear
/// walk over the result), and both cold's `Writ.compile` and warm's
/// `CompiledQuery.compile` need both — so deriving them together is what keeps
/// a second AST off the compile path. `arena` owns the plan's storage and the
/// literals it borrows; the swell is by-value and outlives it.
///
/// `plan_limits` is null when the caller does not want a cover plan (a caseless
/// pattern, whose cover atoms would have to be case-expanded to stay sound).
/// The swell is unconditional: it reads character-class density, which case
/// folding does not change.
pub fn winnow(
    arena: std.mem.Allocator,
    pattern: []const u8,
    opts: lower.Options,
    plan_limits: ?cover.Limits,
) Winnow {
    const ast = lower.parse(arena, pattern, opts) catch return .{};
    const ranked = analysis.forcedRanked(
        arena,
        ast,
        crest.default_budget,
        crest.default_rank,
    ) catch crest.RankedSwell{};
    return .{
        .plan = if (plan_limits) |lim| (cover.plan(arena, ast, lim) catch null) else null,
        .sieve = ranked.projectQ1(),
    };
}

const t = std.testing;

fn freeVariants(vs: []const []const u8) void {
    for (vs) |v| t.allocator.free(v);
    t.allocator.free(vs);
}

test "caselessVariants: full case cross-product of one window" {
    const vs = (try caselessVariants(t.allocator, "abc", false)).?;
    defer freeVariants(vs);
    try t.expectEqual(@as(usize, 8), vs.len); // 3 letters ⇒ 2³
    // Every variant is a case-spelling of "abc"; all distinct.
    for (vs, 0..) |v, i| {
        try t.expect(std.ascii.eqlIgnoreCase("abc", v));
        for (vs[i + 1 ..]) |w| try t.expect(!std.mem.eql(u8, v, w));
    }
}

test "caselessVariants: prefers the window with fewest letters" {
    // "err_1234" — the leftmost letter-free window needs exactly 1 variant.
    const vs = (try caselessVariants(t.allocator, "err_1234", false)).?;
    defer freeVariants(vs);
    try t.expectEqual(@as(usize, 1), vs.len);
    try t.expectEqualStrings("_123", vs[0]);
}

test "caselessVariants: Kelvin/long-s orbits inadmissible under Unicode fold" {
    // Every window of "sks" holds a k/s — whose simple-fold orbits (U+017F,
    // U+212A) escape ASCII — so Unicode fold must decline entirely…
    try t.expect((try caselessVariants(t.allocator, "sks", true)) == null);
    // …while ASCII fold admits them,
    const ascii = (try caselessVariants(t.allocator, "sks", false)).?;
    defer freeVariants(ascii);
    try t.expectEqual(@as(usize, 8), ascii.len);
    // and Unicode fold routes around them when a clean window exists
    // ("kelvin" ⇒ "elvi", skipping the k).
    const uni = (try caselessVariants(t.allocator, "kelvin", true)).?;
    defer freeVariants(uni);
    for (uni) |v| try t.expect(std.ascii.eqlIgnoreCase("elvi", v));
}

test "caselessVariants: non-ASCII and short literals decline" {
    try t.expect((try caselessVariants(t.allocator, "caf\xc3\xa9", true)) == null); // é in every window
    try t.expect((try caselessVariants(t.allocator, "ab", false)) == null); // below trigram floor
}

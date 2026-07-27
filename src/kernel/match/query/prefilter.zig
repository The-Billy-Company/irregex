//! Sound trigram-prefilter literal derivation for the compiled query (ADR-352).
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
//! Cold's `surface/exec/cold/engine/{serial,ranked}.zig` (and, for the escape,
//! `session/render.zig` · `compose/blast.zig` · `batch/patterns.zig`) import
//! these verbatim, so warm and cold cannot drift on which literals are safe to
//! prune by. This is `query.zig`'s private sub-module; it re-exports the surface.

const std = @import("std");
const Regex = @import("../regex/regex.zig").Regex;
const Matcher = @import("../regex/regex.zig").Matcher;

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

/// The longest ASCII-fold-CLOSED window of a literal, or null when none
/// reaches 2 bytes. A byte is fold-closed when its case-fold orbit stays
/// within its two ASCII spellings: non-ASCII bytes decline (multi-byte
/// positional orbits), and under Unicode fold (rg's `-i` default) `k`/`K`
/// (KELVIN SIGN U+212A) and `s`/`S` (LONG S U+017F) decline — the same two
/// escape orbits `caselessVariants` excludes; ASCII fold (`(?-u)`) admits
/// them. A caseless match must contain every segment of the raw literal in
/// some case spelling, so gating on one admissible window stays a sound
/// necessary condition even when the whole literal declines (`walletservice`
/// carries an `s` whose Unicode orbit escapes ASCII — but its `wallet` prefix
/// gates cleanly). Only a window covering the ENTIRE literal can ever prove
/// match equivalence; a partial window is containment-only.
pub fn foldClosedWindow(lit: []const u8, unicode: bool) ?[]const u8 {
    var best: ?[]const u8 = null;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= lit.len) : (i += 1) {
        const closed = i < lit.len and lit[i] < 0x80 and
            !(unicode and (lit[i] == 'k' or lit[i] == 'K' or lit[i] == 's' or lit[i] == 'S'));
        if (!closed) {
            if (i - start >= 2 and (best == null or i - start > best.?.len)) best = lit[start..i];
            start = i + 1;
        }
    }
    return best;
}

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
/// (`surface/exec/session/facet/render.zig`) and the cold `-F` path both build their
/// emission `Matcher` from the SAME escaped form, so they cannot drift.
pub fn escapeLiteral(a: std.mem.Allocator, pat: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pat) |c| {
        if (std.mem.indexOfScalar(u8, ".^$*+?()[]{}|\\", c) != null) try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
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

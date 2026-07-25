//! gist — the engine ladder: every boolean "does this match?" entry point, and
//! the dispatch that picks the cheapest sound machine to answer it. Rungs, in
//! order of cost: a zero-width end-of-line certainty (no scan at all), the SIMD
//! class-run kernel (load bandwidth), the byte-class DFA (one table lookup per
//! byte, whole document in one fused pass), and the Pike VM (`pike/search.zig`)
//! as the capped fallback and proven oracle.
//!
//! Dispatch only — never semantics. Every rung answers identically to the Pike
//! VM; the equality is held by the rg oracle and the differential fuzz, so a
//! rung that cannot decide a haystack (`.unproven`, a Unicode word-boundary
//! quit) falls through instead of guessing. The `*Fused` predicates let callers
//! with their own per-line loops ask *which* machine would answer before paying
//! a line split.

const std = @import("std");
const core = @import("../program/core.zig");
const scratch = @import("../pike/scratch.zig");
const search = @import("../pike/search.zig");

const Regex = core.Regex;
const Sim = scratch.Sim;

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
        if (d.word_ctx) return d.matchWord(line) orelse search.lineMatchPike(re, sim, line);
        return d.match(line);
    }
    return search.lineMatchPike(re, sim, line);
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
        if (lineMatch(re, sim, doc[i..end])) return true;
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
    if (!countRunFused(re)) return null;
    return re.classrun.?.countLines(doc);
}

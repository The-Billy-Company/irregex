//! The ripgrep `-w` word-boundary rule for the compiled query.
//!
//! `-w` is a POST-match rule, NOT `\b(pat)\b`: a match span `[s,e)` counts iff a
//! non-word codepoint (or the line edge) bounds it on BOTH sides. The verdict
//! itself lives with the engines (`regex/syntax/word.zig::wordOk`) — the shared
//! search core cannot import the cold runtime (dependency direction), and both
//! planes re-export that one function rather than restating it.
//!
//! This is `query.zig`'s private `-w` sub-module: only word queries route
//! through it, so the non-word match faces never pay for any of it.

const std = @import("std");
const word_mod = @import("../regex/regex.zig").word;
const Matcher = @import("../regex/regex.zig").Matcher;

/// The `-w` regex scratch pair. The boolean DFA cannot decide `-w` (it has no
/// span), so a word query carries BOTH VMs: the boolean `sim` stays the cheap
/// doc/line pre-gate (word only narrows the match set — a doc/line the plain
/// engine rejects can never hold a word-valid span), and the `span` VM decides
/// word validity per span. Both grains ride the `Matcher` seam, so `-w` works
/// over either engine (linear or `-P` PCRE2).
pub const WordScratch = struct { sim: Matcher.Sim, span: Matcher.SpanSim };

/// ripgrep `-w`, from the engines' own module (`regex/syntax/word.zig`) rather
/// than restated here: cold's emit path re-exports the same symbol, so the warm
/// and cold `-w` verdicts are one function and cannot drift.
pub const wordOk = word_mod.wordOk;

/// Leftmost word-valid occurrence of `needle` in `hay`, over rg's
/// non-overlapping leftmost scan — the literal twin of `nextSpan`'s progress
/// rule (a word-rejected occurrence advances past its own end and the scan
/// continues; adjacent repeats like "aa" in "aaa" never overlap). Null when no
/// occurrence is word-valid. An empty needle is never word-valid (a zero-width
/// span never counts under `-w`).
pub fn firstWordHit(unicode: bool, hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, hay, from, needle)) |i| {
        if (wordOk(unicode, hay, i, i + needle.len)) return i;
        from = i + needle.len;
    }
    return null;
}

/// One line's `-w` verdict for a regex body: the cheap boolean pre-gate first
/// (a line the plain engine rejects can never hold a word-valid span), then the
/// span walk until the first word-valid match.
///
/// A zero-width match counts, exactly as it does in the cold printer: rg selects
/// ". ." under `-w 'x?'` on the strength of an empty match bounded by non-word
/// bytes. Requiring a NON-EMPTY span here made a nullable pattern report almost
/// no lines at all (`-c -w 'a*'` over one source file: 72 lines against rg's
/// 565). Zero-width matches only arise for a nullable pattern, so an ordinary
/// pattern walks this loop exactly as before.
pub fn lineHasWordMatch(unicode: bool, m: *const Matcher, line: []const u8, w: *WordScratch) bool {
    if (!m.lineMatch(&w.sim, line)) return false;
    const nullable = m.nullable();
    var from: usize = 0;
    var last_end: ?usize = null;
    while (from <= line.len) {
        const sp = m.matchSpan(&w.span, line, from) orelse return false;
        const empty = sp.end == sp.start;
        from = if (empty) sp.start + 1 else sp.end;
        // rg's progress rule: an empty match adjacent to the previous match's
        // end is not a separate match, so it cannot carry the line either.
        const adjacent = empty and last_end != null and sp.start == last_end.?;
        if (empty and (!nullable or adjacent)) continue;
        if (wordOk(unicode, line, sp.start, sp.end)) return true;
        last_end = sp.end;
    }
    return false;
}

//! The ripgrep `-w` word-boundary rule for the compiled query (ADR-352).
//!
//! `-w` is a POST-match rule, NOT `\b(pat)\b`: a match span `[s,e)` counts iff a
//! non-word codepoint (or the line edge) bounds it on BOTH sides. The shared
//! search core (`query.zig`) cannot import the cold runtime (dependency
//! direction), so the identical decision cold's
//! `surface/exec/cold/emit/output.zig::wordOk` applies is restated here over the
//! engines' one shared `\b` oracle (`regex/syntax/word.zig`) — both reduce to
//! that oracle, so they cannot drift.
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

/// ripgrep `-w`: a match span `[s,e)` is a word match iff bounded by a non-word
/// CODEPOINT (or the line edge) on BOTH sides. The same 2-term composition of
/// the engines' shared `\b` oracle (`regex/syntax/word.zig`) that cold's
/// `surface/exec/cold/emit/output.zig::wordOk` applies — restated here because the
/// search core cannot import the cold runtime (dependency direction), and both
/// reduce to the one oracle, so they cannot drift.
pub fn wordOk(unicode: bool, hay: []const u8, s: usize, e: usize) bool {
    return !word_mod.wordBefore(unicode, hay, s) and !word_mod.wordAt(unicode, hay, e);
}

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
/// (a line the plain engine rejects can never hold a word-valid span), then
/// cold `nextSpan`'s exact loop until the first word-valid non-empty span.
pub fn lineHasWordMatch(unicode: bool, m: *const Matcher, line: []const u8, w: *WordScratch) bool {
    if (!m.lineMatch(&w.sim, line)) return false;
    var from: usize = 0;
    while (from <= line.len) {
        const sp = m.matchSpan(&w.span, line, from) orelse return false;
        if (sp.end == sp.start) {
            from = sp.start + 1;
            continue;
        }
        from = sp.end;
        if (wordOk(unicode, line, sp.start, sp.end)) return true;
    }
    return false;
}

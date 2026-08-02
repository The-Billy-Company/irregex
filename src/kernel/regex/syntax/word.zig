//! gist — the `\w` word-character test shared by every regex engine arm.
//!
//! `\b` / `\B` / `\<` / `\>` (and `-w`) all reduce to one question: is the
//! codepoint on a given side of a gap position a word character? The boolean
//! Pike VM (`../linear/pike/`) and the slot-carrying capture VM (`captures.zig`) both
//! resolve that per position — and the two engines MUST agree byte-for-byte,
//! or a `-r`/`--json` capture run could disagree with the boolean match that
//! selected the line (a twin-engine parity bug). One definition per helper
//! (styleguide §Boilerplate): this module is the single source both import.

const std = @import("std");
const syn = @import("syntax.zig");
const udec = @import("../unicode/decode.zig");
const utables = @import("../unicode/tables.zig");

/// A "word" byte for ASCII `\b`/`\B` (`(?-u)`): `[0-9A-Za-z_]` — exactly `\w`
/// and rg's `--no-unicode` word class.
pub fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// Is the codepoint STARTING at gap-position `p` a word character? In Unicode
/// mode (rg default) the scalar straddling the gap is decoded forward and tested
/// against the full `\w` set (Alphabetic ∪ M ∪ Nd ∪ Pc ∪ Join_Control); an
/// ill-formed byte or line end is never a word char (rust-regex
/// `is_word_char::fwd`). ASCII/`(?-u)` mode is the single-byte fast path.
pub fn wordAt(unicode: bool, line: []const u8, p: usize) bool {
    if (p >= line.len) return false;
    if (!unicode or line[p] < 0x80) return isWordByte(line[p]);
    const d = udec.decode(line[p..]) orelse return false;
    return utables.isWord(d.cp);
}

/// Is the codepoint ending immediately BEFORE gap-position `p` a word character?
/// Unicode mode decodes the scalar backward (`decodeLast`); ASCII/`(?-u)` mode is
/// the single-byte test. False at BOL / on an ill-formed tail (rust-regex
/// `is_word_char::rev`).
pub fn wordBefore(unicode: bool, line: []const u8, p: usize) bool {
    if (p == 0) return false;
    if (!unicode or line[p - 1] < 0x80) return isWordByte(line[p - 1]);
    const d = udec.decodeLast(line[0..p]) orelse return false;
    return utables.isWord(d.cp);
}

/// Everything a word assertion may ask about gap `p`, read in one pass.
///
/// `wordBefore`/`wordAt` above are the two answers on their own; this also
/// reports whether each side is a whole character, which `\B` and the two
/// halves need and cannot get from a boolean that says "false" for both a comma
/// and half of `é` (see `syntax.mask.holds`). Under `(?-u)` no decode is
/// attempted and both flags stay true, so the ASCII path costs what it always did.
pub fn sides(unicode: bool, line: []const u8, p: usize) syn.Sides {
    var s: syn.Sides = .{ .before = false, .after = false };
    if (p > 0) {
        if (!unicode or line[p - 1] < 0x80) {
            s.before = isWordByte(line[p - 1]);
        } else if (udec.decodeLast(line[0..p])) |d| {
            s.before = utables.isWord(d.cp);
        } else s.left_ok = false;
    }
    if (p < line.len) {
        if (!unicode or line[p] < 0x80) {
            s.after = isWordByte(line[p]);
        } else if (udec.decode(line[p..])) |d| {
            s.after = utables.isWord(d.cp);
        } else s.right_ok = false;
    }
    return s;
}

/// ripgrep `-w`: a match span `[s,e)` is a word match iff a non-word CODEPOINT
/// (or the line edge) bounds it on BOTH sides. Unlike `\b(pat)\b` this does not
/// require the match to contain word chars, so a punctuation match (e.g. `.`
/// matching `.`) is still a valid word match — rg's actual semantics.
///
/// This is NOT `!wordBefore and !wordAt`. rg implements `-w` by wrapping the
/// pattern as `(?:^|\W)(pat)(?:$|\W)`, and `\W` must CONSUME a codepoint where
/// `\b` merely asserts one isn't a word char. The two differ exactly where no
/// codepoint exists to consume — a gap inside a multi-byte scalar, or an
/// ill-formed sequence. `\b` is satisfied there (nothing word-ish is present);
/// `\W` cannot match there at all, so rg rejects. Reading it as `\b` let a
/// zero-width match land between the continuation bytes of `—` and be admitted:
/// `-o -w 'x?'` over "a—b" emitted two phantom rows rg never prints.
///
/// Unicode-aware by default (`中`/`é`/Cyrillic beside a match kill it, exactly
/// as rg); under `--no-unicode` every byte is its own codepoint, so the ASCII
/// class decides and the boundary question cannot arise.
pub fn wordOk(unicode: bool, line: []const u8, s: usize, e: usize) bool {
    return nonWordBefore(unicode, line, s) and nonWordAt(unicode, line, e);
}

/// The `(?:^|\W)` half: line start, or a real non-word codepoint ending at `p`.
fn nonWordBefore(unicode: bool, line: []const u8, p: usize) bool {
    if (p == 0) return true;
    if (!unicode or line[p - 1] < 0x80) return !isWordByte(line[p - 1]);
    const d = udec.decodeLast(line[0..p]) orelse return false;
    return !utables.isWord(d.cp);
}

/// The `(?:$|\W)` half: line end, or a real non-word codepoint starting at `p`.
fn nonWordAt(unicode: bool, line: []const u8, p: usize) bool {
    if (p >= line.len) return true;
    if (!unicode or line[p] < 0x80) return !isWordByte(line[p]);
    const d = udec.decode(line[p..]) orelse return false;
    return !utables.isWord(d.cp);
}

test "-w admits a span the line edge or a non-word codepoint bounds" {
    const t = std.testing;
    // "a  b": the gap between the two spaces is the only word-valid position
    // for a zero-width match; every other gap touches `a` or `b`.
    // Captured from ripgrep 15.2.0: `rg -o -w -n --column 'x?'` ⇒ 1:3:
    const spaced = "a  b";
    try t.expect(wordOk(true, spaced, 2, 2));
    for ([_]usize{ 0, 1, 3, 4 }) |p| try t.expect(!wordOk(true, spaced, p, p));
    // A punctuation match needs no word chars of its own — rg's actual `-w`,
    // which is why this is not `\b(pat)\b`.
    try t.expect(wordOk(true, ". .", 0, 1));
    // Both line edges count as boundaries.
    try t.expect(wordOk(true, "word", 0, 4));
}

test "-w rejects a gap inside a codepoint, where there is no \\W to consume" {
    const t = std.testing;
    // "a—b" — the em dash is E2 80 94, so byte gaps 2 and 3 fall INSIDE it.
    // `\b` is satisfied there (no word char is present either side) but rg
    // wraps `-w` as `(?:^|\W)(pat)(?:$|\W)`, and `\W` cannot match half a
    // scalar. Captured from ripgrep 15.2.0: `rg -o -w 'x?'` over this line
    // prints nothing at all.
    const dashed = "a\xE2\x80\x94b";
    for (0..dashed.len + 1) |p| try t.expect(!wordOk(true, dashed, p, p));
    // The em dash IS a non-word codepoint, so a span bounded by it whole is
    // word-valid — the rejection above is about codepoint boundaries, not
    // about the dash being somehow word-ish.
    try t.expect(wordOk(true, "\xE2\x80\x94x\xE2\x80\x94", 3, 4));
    // `\b` genuinely disagrees at those interior gaps: that is the distinction
    // this rule exists to draw, so pin it rather than let it look incidental.
    try t.expect(!wordBefore(true, dashed, 2) and !wordAt(true, dashed, 2));
}

test "an assertion that can fire on silence will not fire inside a character" {
    const t = std.testing;
    // "a—b" — the em dash is E2 80 94, so byte gaps 2 and 3 fall INSIDE it.
    // Every helper here says "not a word character" on both sides, because
    // half a dash is not a word character; the difference is that at gaps 2
    // and 3 it is not a *character*. Captured from ripgrep 15.2.0:
    // `rg -o -b '\B'` over this line prints nothing at all, while
    // `\b{start-half}` prints 0 and 4 and `\b{end-half}` prints 1 and 5.
    const dashed = "a\xE2\x80\x94b";
    for ([_]usize{ 2, 3 }) |p| {
        const s = sides(true, dashed, p);
        try t.expect(!s.before and !s.after);
        try t.expect(!s.left_ok and !s.right_ok);
        for ([_]syn.Word{ .not_boundary, .start_half, .end_half }) |w| try t.expect(!w.holds(s));
    }
    // The four whole-character gaps are all real boundaries (the dash is not a
    // word character, so each of them separates one from a non-word neighbor),
    // which is why rg prints nothing for `\B` on this line at all.
    for ([_]usize{ 0, 1, 4, 5 }) |p| {
        const s = sides(true, dashed, p);
        try t.expect(s.left_ok and s.right_ok);
        try t.expect(!syn.Word.not_boundary.holds(s));
    }
    try t.expect(syn.Word.start_half.holds(sides(true, dashed, 0)));
    try t.expect(syn.Word.start_half.holds(sides(true, dashed, 4)));
    try t.expect(syn.Word.end_half.holds(sides(true, dashed, 1)));
    try t.expect(syn.Word.end_half.holds(sides(true, dashed, 5)));
    // The guard is Unicode-only: under `(?-u)` the dash is three non-word bytes
    // and its interior gaps are ordinary silence.
    for ([_]usize{ 2, 3 }) |p| {
        const s = sides(false, dashed, p);
        try t.expect(s.left_ok and s.right_ok);
        try t.expect(syn.Word.not_boundary.holds(s));
    }
}

test "invalid UTF-8 splits the sides independently" {
    const t = std.testing;
    // A lone 0xFF is not a character, but `a` after it is. rust-regex guards
    // only the side a mask reads, so `\b{end-half}` (which reads right) is
    // unaffected here while `\b{start-half}` (which reads left) is refused.
    const junk = "\xFFa";
    const s = sides(true, junk, 1);
    try t.expect(!s.left_ok and s.right_ok);
    try t.expect(!syn.Word.start_half.holds(s));
    try t.expect(!syn.Word.end_half.holds(s)); // a word char is ahead, so it fails on the table
    const s2 = sides(true, "\xFF ", 1);
    try t.expect(!s2.left_ok and s2.right_ok);
    try t.expect(syn.Word.end_half.holds(s2)); // reads only the right, which is whole
    try t.expect(!syn.Word.start_half.holds(s2)); // reads the left, which is not
}

test "--no-unicode keeps byte semantics, where every byte is its own codepoint" {
    const t = std.testing;
    const dashed = "a\xE2\x80\x94b";
    // Under `(?-u)` the dash's bytes are three non-word bytes, so the interior
    // gaps ARE valid boundaries — no decode is attempted and none is needed.
    try t.expect(wordOk(false, dashed, 2, 2));
    try t.expect(wordOk(false, dashed, 3, 3));
    // The ASCII class still decides at the edges.
    try t.expect(!wordOk(false, dashed, 1, 1));
    try t.expect(!wordOk(false, "ab", 1, 1));
}

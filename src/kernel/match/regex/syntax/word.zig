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

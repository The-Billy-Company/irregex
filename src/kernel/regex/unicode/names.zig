//! irregex — Unicode character-name lookup, the engine behind `\N{NAME}`.
//!
//! `\N{LATIN SMALL LETTER A}` is the one escape that asks a *question of the
//! Unicode database* rather than doing arithmetic on digits, so it is the one
//! that needs a table. rg declines it outright ("unrecognized escape sequence");
//! `re` answers it via `unicodedata`. This is that answer, at parse time.
//!
//! Three lookups in priority order, and the order is not arbitrary — the stored
//! table is consulted first because it is the only one that can be authoritative
//! about a *specific* character, while the derived rules answer for whole ranges:
//!
//!  1. **The stored table** — 40k explicitly named codepoints plus every
//!     NameAliases spelling, front-coded in blocks of 32 (see
//!     `tools/build_unicode_names.py` for the encoding). A binary search over the
//!     block heads, then one forward scan reconstructing at most 31 names.
//!     Comparison is exact byte equality, so a name that is not in the database
//!     cannot resolve to a neighbour — the failure mode a hash-keyed table could
//!     not exclude.
//!  2. **UAX #44 NR2** — the `PREFIX-XXXX` ideograph ranges (CJK, Tangut), whose
//!     names are the prefix plus the codepoint in hex.
//!  3. **UAX #44 NR1** — Hangul syllables, whose names are composed from jamo
//!     short names and decompose back arithmetically.
//!
//! Rules 2 and 3 cover ~97k codepoints that would otherwise more than triple the
//! table for no information: the name and the codepoint determine each other.
//! Surrogates and private-use codepoints deliberately resolve to nothing, because
//! they have no names — `<Private Use, First>` is a marker, not a name.
//!
//! Matching is ASCII-case-insensitive, which is `re`'s behaviour
//! (`\N{latin small letter a}` resolves there). Whitespace is *not* normalized on
//! either side: `re` rejects `\N{LATIN  SMALL LETTER A}`, and so do we.

const std = @import("std");
const gen = @import("names.gen.zig");

/// The codepoint a Unicode character name denotes, or null if no character has
/// that name. Case-insensitive; a query longer than the longest real name is
/// rejected before any table is touched.
pub fn lookup(query: []const u8) ?u21 {
    if (query.len == 0 or query.len > gen.longest_name) return null;
    var folded: [gen.longest_name]u8 = undefined;
    for (query, 0..) |c, i| folded[i] = std.ascii.toUpper(c);
    const want = folded[0..query.len];

    return stored(want) orelse derived(want) orelse hangul(want);
}

/// Read a block's head name — stored whole — into `buf`.
fn head(block: usize, buf: []u8) []const u8 {
    const at = gen.block_offsets[block];
    const n = gen.blob[at] - gen.len_bias;
    @memcpy(buf[0..n], gen.blob[at + 1 ..][0..n]);
    return buf[0..n];
}

/// The stored table. Byte-sorted order IS name order, so the block heads are
/// binary-searchable; the answer, if any, lies in the last block whose head does
/// not exceed the query.
fn stored(want: []const u8) ?u21 {
    var buf: [gen.longest_name]u8 = undefined;
    var lo: usize = 0;
    var hi: usize = gen.block_offsets.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, head(mid, &buf), want) == .gt) hi = mid else lo = mid + 1;
    }
    if (lo == 0) return null; // sorts before every name in the database
    const block = lo - 1;

    // Walk the block, rebuilding each name from the prefix it shares with the
    // one before it plus its own tail.
    var at: usize = gen.block_offsets[block] + 1;
    var len: usize = gen.blob[gen.block_offsets[block]] - gen.len_bias;
    @memcpy(buf[0..len], gen.blob[at..][0..len]);
    at += len;

    const first = block * gen.block;
    const entries = @min(gen.block, gen.count - first);
    for (0..entries) |i| {
        if (i > 0) {
            const shared: usize = gen.blob[at] - gen.len_bias;
            const tail: usize = gen.blob[at + 1] - gen.len_bias;
            @memcpy(buf[shared..][0..tail], gen.blob[at + 2 ..][0..tail]);
            len = shared + tail;
            at += 2 + tail;
        }
        if (std.mem.eql(u8, buf[0..len], want)) return @intCast(gen.codepoints[first + i]);
    }
    return null;
}

/// UAX #44 NR2: `PREFIX-XXXX`, where XXXX is the codepoint in uppercase hex —
/// at least four digits, and no padding beyond that, so `CJK UNIFIED
/// IDEOGRAPH-04E00` is not a name even though `-4E00` is.
fn derived(want: []const u8) ?u21 {
    for (gen.derived) |range| {
        if (!std.mem.startsWith(u8, want, range.prefix)) continue;
        const hex = want[range.prefix.len..];
        if (hex.len < 4 or (hex.len > 4 and hex[0] == '0')) continue;
        const cp = std.fmt.parseUnsigned(u21, hex, 16) catch continue;
        if (cp >= range.lo and cp <= range.hi) return cp;
    }
    return null;
}

/// UAX #44 NR1: `HANGUL SYLLABLE ` followed by the leading/vowel/trailing jamo
/// short names run together. Decomposition is unique by construction, so trying
/// the candidate jamo that prefix the remainder finds the one answer or none.
/// The empty leading slot is a real jamo (ieung is written as nothing), which is
/// why `HANGUL SYLLABLE A` is a syllable and not a malformed name.
fn hangul(want: []const u8) ?u21 {
    const prefix = "HANGUL SYLLABLE ";
    if (!std.mem.startsWith(u8, want, prefix)) return null;
    const jamo = want[prefix.len..];
    for (gen.jamo_l, 0..) |l, li| {
        if (!std.mem.startsWith(u8, jamo, l)) continue;
        const after_l = jamo[l.len..];
        for (gen.jamo_v, 0..) |v, vi| {
            if (!std.mem.startsWith(u8, after_l, v)) continue;
            const after_v = after_l[v.len..];
            for (gen.jamo_t, 0..) |t, ti| {
                if (!std.mem.eql(u8, after_v, t)) continue;
                return @intCast(gen.hangul_lo + (li * 21 + vi) * 28 + ti);
            }
        }
    }
    return null;
}

test "unicode/names: stored table resolves real names and rejects near-misses" {
    try std.testing.expectEqual(@as(?u21, 'a'), lookup("LATIN SMALL LETTER A"));
    try std.testing.expectEqual(@as(?u21, 0x00E9), lookup("LATIN SMALL LETTER E WITH ACUTE"));
    try std.testing.expectEqual(@as(?u21, 0x03B1), lookup("GREEK SMALL LETTER ALPHA"));
    try std.testing.expectEqual(@as(?u21, 0x1F600), lookup("GRINNING FACE"));
    // Case-insensitive, as `re` is.
    try std.testing.expectEqual(@as(?u21, 'a'), lookup("latin small letter a"));
    try std.testing.expectEqual(@as(?u21, 'a'), lookup("Latin Small Letter A"));
    // A prefix of a real name, and a name with a doubled space, are not names —
    // this is the property a hash-keyed table could not guarantee.
    try std.testing.expectEqual(@as(?u21, null), lookup("LATIN SMALL LETTER"));
    try std.testing.expectEqual(@as(?u21, null), lookup("LATIN  SMALL LETTER A"));
    try std.testing.expectEqual(@as(?u21, null), lookup("NOT A REAL NAME"));
    try std.testing.expectEqual(@as(?u21, null), lookup(""));
    // Sorts before every stored name, so the binary search lands at block 0.
    try std.testing.expectEqual(@as(?u21, null), lookup("!"));
}

test "unicode/names: NameAliases give control characters their only spelling" {
    try std.testing.expectEqual(@as(?u21, 0x0000), lookup("NULL"));
    try std.testing.expectEqual(@as(?u21, 0x000A), lookup("LINE FEED"));
    try std.testing.expectEqual(@as(?u21, 0x000A), lookup("LF")); // abbreviation
    try std.testing.expectEqual(@as(?u21, 0x0007), lookup("ALERT"));
}

test "unicode/names: derived NR2 ideograph ranges" {
    try std.testing.expectEqual(@as(?u21, 0x4E00), lookup("CJK UNIFIED IDEOGRAPH-4E00"));
    try std.testing.expectEqual(@as(?u21, 0x20000), lookup("CJK UNIFIED IDEOGRAPH-20000"));
    try std.testing.expectEqual(@as(?u21, 0x17000), lookup("TANGUT IDEOGRAPH-17000"));
    // In the prefix's family but outside every assigned range.
    try std.testing.expectEqual(@as(?u21, null), lookup("CJK UNIFIED IDEOGRAPH-0041"));
    // Padded past four digits is not the canonical name.
    try std.testing.expectEqual(@as(?u21, null), lookup("CJK UNIFIED IDEOGRAPH-04E00"));
}

test "unicode/names: derived NR1 Hangul syllables" {
    try std.testing.expectEqual(@as(?u21, 0xAC00), lookup("HANGUL SYLLABLE GA"));
    try std.testing.expectEqual(@as(?u21, 0xAC01), lookup("HANGUL SYLLABLE GAG"));
    try std.testing.expectEqual(@as(?u21, 0xD7A3), lookup("HANGUL SYLLABLE HIH"));
    try std.testing.expectEqual(@as(?u21, 0xD4DB), lookup("HANGUL SYLLABLE PWILH"));
    // The empty leading consonant is a real jamo.
    try std.testing.expectEqual(@as(?u21, 0xC544), lookup("HANGUL SYLLABLE A"));
    try std.testing.expectEqual(@as(?u21, null), lookup("HANGUL SYLLABLE QQQ"));
}

test "unicode/names: surrogates and private use have no names" {
    try std.testing.expectEqual(@as(?u21, null), lookup("HIGH SURROGATE-D800"));
    try std.testing.expectEqual(@as(?u21, null), lookup("PRIVATE USE-E000"));
}

test "unicode/names: every stored name round-trips" {
    // The encoding's own proof: walk all 40k entries out of the front-coded blob
    // and look each one back up. A prefix-length bug would surface here as a name
    // that cannot find itself.
    var buf: [gen.longest_name]u8 = undefined;
    for (0..gen.block_offsets.len) |block| {
        var at: usize = gen.block_offsets[block] + 1;
        var len: usize = gen.blob[gen.block_offsets[block]] - gen.len_bias;
        @memcpy(buf[0..len], gen.blob[at..][0..len]);
        at += len;
        const first = block * gen.block;
        const entries = @min(gen.block, gen.count - first);
        for (0..entries) |i| {
            if (i > 0) {
                const shared: usize = gen.blob[at] - gen.len_bias;
                const tail: usize = gen.blob[at + 1] - gen.len_bias;
                @memcpy(buf[shared..][0..tail], gen.blob[at + 2 ..][0..tail]);
                len = shared + tail;
                at += 2 + tail;
            }
            const want: u21 = @intCast(gen.codepoints[first + i]);
            try std.testing.expectEqual(@as(?u21, want), lookup(buf[0..len]));
        }
    }
}

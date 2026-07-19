//! Crest kernel unit tests — deterministic calculus checks with hand-computed
//! expected ĝ, plus the sieve decision and the soundness-by-degradation edges.
//! The randomized corpus-scale soundness proof against the REAL matcher lives
//! in `bench/crest/bench.zig` (fail-closed, `zig build crest`).

const std = @import("std");
const testing = std.testing;
const crest = @import("crest.zig");

const ascii: crest.Opts = .{ .unicode = false };
const uni: crest.Opts = .{ .unicode = true };

fn g(pattern: []const u8, opts: crest.Opts, c: crest.Class) u16 {
    return crest.ghat(pattern, opts)[@intFromEnum(c)];
}

test "crest vector: longest per-class run" {
    const v = crest.crest("ab  12ff  ABCD_ef00");
    try testing.expectEqual(@as(u16, 2), v[@intFromEnum(crest.Class.digit)]); // "12"
    try testing.expectEqual(@as(u16, 4), v[@intFromEnum(crest.Class.hex)]); // "ef00"
    try testing.expectEqual(@as(u16, 4), v[@intFromEnum(crest.Class.upper)]); // "ABCD"
    try testing.expectEqual(@as(u16, 9), v[@intFromEnum(crest.Class.word)]); // "ABCD_ef00"
    try testing.expectEqual(@as(u16, 2), v[@intFromEnum(crest.Class.space)]); // "  "
}

test "forced-crest: class repetition is the whole point" {
    try testing.expectEqual(@as(u16, 8), g("[0-9a-f]{8}", uni, .hex));
    try testing.expectEqual(@as(u16, 8), g("[0-9a-f]{8}", uni, .word)); // hex ⊂ word
    try testing.expectEqual(@as(u16, 6), g("[0-9]{6}", uni, .digit));
    try testing.expectEqual(@as(u16, 4), g("[A-Z]{4}", uni, .upper));
    // \d certifies in ASCII mode only (Alphabet Contract).
    try testing.expectEqual(@as(u16, 3), g("\\d{3}", ascii, .digit));
    try testing.expectEqual(@as(u16, 0), g("\\d{3}", uni, .digit));
}

test "forced-crest: straddle across concatenation" {
    try testing.expectEqual(@as(u16, 3), g("[0-9][0-9][0-9]", uni, .digit));
    try testing.expectEqual(@as(u16, 1), g("[0-9]+", uni, .digit)); // one forced copy
    // anchors are zero-width identity: runs cross them freely.
    try testing.expectEqual(@as(u16, 4), g("^[0-9]{4}$", uni, .digit));
}

test "forced-crest: alternation takes the adversary's cheaper branch" {
    try testing.expectEqual(@as(u16, 2), g("[0-9]{4}|[0-9]{2}", uni, .digit));
    try testing.expectEqual(@as(u16, 0), g("[0-9]{4}|abcd", uni, .digit));
    // ghatMany ≡ multi -e alternation semantics.
    const many = crest.ghatMany(&.{ "[0-9]{4}", "[0-9]{2}" }, uni);
    try testing.expectEqual(@as(u16, 2), many[@intFromEnum(crest.Class.digit)]);
}

test "soundness by degradation: unsupported or caseless ⇒ zero ⇒ no prune" {
    try testing.expectEqual(@as(u16, 0), g("(?=foo)[0-9]{8}", uni, .digit)); // lookahead
    try testing.expectEqual(@as(u16, 0), g("(\\d)\\1{7}", ascii, .digit)); // backreference
    try testing.expectEqual(@as(u16, 0), g("[0-9]*", uni, .digit)); // star forces nothing
    try testing.expectEqual(@as(u16, 0), g("[0-9]{0,8}", uni, .digit));
    try testing.expectEqual(@as(u16, 0), g("\\p{L}{4}", uni, .alpha)); // \p unsupported
    try testing.expectEqual(@as(u16, 0), g("\\x41{4}", uni, .upper)); // \x unsupported
    // caseless: the fold changes byte membership — decline everything.
    try testing.expectEqual(@as(u16, 0), g("[0-9a-f]{8}", .{ .unicode = true, .caseless = true }, .hex));
}

test "escapes carry their real bytes (\\n is newline, not 'n')" {
    // \n{5}: five newlines — a SPACE run of 5, and no word run at all. Getting
    // this wrong (treating \n as the byte 'n') would manufacture false negatives.
    try testing.expectEqual(@as(u16, 5), g("\\n{5}", uni, .space));
    try testing.expectEqual(@as(u16, 0), g("\\n{5}", uni, .word));
    try testing.expectEqual(@as(u16, 2), g("\\t\\t", uni, .space));
    // escaped metachar is itself: \. is the punct byte '.'.
    try testing.expectEqual(@as(u16, 3), g("\\.{3}", uni, .punct));
}

test "unicode mode certifies explicit ASCII classes only" {
    // Explicit ASCII class: codepoint ≡ byte, certifies in both modes.
    try testing.expectEqual(@as(u16, 8), g("[0-9a-f]{8}", uni, .hex));
    // Perl class inside [...] under unicode: population uncertifiable.
    try testing.expectEqual(@as(u16, 0), g("[\\d]{6}", uni, .digit));
    try testing.expectEqual(@as(u16, 6), g("[\\d]{6}", ascii, .digit));
    // Negated class accepts multi-byte codepoints — never certifies ASCII.
    try testing.expectEqual(@as(u16, 0), g("[^x]{9}", uni, .word));
}

test "tightness gap is under-prune (sound, not tight)" {
    // [0-9](?:)[0-9] truly forces 2; the empty group breaks the straddle and
    // the calculus reports 1. Under-pruning is sound — never a false negative.
    try testing.expectEqual(@as(u16, 1), g("[0-9](?:)[0-9]", uni, .digit));
}

test "sieve decision + saturation monotonicity" {
    const gv = crest.ghat("[0-9a-f]{8}", uni);
    try testing.expect(crest.active(gv));
    try testing.expect(crest.pruned(crest.crest("no hex run here: zz zz"), gv));
    try testing.expect(!crest.pruned(crest.crest("id=0123abcdef more"), gv));
    try testing.expect(!crest.active(crest.ghat("\\w+", uni)));
    // saturation: a huge forced count clamps but stays comparable.
    const big = crest.ghat("[0-9]{4000}", uni);
    try testing.expect(big[@intFromEnum(crest.Class.digit)] == 4000);
}

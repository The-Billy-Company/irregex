//! gist — minimal UTF-8 codepoint decode for the Unicode word-boundary engine.
//! `\b`/`\B`/`\<`/`\>` and `-w` resolve on the word-ness of the *codepoints*
//! straddling a gap, so the Pike VM must decode the scalar value immediately
//! after a position (`decode`) and immediately before it (`decodeLast`). Both
//! fail closed: on empty input or ill-formed UTF-8 they return null, and the
//! caller treats "no decodable codepoint" as a non-word boundary — exactly
//! rust-regex's `is_word_char::{fwd,rev}` contract (an invalid byte is never a
//! word character).

const std = @import("std");

pub const Decoded = struct { cp: u21, len: u3 };

/// Decode the first codepoint of `bytes`; null on empty or ill-formed UTF-8.
pub fn decode(bytes: []const u8) ?Decoded {
    if (bytes.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (bytes.len < len) return null;
    const cp = std.unicode.utf8Decode(bytes[0..len]) catch return null;
    return .{ .cp = cp, .len = len };
}

/// Decode the codepoint whose encoding *ends* at `bytes.len`; null on empty or
/// ill-formed UTF-8. Walks back over up to three continuation bytes to find the
/// lead byte, then requires the decode to consume exactly to the end (so a
/// truncated or overlong tail is rejected rather than silently accepted).
pub fn decodeLast(bytes: []const u8) ?Decoded {
    if (bytes.len == 0) return null;
    var i: usize = bytes.len - 1;
    var back: usize = 0;
    // A continuation byte is 0b10xxxxxx; a lead/ASCII byte is anything else.
    while (i > 0 and back < 3 and (bytes[i] & 0xC0) == 0x80) : (back += 1) i -= 1;
    const d = decode(bytes[i..]) orelse return null;
    if (i + d.len != bytes.len) return null; // trailing bytes weren't one codepoint
    return d;
}

// ─────────────────────────────── tests ───────────────────────────────

const testing = std.testing;

test "decode forward: ascii, multibyte, invalid" {
    try testing.expectEqual(@as(u21, 'a'), decode("abc").?.cp);
    try testing.expectEqual(@as(u3, 1), decode("abc").?.len);
    const e = decode("\u{00E9}x").?; // é = C3 A9
    try testing.expectEqual(@as(u21, 0xE9), e.cp);
    try testing.expectEqual(@as(u3, 2), e.len);
    const emoji = decode("\u{1F600}").?; // 4 bytes
    try testing.expectEqual(@as(u21, 0x1F600), emoji.cp);
    try testing.expectEqual(@as(u3, 4), emoji.len);
    try testing.expect(decode("") == null);
    try testing.expect(decode(&[_]u8{0x80}) == null); // lone continuation
    try testing.expect(decode(&[_]u8{ 0xC3, 0x28 }) == null); // bad continuation
}

test "decodeLast: ends-at boundary, ascii, multibyte, invalid tail" {
    try testing.expectEqual(@as(u21, 'c'), decodeLast("abc").?.cp);
    const e = decodeLast("x\u{00E9}").?;
    try testing.expectEqual(@as(u21, 0xE9), e.cp);
    try testing.expectEqual(@as(u3, 2), e.len);
    const emoji = decodeLast("a\u{1F600}").?;
    try testing.expectEqual(@as(u21, 0x1F600), emoji.cp);
    try testing.expect(decodeLast("") == null);
    // A truncated multibyte tail (lead byte with a missing continuation) has no
    // codepoint ending exactly at the end → null.
    try testing.expect(decodeLast(&[_]u8{ 'a', 0xC3 }) == null);
    // A lone continuation byte after ASCII: walk-back finds 'a' at i, but 'a'
    // decodes as length 1 which doesn't reach the end → null.
    try testing.expect(decodeLast(&[_]u8{ 'a', 0x80 }) == null);
}

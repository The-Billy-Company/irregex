//! gist — unsigned LEB128 varint codec (csearch's own posting-list encoding:
//! see google/codesearch `index/write.go` `WriteVarint` / `read.go` `uvarint`).
//!
//! The compact trigram index (`trigram.zig`) delta-encodes each posting list's
//! ascending doc ids, and most deltas are small (a common trigram's docs sit
//! close together relative to the corpus), so 7-bits-per-byte varints shrink
//! the 4-byte-per-posting flat encoding by 3-8x — the lever that closes most of
//! gist's index-size gap vs csearch's 28 MiB (README "COLD one-shot literal").

const std = @import("std");

/// Worst-case bytes to encode any `u32` (⌈32/7⌉).
pub const max_len: usize = 5;

/// Bytes needed to encode `v` (7 continuation bits/byte, MSB = "more follows").
pub fn size(v: u64) usize {
    var n: usize = 1;
    var x = v >> 7;
    while (x != 0) : (x >>= 7) n += 1;
    return n;
}

/// Encode `v` into `buf` (>= `size(v)` long); returns bytes written.
pub fn encode(buf: []u8, v: u64) usize {
    var x = v;
    var i: usize = 0;
    while (x >= 0x80) : (i += 1) {
        buf[i] = @truncate((x & 0x7f) | 0x80);
        x >>= 7;
    }
    buf[i] = @truncate(x);
    return i + 1;
}

pub const Decoded = struct { value: u64, len: usize };

/// Decode one varint starting at `buf[0]`. The compact index's directory
/// carries an exact per-group count, so the caller always knows how many
/// varints remain — this never needs a terminator or a length bound beyond
/// what the caller already has (`buf` must have >= 1 valid byte).
pub fn decode(buf: []const u8) Decoded {
    var result: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (true) {
        const b = buf[i];
        result |= @as(u64, b & 0x7f) << shift;
        i += 1;
        if (b & 0x80 == 0) break;
        shift += 7;
    }
    return .{ .value = result, .len = i };
}

pub const DecodeError = error{
    /// Ran out of bytes (or `max_bytes`) with the continuation bit still set.
    Truncated,
    /// Encoding needs more than `max_len` (5) bytes — cannot be a canonical u32.
    TooLong,
    /// A multi-byte encoding terminating in `0x00` (high group all-zero); its
    /// value fits in fewer bytes, so the encoding is non-minimal.
    NonCanonical,
    /// The decoded value exceeds `maxInt(u32)` (a doc id / posting must fit u32).
    Overflow,
};

pub const DecodedBounded = struct { value: u32, len: usize };

/// The UNTRUSTED-input decoder: `decode` above trusts a well-formed body (it has
/// no terminator or length bound), which is right on the hot query path but wrong
/// for the loader, where a corrupt/hostile blob must be rejected — not walked out
/// of bounds, not silently accepted noncanonical. This reads at most
/// `min(max_bytes, buf.len)` bytes and rejects truncated, > `max_len`,
/// noncanonical (trailing `0x00` group), and `> maxInt(u32)` encodings. Used by
/// `trigram.zig`'s `validateStructure` to prove every posting-body varint is safe
/// to hand to the fast `decode` afterwards.
pub fn decodeBoundedCanonical(buf: []const u8, max_bytes: usize) DecodeError!DecodedBounded {
    const limit = @min(max_bytes, buf.len);
    var result: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (true) {
        if (i >= limit) return DecodeError.Truncated;
        const b = buf[i];
        result |= @as(u64, b & 0x7f) << shift;
        i += 1;
        if (b & 0x80 == 0) {
            if (i > 1 and b == 0) return DecodeError.NonCanonical;
            break;
        }
        if (i >= max_len) return DecodeError.TooLong;
        shift += 7;
    }
    if (result > std.math.maxInt(u32)) return DecodeError.Overflow;
    return .{ .value = @intCast(result), .len = i };
}

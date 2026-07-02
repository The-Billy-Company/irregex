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

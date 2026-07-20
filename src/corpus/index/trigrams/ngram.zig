//! gist — n-gram extraction strategy (which grams to emit).
//!
//! Isolated from the index build/query in `trigram.zig` so the SoTA sparse-n-gram
//! variant (ADR-pending) drops in HERE without touching either. Pure,
//! allocation-free primitives over caller-owned buffers — `extractSortedUnique`
//! is the cross-language parity oracle the C-ABI `irregex_trigram_count` calls into.

const std = @import("std");

/// A trigram packed big-endian into the low 24 bits of a u32.
pub const Trigram = u32;

inline fn key(a: u8, b: u8, c: u8) Trigram {
    return (@as(Trigram, a) << 16) | (@as(Trigram, b) << 8) | @as(Trigram, c);
}

/// In-place dedup of the already-sorted prefix `buf[0..n]`; returns distinct count.
pub inline fn dedupSorted(comptime T: type, buf: []T, n: usize) usize {
    var w: usize = 0;
    for (buf[0..n]) |v| if (w == 0 or buf[w - 1] != v) {
        buf[w] = v;
        w += 1;
    };
    return w;
}

/// Overlapping trigrams of `text`, sorted ascending and deduplicated, into
/// `buf` (≥ `text.len` long). Returns the distinct count; `text.len < 3` ⇒ 0.
pub fn extractSortedUnique(text: []const u8, buf: []Trigram) usize {
    if (text.len < 3) return 0;
    const n = text.len - 2; // overlapping trigram count
    for (0..n) |i| buf[i] = key(text[i], text[i + 1], text[i + 2]);
    std.mem.sort(Trigram, buf[0..n], {}, comptime std.sort.asc(Trigram));
    return dedupSorted(Trigram, buf, n);
}

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

/// The trigram of three adjacent bytes — the packing every extractor here
/// shares, exposed so a query planner can name ONE trigram (to look up its
/// posting cardinality) without walking a scratch buffer.
pub inline fn pack(g: [3]u8) Trigram {
    return key(g[0], g[1], g[2]);
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

/// One presence bit per possible trigram (2^24 bits = 2 MiB of u64 words) —
/// the scratch `extractUniqueUnordered` dedups against.
pub const bitmap_words = (1 << 24) / 64;

/// Distinct trigrams of `text` in FIRST-APPEARANCE order (unsorted), into
/// `buf` (≥ `text.len` long). O(len) — the index build's replacement for
/// `extractSortedUnique`'s per-doc O(len·log len) sort: both build paths
/// order postings globally afterwards (serial: one whole-corpus sort;
/// parallel: a stable 24-bit counting sort), so per-doc order is dead work.
/// `bitmap` must be `bitmap_words` long and ALL-ZERO on entry; it is restored
/// to all-zero before return by clearing exactly the bits this doc set —
/// O(distinct), no per-doc memset of the 2 MiB. Returns the distinct count.
pub fn extractUniqueUnordered(text: []const u8, bitmap: []u64, buf: []Trigram) usize {
    if (text.len < 3) return 0;
    var w: usize = 0;
    for (0..text.len - 2) |i| {
        const t = key(text[i], text[i + 1], text[i + 2]);
        const word = &bitmap[t >> 6];
        const bit = @as(u64, 1) << @intCast(t & 63);
        if (word.* & bit == 0) {
            word.* |= bit;
            buf[w] = t;
            w += 1;
        }
    }
    for (buf[0..w]) |t| bitmap[t >> 6] &= ~(@as(u64, 1) << @intCast(t & 63));
    return w;
}

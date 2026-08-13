//! irregex n-gram extraction tests — split from `ngram.zig` to keep the strategy
//! file under the shape cap. Pulled into `zig build test` via `root.zig`'s test
//! block. Covers `extractSortedUnique`'s distinct/ascending contract and the
//! sub-3-byte boundary (the floor below which the trigram filter can't apply).

const std = @import("std");
const ngram = @import("ngram.zig");
const Trigram = ngram.Trigram;

test "extract: distinct overlapping trigrams of 'banana'" {
    var buf: [8]Trigram = undefined;
    const n = ngram.extractSortedUnique("banana", &buf);
    // ban, ana, nan, ana → {ban, ana, nan} = 3 distinct
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "extract: under 3 bytes yields nothing" {
    var buf: [4]Trigram = undefined;
    try std.testing.expectEqual(@as(usize, 0), ngram.extractSortedUnique("ab", &buf));
}

test "extractUniqueUnordered: same distinct set as extractSortedUnique, bitmap restored, first-appearance order" {
    const gpa = std.testing.allocator;
    const bitmap = try gpa.alloc(u64, ngram.bitmap_words);
    defer gpa.free(bitmap);
    @memset(bitmap, 0);

    // First-appearance order on the canonical example: ban, ana, nan.
    var small: [8]Trigram = undefined;
    try std.testing.expectEqual(@as(usize, 3), ngram.extractUniqueUnordered("banana", bitmap, &small));
    try std.testing.expect(small[0] > small[1]); // 'ban' > 'ana' numerically — proves unordered
    try std.testing.expectEqual(@as(usize, 0), ngram.extractUniqueUnordered("ab", bitmap, &small));

    // Randomized parity vs the sorted oracle over adversarial alphabets
    // (tiny = heavy duplication, full-byte = wide fanout), plus the
    // bitmap-restored invariant BETWEEN docs — a leaked bit would silently
    // drop that trigram from every later doc sharing the scratch.
    var prng = std.Random.DefaultPrng.init(0xC0D1C11);
    const rand = prng.random();
    var text: [512]u8 = undefined;
    var a: [512]Trigram = undefined;
    var b: [512]Trigram = undefined;
    for (0..300) |round| {
        const len = rand.intRangeAtMost(usize, 0, text.len);
        const span: u8 = if (round % 2 == 0) 4 else 255;
        for (text[0..len]) |*ch| ch.* = rand.uintAtMost(u8, span);
        const na = ngram.extractSortedUnique(text[0..len], &a);
        const nb = ngram.extractUniqueUnordered(text[0..len], bitmap, &b);
        std.mem.sort(Trigram, b[0..nb], {}, comptime std.sort.asc(Trigram));
        try std.testing.expectEqualSlices(Trigram, a[0..na], b[0..nb]);
    }
    for (bitmap) |w| try std.testing.expectEqual(@as(u64, 0), w);
}

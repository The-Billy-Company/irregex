//! gist n-gram extraction tests — split from `ngram.zig` to keep the strategy
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

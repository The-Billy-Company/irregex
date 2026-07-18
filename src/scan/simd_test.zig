//! gist bench SIMD `contains` test — split from `simd.zig` so the kernel file
//! holds only the hot routine. Pulled into `zig build test` via `bench.zig`'s
//! test block. A differential check that the SIMD substring-presence scan is
//! byte-exact with `std.mem.indexOf` across the edge cases (empty needle/hay,
//! 1-byte, tail-only matches, overlong needle) plus a randomized fuzz over a
//! tiny-alphabet buffer (⇒ many hits, exercising the survivor-verify path).

const std = @import("std");
const simd = @import("simd.zig");
const verify = @import("verify.zig");
const contains = simd.contains;

test "simd contains ≡ std.mem.indexOf" {
    const cases = [_]struct { hay: []const u8, ndl: []const u8 }{
        .{ .hay = "", .ndl = "x" },
        .{ .hay = "abc", .ndl = "" },
        .{ .hay = "a", .ndl = "a" },
        .{ .hay = "the quick brown fox", .ndl = "x" },
        .{ .hay = "})}{)(", .ndl = "})" },
        .{ .hay = "func foo() { return ctx }", .ndl = "ctx" },
        .{ .hay = "func foo() { return ctx }", .ndl = "func" },
        .{ .hay = "no match here at all", .ndl = "zzzz" },
        .{ .hay = "aXbXcXdXeXfXgXhXiXjXkXlXmXnXoXpXqXrXsXtX", .ndl = "tX" },
        .{ .hay = "edge at the very end>>", .ndl = ">>" },
        .{ .hay = "needle longer than the haystack here", .ndl = "this needle is far too long to ever fit" },
    };
    for (cases) |c| {
        const want = std.mem.indexOf(u8, c.hay, c.ndl) != null;
        try std.testing.expectEqual(want, contains(c.hay, c.ndl));
    }
    // Randomized differential fuzz over a noisy buffer.
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    var buf: [4096]u8 = undefined;
    for (&buf) |*b| b.* = 'a' + rng.uintLessThan(u8, 4); // tiny alphabet ⇒ many hits
    var ndl: [6]u8 = undefined;
    var t: usize = 0;
    while (t < 5000) : (t += 1) {
        const nlen = 1 + rng.uintLessThan(usize, 6);
        for (ndl[0..nlen]) |*b| b.* = 'a' + rng.uintLessThan(u8, 4);
        const hlen = rng.uintLessThan(usize, buf.len);
        const want = std.mem.indexOf(u8, buf[0..hlen], ndl[0..nlen]) != null;
        try std.testing.expectEqual(want, contains(buf[0..hlen], ndl[0..nlen]));
    }
}

test "containsWide ≡ std.mem.indexOf across the parallel threshold (seam adversarial)" {
    const gpa = std.testing.allocator;
    // Big enough to actually fan out (≥ wide_threshold ⇒ ≥ 2 shards when the
    // machine has ≥ 2 cores), small enough to stay a fast test.
    const len = verify.wide_threshold * 3;
    const hay = try gpa.alloc(u8, len);
    defer gpa.free(hay);
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rng = prng.random();
    for (hay) |*b| b.* = 'a' + rng.uintLessThan(u8, 4);

    const needle = "xqzk_needle"; // alphabet-disjoint ⇒ absent until spliced
    try std.testing.expect(!verify.containsWide(gpa, hay, needle));

    // Splice the needle at every adversarial seam the sharding geometry has:
    // buffer start/end, slab multiples ±1 (the intra-shard slab loop), and
    // chunk-boundary straddles for every plausible thread count (2..16 —
    // whatever `getCpuCount` says at runtime is one of these). Each position
    // must flip the answer to true, then restore to noise and re-verify false.
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(gpa);
    try positions.appendSlice(gpa, &.{ 0, len - needle.len, (1 << 20) - needle.len / 2, (1 << 20) * 7 - 1 });
    var nthr: usize = 2;
    while (nthr <= 16) : (nthr += 1) {
        const chunk = len / nthr;
        for (1..nthr) |k| {
            const seam = k * chunk;
            if (seam >= needle.len / 2 and seam + needle.len / 2 + needle.len <= len)
                try positions.append(gpa, seam - needle.len / 2); // straddles the seam
        }
    }
    for (positions.items) |at| {
        var saved: [needle.len]u8 = undefined;
        @memcpy(&saved, hay[at .. at + needle.len]);
        @memcpy(hay[at .. at + needle.len], needle);
        const want = std.mem.indexOf(u8, hay, needle) != null;
        try std.testing.expect(want); // sanity: the splice really is present
        try std.testing.expectEqual(want, verify.containsWide(gpa, hay, needle));
        @memcpy(hay[at .. at + needle.len], &saved);
    }
    try std.testing.expect(!verify.containsWide(gpa, hay, needle));

    // Any-of shape over the same buffer: one absent + one spliced needle.
    @memcpy(hay[len / 2 .. len / 2 + needle.len], needle);
    try std.testing.expect(verify.containsAnyWide(gpa, hay, &.{ "zzqq_absent", needle }));
    try std.testing.expect(!verify.containsAnyWide(gpa, hay, &.{ "zzqq_absent", "yyww_absent" }));
}

test "simd containsAny ≡ any-of std.mem.indexOf (fused kernel differential)" {
    const any = simd.containsAny;
    // Edge shapes: empty set, singleton, an empty needle (matches everywhere),
    // a 1-byte needle (fused-ineligible fallback), tail-only hits, no hits.
    try std.testing.expect(!any("panic at the disco", &.{}));
    try std.testing.expect(any("panic at the disco", &.{"panic"}));
    try std.testing.expect(any("whatever", &.{ "zz", "" }));
    try std.testing.expect(any("0x1234", &.{ "panic", "0x" }));
    try std.testing.expect(any("deadbeef p", &.{ "panic", "p" })); // 1-byte fallback
    try std.testing.expect(!any("deadbeef", &.{ "panic", "0x" }));
    try std.testing.expect(any("ends with 0x", &.{ "panic", "0x" })); // tail hit
    // Randomized differential fuzz: 2–8 needles of 2–6 bytes over a
    // tiny-alphabet buffer (⇒ dense fingerprint survivors on the fused path).
    var prng = std.Random.DefaultPrng.init(0xDECAF);
    const rng = prng.random();
    var buf: [4096]u8 = undefined;
    for (&buf) |*b| b.* = 'a' + rng.uintLessThan(u8, 4);
    var store: [8][6]u8 = undefined;
    var set: [8][]const u8 = undefined;
    var t: usize = 0;
    while (t < 3000) : (t += 1) {
        const nn = 2 + rng.uintLessThan(usize, 7);
        for (0..nn) |k| {
            const nlen = 2 + rng.uintLessThan(usize, 5);
            for (store[k][0..nlen]) |*b| b.* = 'a' + rng.uintLessThan(u8, 4);
            set[k] = store[k][0..nlen];
        }
        const hlen = rng.uintLessThan(usize, buf.len);
        var want = false;
        for (set[0..nn]) |n| want = want or std.mem.indexOf(u8, buf[0..hlen], n) != null;
        try std.testing.expectEqual(want, any(buf[0..hlen], set[0..nn]));
    }
}

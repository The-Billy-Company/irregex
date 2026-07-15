//! gist bench SIMD `contains` test — split from `simd.zig` so the kernel file
//! holds only the hot routine. Pulled into `zig build test` via `bench.zig`'s
//! test block. A differential check that the SIMD substring-presence scan is
//! byte-exact with `std.mem.indexOf` across the edge cases (empty needle/hay,
//! 1-byte, tail-only matches, overlong needle) plus a randomized fuzz over a
//! tiny-alphabet buffer (⇒ many hits, exercising the survivor-verify path).

const std = @import("std");
const simd = @import("simd.zig");
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

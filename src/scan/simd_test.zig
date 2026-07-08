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
        const want = std.mem.find(u8, c.hay, c.ndl) != null;
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
        const want = std.mem.find(u8, buf[0..hlen], ndl[0..nlen]) != null;
        try std.testing.expectEqual(want, contains(buf[0..hlen], ndl[0..nlen]));
    }
}

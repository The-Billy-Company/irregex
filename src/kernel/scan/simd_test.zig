//! irregex bench SIMD `contains` test — split from `simd.zig` so the kernel file
//! holds only the hot routine. Pulled into `zig build test` via `bench.zig`'s
//! test block. A differential check that the SIMD substring-presence scan is
//! byte-exact with `std.mem.indexOf` across the edge cases (empty needle/hay,
//! 1-byte, tail-only matches, overlong needle) plus a randomized fuzz over a
//! tiny-alphabet buffer (⇒ many hits, exercising the survivor-verify path).

const std = @import("std");
const simd = @import("simd.zig");
const verify = @import("verify.zig");
const teddy = @import("teddy.zig");
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

/// Scalar reference for the caseless kernel: a sliding `eqlIgnoreCase` scan.
fn scalarCaseless(hay: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0) return true;
    if (needle_lower.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle_lower.len <= hay.len) : (i += 1)
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle_lower.len], needle_lower)) return true;
    return false;
}

test "simd containsCaseless ≡ sliding eqlIgnoreCase" {
    const cases = [_]struct { hay: []const u8, ndl: []const u8 }{
        .{ .hay = "", .ndl = "x" },
        .{ .hay = "abc", .ndl = "" },
        .{ .hay = "A", .ndl = "a" },
        .{ .hay = "The Quick Brown Fox", .ndl = "quick" },
        .{ .hay = "ACMEPROVIDER", .ndl = "acmeprovider" },
        .{ .hay = "AcMePrOvIdEr in the middle", .ndl = "acmeprovider" },
        .{ .hay = "no match here at all", .ndl = "zzzz" },
        .{ .hay = "edge at the very END>>", .ndl = "end>>" },
        .{ .hay = "punct_1234 unchanged", .ndl = "_1234" },
        .{ .hay = "needle longer than the haystack", .ndl = "this needle is far too long to ever fit" },
    };
    for (cases) |c| try std.testing.expectEqual(scalarCaseless(c.hay, c.ndl), simd.containsCaseless(c.hay, c.ndl));

    // Randomized differential fuzz over a mixed-case tiny alphabet (many
    // survivor verifies, both case spellings of the anchor bytes).
    var prng = std.Random.DefaultPrng.init(0xCA5E1E55);
    const rng = prng.random();
    var buf: [4096]u8 = undefined;
    for (&buf) |*b| {
        const c = 'a' + rng.uintLessThan(u8, 3);
        b.* = if (rng.boolean()) std.ascii.toUpper(c) else c;
    }
    var ndl: [6]u8 = undefined;
    var t: usize = 0;
    while (t < 5000) : (t += 1) {
        const nlen = 1 + rng.uintLessThan(usize, 6);
        for (ndl[0..nlen]) |*b| b.* = 'a' + rng.uintLessThan(u8, 3); // pre-lowered
        const hlen = rng.uintLessThan(usize, buf.len);
        const want = scalarCaseless(buf[0..hlen], ndl[0..nlen]);
        try std.testing.expectEqual(want, simd.containsCaseless(buf[0..hlen], ndl[0..nlen]));
    }
}

test "Gate dispatches the caseless kernel; gateWide agrees across the wide threshold" {
    const gpa = std.testing.allocator;
    const cs = simd.Gate.of("Needle");
    const ci = simd.Gate.caseless("needle", false);
    try std.testing.expect(cs.in("a Needle here"));
    try std.testing.expect(!cs.in("a NEEDLE here"));
    try std.testing.expect(ci.in("a NEEDLE here"));
    try std.testing.expect(!ci.in("a nee dle here"));

    // Wide path: the caseless needle only appears (uppercased) near the tail,
    // past several shard seams.
    const hay = try gpa.alloc(u8, verify.wide_threshold * 2 + 64);
    defer gpa.free(hay);
    @memset(hay, 'x');
    std.mem.copyForwards(u8, hay[hay.len - 40 ..], "NEEDLE");
    try std.testing.expect(verify.gateWide(gpa, hay, ci));
    try std.testing.expect(!verify.gateWide(gpa, hay, cs));
    try std.testing.expect(!verify.gateWide(gpa, hay, simd.Gate.caseless("absent", false)));
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

test "simd indexOfAnyPos ≡ leftmost of std.mem.indexOfPos (fused kernel differential)" {
    const at = simd.indexOfAnyPos;
    // Edge shapes: empty set, singleton, tail hit, no hit, resume `from` past a hit.
    try std.testing.expectEqual(@as(?usize, null), at("panic at the disco", 0, &.{}));
    try std.testing.expectEqual(@as(?usize, 0), at("panic", 0, &.{"panic"}));
    try std.testing.expectEqual(@as(?usize, 3), at("aa 0x1234", 0, &.{ "panic", "0x" }));
    try std.testing.expectEqual(@as(?usize, 5), at("aaaa 0x", 0, &.{ "0x", "zz" })); // tail
    try std.testing.expectEqual(@as(?usize, null), at("deadbeef", 0, &.{ "panic", "0x" }));
    try std.testing.expectEqual(@as(?usize, 6), at("0x aa 0x", 3, &.{"0x"})); // from-skip
    // Randomized differential fuzz: leftmost hit over a tiny alphabet (⇒ dense
    // fused survivors), from a random resume offset, vs the std reference min.
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
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
        const from = rng.uintLessThan(usize, hlen + 1);
        var want: ?usize = null;
        for (set[0..nn]) |n| if (std.mem.indexOfPos(u8, buf[0..hlen], from, n)) |p| {
            if (want == null or p < want.?) want = p;
        };
        try std.testing.expectEqual(want, at(buf[0..hlen], from, set[0..nn]));
    }
}

test "teddy ≡ leftmost of std.mem.indexOfPos (2-load nibble-bucket prefilter)" {
    // Edge shapes: eligibility floor, tail hit, no hit, resume `from` past a hit.
    try std.testing.expect(teddy.Teddy.init(&.{"x"}) == null); // <2 needles
    try std.testing.expect(teddy.Teddy.init(&.{ "ab", "c" }) == null); // a 1-byte needle
    // >max_buckets (64): the slim Teddy tops out at eight 8-bucket groups.
    const pairs = comptime blk: {
        var p: [65][2]u8 = undefined;
        for (&p, 0..) |*n, i| n.* = .{ 'a' + @as(u8, @intCast(i / 16)), 'a' + @as(u8, @intCast(i % 16)) };
        break :blk p;
    };
    var too_many: [65][]const u8 = undefined;
    for (&too_many, 0..) |*n, i| n.* = &pairs[i];
    try std.testing.expect(teddy.Teddy.init(&too_many) == null);
    {
        const td = teddy.Teddy.init(&.{ "panic", "0x" }).?;
        try std.testing.expectEqual(@as(?usize, 3), td.find("aa 0x1234", 0));
        try std.testing.expectEqual(@as(?usize, 5), td.find("aaaa 0x", 0)); // tail
        try std.testing.expect(!td.contains("deadbeef"));
    }
    // Randomized differential: 2–8 needles of 2–6 bytes over a tiny alphabet
    // (⇒ dense candidate lanes), from a random resume offset, vs the std min.
    var prng = std.Random.DefaultPrng.init(0x7EDD1);
    const rng = prng.random();
    var buf: [4096]u8 = undefined;
    for (&buf) |*b| b.* = 'a' + rng.uintLessThan(u8, 4);
    var st: [8][6]u8 = undefined;
    var set: [8][]const u8 = undefined;
    var t: usize = 0;
    while (t < 4000) : (t += 1) {
        const nn = 2 + rng.uintLessThan(usize, 7);
        for (0..nn) |k| {
            const nlen = 2 + rng.uintLessThan(usize, 5);
            for (st[k][0..nlen]) |*b| b.* = 'a' + rng.uintLessThan(u8, 4);
            set[k] = st[k][0..nlen];
        }
        const hlen = rng.uintLessThan(usize, buf.len);
        const from = rng.uintLessThan(usize, hlen + 1);
        var want: ?usize = null;
        for (set[0..nn]) |n| if (std.mem.indexOfPos(u8, buf[0..hlen], from, n)) |p| {
            if (want == null or p < want.?) want = p;
        };
        const td = teddy.Teddy.init(set[0..nn]).?;
        try std.testing.expectEqual(want, td.find(buf[0..hlen], from));
    }
}

test "simd memchr / lastIndexOfScalar / countByte ≡ std (line-scanner primitives)" {
    const t = std.testing;
    // Hand shapes crossing the vector/scalar boundary.
    try t.expectEqual(@as(?usize, 3), simd.memchr("abc\ndef", 0, '\n'));
    try t.expectEqual(@as(?usize, null), simd.memchr("abcdef", 0, '\n'));
    try t.expectEqual(@as(?usize, 3), simd.lastIndexOfScalar("a\nb\nc", 4, '\n')); // last '\n' in [0,4)
    try t.expectEqual(@as(?usize, 1), simd.lastIndexOfScalar("a\nb\nc", 3, '\n'));
    try t.expectEqual(@as(?usize, null), simd.lastIndexOfScalar("abc", 3, '\n'));
    try t.expectEqual(@as(usize, 3), simd.countByte("a\nb\nc\n", '\n'));
    // Randomized differential vs std over a sparse-newline buffer that spans
    // many vector blocks (exercises SIMD body + scalar tail on all three).
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const rng = prng.random();
    var buf: [8192]u8 = undefined;
    var trial: usize = 0;
    while (trial < 2000) : (trial += 1) {
        for (&buf) |*b| b.* = if (rng.uintLessThan(u8, 12) == 0) '\n' else 'x';
        const hlen = rng.uintLessThan(usize, buf.len + 1);
        const hay = buf[0..hlen];
        const from = rng.uintLessThan(usize, hlen + 1);
        try t.expectEqual(std.mem.indexOfScalarPos(u8, hay, from, '\n'), simd.memchr(hay, from, '\n'));
        const upto = rng.uintLessThan(usize, hlen + 1);
        try t.expectEqual(std.mem.lastIndexOfScalar(u8, hay[0..upto], '\n'), simd.lastIndexOfScalar(hay, upto, '\n'));
        try t.expectEqual(std.mem.count(u8, hay, "\n"), simd.countByte(hay, '\n'));
        // Fused count-and-flag ≡ separate countByte + indexOfScalar presence.
        const f = simd.countByteWithFlag(hay, '\n', 0);
        try t.expectEqual(simd.countByte(hay, '\n'), f.count);
        try t.expectEqual(std.mem.indexOfScalar(u8, hay, 0) != null, f.seen);
    }
    // A spliced NUL is seen; the newline count is unaffected by the other byte.
    var withnul = [_]u8{ 'a', '\n', 0, 'b', '\n' };
    const r = simd.countByteWithFlag(&withnul, '\n', 0);
    try t.expectEqual(@as(usize, 2), r.count);
    try t.expect(r.seen);
}

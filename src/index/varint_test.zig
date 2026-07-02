//! gist T0 varint codec tests — split out per the shape cap, wired via
//! `root.zig`'s test block.

const std = @import("std");
const varint = @import("varint.zig");

test "round-trip: boundary values across every byte-length tier" {
    const cases = [_]u64{
        0,     1,          126,        127,        128,
        16383, 16384,      2097151,    2097152,    268435455,
        268435456, std.math.maxInt(u32), std.math.maxInt(u64),
    };
    var buf: [10]u8 = undefined;
    for (cases) |v| {
        const n = varint.encode(&buf, v);
        try std.testing.expectEqual(varint.size(v), n);
        const d = varint.decode(&buf);
        try std.testing.expectEqual(v, d.value);
        try std.testing.expectEqual(n, d.len);
    }
}

test "size: matches the 7-bits-per-byte boundary exactly" {
    try std.testing.expectEqual(@as(usize, 1), varint.size(0));
    try std.testing.expectEqual(@as(usize, 1), varint.size(127));
    try std.testing.expectEqual(@as(usize, 2), varint.size(128));
    try std.testing.expectEqual(@as(usize, 2), varint.size(16383));
    try std.testing.expectEqual(@as(usize, 3), varint.size(16384));
    try std.testing.expectEqual(@as(usize, 5), varint.size(std.math.maxInt(u32)));
}

test "encode: small values (the common posting delta) cost exactly one byte" {
    var buf: [10]u8 = undefined;
    const n = varint.encode(&buf, 42);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 42), buf[0]);
}

test "decode: only consumes its own bytes, leaving a trailing stream intact" {
    var buf: [10]u8 = undefined;
    const n0 = varint.encode(buf[0..], 300); // 2 bytes
    const n1 = varint.encode(buf[n0..], 5); // 1 byte, right after
    const d0 = varint.decode(buf[0..]);
    try std.testing.expectEqual(@as(u64, 300), d0.value);
    try std.testing.expectEqual(n0, d0.len);
    const d1 = varint.decode(buf[d0.len..]);
    try std.testing.expectEqual(@as(u64, 5), d1.value);
    try std.testing.expectEqual(n1, d1.len);
}

test "fuzz: random u32 round-trips against a PRNG, 10k draws" {
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const rng = prng.random();
    var buf: [10]u8 = undefined;
    for (0..10_000) |_| {
        const v: u64 = rng.int(u32);
        const n = varint.encode(&buf, v);
        const d = varint.decode(&buf);
        try std.testing.expectEqual(v, d.value);
        try std.testing.expectEqual(n, d.len);
    }
}

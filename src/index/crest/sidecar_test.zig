//! Crest sidecar codec tests — round-trip identity plus the adversarial
//! fail-closed suite every persisted-blob loader in this kernel carries: any
//! malformed byte pattern must decode to null, never to a wrong table.

const std = @import("std");
const testing = std.testing;
const crest = @import("../../math/crest.zig");
const sidecar = @import("sidecar.zig");

test "round-trip: build → writeInto → decode is identity" {
    const gpa = testing.allocator;
    const docs: []const []const u8 = &.{ "deadbeef00", "no runs zz", "ABC 123 xyz_9" };
    const vectors = try sidecar.build(gpa, docs);
    defer gpa.free(vectors);
    for (docs, vectors) |d, v| try testing.expectEqual(crest.crest(d), v);

    const buf = try gpa.alignedAlloc(u8, .of(crest.Vector), sidecar.encodedSize(docs.len));
    defer gpa.free(buf);
    try testing.expectEqual(buf.len, sidecar.writeInto(vectors, buf));

    const view = sidecar.decode(buf, @intCast(docs.len)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(crest.Vector, vectors, view);
}

test "fail-closed: every malformed blob decodes to null" {
    const gpa = testing.allocator;
    const vectors = [_]crest.Vector{ crest.crest("0123abcd"), crest.crest("hello") };
    const buf = try gpa.alignedAlloc(u8, .of(crest.Vector), sidecar.encodedSize(vectors.len));
    defer gpa.free(buf);
    _ = sidecar.writeInto(&vectors, buf);

    // wrong doc binding (index/table doc-space mismatch)
    try testing.expectEqual(@as(?[]const crest.Vector, null), sidecar.decode(buf, 3));
    // truncated body / truncated header
    try testing.expectEqual(@as(?[]const crest.Vector, null), sidecar.decode(buf[0 .. buf.len - 1], 2));
    try testing.expectEqual(@as(?[]const crest.Vector, null), sidecar.decode(buf[0..7], 2));
    // trailing garbage (length must match exactly)
    const padded = try gpa.alignedAlloc(u8, .of(crest.Vector), buf.len + 4);
    defer gpa.free(padded);
    @memcpy(padded[0..buf.len], buf);
    try testing.expectEqual(@as(?[]const crest.Vector, null), sidecar.decode(padded, 2));
    // foreign magic and foreign lattice arity
    var bad = try gpa.alignedAlloc(u8, .of(crest.Vector), buf.len);
    defer gpa.free(bad);
    @memcpy(bad, buf);
    bad[0] ^= 0xFF;
    try testing.expectEqual(@as(?[]const crest.Vector, null), sidecar.decode(bad, 2));
    @memcpy(bad, buf);
    bad[12] += 1; // k
    try testing.expectEqual(@as(?[]const crest.Vector, null), sidecar.decode(bad, 2));
}

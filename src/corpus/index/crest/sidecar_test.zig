//! Crest sidecar codec tests — round-trip identity plus the adversarial
//! fail-closed suite every persisted-blob loader in this kernel carries: any
//! malformed byte pattern must decode to null, never to a wrong table.

const std = @import("std");
const testing = std.testing;
const crest = @import("../../../kernel/primitives/crest.zig");
const signet = @import("../../../kernel/primitives/signet.zig");
const sidecar = @import("sidecar.zig");

const version_off = 8;
const class_count_off = 10;
const element_width_off = 11;
const doc_count_off = 12;
const schema_hash_off = 16;
const reserved_off = 48;

test "round-trip: build → writeInto → decode is identity" {
    const gpa = testing.allocator;
    const docs: []const []const u8 = &.{ "deadbeef00", "no runs zz", "ABC 123 xyz_9" };
    const vectors = try sidecar.build(gpa, docs);
    defer gpa.free(vectors);
    for (docs, vectors) |d, v| try testing.expectEqual(crest.crest(d), v);

    const buf = try gpa.alignedAlloc(u8, .of(crest.Vector), try sidecar.encodedSize(docs.len));
    defer gpa.free(buf);
    try testing.expectEqual(buf.len, try sidecar.writeInto(vectors, buf));

    try testing.expectEqualSlices(u8, &crest.SidecarSchema.hash().bytes, buf[schema_hash_off..reserved_off]);
    var off: usize = sidecar.header_len;
    for (vectors) |vector| {
        for (vector) |value| {
            try testing.expectEqual(value, std.mem.readInt(u16, buf[off..][0..2], .little));
            off += @sizeOf(u16);
        }
    }

    const view = sidecar.decode(buf, @intCast(docs.len)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(crest.Vector, vectors, view);
}

test "fail-closed: old magic, version, schema, and shape tampering are rejected" {
    const gpa = testing.allocator;
    const vectors = [_]crest.Vector{ crest.crest("0123abcd"), crest.crest("hello") };
    const buf = try gpa.alignedAlloc(u8, .of(crest.Vector), try sidecar.encodedSize(vectors.len));
    defer gpa.free(buf);
    _ = try sidecar.writeInto(&vectors, buf);

    const bad = try gpa.alignedAlloc(u8, .of(crest.Vector), buf.len);
    defer gpa.free(bad);

    @memcpy(bad, buf);
    @memcpy(bad[0..8], "GISTCRS1");
    try testing.expect(sidecar.decode(bad, 2) == null);

    @memcpy(bad, buf);
    std.mem.writeInt(u16, bad[version_off..][0..2], crest.SidecarSchema.format_version + 1, .little);
    try testing.expect(sidecar.decode(bad, 2) == null);

    @memcpy(bad, buf);
    bad[schema_hash_off] ^= 1;
    try testing.expect(sidecar.decode(bad, 2) == null);

    @memcpy(bad, buf);
    bad[class_count_off] += 1;
    try testing.expect(sidecar.decode(bad, 2) == null);

    @memcpy(bad, buf);
    bad[element_width_off] += 1;
    try testing.expect(sidecar.decode(bad, 2) == null);

    @memcpy(bad, buf);
    std.mem.writeInt(u32, bad[doc_count_off..][0..4], 3, .little);
    try testing.expect(sidecar.decode(bad, 2) == null);
    try testing.expect(sidecar.decode(buf, 3) == null); // loaded index has foreign doc space
}

test "fail-closed: truncation, padding, and misalignment are rejected" {
    const gpa = testing.allocator;
    const vectors = [_]crest.Vector{crest.crest("0123abcd")};
    const buf = try gpa.alignedAlloc(u8, .of(crest.Vector), try sidecar.encodedSize(vectors.len));
    defer gpa.free(buf);
    _ = try sidecar.writeInto(&vectors, buf);

    try testing.expect(sidecar.decode(buf[0 .. buf.len - 1], 1) == null);
    try testing.expect(sidecar.decode(buf[0..7], 1) == null);

    const bad = try gpa.alignedAlloc(u8, .of(crest.Vector), buf.len);
    defer gpa.free(bad);
    @memcpy(bad, buf);
    bad[reserved_off] = 1;
    try testing.expect(sidecar.decode(bad, 1) == null);

    const padded = try gpa.alignedAlloc(u8, .of(crest.Vector), buf.len + 4);
    defer gpa.free(padded);
    @memcpy(padded[0..buf.len], buf);
    @memset(padded[buf.len..], 0);
    try testing.expect(sidecar.decode(padded, 1) == null);

    const shifted = try gpa.alignedAlloc(u8, .of(crest.Vector), buf.len + 1);
    defer gpa.free(shifted);
    @memcpy(shifted[1..], buf);
    try testing.expect(sidecar.decode(shifted[1..], 1) == null);
}

test "the seal catches the record rot that every layout check passes" {
    const gpa = testing.allocator;
    const vectors = [_]crest.Vector{ crest.crest("0123abcd"), crest.crest("wwwwww") };
    const buf = try gpa.alignedAlloc(u8, .of(crest.Vector), try sidecar.encodedSize(vectors.len));
    defer gpa.free(buf);
    _ = try sidecar.writeInto(&vectors, buf);
    try sidecar.verify(buf);

    // A rotted ρ(d) is a structurally perfect table: right magic, right
    // schema, right length, right alignment — and a sieve that silently
    // prunes a matching document. The seal is the only reader that sees it.
    buf[sidecar.header_len] ^= 0x40;
    const view = sidecar.decode(buf, vectors.len) orelse return error.TestUnexpectedResult;
    try testing.expect(!std.mem.eql(u16, &vectors[0], &view[0]));
    try testing.expectError(signet.Error.Corrupt, sidecar.verify(buf));
}

test "checked size arithmetic rejects the first overflowing document count" {
    const record_len = crest.K * @sizeOf(u16);
    const framed = sidecar.header_len + signet.len;
    const max_docs = (std.math.maxInt(usize) - framed) / record_len;
    const largest = sidecar.checkedEncodedSize(max_docs) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(framed + max_docs * record_len, largest);
    try testing.expect(sidecar.checkedEncodedSize(max_docs + 1) == null);
    if (@bitSizeOf(usize) > @bitSizeOf(u32))
        try testing.expectError(error.Oversized, sidecar.encodedSize(@as(usize, std.math.maxInt(u32)) + 1));
}

test "encoder rejects a short destination" {
    const vectors = [_]crest.Vector{crest.crest("0123")};
    var buf: [sidecar.header_len]u8 = undefined;
    try testing.expectError(error.Oversized, sidecar.writeInto(&vectors, &buf));
}

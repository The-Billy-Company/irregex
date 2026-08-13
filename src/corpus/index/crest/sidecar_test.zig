const std = @import("std");
const testing = std.testing;
const builder = @import("builder.zig");
const crest = @import("../../../kernel/math/crest.zig");
const sidecar = @import("sidecar.zig");
const signet = @import("../frame/signet.zig");

fn binding(label: []const u8) sidecar.Binding {
    return sidecar.Binding.forBuild(signet.of(.content, label));
}

fn encoded(rows: []const crest.Spectrum, q: u8, mark: sidecar.Binding) ![]u8 {
    const out = try testing.allocator.alloc(u8, try sidecar.encodedSize(rows, q));
    errdefer testing.allocator.free(out);
    _ = try sidecar.writeInto(rows, .{ .q = q, .binding = mark }, out);
    return out;
}

test "v6 round-trip preserves q4 spectra and q1 projection" {
    const docs = [_][]const u8{
        "",
        "id=0123456789abcdef",
        "111a22222b333c44",
        "\u{0660}\u{0661}\u{0662}abc\u{3000}",
    };
    const rows = try builder.build(testing.allocator, &docs);
    defer testing.allocator.free(rows);
    const mark = binding("round-trip");
    const bytes = try encoded(rows, 4, mark);
    defer testing.allocator.free(bytes);

    const view = sidecar.decode(bytes, .{
        .document_count = docs.len,
        .q = 4,
        .binding = mark,
    }) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, docs.len), view.len());
    for (rows, 0..) |row, document| try testing.expectEqual(row, view.row(document));
    for (docs, 0..) |doc, document| {
        const vector = crest.crest(doc);
        for (0..crest.K) |predicate|
            try testing.expectEqual(vector[predicate], view.value(predicate, 0, document));
    }
}

test "sparse overflow preserves saturated and long runs" {
    var long: [600]u8 = @splat('7');
    const docs = [_][]const u8{ "7", long[0..] };
    const rows = try builder.build(testing.allocator, &docs);
    defer testing.allocator.free(rows);
    const mark = binding("overflow");
    const bytes = try encoded(rows, 1, mark);
    defer testing.allocator.free(bytes);
    const view = sidecar.decode(bytes, .{
        .document_count = docs.len,
        .q = 1,
        .binding = mark,
    }) orelse return error.TestUnexpectedResult;

    const digit = crest.lane(.digit, .ascii);
    try testing.expectEqual(@as(u16, 1), view.value(digit, 0, 0));
    try testing.expectEqual(@as(u16, 600), view.value(digit, 0, 1));
    try testing.expect(view.overflow.len >= sidecar.overflow_entry_len);
}

test "decode refuses foreign identity shape and damage" {
    const rows = try builder.build(testing.allocator, &.{"123"});
    defer testing.allocator.free(rows);
    const mark = binding("bound");
    const bytes = try encoded(rows, 4, mark);
    defer testing.allocator.free(bytes);
    const expected: sidecar.Expected = .{ .document_count = 1, .q = 4, .binding = mark };

    try testing.expect(sidecar.decode(bytes, .{ .document_count = 2, .q = 4, .binding = mark }) == null);
    try testing.expect(sidecar.decode(bytes, .{ .document_count = 1, .q = 2, .binding = mark }) == null);
    try testing.expect(sidecar.decode(bytes, .{ .document_count = 1, .q = 4, .binding = binding("foreign") }) == null);
    try testing.expect(sidecar.decode(bytes[0 .. bytes.len - 1], expected) == null);

    const cases = [_]usize{
        0,
        sidecar.Offset.version,
        sidecar.Offset.predicate_count,
        sidecar.Offset.q,
        sidecar.Offset.semantic_hash,
        sidecar.Offset.dictionary_hash,
        sidecar.Offset.build_id,
        sidecar.header_len,
    };
    for (cases) |offset| {
        const original = bytes[offset];
        bytes[offset] ^= 1;
        try testing.expect(sidecar.decode(bytes, expected) == null);
        bytes[offset] = original;
    }
}

test "decode rejects structurally invalid overflow even after reseal" {
    var long: [300]u8 = @splat('7');
    const rows = try builder.build(testing.allocator, &.{long[0..]});
    defer testing.allocator.free(rows);
    const mark = binding("directory");
    const bytes = try encoded(rows, 1, mark);
    defer testing.allocator.free(bytes);
    const expected: sidecar.Expected = .{ .document_count = 1, .q = 1, .binding = mark };
    const seal: usize = std.mem.readInt(u64, bytes[sidecar.Offset.seal..][0..8], .little);
    const overflow: usize = std.mem.readInt(u64, bytes[sidecar.Offset.overflow..][0..8], .little);

    std.mem.writeInt(u32, bytes[overflow..][0..4], 1, .little);
    signet.sealAt(bytes, seal);
    try testing.expect(sidecar.decode(bytes, expected) == null);
}

test "columnar retain equals allocation-free document pruning" {
    const docs = [_][]const u8{
        "plain prose",
        "id=0123456789abcdef",
        "rule=" ++ "~" ** 12,
        "111a22222b333c44",
    };
    const rows = try builder.build(testing.allocator, &docs);
    defer testing.allocator.free(rows);
    const mark = binding("retain");
    const bytes = try encoded(rows, 4, mark);
    defer testing.allocator.free(bytes);
    const view = sidecar.decode(bytes, .{
        .document_count = docs.len,
        .q = 4,
        .binding = mark,
    }) orelse return error.TestUnexpectedResult;

    var swell: crest.RankedSwell = .{ .len = 1, .rank = 1 };
    swell.requirements[0][crest.spectrumLane(crest.lane(.hex, .ascii), 0)] = 8;
    var scalar = std.StaticBitSet(docs.len).initFull();
    view.retain(&scalar, swell);
    var columnar = try std.DynamicBitSet.initFull(testing.allocator, docs.len);
    defer columnar.deinit();
    try view.retainColumnar(testing.allocator, &columnar, swell);
    for (0..docs.len) |document| try testing.expectEqual(scalar.isSet(document), columnar.isSet(document));
}

test "legacy v4 magic is refused" {
    var bytes: [sidecar.header_len + sidecar.seal_len]u8 = @splat(0);
    @memcpy(bytes[0..8], "GISTCRS4");
    try testing.expect(sidecar.decode(&bytes, .{
        .document_count = 0,
        .q = 1,
        .binding = binding("legacy"),
    }) == null);
}

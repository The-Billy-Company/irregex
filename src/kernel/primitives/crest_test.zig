//! Crest kernel unit tests — the DOCUMENT half: the ρ(d) scan, the sieve
//! decision, and the persisted sidecar's semantic schema. The query half (ĝ)
//! is tested against the engine's own AST in
//! `../match/regex/analysis/swell_test.zig`, which also carries the Sieve
//! Theorem differential; the corpus-scale version is `zig build crest`.

const std = @import("std");
const testing = std.testing;
const crest = @import("crest.zig");

fn sha256(bytes: []const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

test "crest vector: longest per-class run" {
    const v = crest.crest("ab  12ff  ABCD_ef00");
    try testing.expectEqual(@as(u16, 2), v[@intFromEnum(crest.Class.digit)]); // "12"
    try testing.expectEqual(@as(u16, 4), v[@intFromEnum(crest.Class.hex)]); // "ef00"
    try testing.expectEqual(@as(u16, 4), v[@intFromEnum(crest.Class.upper)]); // "ABCD"
    try testing.expectEqual(@as(u16, 9), v[@intFromEnum(crest.Class.word)]); // "ABCD_ef00"
    try testing.expectEqual(@as(u16, 2), v[@intFromEnum(crest.Class.space)]); // "  "
}

test "semantic schema pins class order and byte-boundary memberships" {
    const order = [_]crest.Class{ .digit, .hex, .upper, .lower, .alpha, .word, .space, .punct };
    try testing.expectEqual(crest.K, order.len);
    for (order, 0..) |class, i| try testing.expectEqual(i, @intFromEnum(class));
    try testing.expectEqualStrings("digit\x00hex\x00upper\x00lower\x00alpha\x00word\x00space\x00punct", crest.SidecarSchema.class_order);

    const cases = [_]struct { byte: u8, bits: u8 }{
        .{ .byte = '/', .bits = 0x80 },
        .{ .byte = '0', .bits = 0x23 },
        .{ .byte = '9', .bits = 0x23 },
        .{ .byte = ':', .bits = 0x80 },
        .{ .byte = 'A', .bits = 0x36 },
        .{ .byte = 'F', .bits = 0x36 },
        .{ .byte = 'G', .bits = 0x34 },
        .{ .byte = '_', .bits = 0x20 },
        .{ .byte = '`', .bits = 0x80 },
        .{ .byte = 'a', .bits = 0x3a },
        .{ .byte = 'f', .bits = 0x3a },
        .{ .byte = 'g', .bits = 0x38 },
        .{ .byte = '\t', .bits = 0x40 },
        .{ .byte = '\n', .bits = 0x40 },
        .{ .byte = 0x0B, .bits = 0x40 },
        .{ .byte = 0x0C, .bits = 0x40 },
        .{ .byte = '\r', .bits = 0x40 },
        .{ .byte = ' ', .bits = 0x40 },
        .{ .byte = 0x7F, .bits = 0 },
        .{ .byte = 0x80, .bits = 0 },
    };
    for (cases) |case| try testing.expectEqual(case.bits, crest.membership[case.byte]);
}

test "semantic hash binds cap, interpretation, and full membership table" {
    const canonical = &crest.SidecarSchema.canonical_bytes;
    try testing.expect(std.mem.endsWith(u8, canonical, &crest.membership));
    try testing.expectEqual(std.math.maxInt(u16), crest.SidecarSchema.saturation_cap);
    try testing.expectEqual(@as(u16, 2), crest.SidecarSchema.format_version);

    const original = crest.SidecarSchema.hash();
    const pinned = [_]u8{
        0x8a, 0x37, 0xaa, 0xc5, 0xf8, 0xcc, 0x50, 0x11,
        0x8b, 0xd3, 0xd9, 0x29, 0x53, 0xfb, 0x0a, 0x52,
        0xad, 0xb7, 0xa0, 0x4c, 0x8f, 0x9c, 0xf3, 0xad,
        0x42, 0x8d, 0xf9, 0x5b, 0x34, 0x52, 0xe4, 0xbe,
    };
    try testing.expectEqualSlices(u8, &pinned, &original);

    var altered = crest.SidecarSchema.canonical_bytes;
    const version_marker = "format-version/u16le\x00";
    const version_at = (std.mem.indexOf(u8, &altered, version_marker) orelse return error.TestUnexpectedResult) + version_marker.len;
    altered[version_at] ^= 1;
    try testing.expect(!std.mem.eql(u8, &original, &sha256(&altered)));

    altered = crest.SidecarSchema.canonical_bytes;
    const order_at = std.mem.indexOf(u8, &altered, crest.SidecarSchema.class_order) orelse return error.TestUnexpectedResult;
    altered[order_at] ^= 1;
    try testing.expect(!std.mem.eql(u8, &original, &sha256(&altered)));

    altered = crest.SidecarSchema.canonical_bytes;
    const cap_marker = "saturation-cap/u16le\x00";
    const cap_at = (std.mem.indexOf(u8, &altered, cap_marker) orelse return error.TestUnexpectedResult) + cap_marker.len;
    altered[cap_at] ^= 1;
    try testing.expect(!std.mem.eql(u8, &original, &sha256(&altered)));

    altered = crest.SidecarSchema.canonical_bytes;
    const interpretation_at = std.mem.indexOf(u8, &altered, crest.SidecarSchema.element_interpretation) orelse return error.TestUnexpectedResult;
    altered[interpretation_at] ^= 1;
    try testing.expect(!std.mem.eql(u8, &original, &sha256(&altered)));

    altered = crest.SidecarSchema.canonical_bytes;
    altered[altered.len - 1] ^= 1;
    try testing.expect(!std.mem.eql(u8, &original, &sha256(&altered)));
}

test "sieve decision: dominance, componentwise, over the class family" {
    // An 8-byte hex run is the family's motivating query (`[0-9a-f]{8}`).
    var gv = crest.zero_vector;
    gv[@intFromEnum(crest.Class.hex)] = 8;
    gv[@intFromEnum(crest.Class.word)] = 8;
    try testing.expect(crest.active(gv));
    try testing.expect(!crest.active(crest.zero_vector));
    try testing.expect(crest.pruned(crest.crest("no hex run here: zz zz"), gv));
    try testing.expect(!crest.pruned(crest.crest("id=0123abcdef more"), gv));
    // Falling short in ANY single class is enough to prune: a 9-byte word run
    // that is only 7 hex bytes long fails the hex component alone.
    try testing.expect(crest.pruned(crest.crest("id=0123abcx more"), gv));
    // `weaker` is the alternation fold — it can only ever relax the sieve.
    var half = crest.zero_vector;
    half[@intFromEnum(crest.Class.hex)] = 3;
    const w = crest.weaker(gv, half);
    try testing.expectEqual(@as(u16, 3), w[@intFromEnum(crest.Class.hex)]);
    try testing.expectEqual(@as(u16, 0), w[@intFromEnum(crest.Class.word)]);
    try testing.expect(!crest.pruned(crest.crest("id=0123abcx more"), w));
}

test "saturation is monotone on both sides of the compare" {
    // A document past the u16 cap saturates, and a saturated ĝ still admits it —
    // saturation may cost pruning, never a match.
    var long_doc: [70_000]u8 = @splat('0');
    const long_crest = crest.crest(&long_doc);
    try testing.expectEqual(std.math.maxInt(u16), long_crest[@intFromEnum(crest.Class.digit)]);
    var saturated = crest.zero_vector;
    saturated[@intFromEnum(crest.Class.digit)] = std.math.maxInt(u16);
    try testing.expect(!crest.pruned(long_crest, saturated));
    // A run that merely ends the document still counts (no off-by-one at EOF).
    try testing.expectEqual(@as(u16, 3), crest.crest("xy 123")[@intFromEnum(crest.Class.digit)]);
}

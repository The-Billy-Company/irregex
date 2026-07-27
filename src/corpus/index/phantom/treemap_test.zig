//! Adversarial unit suite for the phantom `tree.map` layout (`treemap.zig`):
//! a hand-framed blob round-trips through `decode`, `resolve` places explicit
//! roots by name, and every torn/dangling variant fails CLOSED so the walk
//! falls back live rather than serving corrupt membership. `decode` is the
//! layout half of `frame.mapArtifact`, so its refusals surface as
//! `error.Corrupt` and the protocol turns them into the null the walk sees.

const std = @import("std");
const treemap = @import("treemap.zig");
const signet = @import("../../../kernel/primitives/signet.zig");

/// Frame a valid two-level blob: root{ "src"(dir→1), "a.txt"(file) },
/// src{ "b.go"(file), "hid"(dir, never descended) }.
fn frameBlob(a: std.mem.Allocator, anchor: i64) ![]u8 {
    const names = "src" ++ "a.txt" ++ "b.go" ++ "hid";
    const dirs = [_]treemap.Rec{ .{ .first = 0, .count = 2 }, .{ .first = 2, .count = 2 } };
    const ents = [_]treemap.Ent{
        .{ .name_off = 0, .name_len = 3, .kind = 1, .dir_ix = 1 },
        .{ .name_off = 3, .name_len = 5, .kind = 0, .dir_ix = treemap.not_walked },
        .{ .name_off = 8, .name_len = 4, .kind = 0, .dir_ix = treemap.not_walked },
        .{ .name_off = 12, .name_len = 3, .kind = 1, .dir_ix = treemap.not_walked },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "GISTTRE2");
    var b8: [8]u8 = undefined;
    std.mem.writeInt(i64, &b8, anchor, .little);
    try out.appendSlice(a, &b8);
    std.mem.writeInt(u32, b8[0..4], dirs.len, .little);
    try out.appendSlice(a, b8[0..4]);
    std.mem.writeInt(u32, b8[0..4], ents.len, .little);
    try out.appendSlice(a, b8[0..4]);
    std.mem.writeInt(u32, b8[0..4], names.len, .little);
    try out.appendSlice(a, b8[0..4]);
    try out.appendSlice(a, &[_]u8{0} ** 4);
    try out.appendSlice(a, std.mem.sliceAsBytes(dirs[0..]));
    try out.appendSlice(a, std.mem.sliceAsBytes(ents[0..]));
    try out.appendSlice(a, names);
    // Sealed like `build` writes it, so the torn/dangling cases below stay
    // tests of the LAYOUT refusals they name rather than of a missing trailer.
    try signet.sealInto(a, &out);
    return out.toOwnedSlice(a);
}

/// `decode` wants a page-aligned `frame.Mapping`-shaped slice; tests copy
/// the framed bytes into an aligned buffer to mimic mmap.
fn aligned(a: std.mem.Allocator, blob: []const u8) ![]align(std.heap.page_size_min) u8 {
    const buf = try a.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), blob.len);
    @memcpy(buf, blob);
    return buf;
}

test "treemap: a framed blob decodes and serves membership" {
    const a = std.testing.allocator;
    const blob = try frameBlob(a, 12345);
    defer a.free(blob);
    const map = try aligned(a, blob);
    defer a.free(map);

    const v = try treemap.decode({}, map);
    try std.testing.expectEqual(@as(i128, 12345), v.anchor_ns);
    const root_kids = v.children(0);
    try std.testing.expectEqual(@as(usize, 2), root_kids.len);
    try std.testing.expectEqualStrings("src", v.name(root_kids[0]));
    try std.testing.expect(root_kids[0].isDir());
    try std.testing.expectEqual(@as(u32, 1), root_kids[0].dir_ix);
    try std.testing.expectEqualStrings("a.txt", v.name(root_kids[1]));
    try std.testing.expect(!root_kids[1].isDir());
    const src_kids = v.children(1);
    try std.testing.expectEqualStrings("b.go", v.name(src_kids[0]));
    // Recorded but never descended: a query that admits it must walk live.
    try std.testing.expectEqual(treemap.not_walked, src_kids[1].dir_ix);
}

test "treemap: resolve places roots by name and declines the unplaceable" {
    const a = std.testing.allocator;
    const blob = try frameBlob(a, 1);
    defer a.free(blob);
    const map = try aligned(a, blob);
    defer a.free(map);
    const v = try treemap.decode({}, map);

    try std.testing.expectEqual(@as(?u32, 0), treemap.resolve(&v, ""));
    try std.testing.expectEqual(@as(?u32, 0), treemap.resolve(&v, "."));
    try std.testing.expectEqual(@as(?u32, 1), treemap.resolve(&v, "src"));
    try std.testing.expectEqual(@as(?u32, 1), treemap.resolve(&v, "./src"));
    try std.testing.expectEqual(@as(?u32, null), treemap.resolve(&v, "src/hid")); // never descended
    try std.testing.expectEqual(@as(?u32, null), treemap.resolve(&v, "a.txt")); // a file, not a dir
    try std.testing.expectEqual(@as(?u32, null), treemap.resolve(&v, "missing"));
    try std.testing.expectEqual(@as(?u32, null), treemap.resolve(&v, "/abs"));
    try std.testing.expectEqual(@as(?u32, null), treemap.resolve(&v, "../up"));
}

test "treemap: every torn variant fails closed" {
    const a = std.testing.allocator;
    const blob = try frameBlob(a, 1);
    defer a.free(blob);
    const expectCorrupt = struct {
        fn f(map: []align(std.heap.page_size_min) const u8) !void {
            try std.testing.expectError(error.Corrupt, treemap.decode({}, map));
        }
    }.f;

    // Wrong magic.
    {
        const map = try aligned(a, blob);
        defer a.free(map);
        map[0] = 'X';
        try expectCorrupt(map);
    }
    // Truncated body.
    {
        const map = try aligned(a, blob);
        defer a.free(map);
        try expectCorrupt(map[0 .. map.len - 1]);
    }
    // Dangling ent span: dirs[1].count runs past ents.
    {
        const map = try aligned(a, blob);
        defer a.free(map);
        std.mem.writeInt(u32, map[32 + 8 + 4 ..][0..4], 99, .little);
        try expectCorrupt(map);
    }
    // Dangling name_off in ent 0 (ents start after 2 dir recs).
    {
        const map = try aligned(a, blob);
        defer a.free(map);
        std.mem.writeInt(u32, map[32 + 16 ..][0..4], 60000, .little);
        try expectCorrupt(map);
    }
    // Dangling dir_ix in ent 0 (dir_ix field sits at offset 8 in Ent).
    {
        const map = try aligned(a, blob);
        defer a.free(map);
        std.mem.writeInt(u32, map[32 + 16 + 8 ..][0..4], 7, .little);
        try expectCorrupt(map);
    }
    // Zero dirs.
    {
        const map = try aligned(a, blob);
        defer a.free(map);
        std.mem.writeInt(u32, map[16..20], 0, .little);
        try expectCorrupt(map);
    }
}

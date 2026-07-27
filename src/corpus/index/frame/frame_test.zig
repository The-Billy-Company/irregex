//! Adversarial unit suite for the shared artifact-load protocol
//! (`frame.mapArtifact` / `frame.mapAt`) and the tree binding it gates on.
//!
//! Both gates used to be per-artifact prose — a `boundHere()` line and a
//! future-anchor line hand-copied into every loader, where omitting either is a
//! silent CORRECTNESS bug rather than a missing optimization (a foreign shard
//! serves another checkout's bytes at a path that exists here; a future anchor
//! "proves" every file unchanged). Now one seam owns the order, so this is
//! where the order is proved.
//!
//! The fixture decoder deliberately ALLOCATES, because the subtle half of the
//! protocol is the reject path: a refusal after a successful decode must run
//! the view's own `deinit` — releasing the mapping AND whatever the decoder
//! took — not just unmap. `std.testing.allocator` fails the test on a leak, so
//! that is checked rather than asserted.

const std = @import("std");
const frame = @import("frame.zig");
const portal = @import("../../../portal.zig");
const Dir = std.Io.Dir;

const magic = "FRAMTST1";

/// A minimal self-anchored artifact: magic(8) · anchor i64 · payload.
const TestView = struct {
    map: frame.Mapping,
    anchor_ns: i128,
    /// Heap-owned on purpose — the reject path must give this back.
    owned: []u8,
    gpa: std.mem.Allocator,

    pub fn deinit(v: *TestView) void {
        v.gpa.free(v.owned);
        portal.unmap(v.map);
    }
};

fn decode(gpa: std.mem.Allocator, map: frame.Mapping) !TestView {
    if (map.len < 16 or !std.mem.eql(u8, map[0..magic.len], magic)) return error.Corrupt;
    const anchor_ns: i128 = std.mem.readInt(i64, map[8..16], .little);
    return .{ .map = map, .anchor_ns = anchor_ns, .owned = try gpa.dupe(u8, map[16..]), .gpa = gpa };
}

fn writeBlob(io: std.Io, path: []const u8, anchor_ns: i64, payload: []const u8, good_magic: bool) !void {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..8], if (good_magic) magic else "XXXXXXXX");
    std.mem.writeInt(i64, buf[8..16], anchor_ns, .little);
    @memcpy(buf[16..][0..payload.len], payload);
    try frame.writeAtomic(io, path, buf[0 .. 16 + payload.len]);
}

test "mapAt: serves a past-anchored blob and refuses every unprovable one" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = try std.fmt.allocPrint(gpa, "/tmp/gist_frame_map_{x}", .{@intFromPtr(&threaded)});
    defer gpa.free(root);
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};
    const path = try std.fmt.allocPrint(gpa, "{s}/blob.bin", .{root});
    defer gpa.free(path);

    const now = std.Io.Clock.now(.real, io).nanoseconds;

    // A blob anchored in the past decodes and serves.
    try writeBlob(io, path, @intCast(now - std.time.ns_per_s), "payload", true);
    var v = frame.mapAt(TestView, io, path, gpa, decode) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("payload", v.owned);
    v.deinit();

    // A FUTURE-dated anchor refuses. Freshness is proved by comparing a file's
    // clocks against this number, so an anchor newer than now would date every
    // file in the tree as unchanged — the whole corpus trusted at once.
    try writeBlob(io, path, @intCast(now + 60 * std.time.ns_per_s), "payload", true);
    try std.testing.expectEqual(@as(?TestView, null), frame.mapAt(TestView, io, path, gpa, decode));

    // A blob the decoder rejects refuses, and the mapping goes back.
    try writeBlob(io, path, @intCast(now - std.time.ns_per_s), "payload", false);
    try std.testing.expectEqual(@as(?TestView, null), frame.mapAt(TestView, io, path, gpa, decode));

    // An absent artifact is the ordinary case, not an error.
    const missing = try std.fmt.allocPrint(gpa, "{s}/nope.bin", .{root});
    defer gpa.free(missing);
    try std.testing.expectEqual(@as(?TestView, null), frame.mapAt(TestView, io, missing, gpa, decode));
}

test "bindingHolds: only this tree's own recording passes the gate" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = try std.fmt.allocPrint(gpa, "/tmp/gist_frame_bind_{x}", .{@intFromPtr(&threaded)});
    defer gpa.free(root);
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};
    const binding = try std.fmt.allocPrint(gpa, "{s}/tree.root", .{root});
    defer gpa.free(binding);

    // Absent reads as unbound: a pre-binding artifact carries no proof of which
    // tree it came from, and absence is not consent.
    try std.testing.expect(!frame.bindingHolds(binding));

    // Another checkout's recording — the case that makes a shard serve foreign
    // bytes at a path this tree really has.
    try frame.writeAtomic(io, binding, "/some/other/checkout\n");
    try std.testing.expect(!frame.bindingHolds(binding));

    // This tree's own recording, published by the same call `gist index` makes.
    frame.publishBinding(io, binding);
    try std.testing.expect(frame.bindingHolds(binding));
}

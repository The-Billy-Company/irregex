//! irregex generation-retention tests — wired via `root.zig`'s test block.
//!
//! Each of `lapse`'s four fences is asserted ALONE, because that is the claim:
//! any one of them by itself keeps a directory. A fixture that satisfied two at
//! once would pass whichever one was broken. Ids are small hex values so
//! ordering is legible, and the grace fence is exercised by policy rather than
//! by sleeping — a zero `grace_ns` leaves eligibility to ordering, a huge one
//! makes every id "young".

const std = @import("std");
const lapse = @import("lapse.zig");
const Dir = std.Io.Dir;

/// A `gens/` directory holding the named generations, each with a file inside
/// so a removal has to actually recurse.
const Fixture = struct {
    root: []const u8,
    gens: []const u8,
    io: std.Io,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, io: std.Io, tag: []const u8, ids: []const []const u8) !Fixture {
        const root = try std.fmt.allocPrint(gpa, "/tmp/gist_lapse_{s}_{d}", .{ tag, std.Io.Clock.now(.real, io).nanoseconds });
        Dir.cwd().deleteTree(io, root) catch {};
        const gens = try std.fmt.allocPrint(gpa, "{s}/gens", .{root});
        for (ids) |id| {
            const dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ gens, id });
            defer gpa.free(dir);
            try Dir.cwd().createDirPath(io, dir);
            const blob = try std.fmt.allocPrint(gpa, "{s}/index.gist", .{dir});
            defer gpa.free(blob);
            try Dir.cwd().writeFile(io, .{ .sub_path = blob, .data = "x" });
        }
        return .{ .root = root, .gens = gens, .io = io, .gpa = gpa };
    }

    fn deinit(self: *Fixture) void {
        Dir.cwd().deleteTree(self.io, self.root) catch {};
        self.gpa.free(self.gens);
        self.gpa.free(self.root);
    }

    fn present(self: *const Fixture, id: []const u8) bool {
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.gens, id }) catch return false;
        _ = Dir.cwd().statFile(self.io, p, .{}) catch return false;
        return true;
    }
};

fn testIo(threaded: *std.Io.Threaded) std.Io {
    return threaded.io();
}

test "lapse: retires superseded generations and keeps the published one" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var fx = try Fixture.init(gpa, io, "basic", &.{ "10", "20", "30", "40" });
    defer fx.deinit();

    const r = lapse.reclaimWith(io, fx.gens, "40", .{ .keep = 0, .grace_ns = 0 });
    try std.testing.expectEqual(@as(usize, 3), r.retired);
    try std.testing.expect(fx.present("40")); // the published generation
    try std.testing.expect(!fx.present("30"));
    try std.testing.expect(!fx.present("20"));
    try std.testing.expect(!fx.present("10"));
}

test "lapse: keeps the N most recent survivors below the published id" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var fx = try Fixture.init(gpa, io, "keep", &.{ "10", "20", "30", "40", "50" });
    defer fx.deinit();

    const r = lapse.reclaimWith(io, fx.gens, "50", .{ .keep = 2, .grace_ns = 0 });
    try std.testing.expectEqual(@as(usize, 2), r.retired);
    try std.testing.expectEqual(@as(usize, 2), r.kept);
    try std.testing.expect(fx.present("50")); // published
    try std.testing.expect(fx.present("40")); // reader grace
    try std.testing.expect(fx.present("30")); // reader grace
    try std.testing.expect(!fx.present("20"));
    try std.testing.expect(!fx.present("10"));
}

test "lapse: never retires a generation newer than the published one (a build in flight)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    // 60 and 70 are ids a concurrent builder minted but has not published.
    var fx = try Fixture.init(gpa, io, "newer", &.{ "10", "50", "60", "70" });
    defer fx.deinit();

    const r = lapse.reclaimWith(io, fx.gens, "50", .{ .keep = 0, .grace_ns = 0 });
    try std.testing.expectEqual(@as(usize, 1), r.retired);
    try std.testing.expect(fx.present("70"));
    try std.testing.expect(fx.present("60"));
    try std.testing.expect(fx.present("50"));
    try std.testing.expect(!fx.present("10"));
}

test "lapse: the grace fence alone spares an older generation still being written" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    // Real ns-scale ids: `now` sits just above them, so a grace window wide
    // enough to cover both makes even the OLDER one young — the case ordering
    // misses (a builder that minted an id, lost the race, and is still
    // writing). `keep = 0` removes the survivor-window fence, so only grace
    // can be what spares it.
    const now: u64 = @truncate(@as(u128, @intCast(std.Io.Clock.now(.real, io).nanoseconds)));
    const older = try std.fmt.allocPrint(gpa, "{x}", .{now - 1_000_000_000});
    defer gpa.free(older);
    const live = try std.fmt.allocPrint(gpa, "{x}", .{now});
    defer gpa.free(live);

    var fx = try Fixture.init(gpa, io, "grace", &.{ older, live });
    defer fx.deinit();

    const spared = lapse.reclaimWith(io, fx.gens, live, .{ .keep = 0, .grace_ns = 60 * std.time.ns_per_s });
    try std.testing.expectEqual(@as(usize, 0), spared.retired);
    try std.testing.expect(fx.present(older));

    // Same fixture, same ordering, grace withdrawn: now it lapses. The only
    // variable is the fence, so this pins the fence rather than the fixture.
    const taken = lapse.reclaimWith(io, fx.gens, live, .{ .keep = 0, .grace_ns = 0 });
    try std.testing.expectEqual(@as(usize, 1), taken.retired);
    try std.testing.expect(!fx.present(older));
    try std.testing.expect(fx.present(live));
}

test "lapse: leaves entries that are not generation ids this package could mint" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    // Zero-padded and uppercase forms parse as hex but are NOT what `{x}`
    // renders, so the round-trip check must reject them: they are somebody
    // else's directories, and a bijective name test is what keeps this from
    // deleting them.
    var fx = try Fixture.init(gpa, io, "alien", &.{ "10", "0010", "ABCD", "notes", "30" });
    defer fx.deinit();

    const r = lapse.reclaimWith(io, fx.gens, "30", .{ .keep = 0, .grace_ns = 0 });
    try std.testing.expectEqual(@as(usize, 1), r.retired);
    try std.testing.expect(!fx.present("10"));
    try std.testing.expect(fx.present("0010"));
    try std.testing.expect(fx.present("ABCD"));
    try std.testing.expect(fx.present("notes"));
    try std.testing.expect(fx.present("30"));
}

test "lapse: an unreadable published id retires nothing" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var fx = try Fixture.init(gpa, io, "unknown", &.{ "10", "20" });
    defer fx.deinit();

    const r = lapse.reclaimWith(io, fx.gens, "not-an-id", .{ .keep = 0, .grace_ns = 0 });
    try std.testing.expectEqual(@as(usize, 0), r.retired);
    try std.testing.expect(fx.present("10"));
    try std.testing.expect(fx.present("20"));
}

test "lapse: a missing gens directory is a no-op, not a failure" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    const r = lapse.reclaimWith(io, "/tmp/gist_lapse_absent_dir_xyz/gens", "40", .{});
    try std.testing.expectEqual(@as(usize, 0), r.retired);
}

test "lapse: one pass retires at most a batch, and the backlog drains over later publishes" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    // 70 superseded generations against a batch ceiling of 64: the first pass
    // is bounded, and a second finishes the job. This is the property that
    // keeps a deep backlog from stalling a 2-second index build.
    var ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (ids.items) |s| gpa.free(s);
        ids.deinit(gpa);
    }
    for (1..71) |i| try ids.append(gpa, try std.fmt.allocPrint(gpa, "{x}", .{i}));
    const live = try std.fmt.allocPrint(gpa, "{x}", .{@as(usize, 100)});
    defer gpa.free(live);
    try ids.append(gpa, try gpa.dupe(u8, live));

    var fx = try Fixture.init(gpa, io, "batch", ids.items);
    defer fx.deinit();

    const first = lapse.reclaimWith(io, fx.gens, live, .{ .keep = 0, .grace_ns = 0 });
    try std.testing.expectEqual(@as(usize, 64), first.retired);
    const second = lapse.reclaimWith(io, fx.gens, live, .{ .keep = 0, .grace_ns = 0 });
    try std.testing.expectEqual(@as(usize, 6), second.retired);
    try std.testing.expect(fx.present(live));

    const third = lapse.reclaimWith(io, fx.gens, live, .{ .keep = 0, .grace_ns = 0 });
    try std.testing.expectEqual(@as(usize, 0), third.retired);
}

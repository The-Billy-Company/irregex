//! gist resident session — the freshness-watcher barrier suite (ADR-352 rung 2.5).
//!
//! The watcher is a pure *accelerator*: when it proves quiescence the session
//! takes the microsecond clean path; on any event it forces a reconcile. These
//! tests pin that barrier's two halves — an armed, event-free window flips
//! `clean` true (fast path) and a `markDirty` clears it (back to reconcile) —
//! and prove the real `Watcher` lifecycle (`start`/`stop`) is crash-free. Both
//! syscall-synchronous backends arm causal quiescence (Linux inotify · macOS
//! kqueue, ADR-372); a target without one stays reconcile-always. The macOS
//! backend's behavior under real mutations lives in `kqueue_test.zig`.

const std = @import("std");
const builtin = @import("builtin");
const resident = @import("resident.zig");
const watch = @import("watch.zig");
const request = @import("request.zig");
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;

fn makeTree(a: std.mem.Allocator, io: std.Io, tag: []const u8, seed: usize) ![]const u8 {
    const root = try std.fmt.allocPrint(a, "/tmp/gist_watch_{s}_{x}", .{ tag, seed });
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/a.txt", .{root}), .data = "needle here\n" });
    return root;
}

test "barrier: an armed, event-free query flips clean; markDirty clears it" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    const root = try makeTree(fixture.allocator(), io, "barrier", @intFromPtr(&threaded));
    defer Dir.cwd().deleteTree(io, root) catch {};

    var session = try ResidentSession.init(gpa, io, &.{root});
    defer session.deinit();

    // Simulate a live watcher proving quiescence (no real backend needed to
    // exercise the seqlock the query path reads).
    session.armWatcher();
    try std.testing.expect(!session.seqlock.provenClean()); // nothing proven yet

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const r = try session.query(q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
        try std.testing.expectEqual(@as(usize, 1), r.files.len);
    }
    // An armed reconcile with no racing event flips the clean fast path on.
    try std.testing.expect(session.seqlock.provenClean());

    // A filesystem event clears the proof; the next query must reconcile again.
    session.markDirty();
    try std.testing.expect(!session.seqlock.provenClean());

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const r = try session.query(q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
        try std.testing.expectEqual(@as(usize, 1), r.files.len); // still correct
    }
    try std.testing.expect(session.seqlock.provenClean()); // re-proven clean
}

test "Watcher.start/stop arms only a causally complete backend" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    const root = try makeTree(fixture.allocator(), io, "lifecycle", @intFromPtr(&threaded));
    defer Dir.cwd().deleteTree(io, root) catch {};

    var session = try ResidentSession.init(gpa, io, &.{root});
    defer session.deinit();

    var w = watch.Watcher(ResidentSession).init(gpa, io, &session);
    w.start();
    defer w.stop();

    // Arming is environment-dependent on both real backends (inotify watch
    // limits, kqueue descriptor budget), so neither is asserted to arm here —
    // but arming without the exactness promise would be the dangerous state: a
    // session trusting quiescence from a backend that cannot account for what
    // changed. Other targets have no causal backend and must stay unarmed.
    switch (builtin.os.tag) {
        .macos, .linux => if (session.seqlock.armed()) try std.testing.expect(session.dirty_log.exact),
        else => try std.testing.expect(!session.seqlock.armed()),
    }

    var q = std.heap.ArenaAllocator.init(gpa);
    defer q.deinit();
    const r = try session.query(q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
    try std.testing.expectEqual(@as(usize, 1), r.files.len);
}

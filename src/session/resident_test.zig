//! gist resident session — the warm-engine correctness suite (ADR-352 rung 2.5).
//!
//! The one invariant the resident path must never break is
//! `resident matches == gist --no-index matches == rg matches`. Freshness has a
//! single unforgivable failure mode — a false result after the tree changed
//! under a warm session — so these tests drive a REAL directory tree through a
//! live `ResidentSession` and prove, over live syscalls: (1) the eligible
//! file-set / count answers match ground truth, (2) a write is visible to the
//! next query (read-your-writes via the reconcile barrier), (3) a deletion is
//! never reported, and (4) the regex + caseless paths agree with the literal
//! one. Assertions pin the expected shape, not a self-run of the engine.

const std = @import("std");
const resident = @import("resident.zig");
const request = @import("request.zig");
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;

/// A throwaway on-disk tree the session searches, with an absolute root so no
/// test ever depends on (or mutates) the process cwd.
const Tree = struct {
    root: []const u8,
    io: std.Io,
    a: std.mem.Allocator,

    fn init(a: std.mem.Allocator, io: std.Io, tag: []const u8, seed: usize) !Tree {
        const root = try std.fmt.allocPrint(a, "/tmp/gist_resident_{s}_{x}", .{ tag, seed });
        Dir.cwd().deleteTree(io, root) catch {};
        try Dir.cwd().createDirPath(io, root);
        return .{ .root = root, .io = io, .a = a };
    }

    fn deinit(self: *Tree) void {
        Dir.cwd().deleteTree(self.io, self.root) catch {};
    }

    fn write(self: *Tree, rel: []const u8, data: []const u8) !void {
        const p = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
        try Dir.cwd().writeFile(self.io, .{ .sub_path = p, .data = data });
    }

    fn remove(self: *Tree, rel: []const u8) !void {
        const p = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
        try Dir.cwd().deleteFile(self.io, p);
    }

    fn abs(self: *Tree, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
    }
};

/// Coarse filesystem clocks can collapse a write onto the previous reconcile
/// tick; a short sleep guarantees the mtime/ctime strictly advance so
/// `changedSince` flags the change (the same 50ms idiom `bulkstat_test` uses).
fn advanceClock(io: std.Io) !void {
    try io.sleep(.fromNanoseconds(60 * std.time.ns_per_ms), .real);
}

/// Assert the files-mode result is exactly `rels` (order-independent set match).
fn expectFileSet(tree: *Tree, files: []const []const u8, rels: []const []const u8) !void {
    try std.testing.expectEqual(rels.len, files.len);
    for (rels) |rel| {
        const want = try tree.abs(rel);
        var found = false;
        for (files) |got| if (std.mem.eql(u8, got, want)) {
            found = true;
            break;
        };
        if (!found) {
            std.debug.print("resident files result missing {s} (got {d} files):\n", .{ want, files.len });
            for (files) |got| std.debug.print("  - {s}\n", .{got});
            return error.TestUnexpectedFileSet;
        }
    }
}

fn queryFiles(session: *ResidentSession, arena: std.mem.Allocator, req: request.Request) ![]const []const u8 {
    const r = try session.query(arena, req);
    return r.files;
}

test "resident: files + count match ground truth over a warm tree" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "parity", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "alpha\nneedle one\n"); // 1 matching line
    try tree.write("b.txt", "needle two\nneedle three\n"); // 2 matching lines
    try tree.write("c.txt", "no match here\n"); // 0

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    var q1 = std.heap.ArenaAllocator.init(gpa);
    defer q1.deinit();
    const files = try queryFiles(&session, q1.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
    try expectFileSet(&tree, files, &.{ "a.txt", "b.txt" });

    var q2 = std.heap.ArenaAllocator.init(gpa);
    defer q2.deinit();
    const counted = try session.query(q2.allocator(), .{ .pattern = "needle", .mode = .count, .fixed = true });
    try std.testing.expectEqual(@as(u64, 3), counted.count);
}

test "resident: a write is visible to the next query (read-your-writes)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "ryw", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "needle here\n");
    try tree.write("c.txt", "not yet\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
        try expectFileSet(&tree, files, &.{"a.txt"});
    }

    try advanceClock(io);
    try tree.write("c.txt", "not yet\nneedle appeared\n"); // c now matches

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
        try expectFileSet(&tree, files, &.{ "a.txt", "c.txt" });
    }
}

test "resident: a deleted file is never reported" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "delete", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "needle stays\n");
    try tree.write("b.txt", "needle goes\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
        try expectFileSet(&tree, files, &.{ "a.txt", "b.txt" });
    }

    try advanceClock(io);
    try tree.remove("b.txt");

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
        try expectFileSet(&tree, files, &.{"a.txt"});
    }
}

test "resident: regex and caseless paths agree with the literal path" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "regex", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("lower.txt", "the needle is here\n");
    try tree.write("upper.txt", "the Needle is HERE\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // Case-sensitive regex `n.edle` matches only the lowercase file.
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "n.edle", .mode = .files });
        try expectFileSet(&tree, files, &.{"lower.txt"});
    }

    // Caseless literal `needle` matches both.
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true, .ignore_case = true });
        try expectFileSet(&tree, files, &.{ "lower.txt", "upper.txt" });
    }
}

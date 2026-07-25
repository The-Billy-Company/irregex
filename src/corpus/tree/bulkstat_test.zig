//! irregex — differential proof that `bulkstat.visitFresh` (getattrlistbulk) finds
//! EXACTLY the same fresh-file set as the pre-existing stat-based walk it
//! replaces inside `fresh.zig`. Freshness has one unforgivable failure mode —
//! a false negative, a changed file the overlay fails to surface — so this
//! test builds a real (not mocked) directory tree with a mix of old/new
//! change timestamps, a skip-dir, and a symlink, and cross-checks two independently
//! reachable code paths over live syscalls rather than asserting a
//! hand-computed "expected" set (a self-referential oracle would prove
//! nothing here — the whole risk is a parsing bug in the hand-rolled
//! `getattrlistbulk` ABI, and this test drives the actual kernel entry point).

const std = @import("std");
const bulkstat = @import("bulkstat.zig");
const haystack = @import("haystack.zig");
const fault = @import("../../fault.zig");
const Dir = std.Io.Dir;

fn cmpStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The exact pre-bulkstat algorithm `fresh.zig::walkShard` used (readdir +
/// `statFile` per entry) — the independent reference this test proves
/// `bulkstat.visitFresh` against.
fn statWalk(a: std.mem.Allocator, io: std.Io, root_path: []const u8, built_ns: i128, out: *std.ArrayList([]const u8)) !void {
    var w = try haystack.Walker.init(io, a, root_path);
    defer w.deinit(io);
    while (try w.next(io)) |hay| {
        const st = hay.dir.statFile(io, hay.name, .{}) catch {
            try out.append(a, hay.path);
            continue;
        };
        if (!bulkstat.needsLiveRead(built_ns, st.mtime.nanoseconds, st.ctime.nanoseconds)) continue;
        try out.append(a, hay.path);
    }
}

test "needsLiveRead elides only when both clocks strictly predate the anchor" {
    const anchor: i128 = 1_000;

    try std.testing.expect(!bulkstat.needsLiveRead(anchor, 999, 999));
    try std.testing.expect(bulkstat.needsLiveRead(anchor, anchor, 999)); // mtime == anchor
    try std.testing.expect(bulkstat.needsLiveRead(anchor, 999, anchor)); // ctime boundary
    try std.testing.expect(bulkstat.needsLiveRead(anchor, null, 999));
    try std.testing.expect(bulkstat.needsLiveRead(anchor, 999, null));
}

test "bulkstat.visitFresh ≡ the stat-based walk over a real tree (old/new metadata, skip-dir, symlink)" {
    if (!bulkstat.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try std.fmt.allocPrint(a, "/tmp/gist_bulkstat_test_{x}", .{@intFromPtr(&threaded)});
    fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root)); // best-effort clean slate from a prior crashed run
    try Dir.cwd().createDirPath(io, root);
    defer fault.spare("remove fixture", Dir.cwd().deleteTree(io, root));

    try Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/sub", .{root}));
    try Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/node_modules", .{root}));

    const files = [_][]const u8{ "old.txt", "new.txt", "sub/new2.txt", "sub/old2.txt", "node_modules/fresh_but_skipped.txt" };
    for (files) |f| {
        try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, f }), .data = "x" });
    }
    try Dir.cwd().symLink(io, "new.txt", try std.fmt.allocPrint(a, "{s}/link.txt", .{root}), .{});

    // Anchor sits strictly between "old" and "new": old files predate the
    // index build, new files (incl. the skip-dir's, to prove it's excluded
    // on NAME alone, not by accident of metadata) postdate it.
    const anchor = std.Io.Timestamp.now(io, .real);
    try io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .real);
    const built_ns: i128 = anchor.nanoseconds;
    try io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .real);

    const new_ts = std.Io.Timestamp.now(io, .real);
    for ([_][]const u8{ "new.txt", "sub/new2.txt", "node_modules/fresh_but_skipped.txt" }) |f| {
        try Dir.cwd().setTimestamps(io, try std.fmt.allocPrint(a, "{s}/{s}", .{ root, f }), .{
            .modify_timestamp = .init(new_ts),
        });
    }

    var got_bulk: std.ArrayList([]const u8) = .empty;
    var dir = try Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    bulkstat.visitFresh(a, io, dir, root, built_ns, &got_bulk);

    var got_stat: std.ArrayList([]const u8) = .empty;
    try statWalk(a, io, root, built_ns, &got_stat);

    std.mem.sort([]const u8, got_bulk.items, {}, cmpStrings);
    std.mem.sort([]const u8, got_stat.items, {}, cmpStrings);

    // `expectEqualSlices([]const u8, …)` compares slice headers (ptr+len), not
    // string CONTENT — `got_bulk`/`got_stat` are two independently-allocated
    // arenas, so a pointer-based check always "fails" even on byte-identical
    // paths. Compare bytes explicitly.
    try std.testing.expectEqual(got_stat.items.len, got_bulk.items.len);
    for (got_stat.items, got_bulk.items) |s, b| try std.testing.expectEqualStrings(s, b);

    // Pin the expected shape too (not just "the two agree with each other" —
    // they could both be wrong the same way): exactly the two new files,
    // never the skip-dir's, never the old ones, never the symlink.
    const want = [_][]const u8{
        try std.fmt.allocPrint(a, "{s}/new.txt", .{root}),
        try std.fmt.allocPrint(a, "{s}/sub/new2.txt", .{root}),
    };
    try std.testing.expectEqual(@as(usize, want.len), got_bulk.items.len);
    for (want) |w| {
        var found = false;
        for (got_bulk.items) |g| if (std.mem.eql(u8, g, w)) {
            found = true;
            break;
        };
        try std.testing.expect(found);
    }
}

test "bulkstat.BulkDir reads name/type/mtime/ctime directly off a small directory" {
    if (!bulkstat.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&buf, "/tmp/gist_bulkdir_test_{x}", .{@intFromPtr(&threaded)});
    fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));
    try Dir.cwd().createDirPath(io, root);
    defer fault.spare("remove fixture", Dir.cwd().deleteTree(io, root));

    var path_buf: [96]u8 = undefined;
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/hello.txt", .{root}), .data = "hi" });
    try Dir.cwd().createDirPath(io, try std.fmt.bufPrint(&path_buf, "{s}/childdir", .{root}));

    var dir = try Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var bd = bulkstat.BulkDir.init(dir.handle);

    var saw_file = false;
    var saw_dir = false;
    while (try bd.next()) |e| {
        if (std.mem.eql(u8, e.name, "hello.txt")) {
            try std.testing.expect(e.is_file);
            try std.testing.expect(!e.is_dir);
            try std.testing.expect(e.mtime_ns.? > 0);
            try std.testing.expect(e.ctime_ns.? > 0);
            saw_file = true;
        } else if (std.mem.eql(u8, e.name, "childdir")) {
            try std.testing.expect(e.is_dir);
            try std.testing.expect(!e.is_file);
            saw_dir = true;
        }
    }
    try std.testing.expect(saw_file);
    try std.testing.expect(saw_dir);
}

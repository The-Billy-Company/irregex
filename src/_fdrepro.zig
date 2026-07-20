//! TEMP repro — isolated fd-transport serve test. Delete after diagnosis.
const std = @import("std");
const serve = @import("surface/face/gist/daemon/serve/serve.zig");
const protocol = @import("surface/exec/session/protocol.zig");
const request = @import("surface/exec/session/request.zig");
const shm = @import("surface/exec/session/shm.zig");
const net = std.Io.net;
const Dir = std.Io.Dir;

const DaemonArgs = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
    socket: []const u8,
};

fn daemonMain(args: DaemonArgs) void {
    serve.run(args.gpa, args.io, args.roots, args.socket) catch {};
}

fn dial(io: std.Io, socket: []const u8) !net.Stream {
    const ua = try net.UnixAddress.init(socket);
    var attempt: usize = 0;
    while (attempt < 1000) : (attempt += 1) {
        if (ua.connect(io)) |s| return s else |_| {}
        try io.sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .real);
    }
    return error.DaemonNeverCameUp;
}

const FdLinesAnswer = struct { out: []const u8, matched: bool, via_fd: bool };

fn collectLinesFd(gpa: std.mem.Allocator, fd: std.posix.fd_t, arena: std.mem.Allocator, req: request.Request) !FdLinesAnswer {
    var qbuf: std.ArrayList(u8) = .empty;
    defer qbuf.deinit(gpa);
    try protocol.encodeQuery(&qbuf, gpa, req);
    try std.testing.expect(protocol.writeAll(fd, qbuf.items));

    var out: std.ArrayList(u8) = .empty;
    while (true) {
        const got = try protocol.recvFrameWithFd(gpa, fd);
        var resp = got.frame;
        defer resp.deinit();
        switch (resp.op) {
            .chunk => {
                if (got.passed_fd) |p| _ = std.c.close(p);
                try out.appendSlice(arena, resp.payload());
            },
            .chunk_fd => {
                const cf = try protocol.decodeChunkFd(resp.payload());
                const shm_fd = got.passed_fd orelse return error.MissingPassedFd;
                defer _ = std.c.close(shm_fd);
                const len: usize = @intCast(cf.length);
                if (len > 0) {
                    const view = try shm.mapReadonly(shm_fd, len);
                    defer shm.unmap(view);
                    try out.appendSlice(arena, view[0..len]);
                }
                return .{ .out = out.items, .matched = cf.matched, .via_fd = true };
            },
            .result => {
                if (got.passed_fd) |p| _ = std.c.close(p);
                return switch (try protocol.decodeResult(resp.payload())) {
                    .lines => |m| .{ .out = out.items, .matched = m, .via_fd = false },
                    else => error.UnexpectedResultMode,
                };
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn handshakeCaps(gpa: std.mem.Allocator, fd: std.posix.fd_t, caps: u8) !void {
    try protocol.sendFrame(gpa, fd, .hello, &.{ protocol.protocol_version, caps });
    var ready = try protocol.recvFrame(gpa, fd);
    defer ready.deinit();
    try std.testing.expectEqual(protocol.Opcode.ready, ready.op);
}

test "REPRO fd-transport" {
    if (!shm.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try std.fmt.allocPrint(a, "/tmp/gist_fdr_{x}", .{@intFromPtr(&threaded)});
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    defer Dir.cwd().deleteTree(io, root) catch {};

    const line = "needle payload widening each rendered row past the fd-transport floor\n";
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    var rendered_estimate: usize = 0;
    while (rendered_estimate <= protocol.fd_transport_floor * 2) : (rendered_estimate += root.len + 9 + line.len)
        try big.appendSlice(gpa, line);
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/big.txt", .{root}), .data = big.items });
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/small.txt", .{root}), .data = "needle once\n" });

    const socket = try std.fmt.allocPrint(a, "{s}/gistd.sock", .{root});
    const roots = try a.dupe([]const u8, &.{root});

    const t = try std.Thread.spawn(.{}, daemonMain, .{DaemonArgs{ .gpa = gpa, .io = io, .roots = roots, .socket = socket }});
    defer t.join();
    defer shm.force_fail_for_test.store(false, .monotonic);
    // Ensure the daemon stops so join() returns even if an assert fires early.
    defer {
        if (dial(io, socket)) |s| {
            protocol.sendFrame(gpa, s.socket.handle, .shutdown, "") catch {};
            s.close(io);
        } else |_| {}
    }

    const q = request.Request{ .pattern = "payload", .mode = .lines, .fixed = true };

    const fd_out = blk: {
        const s = try dial(io, socket);
        defer s.close(io);
        try handshakeCaps(gpa, s.socket.handle, protocol.caps_supported);
        const big_ans = try collectLinesFd(gpa, s.socket.handle, a, q);
        std.debug.print("via_fd={} matched={} len={}\n", .{ big_ans.via_fd, big_ans.matched, big_ans.out.len });
        try std.testing.expect(big_ans.via_fd);
        try std.testing.expect(big_ans.matched);
        try std.testing.expect(big_ans.out.len >= protocol.fd_transport_floor);
        const small = try collectLinesFd(gpa, s.socket.handle, a, .{ .pattern = "once", .mode = .lines, .fixed = true });
        try std.testing.expect(!small.via_fd);
        try std.testing.expect(std.mem.endsWith(u8, small.out, "small.txt:needle once\n"));
        break :blk try a.dupe(u8, big_ans.out);
    };

    {
        const s = try dial(io, socket);
        defer s.close(io);
        try handshakeCaps(gpa, s.socket.handle, 0);
        const ans = try collectLinesFd(gpa, s.socket.handle, a, q);
        try std.testing.expect(!ans.via_fd);
        try std.testing.expectEqualSlices(u8, fd_out, ans.out);
    }

    {
        shm.force_fail_for_test.store(true, .monotonic);
        const s = try dial(io, socket);
        defer s.close(io);
        try handshakeCaps(gpa, s.socket.handle, protocol.caps_supported);
        const ans = try collectLinesFd(gpa, s.socket.handle, a, q);
        try std.testing.expect(!ans.via_fd);
        try std.testing.expectEqualSlices(u8, fd_out, ans.out);
        shm.force_fail_for_test.store(false, .monotonic);
    }
}

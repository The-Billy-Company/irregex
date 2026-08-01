//! The hosted API facade (`api.zig`) over a REAL warm tree.
//!
//! These drive `api.Engine` through live syscalls, exactly as the resident
//! suite does, and pin the *expected* record shape — not a self-run of the
//! engine. They prove the four hosted invariants the internal tiers don't
//! themselves guarantee at this boundary: (1) `search` yields owned records in
//! cold's deterministic path order and `next`/`nextBatch` are two views of one
//! buffer, (2) the `max_results` budget stops at a record boundary while still
//! reporting `anyMatched`, (3) a cooperative cancel yields a clean empty result
//! (never a crash), and (4) an unsupported pattern comes back as a NAMED
//! declinature on the success channel — never a fatal `die()`, and never an
//! error a caller could `try` past.

const std = @import("std");
const api = @import("api.zig");
const fault = @import("../fault.zig");
const Dir = std.Io.Dir;

/// A throwaway on-disk tree with an absolute root — no test touches the cwd.
const Tree = struct {
    root: []const u8,
    io: std.Io,
    a: std.mem.Allocator,

    fn init(a: std.mem.Allocator, io: std.Io, seed: usize) !Tree {
        const root = try std.fmt.allocPrint(a, "/tmp/gist_api_{x}", .{seed});
        fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));
        try Dir.cwd().createDirPath(io, root);
        return .{ .root = root, .io = io, .a = a };
    }

    fn deinit(self: *Tree) void {
        fault.spare("remove fixture", Dir.cwd().deleteTree(self.io, self.root));
    }

    fn write(self: *Tree, rel: []const u8, data: []const u8) !void {
        const p = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
        try Dir.cwd().writeFile(self.io, .{ .sub_path = p, .data = data });
    }
};

/// Stand up an engine over a fixture tree with two known files (3 matching
/// lines of the literal "needle", in path order a.txt → b.txt).
fn openFixture(gpa: std.mem.Allocator, threaded: *std.Io.Threaded, fixture: *std.heap.ArenaAllocator, tree: *Tree) !*api.Engine {
    const io = threaded.io();
    tree.* = try Tree.init(fixture.allocator(), io, @intFromPtr(threaded));
    try tree.write("a.txt", "alpha\nneedle one\n"); // 1 matching line (line 2)
    try tree.write("b.txt", "needle two\nneedle three\n"); // 2 matching lines
    try tree.write("c.txt", "no match here\n"); // 0
    return api.Engine.open(gpa, &.{tree.root});
}

test "api: search yields owned records in path order; next and nextBatch agree" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    var tree: Tree = undefined;

    var engine = try openFixture(gpa, &threaded, &fixture, &tree);
    defer engine.close();
    defer tree.deinit();

    const cur = (try engine.search(.{ .pattern = "needle", .fixed = true }, .{})).got;
    defer cur.deinit();

    try std.testing.expectEqual(@as(usize, 3), cur.count());
    try std.testing.expect(cur.anyMatched());

    // next(): the first record is a.txt line 2, the literal at column 1.
    const first = cur.next().?;
    try std.testing.expect(std.mem.endsWith(u8, first.path, "a.txt"));
    try std.testing.expectEqual(@as(u64, 2), first.line_number);
    try std.testing.expectEqualStrings("needle one", first.text);
    try std.testing.expectEqual(api.MatchKind.match, first.kind);
    try std.testing.expectEqual(@as(usize, 1), first.column());

    // …and the remaining two are b.txt's lines, in order.
    const second = cur.next().?;
    try std.testing.expect(std.mem.endsWith(u8, second.path, "b.txt"));
    try std.testing.expectEqualStrings("needle two", second.text);
    const third = cur.next().?;
    try std.testing.expectEqualStrings("needle three", third.text);
    try std.testing.expectEqual(@as(?api.OwnedMatch, null), cur.next());

    // nextBatch() over a rewound cursor is the same three records, chunked.
    cur.reset();
    var buf: [2]api.OwnedMatch = undefined;
    try std.testing.expectEqual(@as(usize, 2), cur.nextBatch(&buf));
    try std.testing.expectEqualStrings("needle one", buf[0].text);
    try std.testing.expectEqualStrings("needle two", buf[1].text);
    try std.testing.expectEqual(@as(usize, 1), cur.nextBatch(&buf));
    try std.testing.expectEqualStrings("needle three", buf[0].text);
    try std.testing.expectEqual(@as(usize, 0), cur.nextBatch(&buf));
}

test "api: a max_results budget stops at a record boundary but still reports matched" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    var tree: Tree = undefined;

    var engine = try openFixture(gpa, &threaded, &fixture, &tree);
    defer engine.close();
    defer tree.deinit();

    const cur = (try engine.search(.{ .pattern = "needle", .fixed = true }, .{ .max_results = 1 })).got;
    defer cur.deinit();

    try std.testing.expectEqual(@as(usize, 1), cur.count());
    try std.testing.expect(cur.anyMatched());
    try std.testing.expectEqualStrings("needle one", cur.next().?.text);
}

test "api: a pre-cancelled token yields a clean empty result, not a crash" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    var tree: Tree = undefined;

    var engine = try openFixture(gpa, &threaded, &fixture, &tree);
    defer engine.close();
    defer tree.deinit();

    var token = api.CancelToken{};
    token.cancel();
    const cur = (try engine.search(.{ .pattern = "needle", .fixed = true }, .{ .cancel = &token })).got;
    defer cur.deinit();

    try std.testing.expectEqual(@as(usize, 0), cur.count());
}

// The compose namespace (exact ∩ compression) moved to the `relate`
// package with its kernels; that package's own wiring pins reachability now.

test "api: an unsupported pattern declines with a named reason, never fatal" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    var tree: Tree = undefined;

    var engine = try openFixture(gpa, &threaded, &fixture, &tree);
    defer engine.close();
    defer tree.deinit();

    // A lookahead is outside the linear-time syntax. The fact reaches the
    // embedder on the DECLINATURE channel, naming the tier that can answer —
    // not as an error, so no `try` can mistake "run this cold" for a failure.
    const answered = try engine.search(.{ .pattern = "needle(?=X)" }, .{});
    try std.testing.expectEqual(fault.Decline.unsupported_syntax, answered.declined);
}

//! Adversarial unit suite for the artifact home's anchor (`home.seek`).
//!
//! The property under test is not "which string comes back" — it is that ONE
//! TREE HAS ONE HOME. The old CWD-relative resolution satisfied the only
//! invariant anyone had written down (two trees cannot collide) while quietly
//! breaking the one nobody had: a search from `services/ai` and a search from
//! the tree root built two indexes and ran two daemons over the same files, and
//! parked a `gistd.sock` in whichever source directory happened to be current.
//! So the central test compares the RESOLVED ABSOLUTE directory reached from two
//! depths rather than comparing the two answers as text — `realpath` folds the
//! `../` legs through real directories, where an equality of strings would only
//! restate the arithmetic the implementation already did.
//!
//! Expectations are built from `home.default_out_dir` rather than spelling
//! `.gist`, because an embedder that rebrands the ecosystem moves that name and
//! this suite is about the CLIMB, not about what the directory is called.

const std = @import("std");
const home = @import("home.zig");
const frame = @import("frame.zig");
const portal = @import("../../../portal.zig");
const Dir = std.Io.Dir;

const dir_name = home.default_out_dir;

/// A scratch checkout under `/tmp`, torn down with the test. `/tmp` rather than
/// a directory inside this repository on purpose: a fixture nested in a real
/// checkout inherits this package's own `.git`, and the ceiling test below needs
/// an ancestry it fully controls.
const Fixture = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,

    fn init(gpa: std.mem.Allocator, threaded: *std.Io.Threaded, name: []const u8) !Fixture {
        const io = threaded.io();
        const root = try std.fmt.allocPrint(gpa, "/tmp/gist_home_{s}_{x}", .{ name, @intFromPtr(threaded) });
        Dir.cwd().deleteTree(io, root) catch {};
        try Dir.cwd().createDirPath(io, root);
        return .{ .gpa = gpa, .io = io, .root = root };
    }

    fn deinit(f: *Fixture) void {
        Dir.cwd().deleteTree(f.io, f.root) catch {};
        f.gpa.free(f.root);
    }

    fn mkdirp(f: Fixture, rel: []const u8) !void {
        var buf: [portal.max_path]u8 = undefined;
        try Dir.cwd().createDirPath(f.io, try std.fmt.bufPrint(&buf, "{s}/{s}", .{ f.root, rel }));
    }

    fn put(f: Fixture, rel: []const u8, bytes: []const u8) !void {
        var buf: [portal.max_path]u8 = undefined;
        try frame.writeAtomic(f.io, try std.fmt.bufPrint(&buf, "{s}/{s}", .{ f.root, rel }), bytes);
    }

    /// A handle on `<root>/<rel>` — the directory `seek` climbs from.
    fn at(f: Fixture, rel: []const u8) !portal.Handle {
        var buf: [portal.max_path]u8 = undefined;
        return portal.openDir(portal.cwd(), try std.fmt.bufPrint(&buf, "{s}/{s}", .{ f.root, rel }));
    }

    /// Where an answer given from `<root>/<rel>` actually lands, canonicalized.
    fn lands(f: Fixture, rel: []const u8, found: []const u8, buf: *[portal.max_path]u8) ![]const u8 {
        var pathz: [portal.max_path]u8 = undefined;
        const p = try std.fmt.bufPrintZ(&pathz, "{s}/{s}/{s}", .{ f.root, rel, found });
        return portal.realpath(p, buf) orelse error.Unresolvable;
    }
};

test "the ascent names exactly the levels asked for" {
    var buf: [home.min_buf]u8 = undefined;
    try std.testing.expectEqualStrings("", home.ascent(&buf, 0));
    try std.testing.expectEqualStrings("../", home.ascent(&buf, 1));
    try std.testing.expectEqualStrings("../../../", home.ascent(&buf, 3));
}

test "one tree, one home — however deep in it you were standing" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var fx = try Fixture.init(gpa, &threaded, "onetree");
    defer fx.deinit();

    try fx.mkdirp(".git");
    try fx.mkdirp(dir_name);
    try fx.mkdirp("services/ai/deep");
    try fx.mkdirp("clients");

    const deep = try fx.at("services/ai/deep");
    defer portal.close(deep);
    const shallow = try fx.at("clients");
    defer portal.close(shallow);

    var a: [home.min_buf]u8 = undefined;
    var b: [home.min_buf]u8 = undefined;
    const from_deep = home.seek(deep, &a);
    const from_shallow = home.seek(shallow, &b);

    // Different ascents, one directory — the whole point of the change.
    var pa: [portal.max_path]u8 = undefined;
    var pb: [portal.max_path]u8 = undefined;
    const landed_deep = try fx.lands("services/ai/deep", from_deep, &pa);
    try std.testing.expectEqualStrings(landed_deep, try fx.lands("clients", from_shallow, &pb));

    // And it is the TREE's directory, not a fresh one beside either caller.
    try std.testing.expectEqualStrings(landed_deep, try fx.lands("", dir_name, &pb));
}

test "a `.git` file is an edge too — a worktree is still a checkout" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var fx = try Fixture.init(gpa, &threaded, "worktree");
    defer fx.deinit();

    // A linked worktree records a POINTER where a repository keeps a directory.
    // Probing by `open` is what makes the two indistinguishable; probing by "is
    // it a directory" would walk straight past every worktree on the machine.
    try fx.put(".git", "gitdir: /elsewhere/.git/worktrees/w\n");
    try fx.mkdirp("pkg/sub");

    const at = try fx.at("pkg/sub");
    defer portal.close(at);
    var buf: [home.min_buf]u8 = undefined;
    try std.testing.expectEqualStrings("../../" ++ dir_name, home.seek(at, &buf));
}

test "an artifact directory already placed is adopted before the boundary" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var fx = try Fixture.init(gpa, &threaded, "adopt");
    defer fx.deinit();

    // The checkout's edge is at the root, but a nested workspace has planted its
    // own home halfway down. A placement is a decision — it outranks the
    // boundary, which is the only way to opt a subtree out.
    try fx.mkdirp(".git");
    try fx.mkdirp("nested/" ++ dir_name);
    try fx.mkdirp("nested/src");

    const at = try fx.at("nested/src");
    defer portal.close(at);
    var buf: [home.min_buf]u8 = undefined;
    const found = home.seek(at, &buf);
    try std.testing.expectEqualStrings("../" ++ dir_name, found);

    var pa: [portal.max_path]u8 = undefined;
    var pb: [portal.max_path]u8 = undefined;
    try std.testing.expectEqualStrings(
        try fx.lands("nested", dir_name, &pa),
        try fx.lands("nested/src", found, &pb),
    );
}

test "a boundary past the ceiling is not found, and the walk stays where it stood" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var fx = try Fixture.init(gpa, &threaded, "ceiling");
    defer fx.deinit();

    // One level further down than the climb is allowed to look. The fallback is
    // reachable ONLY this way on purpose: "no boundary anywhere above" is a
    // claim about the machine's root directory, not about this code.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(gpa);
    for (0..home.max_climb + 1) |_| try deep.appendSlice(gpa, "d/");
    try fx.mkdirp(".git");
    try fx.mkdirp(deep.items);

    const at = try fx.at(deep.items);
    defer portal.close(at);
    var buf: [home.min_buf]u8 = undefined;
    try std.testing.expectEqualStrings(dir_name, home.seek(at, &buf));
}

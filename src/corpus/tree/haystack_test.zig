//! Haystack unit tests — split from `haystack.zig` (shape cap). No filesystem
//! touched: `Walker` itself is exercised indirectly by every corpus caller's
//! own tests plus the CLI (`gist index`/`search`/`--live`) against the real
//! repo tree; these pin the two pure hot-path decisions `Walker` leans on.

const std = @import("std");
const haystack = @import("haystack.zig");

/// The pre-`StaticStringMap` reference: a plain linear scan over the exact
/// same 35-name list. `isSkipDir`'s speedup must never change WHICH names are
/// skipped — this differential is the guardrail. (Project-specific extras ride
/// `GIST_SKIP` at runtime and are deliberately absent here.)
const skip_list = [_][]const u8{
    ".git",          ".github",     ".hg",           ".svn",          "node_modules",
    "target",        "dist",        "dist-types",    "build",         ".build",
    "out",           ".next",       "coverage",      ".venv",         "venv",
    "site-packages", "__pycache__", ".pytest_cache", ".mypy_cache",   ".ruff_cache",
    ".zig-cache",    "zig-out",     "zig-pkg",       ".cache",        ".local",
    ".turbo",        "vendor",      ".swiftpm",      "Pods",          "DerivedData",
    ".cursor",       ".idea",       ".vscode",       ".parcel-cache", ".pnpm-store",
};
fn isSkipDirLinear(name: []const u8) bool {
    for (skip_list) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

test "isSkipDir: every entry in the skip list is skipped" {
    for (skip_list) |name| try std.testing.expect(haystack.isSkipDir(name));
}

test "isSkipDir: near-misses (prefix/suffix/case/substring) are NOT skipped" {
    const near_misses = [_][]const u8{
        "git",           ".gitx",   "gitt",    ".GIT",  "targets",
        "ta",            "builds",  ".buildx", "outer", "node_module",
        "node_modules2", "vendors", "cache",   ".cach", "",
        "graphify-out", // was a hardcoded Billy-ism; now GIST_SKIP territory
    };
    for (near_misses) |name| try std.testing.expect(!haystack.isSkipDir(name));
}

test "isSkipDir: matches the naive linear scan across a mixed sample" {
    const sample = [_][]const u8{
        "services",     "libs",    "src",     ".git",     "node_modules",
        "commands",     "corpus",  "regex",   "target",   "dist-types",
        "index",        "scan",    "rank",    "vendor",   ".idea",
        "kernels",      "biology", "runtime", "tools",    "neural",
        "graphify-out", "quality", ".turbo",  "internal", "pkg",
        "zig-pkg",
    };
    for (sample) |name| try std.testing.expectEqual(isSkipDirLinear(name), haystack.isSkipDir(name));
}

test "joinPath: byte-identical to `root ++ \"/\" ++ rel` for every shape the walk feeds it" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { root: []const u8, rel: []const u8 }{
        .{ .root = "services", .rel = "backend/gateway/main.go" },
        .{ .root = ".", .rel = "README.md" },
        .{ .root = "libs", .rel = "kernels/irregex/src/corpus/tree/haystack.zig" },
        .{ .root = "a", .rel = "b" },
    };
    for (cases) |c| {
        const got = try haystack.joinPath(gpa, c.root, c.rel);
        defer gpa.free(got);
        const want = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ c.root, c.rel });
        defer gpa.free(want);
        try std.testing.expectEqualStrings(want, got);
    }
}

test "Walker applies nested gitignore precedence to every corpus consumer" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = "/tmp/irregex_haystack_ignore_fixture";

    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/.git");
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/nested");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/.gitignore", .data = "ignored.txt\nnested/*.log\n!nested/keep.log\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/visible.txt", .data = "visible" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/ignored.txt", .data = "ignored" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/nested/ignored.log", .data = "ignored" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/nested/keep.log", .data = "kept" });

    var walker = try haystack.Walker.init(io, a, root);
    defer walker.deinit(io);
    var visible = false;
    var kept = false;
    while (try walker.next(io)) |file| {
        try t.expect(!std.mem.endsWith(u8, file.path, "/ignored.txt"));
        try t.expect(!std.mem.endsWith(u8, file.path, "/ignored.log"));
        visible = visible or std.mem.endsWith(u8, file.path, "/visible.txt");
        kept = kept or std.mem.endsWith(u8, file.path, "/keep.log");
    }
    try t.expect(visible and kept);
}

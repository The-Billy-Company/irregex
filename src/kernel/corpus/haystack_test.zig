//! Haystack unit tests — split from `haystack.zig` (shape cap). No filesystem
//! touched: `Walker` itself is exercised indirectly by every corpus caller's
//! own tests plus the CLI (`gist index`/`search`/`--live`) against the real
//! repo tree; these pin the two pure hot-path decisions `Walker` leans on.

const std = @import("std");
const haystack = @import("haystack.zig");

/// The pre-`StaticStringMap` reference: a plain linear scan over the exact
/// same 35-name list. `isSkipDir`'s speedup must never change WHICH names are
/// skipped — this differential is the guardrail.
const skip_list = [_][]const u8{
    ".git",          ".github",     ".hg",           ".svn",        "node_modules",
    "target",        "dist",        "dist-types",    "build",       ".build",
    "out",           ".next",       "coverage",      ".venv",       "venv",
    "site-packages", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    ".zig-cache",    "zig-out",     ".cache",        ".local",      ".turbo",
    "vendor",        ".swiftpm",    "Pods",          "DerivedData", ".cursor",
    ".idea",         ".vscode",     ".parcel-cache", ".pnpm-store", "graphify-out",
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
    };
    for (sample) |name| try std.testing.expectEqual(isSkipDirLinear(name), haystack.isSkipDir(name));
}

test "joinPath: byte-identical to `root ++ \"/\" ++ rel` for every shape the walk feeds it" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { root: []const u8, rel: []const u8 }{
        .{ .root = "services", .rel = "backend/gateway/main.go" },
        .{ .root = ".", .rel = "README.md" },
        .{ .root = "libs", .rel = "kernels/gist/src/kernel/corpus/haystack.zig" },
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

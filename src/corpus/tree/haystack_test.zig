//! Haystack unit tests — split from `haystack.zig` (shape cap). No filesystem
//! touched: `Walker` itself is exercised indirectly by every corpus caller's
//! own tests plus the CLI (`index`/`search`/`--live`) against the real
//! repo tree; these pin the two pure hot-path decisions `Walker` leans on.

const std = @import("std");
const haystack = @import("haystack.zig");
const fault = @import("../../fault.zig");

/// The pre-`StaticStringMap` reference: a plain linear scan over the exact
/// same 36-name list. The comptime-baseline lookup's speedup must never change
/// WHICH names are skipped — this differential is the guardrail, so it pins
/// `inBaselineSkipSet` (the pure map), not the full-policy `isSkipDir`.
/// Project-specific extras ride the runtime `<prefix>SKIP`/`skips.list` overlay
/// and are deliberately absent from the baseline the guardrail compares.
const skip_list = [_][]const u8{
    ".git",          ".github",     ".hg",           ".svn",          "node_modules",
    "target",        "dist",        "dist-types",    "build",         ".build",
    "out",           ".next",       "coverage",      ".venv",         "venv",
    "site-packages", "__pycache__", ".pytest_cache", ".mypy_cache",   ".ruff_cache",
    ".zig-cache",    "zig-out",     "zig-pkg",       ".cache",        ".local",
    ".turbo",        "vendor",      ".swiftpm",      "Pods",          "DerivedData",
    ".cursor",       ".idea",       ".vscode",       ".parcel-cache", ".pnpm-store",
    ".gist",
};
fn isSkipDirLinear(name: []const u8) bool {
    for (skip_list) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

test "skip-dir baseline: every entry in the skip list is skipped" {
    for (skip_list) |name| try std.testing.expect(haystack.inBaselineSkipSet(name));
}

test "skip-dir baseline: near-misses (prefix/suffix/case/substring) are NOT skipped" {
    const near_misses = [_][]const u8{
        "git",           ".gitx",   "gitt",    ".GIT",  "targets",
        "ta",            "builds",  ".buildx", "outer", "node_module",
        "node_modules2", "vendors", "cache",   ".cach", "",
        "gist",          ".gistx",  ".GIST",   ".gis",
        "derived-out", // a per-tree output dir: overlay territory, never baseline
    };
    for (near_misses) |name| try std.testing.expect(!haystack.inBaselineSkipSet(name));
}

test "skip-dir baseline: the engine never indexes its own artifact home" {
    // The artifact directory is where the trigram index, kinship atlas, shelf,
    // freshness anchor, and daemon socket live, and it sits inside the walk root
    // by default — so a corpus walk that entered it would be indexing its own
    // exhaust, and every index build would grow the corpus it just measured.
    // It is baseline, not overlay: it holds for any tree, with no charter —
    // which is why this asserts the pure map rather than `isSkipDir`, whose
    // answer would also be true for a machine that merely seeded it.
    try std.testing.expect(haystack.inBaselineSkipSet(".gist"));
}

test "policy skip is the charter/env overlay, not the generic baseline" {
    // `.git` is baseline-only — cold `-uu` must still enter it (rg parity), and
    // the baseline never doubles as the overlay. A per-tree output directory
    // like `derived-out` is the overlay's business only: the baseline must not
    // carry it, so no clone of an unrelated tree inherits another tree's
    // folklore as if it were a universal convention.
    try std.testing.expect(haystack.inBaselineSkipSet(".git"));
    try std.testing.expect(!haystack.isPolicySkip(".git"));
    try std.testing.expect(!haystack.inBaselineSkipSet("derived-out"));

    // The overlay half is NOT asserted here on purpose. `isPolicySkip` reads
    // whatever the ambient charter, `<prefix>SKIP`, and `<prefix>DIR/skips.list`
    // happen to say, so any claim about a specific name here is a claim about
    // the machine, not the code: it goes vacuous in a checkout with no charter
    // and answers out of an unrelated repository whenever `<prefix>DIR` is
    // inherited from one. `charter_test.zig` drives that path properly, from a
    // charter it writes itself.
}

test "skip-dir baseline: matches the naive linear scan across a mixed sample" {
    const sample = [_][]const u8{
        "services",    "lib",      "src",     ".git",     "node_modules",
        "commands",    "corpus",   "regex",   "target",   "dist-types",
        "index",       "scan",     "rank",    "vendor",   ".idea",
        "kernel",      "bindings", "runtime", "tools",    "research",
        "derived-out", "quality",  ".turbo",  "internal", "pkg",
        "zig-pkg",     ".gist",    "gist",    "upstream",
    };
    for (sample) |name| try std.testing.expectEqual(isSkipDirLinear(name), haystack.inBaselineSkipSet(name));
}

test "joinPath: byte-identical to `root ++ \"/\" ++ rel` for every shape the walk feeds it" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { root: []const u8, rel: []const u8 }{
        .{ .root = "services", .rel = "backend/gateway/main.go" },
        .{ .root = ".", .rel = "README.md" },
        .{ .root = "lib", .rel = "irregex/src/corpus/tree/haystack.zig" },
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

    // The claim is about gitignore precedence, so the skip overlay is held at
    // the baseline: an operator whose policy names `nested` would prune the
    // very directory whose `keep.log` negation this proves.
    const scope = haystack.stateSkipOverlay(.none);
    defer scope.release();

    fault.spare("clear leftover fixture", std.Io.Dir.cwd().deleteTree(io, root));
    defer fault.spare("remove fixture", std.Io.Dir.cwd().deleteTree(io, root));
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

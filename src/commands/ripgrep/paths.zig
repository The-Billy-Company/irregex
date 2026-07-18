//! gist `rg` — the one path-string vocabulary shared by the serial engine
//! (`run.zig`), the parallel pipeline (`pipeline.zig`), and the ignore
//! protocol (`ignore.zig`).
//!
//! These four helpers used to live as per-file copies; any drift between the
//! copies was a parity bug by construction (the serial and parallel engines
//! must render, strip, and depth-count paths identically for byte-identical
//! output and ignore verdicts). One definition each makes drift impossible.

const std = @import("std");
const oom = @import("args.zig").oom;

/// Drop a leading `./` (or a bare `.`) so a `./root` positional's paths compare
/// against ignore rules / index keys the same as a bare `root` positional's do.
pub fn stripDot(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "./")) return s[2..];
    if (std.mem.eql(u8, s, ".")) return "";
    return s;
}

/// Component depth of an explicit positional root (`Ignore.scopeToRoot`'s
/// rule): `""`/`"."` → 0 (the implicit whole-CWD walk), else 1 + slash count
/// after any `./` prefixes are peeled.
pub fn rootDepth(prefix: []const u8) usize {
    var s = prefix;
    while (std.mem.startsWith(u8, s, "./")) s = s[2..];
    if (s.len == 0 or std.mem.eql(u8, s, ".")) return 0;
    return std.mem.count(u8, s, "/") + 1;
}

/// On-disk (openable) join: a `""`/`.` dir contributes no prefix, so the name
/// stays CWD-relative exactly as the walker discovered it.
pub fn join(a: std.mem.Allocator, dir: []const u8, name: []const u8) []const u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return name;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch oom();
}

/// ASCII-lowered copy of `s` — the one case fold shared by the `--iglob`
/// caseless glob path (`args.zig`) and git's case-insensitive config keys /
/// ignore homes (`ignore.zig`). Byte-wise ASCII on purpose: gitignore and
/// glob folding are defined over bytes, never Unicode.
pub fn lowerDup(a: std.mem.Allocator, s: []const u8) []u8 {
    const o = a.alloc(u8, s.len) catch oom();
    for (s, 0..) |c, i| o[i] = std.ascii.toLower(c);
    return o;
}

/// Replace every `/` in `path` with the (arbitrary-length) `sep` string for
/// `--path-separator`. Returns `path` unchanged when it has no separator.
pub fn replaceSep(a: std.mem.Allocator, path: []const u8, sep: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/') == null) return path;
    var out: std.ArrayList(u8) = .empty;
    for (path) |c| {
        if (c == '/') out.appendSlice(a, sep) catch oom() else out.append(a, c) catch oom();
    }
    return out.toOwnedSlice(a) catch oom();
}

test "stripDot peels one ./ and collapses bare dot" {
    const t = std.testing;
    try t.expectEqualStrings("a/b", stripDot("./a/b"));
    try t.expectEqualStrings("", stripDot("."));
    try t.expectEqualStrings("a/b", stripDot("a/b"));
}

test "rootDepth counts components under any ./ prefix" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), rootDepth(""));
    try t.expectEqual(@as(usize, 0), rootDepth("."));
    try t.expectEqual(@as(usize, 0), rootDepth("././."));
    try t.expectEqual(@as(usize, 1), rootDepth("services"));
    try t.expectEqual(@as(usize, 3), rootDepth("./a/b/c"));
}

test "join elides an empty or dot dir" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("x", join(a, "", "x"));
    try t.expectEqualStrings("x", join(a, ".", "x"));
    try t.expectEqualStrings("d/x", join(a, "d", "x"));
}

test "replaceSep rewrites every slash, multi-byte seps included" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("a::b::c", replaceSep(a, "a/b/c", "::"));
    try t.expectEqualStrings("plain", replaceSep(a, "plain", "::"));
}

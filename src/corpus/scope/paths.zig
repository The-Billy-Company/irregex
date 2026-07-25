//! irregex — the path-string vocabulary shared by corpus traversal, gist's
//! serial/parallel engines, and the gitignore protocol.
//!
//! These helpers used to live as per-file copies; any drift between the
//! copies was a parity bug by construction (the serial and parallel engines
//! must render, strip, and depth-count paths identically for byte-identical
//! output and ignore verdicts). One definition each makes drift impossible.

const std = @import("std");
const assay = @import("../../assay/assay.zig");

/// The one OOM diagnostic. `allocFailure` below is the single emitter — the CLI
/// reaches it as `outcome.oom`, so the corpus layer and the CLI have nothing
/// left to drift between. Routed through assay so a `dark`/`buffer` sink honors
/// the never-write contract (ADR-373 law 6).
pub const oom_notice =
    \\oom: allocation failed
    \\gist: note: scope the query (PATH / -t / -g) or raise the process memory limit
    \\
;

pub fn allocFailure() noreturn {
    assay.diag(oom_notice, .{});
    std.process.exit(2);
}

/// Drop a leading `./` (or a bare `.`) so a `./root` positional's paths compare
/// against ignore rules / index keys the same as a bare `root` positional's do.
pub fn stripDot(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "./")) return s[2..];
    return if (std.mem.eql(u8, s, ".")) "" else s;
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

/// Path spelling globs should inspect: relative to CWD when an absolute
/// positional root sits beneath it, otherwise unchanged. Output keeps its
/// original absolute spelling; this view exists only for `-g`/`-t` admission.
pub fn cwdRelative(a: std.mem.Allocator, io: std.Io, path: []const u8) []const u8 {
    if (!std.fs.path.isAbsolute(path)) return path;
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", a) catch return path;
    if (std.mem.eql(u8, path, cwd)) return "";
    if (path.len > cwd.len and std.mem.startsWith(u8, path, cwd) and path[cwd.len] == '/')
        return path[cwd.len + 1 ..];
    return path;
}

/// On-disk (openable) join: a `""`/`.` dir contributes no prefix, so the name
/// stays CWD-relative exactly as the walker discovered it.
///
/// Returns `error.OutOfMemory` rather than calling `allocFailure` because this
/// is the one path helper the **library** reaches: every ignore-tier load under
/// `corpus/tree/ignore.zig` joins through here, and those run inside
/// `irregex_open` / `irregex_search`, where exiting the process is not a
/// failure mode a host can survive (ADR-373 law 1). Its two siblings below
/// still exit: `lowerDup` is only reached under case-insensitive ignore
/// matching and `replaceSep` only under `--path-separator`, neither of which
/// the C seam can select, so both remain command-plane-only.
pub fn join(a: std.mem.Allocator, dir: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return name;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

/// ASCII-lowered copy of `s` — the one case fold shared by the `--iglob`
/// caseless glob path (`args.zig`) and git's case-insensitive config keys /
/// ignore homes (`ignore.zig`). Byte-wise ASCII on purpose: gitignore and
/// glob folding are defined over bytes, never Unicode.
pub fn lowerDup(a: std.mem.Allocator, s: []const u8) []u8 {
    const o = a.alloc(u8, s.len) catch allocFailure();
    for (s, 0..) |c, i| o[i] = std.ascii.toLower(c);
    return o;
}

/// POSIX `realpath(3)` into an `a`-owned copy; null when unresolvable
/// (dangling symlink, permission, name too long). On macOS this also
/// canonicalizes ASCII case and `/tmp`-style firmlinks — the aliasing
/// oracle both the `-L` cycle walk and the warm session's delta resolver use.
pub fn realpathAlloc(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const cpath = std.posix.toPosixPath(path) catch return null;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const resolved = std.c.realpath(&cpath, &buf) orelse return null;
    return a.dupe(u8, std.mem.sliceTo(resolved, 0)) catch null;
}

/// Replace every `/` in `path` with the (arbitrary-length) `sep` string for
/// `--path-separator`. Returns `path` unchanged when it has no separator.
pub fn replaceSep(a: std.mem.Allocator, path: []const u8, sep: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/') == null) return path;
    var out: std.ArrayList(u8) = .empty;
    for (path) |c| (if (c == '/') out.appendSlice(a, sep) else out.append(a, c)) catch allocFailure();
    return out.toOwnedSlice(a) catch allocFailure();
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
    try t.expectEqualStrings("x", try join(a, "", "x"));
    try t.expectEqualStrings("x", try join(a, ".", "x"));
    try t.expectEqualStrings("d/x", try join(a, "d", "x"));
}

test "replaceSep rewrites every slash, multi-byte seps included" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("a::b::c", replaceSep(a, "a/b/c", "::"));
    try t.expectEqualStrings("plain", replaceSep(a, "plain", "::"));
}

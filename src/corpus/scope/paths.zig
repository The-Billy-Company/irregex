//! irregex — the path-string vocabulary shared by corpus traversal, gist's
//! serial/parallel engines, and the gitignore protocol.
//!
//! These helpers used to live as per-file copies; any drift between the
//! copies was a parity bug by construction (the serial and parallel engines
//! must render, strip, and depth-count paths identically for byte-identical
//! output and ignore verdicts). One definition each makes drift impossible.

const std = @import("std");
const assay = @import("../../assay/assay.zig");
const portal = @import("../../portal.zig");

/// The one OOM diagnostic. `allocFailure` below is the single emitter — the CLI
/// reaches it as `outcome.oom`, so the corpus layer and the CLI have nothing
/// left to drift between. Routed through assay so a `dark`/`buffer` sink honors
/// the never-write contract (fault-channel law 6).
pub const oom_notice =
    \\oom: allocation failed
    \\gist: note: scope the query (PATH / -t / -g) or raise the process memory limit
    \\
;

pub fn allocFailure() noreturn {
    assay.diag(oom_notice, .{});
    std.process.exit(2);
}

/// A walker path in gist's separator.
///
/// On a platform that already spells `/` this is the identity — `p` comes back
/// untouched, no allocation, so the seam costs POSIX nothing at all. Only where
/// the separator actually differs does it copy, because the rewrite is in-place
/// and `std.Io.Dir.Walker` reuses the buffer it lends out (the walker appends
/// each child onto the parent path still sitting there). Either way the result
/// is read-only and lives no longer than the walker's own `entry.path` does —
/// until the next `next()` — which is all any consumer here needs.
///
/// The walker joins with the PLATFORM's separator, so on Windows it hands back
/// `sub\a.txt` — and gist speaks `/` everywhere, deliberately: the portability
/// slate hashes stdout and diffs it against the NATIVE oracle, so one spelling
/// on every platform is a gated claim rather than a preference. It is also what
/// every consumer in this file already assumes — `rootDepth` and gist's
/// `pathDepth` count `/`, the gitignore protocol matches the `/` a rule is
/// written in, and every join here spells `/` literally. Normalizing at the two
/// seams a walker path enters (gist's serial walk, the corpus `Haystack`) is what
/// keeps those consumers from each needing a platform branch — and on Windows
/// the unnormalized spelling silently defeated `.gitignore` rules containing a
/// separator, plus `--max-depth`, in the serial engine.
///
/// (This is where ripgrep and gist genuinely part: rg renders the native
/// separator while normalizing internally for matching. Same matching, different
/// render — and a `/` render is what lets a captured expectation, a script, and
/// an agent read identically on every platform.)
pub fn slashed(a: std.mem.Allocator, p: []const u8) error{OutOfMemory}![]const u8 {
    if (comptime std.fs.path.sep == '/') return p;
    const out = try a.dupe(u8, p);
    slashInPlace(out);
    return out;
}

/// `slashed` for a buffer the caller already owns — the form to reach for when a
/// path was just built (a join, a print) and can be fixed up where it lies,
/// rather than copied a second time to change one byte per component.
pub fn slashInPlace(p: []u8) void {
    if (comptime std.fs.path.sep != '/') std.mem.replaceScalar(u8, p, std.fs.path.sep, '/');
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
/// The result is ALWAYS owned by `a`, on both arms. The no-prefix arm used to
/// return `name` itself, which is only safe when the caller's `name` outlives
/// `a` — and in the parallel walk it does the opposite: `descent.handleEntry`
/// joins an entry name that points into the per-directory listing scratch
/// `workerMain` recycles after every directory, so a borrowed `disk` on a queued
/// `DirTask` dangled by the time a worker opened it. That read garbage for the
/// direct children of a `.` root: a lost subtree in a small tree, a SIGSEGV
/// inside `openat`'s path copy in a large one — i.e. `gist --files .` and every
/// bare `gist PATTERN` in a tree deep enough to recycle the scratch. Copying is
/// one basename per root child, and it makes the lifetime unconditional so no
/// future caller has to know which arm it took (descent's sibling `joinRel`
/// already carries this note for the same reason).
///
/// Returns `error.OutOfMemory` rather than calling `allocFailure` because this
/// is the one path helper the **library** reaches: every ignore-tier load under
/// `corpus/tree/ignore.zig` joins through here, and those run inside
/// `irgx_open` / `irgx_search`, where exiting the process is not a
/// failure mode a host can survive (fault-channel law 1). Its two siblings below
/// still exit: `lowerDup` is only reached under case-insensitive ignore
/// matching and `replaceSep` only under `--path-separator`, neither of which
/// the C seam can select, so both remain command-plane-only.
pub fn join(a: std.mem.Allocator, dir: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return a.dupe(u8, name);
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
    var buf: [portal.max_path]u8 = undefined;
    const resolved = portal.realpath(&cpath, &buf) orelse return null;
    return a.dupe(u8, resolved) catch null;
}

/// Replace every `/` in `path` with the (arbitrary-length) `sep` string for
/// `--path-separator`. Returns `path` unchanged when it has no separator.
pub fn replaceSep(a: std.mem.Allocator, path: []const u8, sep: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/') == null) return path;
    var out: std.ArrayList(u8) = .empty;
    for (path) |c| (if (c == '/') out.appendSlice(a, sep) else out.append(a, c)) catch allocFailure();
    return out.toOwnedSlice(a) catch allocFailure();
}

test "slashed hands back gist's separator on every platform, copying only where it must" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The invariant the whole suite rests on: what a consumer receives is
    // `/`-joined no matter which platform's walker produced it. Windows is the
    // only place the input differs, so the assertion is written in the platform's
    // own spelling rather than a hardcoded `\` a POSIX run would wrongly demand.
    const native = "sub" ++ std.fs.path.sep_str ++ "a.txt";
    try t.expectEqualStrings("sub/a.txt", try slashed(a, native));
    try t.expectEqualStrings("a/b/c.zig", try slashed(a, "a" ++ std.fs.path.sep_str ++ "b" ++ std.fs.path.sep_str ++ "c.zig"));
    // Already-`/` input is untouched — a POSIX path is not re-spelled.
    try t.expectEqualStrings("a/b", try slashed(a, "a/b"));

    // Who owns the result: a platform that has to rewrite gets its own buffer,
    // because the rewrite is in-place and the walker reuses the bytes it lends.
    // A platform already spelling `/` gets the input straight back — the seam is
    // free there, which is the whole reason it can sit on the walk's hot path.
    var buf: [3]u8 = .{ 'a', std.fs.path.sep, 'b' };
    const out = try slashed(a, &buf);
    const borrowed = out.ptr == @as([*]const u8, &buf);
    try t.expectEqual(std.fs.path.sep == '/', borrowed);
    try t.expectEqualStrings("a/b", out);

    // The in-place form is the same rewrite for a buffer the caller owns.
    var owned: [5]u8 = .{ 'x', std.fs.path.sep, 'y', std.fs.path.sep, 'z' };
    slashInPlace(&owned);
    try t.expectEqualStrings("x/y/z", &owned);
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
    // …and the elided arm still COPIES. The parallel walk joins names that live
    // in a per-directory scratch it recycles, so a borrowed result outlives its
    // bytes: a `.` root lost its children's subtrees, or segfaulted in `openat`.
    // A caller must not have to know which arm it took, so assert no aliasing.
    var name: [1]u8 = .{'x'};
    const joined = try join(a, ".", &name);
    name[0] = 'y';
    try t.expectEqualStrings("x", joined);
}

test "replaceSep rewrites every slash, multi-byte seps included" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("a::b::c", replaceSep(a, "a/b/c", "::"));
    try t.expectEqualStrings("plain", replaceSep(a, "plain", "::"));
}

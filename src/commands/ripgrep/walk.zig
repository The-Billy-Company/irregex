//! gist `rg` — the single-threaded directory descent that DISCOVERS candidates.
//!
//! Split from `run.zig`: `.gitignore`/depth/hidden filtering must stay inline
//! with the walk (each dir's ignore rules load as we enter it), so this phase
//! only ever discovers candidates — no file is opened here. The actual reads
//! happen afterward, in parallel, over the flat list this builds (`collect.zig`
//! `readCandidates`), matching ripgrep's own split between walking the tree and
//! reading what it finds. `-L/--follow` carries a realpath cycle guard plus a
//! depth cap, mirroring ripgrep's own strategy.

const std = @import("std");
const ignore = @import("ignore.zig");
const grepfile = @import("grepfile.zig");
const args = @import("args.zig");
const Opts = args.Opts;
const die = args.die;
const Dir = std.Io.Dir;

/// A file the walk found but hasn't read yet: `rel` is the display path
/// (`.gitignore`-relative, prefix-joined per root); `disk` is a plain,
/// CWD-openable path string a later phase reopens to actually read bytes.
/// A walker `Dir`/entry handle is only valid until the walk advances past it
/// (`std.Io.Dir.Walker`'s own contract), so a read deferred to a parallel
/// phase — after the single-threaded walk has moved on — needs a reopenable
/// string, not the handle it was discovered through.
pub const Candidate = struct { rel: []const u8, disk: []const u8, explicit: bool = false };

/// The outcome of resolving the query's PATH args: whether the walk was
/// recursive (drives the filename-prefix default) and whether any explicitly
/// named path could not be opened AT ALL. ripgrep reports such a path to stderr
/// and exits 2 (error); gist used to append it as a candidate whose deferred
/// read failed silently, then exit 1 ("no match") — which read to a caller like
/// an instant crash on a typo'd path (`gist search tel` → "search" pattern in
/// nonexistent path "tel" → nothing, exit 1). This carries the error out so the
/// run exits 2, matching rg (error trumps match/no-match).
pub const Gathered = struct { recursive: bool, path_error: bool };

/// Depth of a walker-relative path (root children = 1). `--max-depth` caps it.
fn pathDepth(rel: []const u8) usize {
    return std.mem.count(u8, rel, "/") + 1;
}

/// A walker entry's path relative to CWD (prefix-joined), for output + ignore.
fn relPath(a: std.mem.Allocator, prefix: []const u8, p: []const u8) []const u8 {
    return if (prefix.len == 0) a.dupe(u8, p) catch die("oom\n", .{}) else std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, p }) catch die("oom\n", .{});
}

/// A walker entry's on-disk path (root-joined), for opening/reading ignore files.
fn diskPath(a: std.mem.Allocator, root_path: []const u8, p: []const u8) []const u8 {
    return if (std.mem.eql(u8, root_path, ".")) a.dupe(u8, p) catch die("oom\n", .{}) else std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, p }) catch die("oom\n", .{});
}

/// ripgrep prints a walk error to stderr (`rg: <path>: <errno>`) and lets the run
/// exit 2: a directory it could not descend is a POTENTIAL false negative that
/// MUST be signaled, never skipped in silence. Mirror that — name the path,
/// carry the errno phrase (`pathErrNote`, shared with the explicit-PATH path),
/// and set the shared error flag so `collectFiles` surfaces exit 2.
fn reportWalkError(rel: []const u8, e: anyerror, walk_error: *bool) void {
    std.debug.print("gist: {s}: {s}\n", .{ rel, grepfile.pathErrNote(e) });
    walk_error.* = true;
}

fn walkDir(a: std.mem.Allocator, io: std.Io, root_path: []const u8, prefix: []const u8, o: Opts, ig: *ignore.Ignore, out: *std.ArrayList(Candidate), walk_error: *bool) void {
    ig.loadDir(root_path, prefix);
    // `-L`/`--follow` cycle guard: the real (canonicalized) path of every
    // directory currently on this DFS's ancestor chain — ripgrep's own
    // strategy (ripgrep tracks realpaths, not just a depth counter). A
    // symlink whose target's realpath is already an ancestor is a genuine
    // cycle and is refused; a symlink that reconverges on an already-FINISHED
    // sibling subtree (a diamond, not a cycle) is still followed, since it's
    // popped back off `visited` once its own subtree walk returns.
    var visited: std.ArrayList([]const u8) = .empty;
    if (o.follow) if (realDirPath(a, root_path)) |rp| visited.append(a, rp) catch {};
    walkDirLinked(a, io, root_path, prefix, o, ig, out, 0, &visited, walk_error);
}

/// `-L` symlink-recursion depth cap — defense in depth alongside the realpath
/// cycle guard below (belt-and-suspenders against a non-cyclic but absurdly
/// deep symlink relay, or a platform where `realpath(3)` can't resolve a leg).
const max_link_depth: usize = 40;

/// The canonicalized absolute path of `path` (POSIX `realpath(3)`), or null if
/// it can't be resolved (dangling symlink, permission error, name too long) —
/// treated as "not provably a cycle" (the subsequent `openDir` surfaces the
/// real error if there is one).
fn realDirPath(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const cpath = std.posix.toPosixPath(path) catch return null;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const resolved = std.c.realpath(&cpath, &buf) orelse return null;
    return a.dupe(u8, std.mem.sliceTo(resolved, 0)) catch null;
}

fn containsPath(haystack_paths: []const []const u8, needle_path: []const u8) bool {
    for (haystack_paths) |p| if (std.mem.eql(u8, p, needle_path)) return true;
    return false;
}

/// Single-threaded directory descent: `.gitignore`/depth/hidden filtering must
/// stay inline with the walk (each dir's ignore rules load as we enter it), so
/// this phase only ever DISCOVERS candidates — no file is opened here. The
/// actual reads happen afterward, in parallel, over the flat list this builds
/// (see `collect.readCandidates`), matching ripgrep's own split between walking
/// the tree and reading what it finds.
fn walkDirLinked(a: std.mem.Allocator, io: std.Io, root_path: []const u8, prefix: []const u8, o: Opts, ig: *ignore.Ignore, out: *std.ArrayList(Candidate), link_depth: usize, visited: *std.ArrayList([]const u8), walk_error: *bool) void {
    var root = Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |e| return reportWalkError(prefix, e, walk_error);
    defer root.close(io);
    var walker = root.walkSelectively(a) catch return;
    defer walker.deinit();
    while (true) {
        // A `next` error is a dir whose iteration failed after it was opened
        // (deleted mid-walk, FS error): report it and CONTINUE — the walker has
        // already popped the failed dir, so the next call proceeds. ripgrep keeps
        // walking past such errors rather than aborting the whole run.
        const maybe = walker.next(io) catch |e| {
            reportWalkError(prefix, e, walk_error);
            continue;
        };
        const entry = maybe orelse break;
        const depth = pathDepth(entry.path);
        const rel = relPath(a, prefix, entry.path);
        // ripgrep whitelist-override, with rg's asymmetry (see `Ignore.shouldSkip`
        // + `Filter.whitelists`/`whitelistsHidden`): a `-g`/`--iglob` match
        // (`wl_ig`) force-searches even a hidden/gitignored path and descends a
        // whitelisted `.git`/ignored dir (rg's `-g '*'` searches `.git`); a `-t`
        // type match only additionally un-hides (`wl_hid`), never un-ignores.
        const wl_ig = o.filter.whitelists(a, rel);
        const wl_hid = o.filter.whitelistsHidden(a, rel);
        // -L/--follow: a symlink is resolved to its target — a dir is walked as a
        // subtree (path-prefixed by the link), a file is read like any other.
        if (entry.kind == .sym_link and o.follow) {
            if (link_depth >= max_link_depth) continue;
            if (ig.shouldSkip(rel, false, entry.basename, wl_ig, wl_hid)) continue;
            const full = if (std.mem.eql(u8, root_path, ".")) std.fmt.allocPrint(a, "./{s}", .{entry.path}) catch continue else std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, entry.path }) catch continue;
            if (Dir.cwd().openDir(io, full, .{ .iterate = true })) |sub_const| {
                var sub = sub_const;
                sub.close(io);
                if (o.max_depth == 0 or depth < o.max_depth) {
                    const mark = visited.items.len;
                    var cyclic = false;
                    if (realDirPath(a, full)) |rp| {
                        cyclic = containsPath(visited.items, rp);
                        if (!cyclic) visited.append(a, rp) catch die("oom\n", .{});
                    }
                    if (!cyclic) {
                        ig.loadDir(full, rel);
                        walkDirLinked(a, io, full, rel, o, ig, out, link_depth + 1, visited, walk_error);
                        visited.shrinkRetainingCapacity(mark);
                    }
                }
            } else |_| {
                if (o.max_depth != 0 and depth > o.max_depth) continue;
                out.append(a, .{ .rel = rel, .disk = full }) catch die("oom\n", .{});
            }
            continue;
        }
        if (entry.kind == .directory) {
            // rg's DEFAULT walk descends everything except hidden dirs, `.git`, and
            // ignored ones (.gitignore/.ignore — see ignore.zig). It does NOT
            // hardcode node_modules/target skips (that's gist's monorepo-corpus
            // policy in corpus.zig, wrong for an arbitrary-tree drop-in). A `-g`
            // whitelist (`wl_ig`) overrides all of it, `.git` included (rg parity).
            if (ig.shouldSkip(rel, true, entry.basename, wl_ig, wl_hid)) continue;
            const shallow = o.max_depth == 0 or depth < o.max_depth;
            if (shallow) {
                ig.loadDir(diskPath(a, root_path, entry.path), rel);
                // A dir we chose to descend but cannot open (unreadable / EACCES)
                // is a walk error — report it and exit 2, never skip in silence.
                walker.enter(io, entry) catch |e| reportWalkError(rel, e, walk_error);
            }
            continue;
        }
        if (entry.kind != .file) continue;
        if (ig.shouldSkip(rel, false, entry.basename, wl_ig, wl_hid)) continue;
        if (o.max_depth != 0 and depth > o.max_depth) continue;
        out.append(a, .{ .rel = rel, .disk = diskPath(a, root_path, entry.path) }) catch die("oom\n", .{});
    }
}

/// Resolve the query's PATH args (or the CWD when none) into `out`, single-
/// threaded. An explicitly named file is searched verbatim (never ignore-
/// filtered); a path that can't be opened at all is reported and forces exit 2.
pub fn gather(a: std.mem.Allocator, io: std.Io, roots: []const []const u8, o: Opts, ig: *ignore.Ignore, out: *std.ArrayList(Candidate)) Gathered {
    // A dir the walk discovers but cannot descend (unreadable / EACCES) sets this
    // — folded into `path_error` so, like ripgrep, an unsignaled walk gap forces
    // exit 2 rather than a silent "no match".
    var walk_error = false;
    if (roots.len == 0) {
        walkDir(a, io, ".", "", o, ig, out, &walk_error);
        return .{ .recursive = true, .path_error = walk_error };
    }
    var recursive = false;
    var path_error = false;
    for (roots) |r| {
        if (Dir.cwd().openDir(io, r, .{ .iterate = true })) |dir_const| {
            var dir = dir_const;
            dir.close(io);
            const prefix = if (std.mem.eql(u8, r, ".")) "." else std.mem.trimEnd(u8, r, "/");
            // Exempt this root's own path components from ancestor/CWD-sourced
            // ignore rules (ripgrep never ignore-filters an explicitly named
            // root — only what's found beneath it); see `Ignore.scopeToRoot`.
            ig.scopeToRoot(prefix);
            walkDir(a, io, r, prefix, o, ig, out, &walk_error);
            recursive = true;
        } else |_| {
            // Not a directory. Probe it as a file: ripgrep searches an explicitly
            // named file verbatim (never ignore-filtered), but a path it can't
            // open at all (missing / unreadable / non-dir component) is reported
            // to stderr and forces the error exit — never dropped silently.
            if (std.posix.openat(std.posix.AT.FDCWD, r, .{ .ACCMODE = .RDONLY }, 0)) |fd| {
                _ = std.posix.system.close(fd);
                out.append(a, .{ .rel = r, .disk = r, .explicit = true }) catch die("oom\n", .{});
            } else |ferr| {
                std.debug.print("gist: {s}: {s}\n", .{ r, grepfile.pathErrNote(ferr) });
                path_error = true;
            }
        }
    }
    return .{ .recursive = recursive, .path_error = path_error or walk_error };
}

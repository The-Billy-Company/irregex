//! gist — the corpus walk: what is in the tree, before a byte is read.
//!
//! The single-threaded descent behind the rg-DEFAULT file set. `.gitignore`
//! precedence, the hidden-dotfile rule, `--max-depth`, `-L` symlink cycles, and
//! `--one-file-system` all have to be decided INLINE with the descent — each
//! directory's ignore rules load as the walk enters it — so this phase only ever
//! DISCOVERS `Candidate`s and never opens a file. Reading is a separate,
//! parallel phase over the flat list this builds (`intake.zig`), matching
//! ripgrep's own split between walking a tree and reading what it finds.
//!
//! This is the SOLE authority on what is in the corpus. The trigram index may
//! only elide reads of files this walk already admitted (`elide.zig`); it may
//! never add, drop, or reorder one. `defaultFileSetExtras` is therefore shared
//! verbatim with the warm session, which mirrors this exact set — and returns
//! allocation failure rather than exiting, because the FFI host calling
//! `irgx_open` must receive `IRGX_OOM`, not a dead process (fault-channel law 1).

const std = @import("std");
const args = @import("../argv/args.zig");
const haystack = @import("../../../corpus/tree/haystack.zig");
const ignore = @import("../../../corpus/tree/ignore.zig");
const inode = @import("../../../corpus/read/inode.zig");
const notice = @import("notice.zig");
const paths_mod = @import("../../../corpus/scope/paths.zig");
const portal = @import("../../../portal.zig");

const Dir = std.Io.Dir;
const Opts = args.Opts;

/// The walk returns allocation failure instead of exiting: it is also the warm
/// session's corpus selector, reached from `irgx_open` / `irgx_search`,
/// where an `exit(2)` kills the embedding host rather than yielding
/// `IRGX_OOM` (fault-channel law 1). The command plane absorbs it with
/// `catch oom()` at its own boundary, so the CLI is unchanged.
const Oom = std.mem.Allocator.Error;

/// Depth of a walker-relative path (root children = 1). `--max-depth` caps it.
fn pathDepth(rel: []const u8) usize {
    return std.mem.count(u8, rel, "/") + 1;
}

/// A walker entry's path relative to CWD (prefix-joined), for output + ignore.
/// Deliberate near-twin of the pipeline's `joinRel`: this one ALWAYS allocates
/// because `p` aliases the walker's reused path buffer (invalid once the walk
/// advances); `joinRel` may borrow — its `name` is already arena-owned.
fn relPath(a: std.mem.Allocator, prefix: []const u8, p: []const u8) Oom![]const u8 {
    return if (prefix.len == 0) a.dupe(u8, p) else std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, p });
}

/// A walker entry's on-disk path (root-joined), for opening/reading ignore files.
fn diskPath(a: std.mem.Allocator, root_path: []const u8, p: []const u8) Oom![]const u8 {
    return if (std.mem.eql(u8, root_path, ".")) a.dupe(u8, p) else std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, p });
}

/// A file the walk found but hasn't read yet: `rel` is the display path
/// (`.gitignore`-relative, prefix-joined per root); `disk` is a plain,
/// CWD-openable path string a later phase reopens to actually read bytes.
/// A walker `Dir`/entry handle is only valid until the walk advances past it
/// (`std.Io.Dir.Walker`'s own contract), so a read deferred to a parallel
/// phase — after the single-threaded walk has moved on — needs a reopenable
/// string, not the handle it was discovered through.
/// `root` is the argv ordinal of the PATH argument this file was found under —
/// load-bearing for ascending `--sort path`, the one rg sort applied during
/// traversal (per-directory sibling sort) so roots keep their argv order while
/// only the files WITHIN each root sort (rg hiargs.rs `sort_by_file_name`).
pub const Candidate = struct { rel: []const u8, scope: []const u8, disk: []const u8, explicit: bool = false, root: u32 = 0 };

/// A file the DEFAULT walk skipped at the FILE level — its parent directory was
/// descended, but the leaf itself was dropped by the hidden-dotfile rule
/// (`hidden`) or a gitignore verdict (`ignored`). These are EXACTLY the files a
/// `-t <type>` / `-g <glob>` query un-hides / un-ignores back into the result set
/// (`ignore.zig::skipFromVerdict`: `-t` un-hides only, `-g` does both), yet the
/// persisted default corpus — and the resident daemon's mirror — cannot supply
/// them, since they build from this same hidden/ignore-excluding walk. A file
/// under a PRUNED hidden/ignored directory never reaches this list, because the
/// walk stops descending at the directory (rg/gist never un-hide *into* a hidden
/// or ignored dir — proven in `gist/bench/conformance/gates/parity/index_elision_parity.sh`), so it
/// captures precisely the reachable un-hide/un-ignore candidates and nothing
/// more. Consumed by the warm session (`session/warm/resident.zig`) to keep
/// `resident == gist --no-index == rg` for `-t`/`-g`. `rel` is owned by the
/// caller's walk arena.
pub const ExtraKind = enum { hidden, ignored };
pub const Extra = struct { rel: []const u8, kind: ExtraKind };

/// Classify a file the walk just skipped (with default `Opts`, so the skip was
/// due only to hidden/ignore) into an `Extra`, appending it to `list`. The raw
/// gitignore verdict (`ignore.decide`) distinguishes an ignored leaf (needs `-g`
/// to un-ignore) from a hidden dotfile (needs `-t`/`-g` to un-hide); a file that
/// is neither (should not occur at a skip site under default opts) is dropped.
fn collectExtra(a: std.mem.Allocator, list: *std.ArrayList(Extra), ig: *const ignore.Ignore, rel: []const u8, basename: []const u8) Oom!void {
    const kind: ExtraKind = if (ig.decide(rel, false) == true)
        .ignored
    else if (basename.len > 0 and basename[0] == '.')
        .hidden
    else
        return;
    try list.append(a, .{ .rel = rel, .kind = kind });
}

/// Everything the serial descent can REPORT: opening a root or a chosen
/// subdirectory, and iterating one already open. The walker's own allocation
/// failure never lands here — it propagates as `error.OutOfMemory` (the fault-channel taxonomy
/// law 1), because a swallowed OOM reads as an empty corpus to an embedding
/// host. Naming the set instead of taking `anyerror` (the fault-channel taxonomy
/// law 2) means a widened std set is a build failure here, where the walk can
/// decide what it means, rather than a mystery string on a user's stderr. It is
/// a subset of `notice.WalkFault`, so it coerces into the shared renderer.
const WalkFault = Dir.OpenError || Dir.SelectiveWalker.Error;

/// ripgrep prints a walk error to stderr and lets the run exit 2: a directory
/// it could not descend is a POTENTIAL false negative that MUST be signaled,
/// never skipped in silence. Rendering is the shared `notice.printWalkError`;
/// this sets the serial engine's error flag so `collectFiles` surfaces exit 2.
fn reportWalkError(rel: []const u8, e: WalkFault, walk_error: *bool) void {
    notice.printWalkError(rel, e);
    walk_error.* = true;
}

fn walkDir(a: std.mem.Allocator, io: std.Io, root_path: []const u8, prefix: []const u8, o: Opts, ig: *ignore.Ignore, out: *std.ArrayList(Candidate), walk_error: *bool, extras: ?*std.ArrayList(Extra)) Oom!void {
    try ig.loadDir(root_path, prefix);
    // `-L`/`--follow` cycle guard: the real (canonicalized) path of every
    // directory currently on this DFS's ancestor chain — ripgrep's own
    // strategy (ripgrep tracks realpaths, not just a depth counter). A
    // symlink whose target's realpath is already an ancestor is a genuine
    // cycle and is refused; a symlink that reconverges on an already-FINISHED
    // sibling subtree (a diamond, not a cycle) is still followed, since it's
    // popped back off `visited` once its own subtree walk returns.
    var visited: std.ArrayList(VisitedDir) = .empty;
    // Propagated, never dropped: `visited` IS the symlink-loop guard, so losing
    // an entry silently weakens cycle detection.
    if (o.follow) if (realDirPath(a, root_path)) |rp| try visited.append(a, .{ .real = rp, .display = prefix });
    // --one-file-system: pin the device of the root the walk starts on; the
    // descent below refuses any directory sitting on a different device.
    const root_dev: ?i128 = if (o.one_file_system) deviceOf(root_path) else null;
    try walkDirLinked(a, io, root_path, prefix, paths_mod.cwdRelative(a, io, prefix), o, ig, out, 0, &visited, walk_error, root_dev, extras);
}

/// `-L` symlink-recursion depth cap — defense in depth alongside the realpath
/// cycle guard below (belt-and-suspenders against a non-cyclic but absurdly
/// deep symlink relay, or a platform where `realpath(3)` can't resolve a leg).
const max_link_depth: usize = 40;

/// Canonical absolute path, or null if unresolvable — treated as "not
/// provably a cycle" (the subsequent `openDir` surfaces the real error).
const realDirPath = paths_mod.realpathAlloc;

/// One directory on the `-L` DFS's symlink-entered ancestor chain: its
/// canonical path (the cycle identity) and its DISPLAY path (what rg names as
/// "an ancestor …" in the loop report — never the realpath).
const VisitedDir = struct { real: []const u8, display: []const u8 };

fn findVisited(chain: []const VisitedDir, real: []const u8) ?[]const u8 {
    for (chain) |v| if (std.mem.eql(u8, v.real, real)) return v.display;
    return null;
}

/// True iff canonical `dir` sits at-or-under canonical `ancestor` — canonical
/// paths contain no symlinks, so ancestry is literal prefix containment.
fn underPath(dir: []const u8, ancestor: []const u8) bool {
    if (!std.mem.startsWith(u8, dir, ancestor)) return false;
    return dir.len == ancestor.len or dir[ancestor.len] == '/';
}

/// `path` with its last `n` `/`-components removed ("" when it runs out).
fn stripComponents(path: []const u8, n: usize) []const u8 {
    var s = path;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cut = std.mem.lastIndexOfScalar(u8, s, '/') orelse return s[0..0];
        s = s[0..cut];
    }
    return s;
}

/// Is a `-L` symlink dir whose target canonicalizes to `rp` a filesystem
/// LOOP? Yes iff `rp` is an ancestor of the link itself — either on the
/// literal chain (a canonical prefix of the link's parent directory: the
/// canonical parent contains no symlinks, so ancestry is prefix containment)
/// or a subtree already entered via an earlier symlink (`chain`). Returns the
/// ancestor's DISPLAY path (rg names display paths in its loop report, never
/// realpaths) — for the literal case, derived by stripping the depth
/// difference off the link's own display path `rel`. Null ⇒ not a cycle
/// (a diamond reconvergence stays followable, rg parity).
fn loopAncestor(a: std.mem.Allocator, chain: []const VisitedDir, rp: []const u8, full: []const u8, rel: []const u8) ?[]const u8 {
    if (findVisited(chain, rp)) |display| return if (display.len == 0) "." else display;
    const parent_real = realDirPath(a, stripComponents(full, 1)) orelse return null;
    if (!underPath(parent_real, rp)) return null;
    const extra = std.mem.count(u8, parent_real[rp.len..], "/");
    const anc = stripComponents(rel, extra + 1);
    return if (anc.len == 0) "." else anc;
}

/// The device id backing `path` (POSIX `st_dev`, Windows volume serial), or
/// null if it can't be reached. Powers `--one-file-system`: a directory whose
/// device differs from the walk's starting device is a mount point we refuse to
/// descend. `i128` holds every platform's id (darwin `i32`, linux `u64`,
/// windows `u32`) without loss. Via the shared portable shim, which neither
/// `std.Io`'s `Stat` nor a single Windows query exposes.
fn deviceOf(path: []const u8) ?i128 {
    return inode.devicePath(path);
}

/// True iff `--one-file-system` is active AND `path` sits on a different device
/// than the walk root. A stat failure never prunes (returns false) — an
/// unreadable directory is a walk error surfaced elsewhere, not a silent drop.
fn crossesDevice(root_dev: ?i128, path: []const u8) bool {
    const rd = root_dev orelse return false;
    const dev = deviceOf(path) orelse return false;
    return dev != rd;
}

/// Single-threaded directory descent: `.gitignore`/depth/hidden filtering must
/// stay inline with the walk (each dir's ignore rules load as we enter it), so
/// this phase only ever DISCOVERS candidates — no file is opened here. The
/// actual reads happen afterward, in parallel, over the flat list this builds
/// (see `readCandidates`), matching ripgrep's own split between walking the
/// tree and reading what it finds.
fn walkDirLinked(a: std.mem.Allocator, io: std.Io, root_path: []const u8, prefix: []const u8, scope_prefix: []const u8, o: Opts, ig: *ignore.Ignore, out: *std.ArrayList(Candidate), link_depth: usize, visited: *std.ArrayList(VisitedDir), walk_error: *bool, root_dev: ?i128, extras: ?*std.ArrayList(Extra)) Oom!void {
    var root = Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |e| return reportWalkError(prefix, e, walk_error);
    defer root.close(io);
    // The walker's only construction failure is allocation, and allocation
    // failure RETURNS (fault-channel law 1): the warm session and the FFI call this
    // walk from inside a host process, where folding an OOM into `walk_error`
    // would serve a silently empty set instead of yielding `IRGX_OOM`.
    var walker = try root.walkSelectively(a);
    defer walker.deinit();
    while (true) {
        // A `next` error is a dir whose iteration failed after it was opened
        // (deleted mid-walk, FS error): report it and CONTINUE — the walker has
        // already popped the failed dir, so the next call proceeds. ripgrep keeps
        // walking past such errors rather than aborting the whole run. Its own
        // allocation failure is not a walk gap, though — that one propagates.
        const maybe = walker.next(io) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                reportWalkError(prefix, e, walk_error);
                continue;
            },
        };
        const entry = maybe orelse break;
        // Every use of the walker's path below — display, ignore matching, depth,
        // reopening — wants gist's one separator, not the platform's. Normalized
        // exactly once, here, because this is the only place a foreign spelling
        // can enter: see `slashed`.
        const entry_path = try paths_mod.slashed(a, entry.path);
        const depth = pathDepth(entry_path);
        const rel = try relPath(a, prefix, entry_path);
        const scope_rel = try relPath(a, scope_prefix, entry_path);
        // ripgrep whitelist-override, with rg's asymmetry (see `Ignore.shouldSkip`
        // + `Filter.whitelists`/`whitelistsHidden`): a `-g`/`--iglob` match
        // (`wl_ig`) force-searches even a hidden/gitignored path and descends a
        // whitelisted `.git`/ignored dir (rg's `-g '*'` searches `.git`); a `-t`
        // type match only additionally un-hides (`wl_hid`), never un-ignores.
        const wl_ig = o.filter.whitelists(a, scope_rel);
        const wl_hid = o.filter.whitelistsHidden(a, scope_rel);
        // -L/--follow: a symlink is resolved to its target — a dir is walked as a
        // subtree (path-prefixed by the link), a file is read like any other.
        if (entry.kind == .sym_link and o.follow) {
            if (link_depth >= max_link_depth) continue;
            if (ig.shouldSkip(rel, false, entry.basename, wl_ig, wl_hid)) continue;
            const full = if (std.mem.eql(u8, root_path, ".")) try std.fmt.allocPrint(a, "./{s}", .{entry_path}) else try std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, entry_path });
            if (Dir.cwd().openDir(io, full, .{ .iterate = true })) |sub_const| {
                var sub = sub_const;
                sub.close(io);
                if (crossesDevice(root_dev, full)) continue;
                if (o.max_depth == 0 or depth < o.max_depth) {
                    const mark = visited.items.len;
                    if (realDirPath(a, full)) |rp| {
                        // rg's loop check (walk.rs `check_symlink_loop`): the
                        // target resolving to ANY ancestor of the link — the
                        // literal chain (canonical prefix of the link's parent)
                        // or a symlink-entered one (`visited`) — is announced
                        // with both DISPLAY paths, refused, and errors the run;
                        // the walk itself continues (exit 2 at the end).
                        if (loopAncestor(a, visited.items, rp, full, rel)) |anc| {
                            notice.printLoopError(rel, anc);
                            walk_error.* = true;
                            continue;
                        }
                        try visited.append(a, .{ .real = rp, .display = rel });
                    }
                    try ig.loadDir(full, rel);
                    try walkDirLinked(a, io, full, rel, scope_rel, o, ig, out, link_depth + 1, visited, walk_error, root_dev, extras);
                    visited.shrinkRetainingCapacity(mark);
                }
            } else |e| switch (e) {
                // The link resolves to a regular FILE (openDir refuses with
                // NotDir): read it like any other candidate. Anything else —
                // a DANGLING link (FileNotFound), EACCES, ELOOP — is a walk
                // error rg reports to stderr and folds into exit 2, never a
                // silent drop into "no match".
                error.NotDir => {
                    if (o.max_depth != 0 and depth > o.max_depth) continue;
                    try out.append(a, .{ .rel = rel, .scope = scope_rel, .disk = full });
                },
                else => reportWalkError(rel, e, walk_error),
            }
            continue;
        }
        if (entry.kind == .directory) {
            // Charter / `GIST_SKIP` / `skips.list` basenames are structural — they
            // size the corpus, so `-uu`/`-g` cannot un-hide them. The generic
            // baseline (`.git`, `node_modules`, …) stays off this path: ripgrep
            // parity requires `-uu` to enter those (see `haystack.isPolicySkip`).
            if (haystack.isPolicySkip(entry.basename)) continue;
            // rg's DEFAULT walk descends everything except hidden dirs, `.git`, and
            // ignored ones (.gitignore/.ignore — see ignore.zig). It does NOT
            // hardcode node_modules/target skips (that's gist's monorepo-corpus
            // policy in corpus.zig, wrong for an arbitrary-tree drop-in). A `-g`
            // whitelist (`wl_ig`) overrides all of it, `.git` included (rg parity).
            if (ig.shouldSkip(rel, true, entry.basename, wl_ig, wl_hid)) continue;
            // --one-file-system: never descend a mount point onto another device.
            if (root_dev != null and crossesDevice(root_dev, try diskPath(a, root_path, entry_path))) continue;
            const shallow = o.max_depth == 0 or depth < o.max_depth;
            if (shallow) {
                try ig.loadDir(try diskPath(a, root_path, entry_path), rel);
                // A dir we chose to descend but cannot open (unreadable / EACCES)
                // is a walk error — report it and exit 2, never skip in silence.
                // The walker stack's own allocation failure propagates instead.
                walker.enter(io, entry) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => reportWalkError(rel, e, walk_error),
                };
            }
            continue;
        }
        if (entry.kind != .file) continue;
        if (ig.shouldSkip(rel, false, entry.basename, wl_ig, wl_hid)) {
            // A file the DEFAULT walk drops (hidden dotfile or gitignored) whose
            // parent dir we still descended: the exact leaf a `-t`/`-g` query can
            // un-hide/un-ignore. Record it (with default opts, so `wl_ig`/`wl_hid`
            // are empty and this branch is a pure hidden/ignore skip) for the warm
            // session's parity list. See `Extra`.
            if (extras) |ex| try collectExtra(a, ex, ig, rel, entry.basename);
            continue;
        }
        if (o.max_depth != 0 and depth > o.max_depth) continue;
        try out.append(a, .{ .rel = rel, .scope = scope_rel, .disk = try diskPath(a, root_path, entry_path) });
    }
}

/// The outcome of resolving the query's PATH args: whether the walk was
/// recursive (drives the filename-prefix default) and whether any explicitly
/// named path could not be opened AT ALL. ripgrep reports such a path to stderr
/// and exits 2 (error); gist used to append it as a candidate whose deferred
/// read failed silently, then exit 1 ("no match") — which read to a caller like
/// an instant crash on a typo'd path (`gist search tel` → "search" pattern in
/// nonexistent path "tel" → nothing, exit 1). This carries the error out so the
/// run exits 2, matching rg (error trumps match/no-match).
pub const Gathered = struct { recursive: bool, path_error: bool };

pub fn gather(a: std.mem.Allocator, io: std.Io, roots: []const []const u8, o: Opts, ig: *ignore.Ignore, out: *std.ArrayList(Candidate), extras: ?*std.ArrayList(Extra)) Oom!Gathered {
    // A dir the walk discovers but cannot descend (unreadable / EACCES) sets this
    // — folded into `path_error` so, like ripgrep, an unsignaled walk gap forces
    // exit 2 rather than a silent "no match".
    var walk_error = false;
    if (roots.len == 0) {
        try walkDir(a, io, ".", "", o, ig, out, &walk_error, extras);
        return .{ .recursive = true, .path_error = walk_error };
    }
    var recursive = false;
    var path_error = false;
    for (roots, 0..) |r, root_idx| {
        const first = out.items.len;
        if (Dir.cwd().openDir(io, r, .{ .iterate = true })) |dir_const| {
            var dir = dir_const;
            dir.close(io);
            const prefix = if (std.mem.eql(u8, r, ".")) "." else std.mem.trimEnd(u8, r, "/");
            // Exempt this root's own path components from ancestor/CWD-sourced
            // ignore rules (ripgrep never ignore-filters an explicitly named
            // root — only what's found beneath it); see `Ignore.scopeToRoot`.
            ig.scopeToRoot(prefix);
            try walkDir(a, io, r, prefix, o, ig, out, &walk_error, extras);
            recursive = true;
        } else |_| {
            // Not a directory. Probe it as a file: ripgrep searches an explicitly
            // named file verbatim (never ignore-filtered), but a path it can't
            // open at all (missing / unreadable / non-dir component) is reported
            // to stderr and forces the error exit — never dropped silently.
            if (portal.openFile(portal.cwd(), r)) |fd| {
                portal.close(fd);
                try out.append(a, .{ .rel = r, .scope = paths_mod.cwdRelative(a, io, r), .disk = r, .explicit = true });
            } else |ferr| {
                notice.printWalkError(r, ferr);
                path_error = true;
            }
        }
        for (out.items[first..]) |*c| c.root = @intCast(root_idx);
    }
    return .{ .recursive = recursive, .path_error = path_error or walk_error };
}

/// The default walk's answer: the paths plus whether the walk hit an
/// error (an unreadable directory / unopenable explicit root). Cold reports
/// that to stderr and exits 2; the resident session must DECLINE (answer cold)
/// rather than serve a silently gapped set with a clean exit code.
pub const FileSet = struct { paths: []const []const u8, path_error: bool };

/// The authoritative rg-default file set under `roots`, plus — when requested —
/// the reachable file-level un-hide/un-ignore candidates the same walk skipped
/// (see `Extra`). Both slices are owned by `a`. Passing non-null `extras_out`
/// costs one extra `ignore.decide` classification per skipped file (never per
/// kept file), letting the warm session answer `-t`/`-g` with cold parity.
///
/// Allocation failure RETURNS: the warm session calls this from `irgx_open`
/// and every reconcile behind `irgx_search`, where exiting the process would
/// take the embedding host down instead of yielding `IRGX_OOM` (the fault-channel taxonomy law
/// 1). The command plane absorbs it at `collectFiles` with `catch oom()`, so the
/// CLI's exit 2 and OOM notice are byte-identical to before.
pub fn defaultFileSetExtras(a: std.mem.Allocator, io: std.Io, roots: []const []const u8, extras_out: ?*[]const Extra) Oom!FileSet {
    const o: Opts = .{};
    var ig = try ignore.Ignore.init(a, io, ignore.Options.from(o), roots);
    var candidates: std.ArrayList(Candidate) = .empty;
    var extras: std.ArrayList(Extra) = .empty;
    const g = try gather(a, io, roots, o, &ig, &candidates, if (extras_out != null) &extras else null);
    const paths = try a.alloc([]const u8, candidates.items.len);
    for (candidates.items, paths) |c, *p| p.* = c.rel;
    if (extras_out) |eo| eo.* = try extras.toOwnedSlice(a);
    return .{ .paths = paths, .path_error = g.path_error };
}

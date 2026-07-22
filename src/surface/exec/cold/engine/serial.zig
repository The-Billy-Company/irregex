// MONOLITHIC: serial rg-compat control plane — argv dispatch, walk/read fallbacks, index admission, and output-mode routing share one fail-closed invocation state
//! gist `rg` — a ripgrep-DEFAULT drop-in over an arbitrary directory tree, and
//! (since the two engines merged) the SOLE search engine gist ships: the same
//! walk-and-emit pipeline backs the bare `gist <pattern> [PATH...]` shorthand
//! (no verb, no index required — the everyday zero-setup front door) and the
//! explicit `gist rg` alias. A persisted trigram index, when it covers the
//! searched roots, is used purely to ELIDE reads of files it proves can't match
//! (`IndexSkip` below) — never to change the file set, ignore semantics,
//! ordering, or output; `--no-index`/`--index` force the pure walk / the
//! accelerated path, and `--rank[=N]` ranks the same compiled-regex hits (and
//! PATH scope) via the definition-first RRF view (`ranked.zig`). This needs to *prove* gist is a
//! genuine ripgrep drop-in against ripgrep's own integration suite — which
//! creates a throwaway directory, drops in fixtures, and runs `rg` in that CWD —
//! so this module searches an arbitrary tree with ripgrep's DEFAULT presentation:
//!   • filename shown only when recursive or >1 file (a single explicit file
//!     prints no `path:` prefix), `-H` forces it, `--no-filename`/`-I` suppress;
//!   • line numbers OFF by default, `-n` turns them on;
//!   • `:` frames a match line, `-` a context line, `--` separates groups;
//!   • `-t/-T/-g/--glob/--iglob` scope by type/glob (reusing `../scope/`);
//!   • `.gitignore`/`.ignore`/`.rgignore` precedence honored (`ignore.zig`),
//!     byte-identical to `rg`'s own default corpus scope;
//!   • exit 0 = matched, 1 = no match, 2 = error/unsupported (ripgrep's codes).
//! It reuses gist's linear-time RE2-style matcher for the default per-line and
//! the `-U`/`--multiline` whole-buffer paths, and routes `-P`/`--pcre2` to the
//! opt-in PCRE2 JIT backend (`search/match/regex/pcre2/backend.zig`) — both behind the
//! engine-neutral `Matcher` seam, so `multiline.zig` + `Emitter.buffer` own
//! cross-line emission regardless of which engine produced a span. This module
//! is the walk + presentation shell that makes both engines addressable the way
//! `rg` is: `--json`/`--column`/`--vimgrep` ARE honored (`json.zig`,
//! `output.zig`). A PCRE2 run that trips a resource limit on pathological input
//! (catastrophic backtracking) mirrors ripgrep's exit 2 rather than reporting a
//! silent no-match. `--rank` is the one gist-native view that stays linear-only
//! (it declines loud under `-P`).

const std = @import("std");
const builtin = @import("builtin");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const args = @import("../argv/args.zig");
const output = @import("../emit/output.zig");
const ignore = @import("../../../../corpus/tree/ignore.zig");
const json = @import("../emit/json.zig");
const color = @import("../emit/color.zig");
const grepfile = @import("../read/grepfile.zig");
const ingest = @import("../read/ingest.zig");
const parallel = @import("parallel.zig");
const par = @import("../../../../kernel/primitives/parallel.zig");
const types = @import("../../../../corpus/scope/types.zig");
const simd = @import("../../../../kernel/match/scan/simd.zig");
const verify = @import("../../../../kernel/match/scan/verify.zig");
const persist = @import("../../../../corpus/index/trigrams/persist.zig");
const fresh = @import("../../../../corpus/index/trigrams/fresh.zig");
const crest = @import("../../../../kernel/primitives/crest.zig");
const ranked = @import("ranked.zig");
const commentscope = @import("commentscope.zig");
const query_mod = @import("../../../../kernel/match/query.zig");
const paths_mod = @import("../../../../corpus/scope/paths.zig");
const replaceSep = paths_mod.replaceSep;
const Opts = args.Opts;
const Emitter = output.Emitter;
const die = args.die;
const oom = args.oom;
const Regex = @import("../../../../kernel/match/regex/linear/core.zig").Regex;
const Matcher = @import("../../../../kernel/match/regex/linear/matcher.zig").Matcher;
const pcre2 = @import("../../../../kernel/match/regex/pcre2/backend.zig");
const Pcre = pcre2.Pcre;
const captures_mod = @import("../../../../kernel/match/regex/compile/captures.zig");
const Captures = captures_mod.Captures;
const Caps = captures_mod.Caps;
/// `pub`: the CLI shell (`main.zig`) reuses the same hint module on the warm
/// daemon path, where no engine ran in-process but a no-match still deserves
/// the identical stderr guidance.
pub const hints = @import("../emit/hints.zig");
const Dir = std.Io.Dir;

// Per-file semantics (BOM/UTF-16 ingest, rg line split, binary handling, the
// --stats tally) live in `grepfile.zig`, shared verbatim with the parallel
// pipeline so the two engines cannot drift.
const stripBom = grepfile.stripBom;
const decodeBom = grepfile.decodeBom;
const collectLines = grepfile.collectLines;
const Stats = grepfile.Stats;
const fileMatchStats = grepfile.fileMatchStats;
const emitStats = grepfile.emitStats;

// ─────────────────────────── file gathering ───────────────────────────

const InFile = struct { path: []const u8, bytes: []const u8, explicit: bool = false, sort_time: i96 = 0, root: u32 = 0 };

/// Depth of a walker-relative path (root children = 1). `--max-depth` caps it.
fn pathDepth(rel: []const u8) usize {
    return std.mem.count(u8, rel, "/") + 1;
}

/// A walker entry's path relative to CWD (prefix-joined), for output + ignore.
/// Deliberate near-twin of the pipeline's `joinRel`: this one ALWAYS allocates
/// because `p` aliases the walker's reused path buffer (invalid once the walk
/// advances); `joinRel` may borrow — its `name` is already arena-owned.
fn relPath(a: std.mem.Allocator, prefix: []const u8, p: []const u8) []const u8 {
    return if (prefix.len == 0) a.dupe(u8, p) catch oom() else std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, p }) catch oom();
}

/// A walker entry's on-disk path (root-joined), for opening/reading ignore files.
fn diskPath(a: std.mem.Allocator, root_path: []const u8, p: []const u8) []const u8 {
    return if (std.mem.eql(u8, root_path, ".")) a.dupe(u8, p) catch oom() else std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, p }) catch oom();
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
const Candidate = struct { rel: []const u8, disk: []const u8, explicit: bool = false, root: u32 = 0 };

/// ripgrep prints a walk error to stderr and lets the run exit 2: a directory
/// it could not descend is a POTENTIAL false negative that MUST be signaled,
/// never skipped in silence. Rendering is the shared `grepfile.printWalkError`;
/// this sets the serial engine's error flag so `collectFiles` surfaces exit 2.
fn reportWalkError(rel: []const u8, e: anyerror, walk_error: *bool) void {
    grepfile.printWalkError(rel, e);
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
    var visited: std.ArrayList(VisitedDir) = .empty;
    if (o.follow) if (realDirPath(a, root_path)) |rp| visited.append(a, .{ .real = rp, .display = prefix }) catch {};
    // --one-file-system: pin the device of the root the walk starts on; the
    // descent below refuses any directory sitting on a different device.
    const root_dev: ?i128 = if (o.one_file_system) deviceOf(root_path) else null;
    walkDirLinked(a, io, root_path, prefix, o, ig, out, 0, &visited, walk_error, root_dev);
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

/// The device id backing `path` (POSIX `st_dev`), or null if it can't be
/// stat'd. Powers `--one-file-system`: a directory whose device differs from
/// the walk's starting device is a mount point we refuse to descend. `i128`
/// holds every platform's `dev_t` (darwin `i32`, linux `u64`) without loss.
/// Raw stat via the shared portable shim (`grepfile.statPath`) — the one call
/// behind both `--one-file-system` (device id) and `--sort created` (birth
/// time), neither of which the portable `std.Io` `Stat` exposes.
fn deviceOf(path: []const u8) ?i128 {
    return (grepfile.statPath(path) orelse return null).dev;
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
fn walkDirLinked(a: std.mem.Allocator, io: std.Io, root_path: []const u8, prefix: []const u8, o: Opts, ig: *ignore.Ignore, out: *std.ArrayList(Candidate), link_depth: usize, visited: *std.ArrayList(VisitedDir), walk_error: *bool, root_dev: ?i128) void {
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
                            grepfile.printLoopError(rel, anc);
                            walk_error.* = true;
                            continue;
                        }
                        visited.append(a, .{ .real = rp, .display = rel }) catch {};
                    }
                    ig.loadDir(full, rel);
                    walkDirLinked(a, io, full, rel, o, ig, out, link_depth + 1, visited, walk_error, root_dev);
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
                    out.append(a, .{ .rel = rel, .disk = full }) catch oom();
                },
                else => reportWalkError(rel, e, walk_error),
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
            // --one-file-system: never descend a mount point onto another device.
            if (root_dev != null and crossesDevice(root_dev, diskPath(a, root_path, entry.path))) continue;
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
        out.append(a, .{ .rel = rel, .disk = diskPath(a, root_path, entry.path) }) catch oom();
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
const Gathered = struct { recursive: bool, path_error: bool };

fn gather(a: std.mem.Allocator, io: std.Io, roots: []const []const u8, o: Opts, ig: *ignore.Ignore, out: *std.ArrayList(Candidate)) Gathered {
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
            walkDir(a, io, r, prefix, o, ig, out, &walk_error);
            recursive = true;
        } else |_| {
            // Not a directory. Probe it as a file: ripgrep searches an explicitly
            // named file verbatim (never ignore-filtered), but a path it can't
            // open at all (missing / unreadable / non-dir component) is reported
            // to stderr and forces the error exit — never dropped silently.
            if (std.posix.openat(std.posix.AT.FDCWD, r, .{ .ACCMODE = .RDONLY }, 0)) |fd| {
                _ = std.posix.system.close(fd);
                out.append(a, .{ .rel = r, .disk = r, .explicit = true }) catch oom();
            } else |ferr| {
                std.debug.print("gist: {s}: {s}\n", .{ r, grepfile.pathErrNote(ferr) });
                path_error = true;
            }
        }
        for (out.items[first..]) |*c| c.root = @intCast(root_idx);
    }
    return .{ .recursive = recursive, .path_error = path_error or walk_error };
}

/// `defaultFileSet`'s answer: the walked paths plus whether the walk hit an
/// error (an unreadable directory / unopenable explicit root). Cold reports
/// that to stderr and exits 2; the resident session must DECLINE (answer cold)
/// rather than serve a silently gapped set with a clean exit code.
pub const FileSet = struct { paths: []const []const u8, path_error: bool };

/// The authoritative rg-default file set under `roots` — the SAME certified
/// `gather`/`ignore.zig` walk the bare cold search uses (hidden-file exclusion,
/// `.gitignore`/`.ignore`/`.rgignore` precedence, `.git` skip, per-root
/// scoping), but paths only, no reads. Empty `roots` walks CWD, exactly like a
/// rootless `gist <pattern>`. Exposed so the resident daemon (`src/session/`)
/// builds its corpus and reconciles over a selection BYTE-IDENTICAL to cold,
/// instead of `haystack`'s coarse superset — the whole basis of the warm-path
/// parity guarantee. Paths (and the returned slice) are owned by `a`; the walk's
/// default `Opts` mean no `-g`/`-t`/`--hidden`, which is exactly the query
/// surface `request.classify` admits to the warm path.
pub fn defaultFileSet(a: std.mem.Allocator, io: std.Io, roots: []const []const u8) FileSet {
    const o: Opts = .{};
    var ig = ignore.Ignore.init(a, io, ignore.Options.from(o), roots);
    var candidates: std.ArrayList(Candidate) = .empty;
    const g = gather(a, io, roots, o, &ig, &candidates);
    const paths = a.alloc([]const u8, candidates.items.len) catch oom();
    for (candidates.items, paths) |c, *p| p.* = c.rel;
    return .{ .paths = paths, .path_error = g.path_error };
}

/// Spawn one shard per core above this candidate count; below it, thread-spawn
/// overhead isn't worth it and the whole batch runs inline on the calling
/// thread. Mirrors `ranked.zig`'s identical `read_par_threshold` tuning
/// for its own parallel candidate-read shards.
const par_threshold = 64;

const ReadShard = struct {
    gpa: std.mem.Allocator,
    // Thread-confined bump allocator for every kept file's byte copy — owned
    // by this shard alone until `readCandidates` has copied `out` into the
    // caller's long-lived arena and tears it down, so parallel shards never
    // contend on `gpa`'s shared allocator machinery for that traffic (the
    // exact reasoning `emit.zig`'s `Shard.arena` documents).
    arena: std.heap.ArenaAllocator,
    candidates: []const Candidate,
    needle: ?simd.Gate,
    cfg: *const ingest.Config,
    out: std.ArrayList(InFile) = .empty,
};

/// One candidate's read-and-filter: raw POSIX open/read/close into a reused
/// per-shard scratch buffer — the same proven-fast cold-read idiom
/// `emit.zig`'s `grepShard` already uses for its parallel candidate reads
/// (plain syscalls, no `std.Io` handle to share across threads) — then
/// BOM-decoded, then dropped on the spot when the required-literal gate
/// provably isn't in it: one SIMD `contains` call replaces reading a file all
/// the way to "zero hits" through three more serial passes (binary sniff,
/// line split, per-line match) in the caller's loop. A kept file's bytes are
/// copied into `a` (the shard's arena) so they outlive the next reuse of
/// `scratch`.
///
/// `scratch` is sized to `corpus_mod.per_file_cap` — an indexing-corpus
/// budget, NOT a hard ceiling on what `rg`-compat may search (ripgrep itself
/// has no default max file size; only an explicit `--max-filesize` caps it,
/// applied downstream in `collectFiles`). A file that fills `scratch`
/// completely is ambiguous (exactly cap-sized, or bigger) — `readTail` keeps
/// reading past it into a growable buffer instead of silently truncating.
/// Large regular files are memory-MAPPED rather than read-loop + arena-duped:
/// the ~2× serial copy of a big single file is the Amdahl tail under single-file
/// sharding, and a mapping's pages fault in lazily during the (sharded) scan —
/// exactly ripgrep's large-file strategy. Small files stay on the copying path
/// (one read syscall beats mmap+fault setup below this size).
const mmap_min_bytes: usize = 4 << 20;

fn readOneCandidate(a: std.mem.Allocator, scratch: []u8, c: Candidate, needle: ?simd.Gate, cfg: *const ingest.Config) ?InFile {
    // Untransformed large file: map it (no read loop, no dupe). A transforming
    // run (-z/--pre/-E) must read + rewrite the raw bytes, so it can't map.
    if (!cfg.active()) if (grepfile.mapFile(c.disk, mmap_min_bytes)) |mapped| {
        const body = decodeBom(a, mapped);
        if (needle) |gate| if (!verify.gateWide(a, body, gate)) return null;
        return .{ .path = c.rel, .bytes = body, .explicit = c.explicit, .root = c.root };
    };
    const raw = grepfile.readFileRaw(a, scratch, c.disk) orelse return null;
    // -z/--pre/-E rewrite a file's bytes before matching (decompress, preprocess,
    // transcode); `ingest.apply` owns that whole pipeline (and folds in BOM/
    // encoding). Null means the file is DROPPED — an errored `--pre` whose latch
    // already carries the exit-2 signal. The untransformed fast path stays a plain
    // BOM decode with no per-file branch beyond this one predicate.
    const body = if (cfg.active())
        (ingest.apply(a, cfg, c.disk, c.rel, raw) orelse return null)
    else
        decodeBom(a, raw);
    // `gateWide` ≡ the plain SIMD kernel until the body crosses 16 MiB, then
    // the presence gate fans out across cores (a huge explicit file shouldn't
    // serialize the serial engine's read loop behind one thread's scan).
    if (needle) |gate| if (!verify.gateWide(a, body, gate)) return null;
    // A tail-read (≥ cap) or UTF-16-transcoded body is already `a`-owned; a
    // body still inside `scratch` must be duped to outlive scratch's next reuse.
    const in_scratch = @intFromPtr(body.ptr) >= @intFromPtr(scratch.ptr) and @intFromPtr(body.ptr) < @intFromPtr(scratch.ptr) + scratch.len;
    const owned = if (in_scratch) (a.dupe(u8, body) catch return null) else body;
    return .{ .path = c.rel, .bytes = owned, .explicit = c.explicit, .root = c.root };
}

fn readShard(sh: *ReadShard) void {
    const a = sh.arena.allocator();
    const scratch = sh.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
    defer sh.gpa.free(scratch);
    sh.out.ensureTotalCapacity(sh.gpa, sh.candidates.len) catch {};
    for (sh.candidates) |c| if (readOneCandidate(a, scratch, c, sh.needle, sh.cfg)) |f| sh.out.appendAssumeCapacity(f);
}

/// Read every discovered candidate — in parallel across the machine's cores
/// above `par_threshold` candidates, the multi-core walk ripgrep itself runs
/// (`ignore::WalkParallel`) — and append the kept `InFile`s into `out`, BORROWING
/// each body straight from its shard arena. Below the threshold this runs inline:
/// for a handful of files, spawn cost dwarfs the read itself.
///
/// The shard arenas are intentionally kept alive (never deinit'd): the cold
/// engine is one-shot — `run` owns a single query arena and every terminal path
/// `std.process.exit`s right after emit — so the read arenas outlive every
/// match/emit pass that reads their bytes, and the OS reclaims them at exit. This
/// deletes what was a serial ~½-GB `dest.dupe` of the whole kept corpus (the
/// bandwidth floor sitting UNDER the already-parallel read), for zero copies.
fn readCandidates(dest: std.mem.Allocator, gpa: std.mem.Allocator, candidates: []const Candidate, needle: ?simd.Gate, out: *std.ArrayList(InFile), cfg: *const ingest.Config) void {
    const ncpu = std.Thread.getCpuCount() catch 8;
    // A transforming run (-z/--pre/-E) reads in parallel like any other: each
    // shard decompresses/transcodes on its OWN arena + scratch, and `ingest`'s
    // subprocess path (external decompressor / `--pre`) is concurrency-safe —
    // `std.process.run` holds only per-call state (its own child, pipes, buffers)
    // and `posix_spawn` is thread-safe, so parallel forks never race. The one
    // shared datum, the `--pre` failure latch, is an atomic store. Parallelizing
    // the decode is the whole point: it's the bottleneck rg pays per file.
    const nshards = if (candidates.len < par_threshold) 1 else @min(candidates.len, ncpu);
    const shards = gpa.alloc(ReadShard, nshards) catch oom();
    defer gpa.free(shards);
    const per = (candidates.len + nshards - 1) / nshards;
    for (shards, 0..) |*sh, k| sh.* = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa), .candidates = candidates[@min(k * per, candidates.len)..@min((k + 1) * per, candidates.len)], .needle = needle, .cfg = cfg };
    if (nshards == 1) readShard(&shards[0]) else {
        const threads = gpa.alloc(std.Thread, nshards) catch oom();
        defer gpa.free(threads);
        for (shards, 0..) |*sh, k| threads[k] = std.Thread.spawn(.{}, readShard, .{sh}) catch die("thread spawn failed\n", .{});
        for (threads) |t| t.join();
    }
    out.ensureUnusedCapacity(dest, candidates.len) catch oom();
    // Borrow bodies from the shard arenas (kept alive to process exit — see the
    // doc comment): copy only the small `InFile` structs, never the bytes. The
    // shard's own `out` list (its struct storage) is freed; the arena that backs
    // the bytes is not.
    for (shards) |*sh| {
        out.appendSliceAssumeCapacity(sh.out.items);
        sh.out.deinit(gpa);
    }
}

/// The compiled analyzer's longest literal present in every match, as a SIMD
/// `Gate`. This works for literals and regexes alike (including 1–2 byte
/// literals that cannot use the trigram index), and stays null for
/// alternations without a common literal. Engine-neutral: `Matcher.required()`
/// is the sound per-match literal from either backend (`Regex.required` / the
/// PCRE2 `literal.zig` extractor). A caseless run (`-i`/resolved `-S`) no
/// longer stands the gate down: the raw (pre-fold) required literal is still
/// required in SOME case, so an ASCII-fold-closed literal gates through the
/// caseless SIMD kernel instead (`caselessGate`).
fn requiredLiteralGate(a: std.mem.Allocator, o: Opts, eff: []const u8, re: *const Matcher) ?simd.Gate {
    if (o.invert) return null;
    if (o.caseless) return caselessGate(a, o, eff, re);
    const req = re.required();
    if (req.len == 0) return null;
    return .{ .bytes = req };
}

/// The caseless twin of the required-literal gate: recompile the effective
/// pattern CASE-SENSITIVELY (the fold is what erases `required`, so the
/// unfolded twin still carries it), take the longest fold-closed WINDOW of
/// that raw literal (`query.zig::foldClosedWindow` — ASCII-only; Kelvin/long-s
/// orbits split the window under Unicode fold), and gate through
/// `simd.containsCaseless` against the lowered spelling. When the window IS
/// the whole literal and the raw twin IS one pure literal, the gate is a
/// match EQUIVALENCE (`.equiv`) — the caseless `-l` fast path may then emit
/// on a gate hit alone, no engine run at all. `a` is the run arena: the
/// lowered literal lives for the whole invocation.
fn caselessGate(a: std.mem.Allocator, o: Opts, eff: []const u8, re: *const Matcher) ?simd.Gate {
    switch (re.*) {
        .linear => {},
        .pcre => return null, // no raw-literal twin to mine (literal.zig declines caseless)
    }
    var raw = Regex.compileOpts(a, eff, .{ .unicode = o.unicode, .multiline = o.multiline }) catch return null;
    defer raw.deinit();
    const win = query_mod.foldClosedWindow(raw.required, o.unicode) orelse return null;
    const low = a.dupe(u8, win) catch oom();
    for (low) |*b| b.* = std.ascii.toLower(b.*);
    const whole = win.len == raw.required.len;
    const equiv = whole and raw.lits.len == 1 and std.mem.eql(u8, raw.lits[0], raw.required);
    return .{ .bytes = low, .ci = true, .equiv = equiv };
}

/// A line gate merely avoids a regex run. A whole-file gate drops the file, so
/// modes that emit/tally non-matching bytes must still read every body.
fn wholeFileLiteralGate(o: Opts, needle: ?simd.Gate) ?simd.Gate {
    if (o.files_without or o.stats or o.json or o.passthru) return null;
    return needle;
}

// ─────────────────── index-backed read elision (acceleration) ───────────────────
//
// The persisted trigram index is used ONLY to skip *reading* files the walk
// already discovered but that provably can't match — it never changes the file
// set, the ignore semantics, the ordering, or the output. The live walk above
// stays the sole authority on WHAT to search (so every rgsuite parity guarantee
// holds unchanged); the index just answers, for a walked path it already knows,
// "does this file contain the pattern's required literal?" and, if not (and the
// file is unchanged since the index was built — the freshness overlay forces a
// re-read of anything touched since), lets the read be elided. A skipped file
// couldn't have produced a single line of output, so eliding its read is
// byte-invisible — the win is turning "open+read ~16k files" into "open+read
// only the trigram candidates" for a selective query, gist's whole thesis.
//
// Soundness rests on two sets drawn from the index:
//   • `indexed`  — every path the index covers (only THESE may be elided; a path
//     the index doesn't know — a new file, or one outside the indexed roots — is
//     always read, so nothing is ever wrongly skipped);
//   • `candidates` — `fresh.candidates`: trigram hits for the prefilter UNIONed
//     with every file touched since the build (the freshness overlay closes the
//     stale-index gap — a file that GAINED the needle since the build is in this
//     set and gets read).
// Elide reading path P iff P is exactly indexed AND its doc id is not a candidate.
//
// The CREST SIEVE (research/crest/) adds a second, independent necessary
// condition for the patterns the trigram filter concedes entirely (literal-free
// class repetitions — `[0-9a-f]{8}`): elide P also when its persisted crest
// vector falls short of the pattern's forced crest ĝ — but only for docs the
// freshness overlay did NOT flag (a fresh doc's persisted vector describes
// stale bytes, so it is always read).
const IndexSkip = struct {
    p: persist.Persisted,
    cand: fresh.Candidates,
    indexed_count: usize,
    indexed: parallel.IndexedPaths,
    candidates: std.DynamicBitSet,
    /// Docs the freshness walk flagged (never crest-elided).
    fresh_set: std.DynamicBitSet,
    /// The persisted crest table — null disables the sieve (legacy cache,
    /// rejected blob, inactive ĝ, or no trustworthy anchor).
    table: ?[]const crest.Vector,
    sieve: crest.Vector,

    fn skip(self: *const IndexSkip, rel: []const u8) bool {
        const doc = self.indexed.get(self.p.paths.items[0..self.indexed_count], rel) orelse return false;
        if (!self.candidates.isSet(doc)) return true;
        if (self.table) |t| {
            if (doc < t.len and !self.fresh_set.isSet(doc) and crest.pruned(t[doc], self.sieve)) return true;
        }
        return false;
    }
    fn deinit(self: *IndexSkip) void {
        self.fresh_set.deinit();
        self.candidates.deinit();
        self.indexed.deinit();
        self.cand.deinit();
        self.p.deinit();
    }
};

/// The sound trigram prefilter for this invocation, or empty (⇒ no read is ever
/// elided) whenever anything makes "contains the required literal" an unsafe
/// proxy for "can match": `--no-index`,
/// inversion (`-v` emits zero-hit files too), or the whole-file scans
/// (`--stats`, `--json` — whose summary message carries the same stats —
/// `--passthru`) that must read every byte regardless. Otherwise the
/// engine's own required literal (`re.required`, present in EVERY match) or, for
/// an alternation, its per-branch cover set (`re.alts` — `foo|bar` ⇒ {foo,bar}),
/// both of which `fresh.candidates` treats as sound supersets. Case-folding
/// (`-i`/resolved `-S`) no longer stands the index down wholesale: the raw
/// (pre-fold) required literal is still required in SOME case, so one window
/// of it expands into the ≤16-variant OR-set the index can query
/// (`caselessFilter`) — declining only when no admissible window exists.
fn trigramFilter(a: std.mem.Allocator, o: Opts, eff: []const u8, re: *const Matcher, one: *[1][]const u8) []const []const u8 {
    if (o.no_index or o.invert or o.stats or o.json or o.passthru) return &.{};
    if (o.caseless) return caselessFilter(a, o, eff, re);
    // The regex→sound-literals mapping is the shared search core's, so the cold
    // elision and the warm resident session prune by identical literals. The
    // PCRE2 arm has no gist AST, so it prunes by its required literal alone
    // (≥3 bytes to be trigram-usable) — the same soundness rule, conservatively.
    return switch (re.*) {
        .linear => |*r| query_mod.regexPrefilter(r, one),
        .pcre => blk: {
            const req = re.required();
            if (req.len >= 3) {
                one[0] = req;
                break :blk one[0..1];
            }
            break :blk re.alts();
        },
    };
}

/// The caseless prefilter: recompile the effective pattern CASE-SENSITIVELY (a
/// throwaway parse — the fold is what erases `required`, so the unfolded twin
/// still carries it), then expand one window of that raw literal into its
/// case-variant OR-set (`query.zig::caselessVariants`, which owns the
/// soundness bounds: ASCII-only, Kelvin/long-s orbits excluded under Unicode
/// fold). Every decline returns the empty filter — exactly the old
/// "caseless ⇒ no elision" behavior. `a` is the run arena: the variant strings
/// live for the whole invocation, like every other filter source.
fn caselessFilter(a: std.mem.Allocator, o: Opts, eff: []const u8, re: *const Matcher) []const []const u8 {
    switch (re.*) {
        .linear => {},
        .pcre => return &.{}, // no raw-literal twin to mine (literal.zig declines caseless)
    }
    var raw = Regex.compileOpts(a, eff, .{ .unicode = o.unicode, .multiline = o.multiline }) catch return &.{};
    defer raw.deinit();
    if (raw.required.len < 3) return &.{};
    const vars = query_mod.caselessVariants(a, raw.required, o.unicode) catch return &.{};
    return vars orelse &.{};
}

/// The crest sieve's forced-crest vector ĝ for this invocation, or 0⃗ (⇒ the
/// sieve never elides) under exactly the same unsafety guards as
/// `trigramFilter` — the sieve only ever EXTENDS the pruning criterion where
/// index elision is already admissible, it never widens where elision runs.
/// `pattern` is the EFFECTIVE combined pattern the engine actually compiled
/// (post `-f` fold, `-F` escaping, and leading-flag strip — multi `-e` arrives
/// as `(?:a)|(?:b)`, whose alternation the calculus min-folds natively), so ĝ
/// can never be derived from fewer branches than the engine matches.
/// The Unicode flag is the ACTIVE engine's (linear `-u` vs PCRE2's own), since
/// that is what decides `\d`/`\w` byte semantics (the Alphabet Contract).
fn crestSieve(o: Opts, pattern: []const u8, re: *const Matcher) crest.Vector {
    if (o.no_index or o.caseless or o.invert or o.stats or o.json or o.passthru) return crest.zero_vector;
    const uni = switch (re.*) {
        .linear => o.unicode,
        .pcre => o.pcre_unicode,
    };
    return crest.ghat(pattern, .{ .unicode = uni, .caseless = o.caseless });
}

/// Build the read-elision oracle from the persisted index, or null when there's
/// nothing to gain (no sound prefilter, `--no-index`, or no index on disk — the
/// last probed SILENTLY via `loadQuiet`, since a bare `gist <pattern>` outside an
/// indexed corpus is the normal case, not a miss to nag about). `fresh_roots`
/// scopes the freshness stat-walk to the query's own roots (else the indexed
/// corpus) so a scoped query doesn't pay a whole-corpus stat pass.
fn buildIndexSkip(gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, filters: []const []const u8, sieve: crest.Vector) ?IndexSkip {
    if (!parallel.indexElisionWanted(io, parsed, filters, sieve)) return null;
    return assembleIndexSkip(gpa, io, parsed, filters, sieve) catch null;
}

/// `collectFiles`'s overlap thread body: compute the oracle into the caller's box.
fn computeIndexSkip(out: *?IndexSkip, gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, filters: []const []const u8, sieve: crest.Vector) void {
    out.* = buildIndexSkip(gpa, io, parsed, filters, sieve);
}

/// Fallible half of `buildIndexSkip` (the `assembleElide` idiom): every early
/// exit — no index on disk, an unworthwhile saving, an OOM — is an error, so
/// `errdefer` sheds the half-built state instead of hand-threading `deinit`
/// down each return path.
fn assembleIndexSkip(gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, filters: []const []const u8, sieve: crest.Vector) !IndexSkip {
    var p = (persist.loadQuiet(gpa, io) catch return error.NoIndex) orelse return error.NoIndex;
    errdefer p.deinit();
    // Snapshot the indexed path set BEFORE freshness widens `p.paths` with new
    // files (only originally-indexed paths are elision-eligible; the new files
    // freshness appends are, by definition, things to read).
    const n_indexed = p.paths.items.len;
    // Freshness folds over the roots the index was BUILT with (persisted
    // beside it), unless the query's own explicit roots narrow the walk.
    const fresh_roots = if (parsed.roots.len > 0) parsed.roots else p.roots.items;
    var cand = try fresh.candidates(gpa, io, &p, &p.paths, filters, fresh_roots);
    errdefer cand.deinit();
    var candidates = try std.DynamicBitSet.initEmpty(gpa, p.paths.items.len);
    errdefer candidates.deinit();
    var fresh_set = try std.DynamicBitSet.initEmpty(gpa, p.paths.items.len);
    errdefer fresh_set.deinit();
    for (cand.fresh_ids) |d| fresh_set.set(d);
    // The sieve engages only when there is a ĝ to enforce, a persisted table
    // bound to this doc space, AND a trustworthy anchor (without one, no doc's
    // persisted vector provably describes its live bytes).
    const table: ?[]const crest.Vector = if (crest.active(sieve) and cand.anchored) p.crest else null;
    var indexed_candidates: usize = 0;
    for (cand.ids) |d| {
        candidates.set(d);
        if (d >= n_indexed) continue;
        // Count only docs that will actually be read — the crest sieve's
        // provable prunes are savings, so they inform the worth heuristic too.
        if (table) |t| if (d < t.len and !fresh_set.isSet(d) and crest.pruned(t[d], sieve)) continue;
        indexed_candidates += 1;
    }
    if (!parallel.indexSavingsWorthTable(n_indexed, indexed_candidates)) return error.NotWorthwhile;
    const indexed = try parallel.IndexedPaths.init(gpa, p.paths.items[0..n_indexed]);
    return .{ .p = p, .cand = cand, .indexed_count = n_indexed, .indexed = indexed, .candidates = candidates, .fresh_set = fresh_set, .table = table, .sieve = sieve };
}

/// Gather (walk, single-threaded) → read (parallel, see `readCandidates`) →
/// type/glob filter → path-sort → apply --path-separator. Shared by the
/// search path and `--files`. `gpa` (not the arena `a`) backs the parallel
/// read shards — `std.heap.ArenaAllocator` isn't safe to allocate through
/// concurrently, so each shard gets its OWN arena wrapping the shared,
/// thread-safe `gpa` (see `ReadShard`/`readCandidates`). `filters` is the sound
/// trigram prefilter (`trigramFilter`); empty ⇒ read every walked file (today's
/// behavior), non-empty ⇒ let the persisted index elide provable-non-candidate
/// reads (`buildIndexSkip`) — the output is identical either way.
/// `walked` counts every candidate the walk ADMITTED (post ignore/type/glob/
/// hidden filters, pre body-read) — including index-elided files, which rg
/// would still have opened. It feeds the implicit-path "No files were
/// searched" heuristic (`grepfile.printNothingSearched`), which must fire on
/// "the filters excluded everything", never on "the index proved everything
/// out" or "the pattern missed".
const Collected = struct { files: []InFile, recursive: bool, path_error: bool, walked: usize };
fn collectFiles(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, filters: []const []const u8, sieve: crest.Vector, file_needle: ?simd.Gate, cfg: *const ingest.Config) Collected {
    const o = parsed.opts;
    var candidates: std.ArrayList(Candidate) = .empty;
    var ig = ignore.Ignore.init(a, io, ignore.Options.from(o), parsed.roots);

    // The elision oracle's freshness stat-walk and the gather walk are
    // INDEPENDENT tree passes (gather reads no bodies; `buildIndexSkip`
    // touches only the persisted index + file metadata, allocating through
    // the thread-safe `gpa`), so overlap them: the serial engine's second
    // metadata pass now costs ~zero wall time instead of doubling the
    // walk phase. Spawn failure (or elision not wanted) degrades to the
    // old sequential compute — never a lost oracle.
    var box: ?IndexSkip = null;
    const skip_thread: ?std.Thread = if (parallel.indexElisionWanted(io, parsed, filters, sieve))
        std.Thread.spawn(.{}, computeIndexSkip, .{ &box, gpa, io, parsed, filters, sieve }) catch null
    else
        null;

    const g = gather(a, io, parsed.roots, o, &ig, &candidates);

    var all: std.ArrayList(InFile) = .empty;
    var skip: ?IndexSkip = if (skip_thread) |t| blk: {
        t.join();
        break :blk box;
    } else buildIndexSkip(gpa, io, parsed, filters, sieve);
    defer if (skip) |*s| s.deinit();
    const read_list = if (skip) |*s| blk: {
        // Partition the walked set: read only what the index can't prove out.
        // An elided file contributes nothing to any mode EXCEPT --files-without-
        // match, which lists every non-matching file — so there it's kept as an
        // unread (empty-body) entry, which the run loop treats as "no match".
        var to_read: std.ArrayList(Candidate) = .empty;
        to_read.ensureTotalCapacity(a, candidates.items.len) catch oom();
        for (candidates.items) |c| {
            if (s.skip(c.rel)) {
                if (o.files_without) all.append(a, .{ .path = c.rel, .bytes = "", .explicit = c.explicit, .root = c.root }) catch oom();
            } else to_read.appendAssumeCapacity(c);
        }
        break :blk to_read.items;
    } else candidates.items;
    // A lone explicitly-named file is searched regardless of the whole-file
    // presence gate: it can't be skipped (it was named), so the gate proves
    // nothing the mode's own scan doesn't. Worse, that scan already runs — the
    // sharded count/match pass, or the `-l`/`-q` early-exit — so gating here
    // means faulting the body TWICE, and `gateWide`'s parallel fan-out faults
    // every core's contiguous region before an early-exit can short-circuit,
    // exactly defeating rg's fault-to-first-hit locality. Drop it for the single
    // explicit file (output-neutral: absence yields no match either way); the
    // recursive/multi-file walk keeps it, where it skips whole non-matching files.
    const read_needle = if (read_list.len == 1 and read_list[0].explicit) null else file_needle;
    readCandidates(a, gpa, read_list, read_needle, &all, cfg);

    var files: std.ArrayList(InFile) = .empty;
    files.ensureTotalCapacity(a, all.items.len) catch oom();
    for (all.items) |f| {
        if (o.filter.active() and !o.filter.admits(a, f.path)) continue;
        if (o.max_filesize != 0 and f.bytes.len > o.max_filesize) continue;
        files.appendAssumeCapacity(f);
    }
    // A time-keyed sort needs each file's timestamp; stat only then, and only
    // the kept set. `.path`/`.none` need no metadata (path is already in hand).
    if (o.sort_key == .modified or o.sort_key == .accessed or o.sort_key == .created) for (files.items) |*f| {
        f.sort_time = sortTimeOf(io, o.sort_key, f.path);
    };
    std.mem.sort(InFile, files.items, SortCtx{ .key = o.sort_key, .reverse = o.sort_reverse }, cmpFiles);
    if (o.path_sep) |sepstr| for (files.items) |*f| {
        f.path = replaceSep(a, f.path, sepstr);
    };
    // Path-only filters decide `walked` (rg's `searched` flips as the walk
    // yields a haystack, before any body read); size caps apply post-read.
    var walked: usize = 0;
    for (candidates.items) |c| walked += @intFromBool(!o.filter.active() or o.filter.admits(a, c.rel));
    return .{ .files = files.items, .recursive = g.recursive, .path_error = g.path_error, .walked = walked };
}

/// A leading `(?flags)` directive (rust-regex/rg syntax) on a pattern, honored
/// where the per-line byte engine genuinely can — the contract is "honored
/// where gist can, loud where it can't", never a silent wrong answer:
///   • `i` / `-i` → ASCII caseless on/off for the WHOLE pattern (gist compiles
///     one global engine, so the directive resolves to the run-wide option;
///     mixed demands across `-e`/`-f` patterns fail loud — rgsuite boundary #5);
///   • `m` `s` (and negations) → inert in the per-line model: `^`/`$` already
///     anchor every line and no line carries a `\n` for `.` to cross;
///   • `u` / `-u` → Unicode mode on/off for the WHOLE pattern (`u` = gist's
///     default; `-u` selects byte/ASCII), the run-wide analogue of `-i` reconciled
///     the same way (mixed per-pattern demands fail loud);
///   • `x` `U` `R` → semantics the engine can't reproduce → die with the
///     reason and the rg fallback.
/// Anything else after `(?` (lookaround, a scoped `(?i:…)` group, `(?P<…>`) is
/// not a flag directive — returns null and the regex parser decides.
const LeadingFlags = struct { rest: []const u8, caseless: ?bool = null, unicode: ?bool = null, line_anchors: ?bool = null, dotall: ?bool = null };
fn stripLeadingFlags(pat: []const u8) ?LeadingFlags {
    if (!std.mem.startsWith(u8, pat, "(?")) return null;
    const close = std.mem.indexOfScalar(u8, pat, ')') orelse return null;
    if (close == 2) return null; // `(?)` — empty directive, the parser rejects it
    var f: LeadingFlags = .{ .rest = pat[close + 1 ..] };
    var neg = false;
    for (pat[2..close]) |c| switch (c) {
        '-' => neg = true,
        'i' => f.caseless = !neg,
        'u' => f.unicode = !neg,
        'm' => f.line_anchors = !neg, // `^`/`$` per line (on) vs buffer ends (`(?-m)`)
        's' => f.dotall = !neg, // `.` matches `\n` (`(?s)`), meaningful under `-U`
        'x', 'U', 'R' => die("(?{c}) unsupported by gist's engine — use ripgrep for this\n", .{c}),
        else => return null,
    };
    return f;
}

/// One leading-directive flag reconciled across every pattern source. gist
/// compiles a single engine, so a value one pattern explicitly `demand`s must
/// agree with any pattern that only `inherit`s the CLI base — `see` collects
/// each pattern's stance, `resolve` folds them onto the effective option (or
/// fails loud when a demand contradicts an inheritor, rg's per-branch scoping).
const Directive = struct {
    name: []const u8,
    demand: ?bool = null,
    inherit: bool = false,
    fn see(self: *Directive, v: ?bool) void {
        if (v) |w| {
            if (self.demand != null and self.demand.? != w)
                die("mixed per-pattern (?{s}) demands — gist compiles one engine; use rg for this\n", .{self.name});
            self.demand = w;
        } else self.inherit = true;
    }
    fn resolve(self: Directive, cur: *bool) void {
        if (self.demand) |w| {
            if (self.inherit and w != cur.*)
                die("(?{s}) on some patterns but not others — gist compiles one engine; use rg for this\n", .{self.name});
            cur.* = w;
        }
    }
};

/// Combine every pattern source — bare/`-e`/`--regexp` plus each `-f/--file`
/// line — into one regex: `-F` escapes each literal, multiple patterns OR via
/// `(?:…)|(?:…)`, and `-x/--line-regexp` anchors the whole with `^(?:…)$`.
/// Returns null for the "zero patterns" case (an empty `-f` file with no other
/// source) — ripgrep matches nothing (and everything under `-v`); the caller
/// handles that without the engine. An empty pattern LINE is kept (it's a valid
/// empty pattern = match-all), only the phantom line after a trailing `\n` drops.
/// Leading `(?flags)` directives are resolved here (see `stripLeadingFlags`),
/// which may flip `o.caseless` — under `-F` the bytes `(?i)` stay a literal,
/// exactly as in rg.
fn combinePatterns(a: std.mem.Allocator, io: std.Io, parsed: args.Parsed, o: *Opts) ?[]const u8 {
    var pats: std.ArrayList([]const u8) = .empty;
    pats.appendSlice(a, parsed.patterns) catch oom();
    for (parsed.pattern_files) |pf| {
        const buf = Dir.cwd().readFileAlloc(io, pf, a, .limited(corpus_mod.per_file_cap)) catch die("cannot read pattern file: {s}\n", .{pf});
        if (buf.len == 0) continue;
        var it = std.mem.splitScalar(u8, buf, '\n');
        while (it.next()) |ln| {
            // The piece after a final '\n' is a phantom (not a pattern); every
            // other line — including a genuinely empty one — is a real pattern.
            if (it.index == null and ln.len == 0) break;
            pats.append(a, std.mem.trimEnd(u8, ln, "\r")) catch oom();
        }
    }
    if (pats.items.len == 0) return null;
    // The regex `m` flag rides `-U` by default (rg: `-U` is `m` ON); leading
    // `(?m)`/`(?-m)` directives below override it. Set before both branches so
    // the `-F` and no-directive paths inherit the base unchanged.
    o.re_line_anchors = o.multiline;
    if (parsed.opts.fixed) {
        for (pats.items) |*p| p.* = query_mod.escapeLiteral(a, p.*) catch oom();
    } else {
        // Resolve leading `(?flags)` directives. gist compiles ONE engine, so a
        // flag some pattern explicitly demands may not disagree with a pattern
        // that merely inherits the CLI's own setting (rg scopes flags per branch).
        // `(?i)` case, `(?u)` Unicode, `(?m)` line anchors, `(?s)` dotall each
        // reconcile through the same demand/inherit rule.
        var ci = Directive{ .name = "i" };
        var uni = Directive{ .name = "u" };
        var mln = Directive{ .name = "m" };
        var dot = Directive{ .name = "s" };
        for (pats.items) |*p| {
            const sf = stripLeadingFlags(p.*) orelse {
                for ([_]*Directive{ &ci, &uni, &mln, &dot }) |d| d.inherit = true;
                continue;
            };
            p.* = sf.rest;
            ci.see(sf.caseless);
            uni.see(sf.unicode);
            mln.see(sf.line_anchors);
            dot.see(sf.dotall);
        }
        ci.resolve(&o.caseless);
        uni.resolve(&o.unicode);
        mln.resolve(&o.re_line_anchors);
        dot.resolve(&o.multiline_dotall);
    }
    var combined: []const u8 = pats.items[0];
    if (pats.items.len > 1) {
        var buf: std.ArrayList(u8) = .empty;
        for (pats.items, 0..) |p, i| {
            if (i != 0) buf.append(a, '|') catch oom();
            buf.print(a, "(?:{s})", .{p}) catch oom();
        }
        combined = buf.toOwnedSlice(a) catch oom();
    }
    if (parsed.opts.line_regexp) combined = std.fmt.allocPrint(a, "^(?:{s})$", .{combined}) catch oom();
    return combined;
}

/// Ascending order for one sort key, path-tiebroken so the result is total and
/// deterministic (two files with the same mtime never swap run-to-run).
fn lessAsc(key: args.SortKey, x: InFile, y: InFile) bool {
    return switch (key) {
        .none, .path => pathLess(x.path, y.path),
        .modified, .accessed, .created => if (x.sort_time == y.sort_time)
            pathLess(x.path, y.path)
        else
            x.sort_time < y.sort_time,
    };
}

/// Ascending `--sort path` — the ONE sort rg applies during traversal
/// (`sort_by_file_name` on the walker, hiargs.rs), so PATH arguments keep
/// their argv order and only the files WITHIN each root sort (a DFS with
/// name-sorted siblings is exactly component-wise path order). Every other
/// mode — `--sortr path` and all time keys — is rg's collect-then-sort over
/// the whole haystack set, which IS global (a probe: `rg --sortr path aa zz`
/// interleaves roots; `rg --sort path aa zz` never does).
fn lessAscPathWalk(x: InFile, y: InFile) bool {
    if (x.root != y.root) return x.root < y.root;
    return pathLess(x.path, y.path);
}

/// Path order matching ripgrep's `--sort path` — Rust `Path::cmp`, which compares
/// component-by-component. That is byte order with the separator `/` ranked BELOW
/// every other byte: `warroom/service.go` sorts before `warroom.go`, where a raw
/// byte compare would flip them (`.`=0x2e < `/`=0x2f). Mapping `/`→0 and every
/// other byte→byte+1 keeps all other orderings intact while making the separator
/// the smallest, so gist's ordered output stays byte-identical to ripgrep's.
/// `pub` so the in-process FFI match stream (`session/resident.zig::search`)
/// emits docs in the SAME order the cold `--json` file sort produces — a caller
/// gets one byte-identical record order across both transports.
pub fn pathLess(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |ca, cb| if (ca != cb) return pathOrd(ca) < pathOrd(cb);
    return a.len < b.len;
}

inline fn pathOrd(c: u8) u16 {
    return if (c == '/') 0 else @as(u16, c) + 1;
}

/// `--sort`/`--sortr` comparator. `--sortr` is a true reverse: swapping the
/// operands flips the path tiebreak too, so descending order is the exact
/// mirror of ascending (no adjacent-equal reordering left over) — matching
/// rg's `ordering.reverse()` / `.cmp().reverse()` collect-and-sort. The one
/// asymmetry is ascending `path`, which rg sorts in the WALKER (per root, see
/// `lessAscPathWalk`); its reverse is NOT that order mirrored but a global
/// descending `Path::cmp`.
fn cmpFiles(ctx: SortCtx, x: InFile, y: InFile) bool {
    if (ctx.key == .path and !ctx.reverse) return lessAscPathWalk(x, y);
    return if (ctx.reverse) lessAsc(ctx.key, y, x) else lessAsc(ctx.key, x, y);
}

const SortCtx = struct { key: args.SortKey, reverse: bool };

/// The nanosecond timestamp `--sort <key>` orders `path` by. `modified` and
/// `accessed` come from the portable `statFile` (accessed degrades to modified
/// when the platform doesn't record atime); `created` uses the birth time where
/// the OS exposes it (macOS today) and falls back to the status-change time
/// (ctime) elsewhere, matching the flag note. A stat failure sorts LAST when
/// ascending (max sentinel) — rg's rule ("things that error should appear
/// later"); the mirrored reverse then puts it first, exactly like rg's
/// `ordering.reverse()`.
fn sortTimeOf(io: std.Io, key: args.SortKey, path: []const u8) i96 {
    const st = Dir.cwd().statFile(io, path, .{}) catch return std.math.maxInt(i96);
    return switch (key) {
        .modified => st.mtime.nanoseconds,
        .accessed => if (st.atime) |t| t.nanoseconds else st.mtime.nanoseconds,
        .created => createdTimeNs(path) orelse st.ctime.nanoseconds,
        .none, .path => 0,
    };
}

/// File birth time in ns, or null where the platform/filesystem doesn't record
/// one (then the caller falls back to ctime). macOS carries it in `struct
/// stat`, Linux in `statx` BTIME; gist declines to invent one elsewhere rather
/// than silently mislabel ctime as creation.
fn createdTimeNs(path: []const u8) ?i96 {
    return (grepfile.statPath(path) orelse return null).birthtime_ns;
}

/// ripgrep's `is_readable_stdin` (grep/cli): `!is_terminal(fd0) && (is_file ||
/// is_fifo || is_socket)`. We whitelist exactly those three fd types — regular
/// file, FIFO (pipe), and socket — which by construction excludes a tty and a
/// char device (`/dev/null`), so the `is_terminal` guard is subsumed. This is
/// the rule that lets `cmd | rg pat` and `sock_producer | rg pat` search the
/// stream while `rg pat` (bare tty) and `rg pat </dev/null` fall through to the
/// directory walk. The socket case matters for exec APIs that wire fd0 to a
/// socketpair; omitting it silently diverged from rg on piped-socket input.
///
/// Deliberate departure from raw rg parity — but ONLY for a socket. A socket can
/// be a long-lived control channel that never writes a byte and never closes
/// (seen in the wild — some sandboxed shell/tool-call harnesses wire fd 0 to
/// exactly such a socket); a blocking `read(2)` against that hangs forever,
/// unacceptable for an agent-facing tool. So a socket is admitted only when
/// `poll(2)` shows it ready within a short deadline (a real producer signals in
/// milliseconds; only the pathological silent-forever socket times out, falling
/// through to the directory walk instead of hanging).
///
/// A FIFO (pipe) gets NO such guard: `cmd | gist pat` is the canonical stream,
/// and a slow producer — bytes arriving after a pause, or the first byte only
/// after setup work — is normal, not pathological. A pipe's blocking `read`
/// always terminates: when the writer finishes it closes the write end and
/// `read` returns EOF. Polling it with a deadline is exactly the delayed-pipe
/// false negative we must avoid (a 500 ms-late producer was being dropped to the
/// walk). So a FIFO is classified readable immediately and block-read to true
/// EOF, byte-for-byte rg. A regular file never blocks on `read` either.
const stdin_poll_timeout_ms = 200;

/// fd 0's stream class, deciding stdin admission + the read strategy below.
const StdinKind = enum { none, blocking, socket };

/// Classify fd 0 (ripgrep's `is_readable_stdin`: not a tty, and a file / FIFO /
/// socket). A regular file or FIFO is `.blocking` — safe to block-read to EOF;
/// a socket is `.socket` — admitted only through the bounded poll guard.
fn stdinKind() StdinKind {
    const st = grepfile.statFd(0) orelse return .none;
    return switch (st.mode & std.posix.S.IFMT) {
        std.posix.S.IFREG, std.posix.S.IFIFO => .blocking,
        std.posix.S.IFSOCK => .socket,
        else => .none, // tty, /dev/null char device, … ⇒ fall through to the walk
    };
}

/// True iff fd 0 is a readable stdin stream. `pub` for the warm client
/// (`cli/gist/daemon/client/client.zig`): a rootless query with a readable stdin
/// is a STREAM search only the cold engine can answer, so the client detects the
/// same condition — with the same fd-type rules — and declines to cold. This is
/// a non-consuming probe (stat, plus a `poll` for a socket): the delayed pipe's
/// bytes are never touched here, so nothing the cold `readStdin` will read is
/// stolen.
pub fn readableStdin() bool {
    return switch (stdinKind()) {
        .none => false,
        .blocking => true, // a regular file or a (possibly slow) pipe
        .socket => blk: {
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&fds, stdin_poll_timeout_ms) catch break :blk false;
            break :blk n > 0;
        },
    };
}

/// Ripgrep has no default cap on stdin size (only `--max-filesize`, which
/// doesn't apply to a stream with no a-priori length) — read to EOF, not to
/// `per_file_cap` (that constant is an indexing-corpus budget, not a search
/// ceiling; see `readOneCandidate`'s identical reasoning for on-disk files).
/// A regular file or FIFO is block-read straight to EOF: a slow or paused pipe
/// writer just makes `read` wait, and the writer's close is the EOF — exactly
/// rg, no delayed-pipe truncation. Only a socket keeps the mid-stream silence
/// guard (poll each chunk, treat a timeout as EOF), since a socket peer can go
/// silent forever without closing; whatever arrived before the stall is kept.
fn readStdin(a: std.mem.Allocator) []const u8 {
    const guard = stdinKind() == .socket;
    var buf: std.ArrayList(u8) = .empty;
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        if (guard) {
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, stdin_poll_timeout_ms) catch break;
            if (ready == 0) break; // socket silent for too long — stop waiting, not hanging
        }
        const n = std.posix.read(0, &tmp) catch break;
        if (n == 0) break;
        buf.appendSlice(a, tmp[0..n]) catch oom();
    }
    return buf.toOwnedSlice(a) catch oom();
}

// ─────────────────────────── run ───────────────────────────

/// Interactive long-line guard (gist-native, TTY-only). A single multi-megabyte
/// minified line — a generated `*.gen.json`, a bundled asset — makes a terminal
/// spend ~a second reflowing ONE logical line; that render, not the search, is
/// the "hang near the end" of a high-hit query (gist produces the whole result
/// in ~0.1s, faster than ripgrep). 16 KiB cleanly separates human-authored long
/// lines (observed max a few KB) from generated blobs (tens of KB and up), and a
/// 16 KiB line reflows instantly. Applied ONLY when stdout is a real terminal
/// and the user set no `--max-columns`, so piped/redirected output stays
/// byte-identical to ripgrep (the rgsuite differential harness and every agent
/// capture are untouched). Opt out with `-M0`.
const tty_long_line_cols: usize = 16 * 1024;

/// Compile the search matcher for the resolved engine — `run`'s single build
/// point, reused by the `-r` capture matcher so both sides pick the SAME backend.
///   • `.default` — the linear RE2/Pike engine; fail loud (pointing at `-P` /
///     `--engine auto`) on a construct outside its linear-time syntax.
///   • `.pcre2` (`-P`/`--pcre2`, `--engine pcre2`) — the vendored PCRE2 JIT
///     backend outright; fail loud on a PCRE2 compile error.
///   • `.auto` (`--engine auto`, `--auto-hybrid-regex`) — ripgrep's hybrid:
///     compile the linear engine first (its speed + trigram AST + `--rank`), and
///     escalate to PCRE2 only for a pattern the linear engine declines
///     (lookaround / backreferences / an escape it doesn't own). When NEITHER
///     engine accepts the pattern, fail loud with the PCRE2 diagnostic — never a
///     silent wrong answer, the whole point of gist's fail-closed flag contract.
/// Returns a compiled `Matcher`; every error path is a `die` (noreturn), so the
/// caller reads the resolved backend off the union tag.
fn buildMatcher(gpa: std.mem.Allocator, eff: []const u8, o: Opts) Matcher {
    switch (o.engine) {
        .pcre2 => return .{ .pcre = Pcre.compileOpts(gpa, eff, .{ .caseless = o.caseless, .multiline = o.re_line_anchors, .dotall = o.multiline_dotall, .unicode = o.pcre_unicode }) catch |e| switch (e) {
            error.OutOfMemory => die("oom\n", .{}),
            else => die("gist: error: bad PCRE2 pattern '{s}': {s}\n", .{ eff, pcre2.lastError() }),
        } },
        // The multi-line diagnostic shares the `gist: try` / `gist: note:`
        // grammar (`emit/hints.zig`); these lines always print — they ARE the
        // exit-2 explanation, not a courtesy (`GIST_HINTS` governs only the
        // no-match channel). "linear-time syntax" on line 1 is load-bearing:
        // the Python/Rust bindings classify unsupported-pattern exits by it.
        .default => return .{ .linear = Regex.compileOpts(gpa, eff, .{ .caseless = o.caseless, .multiline = o.multiline, .dotall = o.multiline_dotall, .unicode = o.unicode, .line_anchors = o.re_line_anchors }) catch
            die(
                \\gist: error: bad pattern '{s}' — outside gist's linear-time syntax
                \\gist: note: not owned by the linear engine: lookaround, backreferences (\0-\9; NUL is \x00),
                \\gist: note:   unrecognized escapes (\q, \e, ...), assertion escapes inside [...], mid-pattern
                \\gist: note:   inline flags (--schema lists the exact surface)
                \\gist: try -P / --pcre2 — run this pattern on the vendored PCRE2 JIT backend
                \\gist: try --engine auto — linear first, escalating to PCRE2 only when it declines
                \\
            , .{eff}) },
        .auto => {
            // Hybrid: prefer the linear engine (faster, trigram-AST, --rank-able);
            // its decline is the ONLY signal to escalate. A linear compile error
            // is discarded here precisely because PCRE2 is the fallback.
            if (Regex.compileOpts(gpa, eff, .{ .caseless = o.caseless, .multiline = o.multiline, .dotall = o.multiline_dotall, .unicode = o.unicode, .line_anchors = o.re_line_anchors })) |r|
                return .{ .linear = r }
            else |_| {}
            return .{ .pcre = Pcre.compileOpts(gpa, eff, .{ .caseless = o.caseless, .multiline = o.re_line_anchors, .dotall = o.multiline_dotall, .unicode = o.pcre_unicode }) catch |e| switch (e) {
                error.OutOfMemory => die("oom\n", .{}),
                else => die(
                    \\gist: error: regex '{s}' compiles under neither engine
                    \\gist: note: the linear engine declined it (lookaround / backreferences / an unknown escape)
                    \\gist: note: PCRE2 rejected it too: {s}
                    \\
                , .{ eff, pcre2.lastError() }),
            } };
        },
    }
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, env: *const std.process.Environ.Map) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const parsed = args.parseArgv(a, argv);
    var o = parsed.opts;
    // Resolve the output budget for this run: the ~25k-token soft agent-context
    // guard + the hard OOM ceiling (corpus.zig), honoring `--uncap`/`GIST_UNCAP`
    // and the `GIST_MAX_OUTPUT_*` knobs. Applied at the single stdout seam
    // (`writeStdout`/`emitStdout`) every engine emits through, plus the serial
    // accumulation guard (`outputFull`) below.
    corpus_mod.initOutputBudget(o.uncap);
    // Enumeration modes list one compact line per file; lift the soft context
    // guard so the returned set is COMPLETE and reproducible instead of a
    // truncated (and, on the unordered parallel engine, nondeterministic) subset.
    // The hard OOM ceiling still bounds a genuine blowup. See `Opts.enumeration`.
    if (o.enumeration()) corpus_mod.exemptSoftCap();
    // Resolved ONCE per run (not per file/emitter): stdout tty + `--color` +
    // env. Every emitter below shares this single yes/no.
    const use_color = color.enabled(o, io, env);

    // The content-transform pipeline (-z decompress / --pre preprocess / -E
    // transcode). `pre_error` latches a failed `--pre` invocation (exit 2, rg
    // parity); `transforming` disables index elision + whole-file trigram
    // prefilters below, since those are proven against raw on-disk bytes, not the
    // rewritten stream a candidate's needle actually lives in.
    var pre_error = std.atomic.Value(bool).init(false);
    const icfg = ingest.Config{ .io = io, .search_zip = o.search_zip, .pre = o.pre, .pre_globs = o.pre_globs, .pre_excludes = o.pre_excludes, .encoding = o.encoding, .pre_error = &pre_error };
    const transforming = icfg.active();

    // Cap absurdly long lines when writing to a terminal (see `tty_long_line_cols`):
    // a purely interactive convenience that leaves piped/file output byte-identical
    // to ripgrep. Keyed on the real stdout destination, independent of `--color`.
    if (!o.max_cols_set and (std.Io.File.stdout().isTty(io) catch false))
        o.max_cols = tty_long_line_cols;

    // --type-list: dump every `-t` name and the globs it recognizes, one name
    // per line, in ripgrep's exact presentation — names sorted lexicographically,
    // each row's globs sorted lexicographically (`../scope/types.zig`
    // `writeTypeList`). gist's registry is a strict SUPERSET of ripgrep's, so the
    // listing is rg-shaped and rg-sorted while covering more types + globs.
    if (o.type_list) {
        var out: std.ArrayList(u8) = .empty;
        types.writeTypeList(a, &out) catch oom();
        corpus_mod.emitStdout(out.items);
        std.process.exit(0);
    }

    // --files: list the files that would be searched (no pattern), path-sorted,
    // NUL-terminated under --null. Uses the same gather+filter as the search path.
    if (o.files_list) {
        // The parallel engine never opens a file in --files mode (a listing needs
        // paths, not bytes) — the serial path below reads every body it lists.
        if (parallel.eligible(io, parsed, o)) parallel.run(gpa, io, parsed, o, null, use_color, &.{}, crest.zero_vector, null, null, &icfg);
        // --files lists every file (no pattern) — nothing to prefilter, so no read
        // elision applies; pass an empty trigram filter and an inactive sieve.
        const c = collectFiles(a, gpa, io, parsed, &.{}, crest.zero_vector, null, &icfg);
        if (o.quiet) std.process.exit(if (c.path_error) 2 else if (c.files.len > 0) 0 else 1);
        var out: std.ArrayList(u8) = .empty;
        for (c.files) |f| out.print(a, "{s}{c}", .{ f.path, if (o.null_sep) @as(u8, 0) else '\n' }) catch oom();
        corpus_mod.emitStdout(out.items);
        std.process.exit(if (c.path_error) 2 else if (c.files.len > 0) 0 else 1);
    }

    // Zero patterns (an empty `-f` file): ripgrep matches nothing — so without
    // `-v` there is no output (exit 1); with `-v` every line is a match. We model
    // the latter as "match-all (empty pattern), un-inverted".
    const eff = combinePatterns(a, io, parsed, &o) orelse blk: {
        if (!o.invert) std.process.exit(1);
        o.invert = false;
        break :blk "";
    };
    // `-m 0` (an explicit zero match cap): ripgrep's searcher short-circuits on
    // `max_count == Some(0)` and returns a no-match BEFORE emitting or counting a
    // single hit, so every mode (bare search, `--count[ --include-zero]`, `-l`,
    // `--files-without-match`, `--json`, `-q`) prints nothing and exits 1. Placed
    // after `--files`/`--type-list` (which never search, and exited above) so it
    // scopes to the pattern search alone. The 0-as-unlimited sentinel the per-file
    // emit guards read is untouched — only an explicit `-m0` trips this.
    if (o.max_per_file_set and o.max_per_file == 0) std.process.exit(1);
    // The engine-neutral match seam: the output layer (Emitter, --json, per-file
    // binary/stats) consumes `&re` as a `Matcher` without knowing which engine
    // produced a span. `buildMatcher` resolves the engine choice — `-P`/`--engine
    // pcre2` builds the PCRE2 arm (lookaround, backreferences, Unicode
    // properties); `--engine auto` compiles the linear arm and escalates to PCRE2
    // only for a pattern the linear engine declines; the default is the linear
    // RE2/Pike arm. All honor `-U`/`--multiline` and `--multiline-dotall`.
    var re: Matcher = buildMatcher(gpa, eff, o);
    defer re.deinit();
    // The RESOLVED backend (an auto pattern may have escalated to PCRE2) — drives
    // the sticky-error latch, the `--rank` guard, and the `-r` capture engine
    // below so all three follow the engine actually chosen, not the one requested.
    const is_pcre = std.meta.activeTag(re) == .pcre;
    if (is_pcre) pcre2.clearMatchError(); // fresh sticky-error latch per run

    // rg's NUL policy: with binary detection live (no `-a`/`--text`/`--null-data`),
    // the searcher never feeds a `\0`, so a pattern that *requires* one — a NUL
    // literal or `[\x00]` singleton class — is impossible; rg refuses it (exit 2)
    // rather than silently matching nothing (`crates/regex/src/ban.rs`). Broad
    // classes that merely include NUL (`.`, `[^\x00]`) are fine, so `bansByte`
    // uses the singleton rule, not "can consume". `-a`/`--text` treats NUL as an
    // ordinary byte, so the check is skipped there.
    if (!o.text and !o.binary and !o.null_data and re.bansByte(0))
        die(
            \\gist: error: pattern contains "\0" but it is impossible to match
            \\gist: note: binary detection is enabled, so a NUL byte can never match
            \\gist: try -a / --text — treat NUL as ordinary bytes and match it
            \\
        , .{});

    // --rank: definition-first ranked view over the SAME compiled pattern and
    // PATH scope. Prefer the persisted candidate set; an absent/incomplete index
    // (or --no-index) degrades to the normal live walk, then the same RRF kernel.
    // It is the one gist-native view built on the linear engine's AST analysis
    // (definition-shape ranking), so it declines loud under `-P` rather than
    // silently ignoring the backend the user asked for.
    if (o.rank) {
        if (is_pcre) die("--rank uses gist's linear engine and is unavailable with a PCRE2 pattern (-P/--pcre2, or an --engine auto escalation) — drop one\n", .{});
        const rex: *const Regex = &re.linear;
        // A persisted-index rank reads raw indexed bytes, so it's only taken when
        // not transforming; -z/--pre/-E fall to the live walk (which reads through
        // `ingest`), keeping the ranked view correct over the rewritten stream.
        if (!o.no_index and !transforming) {
            if (try ranked.run(gpa, io, rex, parsed.roots, o.rank_k, o.caseless)) |n| {
                if (n == 0) hints.noMatches(hints.shape(parsed.patterns, o, parsed.roots, parsed.roots.len > 0), null);
                return;
            }
        }
        const c = collectFiles(a, gpa, io, parsed, &.{}, crest.zero_vector, requiredLiteralGate(a, o, eff, &re), &icfg);
        const live = a.alloc(ranked.LiveFile, c.files.len) catch oom();
        for (c.files, live) |file, *dst| dst.* = .{ .path = file.path, .bytes = file.bytes };
        const n = try ranked.runLive(gpa, io, rex, live, o.rank_k);
        if (c.path_error or pre_error.load(.seq_cst)) std.process.exit(2);
        if (n == 0) hints.noMatches(hints.shape(parsed.patterns, o, parsed.roots, parsed.roots.len > 0), c.files.len);
        return;
    }

    // --in-comments / --in-code: the native comment/code-scoped view. Like
    // --rank, it branches early over the SAME compiled matcher and PATH scope
    // and returns, so the certified rg-parity walk/emit paths below stay
    // untouched. The exact engine still decides IF a line matches; the span
    // lexer only filters WHICH matches survive by comment membership.
    if (o.in_comments or o.in_code) {
        if (o.in_comments and o.in_code) die("--in-comments and --in-code are mutually exclusive\n", .{});
        const needle0 = requiredLiteralGate(a, o, eff, &re);
        const c = collectFiles(a, gpa, io, parsed, &.{}, crest.zero_vector, needle0, &icfg);
        const show = switch (o.filename) {
            .always => true,
            .never => false,
            .auto => c.recursive or c.files.len > 1 or parsed.roots.len > 1,
        };
        const scoped = a.alloc(commentscope.File, c.files.len) catch oom();
        for (c.files, scoped) |file, *dst| dst.* = .{ .path = file.path, .bytes = stripBom(file.bytes) };
        var out0: std.ArrayList(u8) = .empty;
        const kept = commentscope.run(a, &re, o, scoped, show, &out0);
        if (!o.quiet) corpus_mod.emitStdout(out0.items);
        pcreFaultExit(&re);
        std.process.exit(if (c.path_error or pre_error.load(.seq_cst)) 2 else if (kept > 0) 0 else 1);
    }

    const line_needle = requiredLiteralGate(a, o, eff, &re);
    // `--include-zero` must count every searched file, so the whole-file literal
    // gate (which would skip a file lacking the required literal) stands down —
    // the per-line `line_needle` still accelerates matching within each file.
    const file_needle = if (o.include_zero) null else wholeFileLiteralGate(o, line_needle);

    // -r/--replace: build the group-aware capture matcher once and share it
    // across every emitter for template expansion. The PCRE2 arm captures from
    // real backreference/lookaround programs; the linear arm is the save-carrying
    // Pike VM over the same AST. Same engine choice as the search matcher above.
    var caps_store: ?Caps = if (o.replace != null) compileCaps(gpa, o, eff, is_pcre) else null;
    defer if (caps_store) |*cp| cp.deinit();
    const caps: ?*Caps = if (caps_store) |*cp| cp else null;

    // Stdin search (rg parity): with no PATH args and a readable stdin (pipe /
    // regular file), search the piped bytes as one unnamed source — no filename
    // prefix, rg exit codes. A tty or /dev/null stdin falls through to the walk.
    if (parsed.roots.len == 0 and readableStdin()) {
        // -z/--pre need a path and don't apply to stdin (rg parity); -E does —
        // transcode the stream, else the default BOM strip.
        const raw = readStdin(a);
        const body = if (o.encoding == .auto) stripBom(raw) else ingest.applyEncoding(a, o.encoding, raw);
        var out0: std.ArrayList(u8) = .empty;
        var em0 = Emitter{ .a = a, .re = &re, .o = o, .show_name = false, .out = &out0, .base = @intFromPtr(body.ptr), .body_end = @intFromPtr(body.ptr) + body.len, .caps = caps, .use_color = use_color, .needle = line_needle };
        // `-U`: match the whole stream as one buffer (a match may cross `\n`);
        // otherwise the per-line path over rg's line split.
        const hits = if (o.multiline) em0.buffer("<stdin>", body) else blk: {
            var lines: std.ArrayList([]const u8) = .empty;
            collectLines(a, body, o.term(), &lines);
            break :blk em0.file("<stdin>", lines.items);
        };
        pcreFaultExit(&re);
        if (o.quiet) std.process.exit(if (hits > 0) 0 else 1);
        corpus_mod.emitStdout(out0.items);
        if (hits == 0) hints.noMatches(hints.shapeStream(parsed.patterns, o), null);
        std.process.exit(if (hits > 0) 0 else 1);
    }

    // The persisted index (when present) accelerates the walk by eliding reads of
    // files that provably can't hold the pattern's required literal — a pure
    // acceleration, output-invisible (see `IndexSkip`). `req_one` backs a possible
    // one-element `{re.required}` filter slice for its lifetime here.
    var req_one: [1][]const u8 = undefined;
    // A transforming run searches rewritten bytes, so the on-disk trigram index
    // can neither elide reads nor prefilter — force the plain live walk. The
    // crest sieve reads the same on-disk artifacts, so it stands down too.
    // `--include-zero` also stands down index elision: an elided (provably
    // non-matching) read would never reach the emitter to print its `path:0`.
    const filters = if (transforming or o.include_zero) &[_][]const u8{} else trigramFilter(a, o, eff, &re, &req_one);
    const sieve = if (transforming or o.include_zero) crest.zero_vector else crestSieve(o, eff, &re);

    // The common recursive-walk case runs on the parallel fused engine
    // (parallel.zig): work-stealing directory walk, bulk-stat listings, inline
    // index/freshness elision, per-file render on every core — byte-identical
    // output, produced in parallel. Anything it declines (see `eligible`) falls
    // through to this proven serial engine.
    if (parallel.eligible(io, parsed, o))
        parallel.run(gpa, io, parsed, o, &re, use_color, filters, sieve, file_needle, line_needle, &icfg);

    const c = collectFiles(a, gpa, io, parsed, filters, sieve, file_needle, &icfg);
    const files = c.files;
    // rg's implicit-path heuristic: a GUESSED search root (no PATH args) whose
    // walk admitted zero files means some filter excluded everything — stderr
    // note + exit 2 via rg's errored flag, never a silent exit-1 "no matches".
    // An explicit path stays silent (rg: "it can otherwise be noisy when it is
    // intended that there is nothing to search"). Search modes only — the
    // --files listing above never fires it (rg parity).
    const nothing_searched = parsed.roots.len == 0 and c.walked == 0;
    if (nothing_searched) grepfile.printNothingSearched();
    // A `--pre` invocation that failed during the reads above is an error (exit 2),
    // exactly like an unopenable explicit path — fold it into every exit below.
    const err_exit = c.path_error or pre_error.load(.seq_cst) or nothing_searched;

    // --json: ripgrep's JSON Lines record stream (own printer, shared engine).
    if (o.json) {
        var jf: std.ArrayList(json.File) = .empty;
        for (files) |f| jf.append(a, .{ .path = f.path, .body = stripBom(f.bytes), .explicit = f.explicit }) catch oom();
        var out: std.ArrayList(u8) = .empty;
        const matched = json.runParallel(gpa, a, &out, &re, caps, o, jf.items, line_needle);
        corpus_mod.emitStdout(out.items);
        pcreFaultExit(&re);
        std.process.exit(if (err_exit) 2 else if (matched) 0 else 1);
    }

    // `--vimgrep` forces the filename on even for a single explicit file —
    // rg's `with_filename` default is `vimgrep || !paths.is_one_file`.
    const show_name = switch (o.filename) {
        .always => true,
        .never => false,
        .auto => o.vimgrep or c.recursive or files.len > 1 or parsed.roots.len > 1,
    };

    var out: std.ArrayList(u8) = .empty;
    // Run-scoped boolean scratch, threaded through the Emitter so the per-file
    // loop below reuses one Sim instead of re-allocating it for every file
    // (mirrors the parallel engine's per-worker `workerSim`). Null on OOM ⇒
    // the Emitter degrades to its file-local build.
    var run_sim: ?Matcher.Sim = Matcher.Sim.init(a, &re) catch null;
    defer if (run_sim) |*s| s.deinit();
    var em = Emitter{ .a = a, .re = &re, .o = o, .show_name = if (o.heading) false else show_name, .out = &out, .caps = caps, .use_color = use_color, .needle = line_needle, .sim = if (run_sim) |*s| s else null };

    // --quiet short-circuits on first match — unless --stats is also asked for,
    // which must run the full search to tally (then print only the stats block).
    // `--files-without-match` inverts the success predicate (a file that LACKS
    // the pattern is the "match"), so it falls through to that mode's own quiet
    // exit below rather than this match-presence one. Under quiet a found match
    // beats a path error (ripgrep's QuietMatched short-circuits the exit to 0
    // even when a later PATH failed to open — e.g. `-q p found missing` → 0).
    if (o.quiet and !o.stats and !o.files_without) {
        const hit = anyMatch(a, &re, o, line_needle, files);
        pcreFaultExit(&re);
        std.process.exit(if (hit) 0 else if (err_exit) 2 else 1);
    }

    if (o.files_without) {
        var lsim = Matcher.Sim.init(a, &re) catch die("engine init failed\n", .{});
        defer lsim.deinit();
        var wss: ?Matcher.SpanSim = if (o.word) (Matcher.SpanSim.init(a, &re) catch null) else null;
        defer if (wss) |*s| s.deinit();
        const wssp: ?*Matcher.SpanSim = if (wss) |*s| s else null;
        // Per-file independent with no output budget — fan out across cores like
        // the parallel READ that preceded it, falling back to the serial loop
        // below the corpus floor, on one core, or under the `GIST_NO_PARALLEL`
        // parity-gate idiom. `-U`'s "match" is a whole-buffer hit; the per-line
        // path reuses the same `-w`/`-v`/zero-width classify as the emit loop.
        const bounds = if (args.envSpan("GIST_NO_PARALLEL") != null) null else par.shardBounds(InFile, files, {}, inFileWeight, par.min_bytes, par.max_shards, a);
        if (bounds) |b| {
            filesWithoutSharded(gpa, a, &out, &re, o, line_needle, files, b);
        } else for (files) |f| {
            fileWithoutMatch(a, &re, o, &em, &lsim, wssp, line_needle, f, &out);
        }
        // Under -q the stream is suppressed; the found-a-without-match file still
        // decides the exit (0 = at least one file lacked the pattern, ripgrep's
        // `--files-without-match` success).
        if (!o.quiet) corpus_mod.emitStdout(out.items);
        pcreFaultExit(&re);
        std.process.exit(if (err_exit) 2 else if (out.items.len > 0) 0 else 1);
    }

    // rg prints a heading only when it would print the path at all: a single
    // explicit file (or --no-filename) suppresses the header, not just the
    // per-line prefix — the sink's path is None so write_path_line is a no-op.
    const heading = o.heading and show_name and !o.count_only and !o.count_matches and !o.files_only and !o.vimgrep;
    const join_groups = o.wantsContext() and !o.files_only and !o.count_only and !o.count_matches and !heading;
    var matched_files: usize = 0;
    var first = true;
    // Binary detection remains active for -l: a match after the buffer that
    // revealed a NUL must not turn the file into a false-positive path.
    // --binary/-uuu (o.binary) searches binary files in full — same as --text for
    // the quit-at-NUL decision, so detection is off for both (gist's superset
    // flavor prints every matching line rather than a binary summary).
    const binary_detect = !o.text and !o.binary and !o.null_data;
    var stat = Stats{};
    // `--include-zero` count: an empty file is still a searched file and rg
    // prints its `path:0`, so don't skip it (the emitter tallies 0 below).
    const count_zero = o.include_zero and (o.count_only or o.count_matches);
    // `--heading`/context `join_groups` carry cross-file separator state (the
    // leading blank line, the `--\n` between context groups) that an order-free
    // split can't reproduce; everything else here is per-file independent and
    // fans out across cores (`emitSharded`) exactly like the parallel READ that
    // preceded it. `shardBounds` returns null below the corpus floor / on one
    // core, keeping the small-corpus answer on this proven serial loop.
    // `GIST_NO_PARALLEL` (the parity-gate idiom, mirrored from `json.runParallel`)
    // forces the serial emit so `rgsuite/run.py`'s serial pass exercises this path
    // too. No production caller sets it.
    const no_par = args.envSpan("GIST_NO_PARALLEL") != null;
    const bounds = if (heading or join_groups or no_par) null else par.shardBounds(InFile, files, {}, inFileWeight, par.min_bytes, par.max_shards, a);
    // A single large file the multi-file shard gate leaves serial (`bounds` is
    // null for one file): fan the line-free literal fast path across cores over
    // its own body — the parallelism ripgrep can't apply to one file. `-l`
    // (files_only) is excluded (a lone first hit, nothing to parallelize).
    const solo_fast = files.len == 1 and !heading and !join_groups and !no_par and !o.stats and !o.files_only and em.litFastEligible();
    if (solo_fast and emitFileSharded(gpa, a, &out, &em, &re, o, use_color, line_needle, files[0], &matched_files, binary_detect, show_name)) {
        // handled by the single-file shard driver
    } else if (bounds) |b| {
        emitSharded(gpa, a, &out, &re, o, eff, is_pcre, use_color, line_needle, files, b, &stat, &matched_files, binary_detect, count_zero, show_name);
    } else for (files) |f| {
        renderFile(&em, f, &stat, &matched_files, &first, binary_detect, count_zero, heading, join_groups, show_name);
        // Serial engine renders into `out` before one flush — stop growing it once
        // the output budget is spent, bounding peak memory (the OOM guard) at the
        // exact point the flush below would truncate anyway. `--stats` runs the
        // full search regardless (it tallies over every file), so never short it.
        if (!o.stats and corpus_mod.outputFull(out.items.len)) break;
    }
    if (o.stats) {
        stat.files_with_match = matched_files;
        // --quiet --stats: suppress the match stream, report 0 bytes printed.
        stat.bytes_printed = if (o.quiet) 0 else out.items.len;
        if (o.quiet) out.clearRetainingCapacity();
        emitStats(a, &out, stat);
    }
    corpus_mod.emitStdout(out.items);
    pcreFaultExit(&re);
    // The no-match hint seam: exit-1 with a clean run (no walk error) is the
    // moment an agent needs guidance — derived from the query's own shape, on
    // stderr, after the (empty) stdout flush. --json and --quiet stay silent
    // by contract; error exits already carry their own diagnostic.
    if (matched_files == 0 and !err_exit)
        hints.noMatches(hints.shape(parsed.patterns, o, parsed.roots, parsed.roots.len > 0), files.len);
    std.process.exit(if (err_exit) 2 else if (matched_files > 0) 0 else 1);
}

/// Compile the `-r/--replace` capture matcher (linear Pike VM or PCRE2) for the
/// effective pattern `eff`. One definition shared by the top-level run and every
/// parallel emit shard — `Caps` carries mutable Pike-VM scratch, so a shard can
/// never share the run's instance and must compile its own.
fn compileCaps(gpa: std.mem.Allocator, o: Opts, eff: []const u8, is_pcre: bool) Caps {
    return if (is_pcre)
        Caps{ .pcre = captures_mod.PcreCaptures.compile(gpa, eff, .{ .caseless = o.caseless, .multiline = o.re_line_anchors, .dotall = o.multiline_dotall, .unicode = o.pcre_unicode }) catch |e| switch (e) {
            error.OutOfMemory => die("oom\n", .{}),
            else => die("bad PCRE2 pattern '{s}': {s}\n", .{ eff, pcre2.lastError() }),
        } }
    else
        Caps{ .linear = Captures.compile(gpa, eff, o.caseless, o.unicode) catch die(
            \\gist: error: bad pattern '{s}' — outside gist's linear-time syntax
            \\gist: try -P / --pcre2 — run this pattern on the PCRE2 backend (lookaround, backreferences)
            \\
        , .{eff}) };
}

/// Render one file's search result into `em.out` exactly as the serial bottom
/// loop does — the per-file core shared by that loop and every parallel emit
/// shard (`emitSharded`). Threads the running `--stats` tally, the
/// `files_with_match` counter, and the `--heading`/context `first`-group flag
/// through pointers so a shard folds its slice independently and the driver
/// merges. It owns no loop control (no output-budget break — the caller's) and,
/// when the driver has gated `--heading`/`join_groups` onto the serial path,
/// those branches stay inert.
fn renderFile(em: *Emitter, f: InFile, stat: *Stats, matched_files: *usize, first: *bool, binary_detect: bool, count_zero: bool, heading: bool, join_groups: bool, show_name: bool) void {
    const a = em.a;
    const o = em.o;
    const re = em.re;
    const out = em.out;
    const body = stripBom(f.bytes);
    if (body.len == 0 and !count_zero) return;
    if (binary_detect) if (verify.firstNulWide(a, body)) |nul| {
        const slice_model = o.multiline and re.canMatchNewline();
        if (!(slice_model and !grepfile.multilineBinary(body.len, nul))) {
            em.base = @intFromPtr(body.ptr);
            em.body_end = em.base + body.len;
            if (o.stats) {
                const searched: []const u8 = if (f.explicit)
                    body
                else if (slice_model)
                    body[0..0]
                else
                    body[0..grepfile.committedPrefix(body, nul)];
                var blines: std.ArrayList([]const u8) = .empty;
                defer blines.deinit(a);
                if (!o.multiline) collectLines(a, searched, o.term(), &blines);
                const fs = fileMatchStats(re, a, o, searched, blines.items, em.needle);
                stat.add(.{ .files_searched = 1, .matches = fs.matches, .matched_lines = fs.lines, .bytes_searched = if (f.explicit and slice_model) nul else fs.bytes });
            }
            if (grepfile.handleBinary(a, re, o, out, em, f.path, f.explicit, body, nul, show_name)) matched_files.* += 1;
            return;
        }
    };
    // The line-free literal fast path (`Emitter.fileLit`) reads `body` directly —
    // a candidate-jump scanner that never materializes the line array — so skip
    // `collectLines` entirely when it's eligible (its guards exclude `--stats`,
    // so the stats block below still collects lines when it needs them).
    const fast = !o.multiline and em.litFastEligible();
    // The fused `-c`/`-l` class-run paths answer from the whole buffer —
    // skip the line split they'd never read (`--stats` still needs it).
    const fused = !o.multiline and !fast and !o.stats and em.fusedFileEligible();
    var lines: std.ArrayList([]const u8) = .empty;
    if (!o.multiline and !fast and !fused) collectLines(a, body, o.term(), &lines);
    if (o.stats) {
        const fs = fileMatchStats(re, a, o, body, lines.items, em.needle);
        stat.add(.{ .files_searched = 1, .matches = fs.matches, .matched_lines = fs.lines, .bytes_searched = fs.bytes });
    }
    const before = out.items.len;
    if (heading) out.print(a, "{s}{s}{s}", .{ if (first.*) "" else "\n", f.path, o.outTerm() }) catch oom();
    em.base = @intFromPtr(body.ptr);
    em.body_end = em.base + body.len;
    const hits = if (o.multiline) em.buffer(f.path, body) else if (fast) em.fileLit(f.path, body, 0, body.len, 0, true) else em.file(f.path, lines.items);
    if (hits > 0) {
        if (join_groups and !first.* and out.items.len > before)
            out.insertSlice(a, before, "--\n") catch oom();
        first.* = false;
        matched_files.* += 1;
    } else if (heading) out.shrinkRetainingCapacity(before);
}

fn inFileWeight(_: void, f: InFile) usize {
    return f.bytes.len;
}

/// The cold bottom emit loop, data-parallel over `files` (covers `--stats`,
/// `--sort/--sortr`, `-r` replace, `--count`, and plain line output — every
/// mode that lands here after the parallel READ). Precondition: the caller has
/// already gated OUT `--heading`, context `join_groups`, and `--quiet` (their
/// cross-file separator / short-circuit state resists an order-free split), so
/// each file is independent. Shards are CONTIGUOUS file ranges (byte-balanced by
/// `shardBounds`), each rendered by the SAME `renderFile` into its own arena
/// buffer with its own `Emitter`/`Sim`/(replace) `Caps` and running `Stats`;
/// the driver then concatenates the buffers in file order and SUMS the tallies —
/// byte-identical to the serial loop. Merges into the caller's `out`, `stat`,
/// and `matched_files`. `bounds` is the precomputed `shardBounds` result.
fn emitSharded(gpa: std.mem.Allocator, a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, o: Opts, eff: []const u8, is_pcre: bool, use_color: bool, line_needle: ?simd.Gate, files: []const InFile, bounds: []const usize, stat: *Stats, matched_files: *usize, binary_detect: bool, count_zero: bool, show_name: bool) void {
    const nthr = bounds.len - 1;
    const Shard = struct {
        re: *const Matcher,
        o: Opts,
        eff: []const u8,
        is_pcre: bool,
        use_color: bool,
        needle: ?simd.Gate,
        files: []const InFile,
        binary_detect: bool,
        count_zero: bool,
        show_name: bool,
        arena: std.heap.ArenaAllocator,
        buf: std.ArrayList(u8) = .empty,
        // One entry per file, in order: buffer length after that file — the
        // boundary the ordered merge (`appendBudgeted`) truncates on so the
        // parallel soft-cap cut lands byte-identical to the serial loop's break.
        marks: std.ArrayList(usize) = .empty,
        stat: Stats = .{},
        matched: usize = 0,

        fn run(sh: *@This()) void {
            const sa = sh.arena.allocator();
            var sim: ?Matcher.Sim = Matcher.Sim.init(sa, sh.re) catch null;
            var caps_store: ?Caps = if (sh.o.replace != null) compileCaps(sa, sh.o, sh.eff, sh.is_pcre) else null;
            var em = Emitter{ .a = sa, .re = sh.re, .o = sh.o, .show_name = if (sh.o.heading) false else sh.show_name, .out = &sh.buf, .caps = if (caps_store) |*cp| cp else null, .use_color = sh.use_color, .needle = sh.needle, .sim = if (sim) |*s| s else null };
            var first = true;
            for (sh.files) |f| {
                renderFile(&em, f, &sh.stat, &sh.matched, &first, sh.binary_detect, sh.count_zero, false, false, sh.show_name);
                sh.marks.append(sa, sh.buf.items.len) catch oom();
            }
        }
    };

    const shards = a.alloc(Shard, nthr) catch oom();
    for (shards, 0..) |*sh, i| sh.* = .{
        .re = re,
        .o = o,
        .eff = eff,
        .is_pcre = is_pcre,
        .use_color = use_color,
        .needle = line_needle,
        .files = files[bounds[i]..bounds[i + 1]],
        .binary_detect = binary_detect,
        .count_zero = count_zero,
        .show_name = show_name,
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = a.alloc(std.Thread, nthr) catch oom();
    par.fanOut(Shard, shards, threads, Shard.run);

    // Merge in file order through the one budget-aware concatenation. `--stats`
    // (which searches every file and truncates nothing) merges whole; otherwise
    // the soft cap cuts at the first file crossing the ceiling, and later shards
    // are dropped — the serial loop's early break, reproduced deterministically.
    // `matched_files` only gates the exit code / no-match hint (never emitted
    // bytes), so the cut shard's whole tally is a safe upper bound.
    for (shards) |*sh| {
        stat.add(sh.stat);
        matched_files.* += sh.matched;
        if (corpus_mod.appendBudgeted(a, out, sh.buf.items, sh.marks.items, !o.stats) != null) break;
    }
}

/// Byte-balanced, LINE-ALIGNED split points over one file's `body` for the
/// single-file fast-path shards. ripgrep is hard-wired single-threaded on one
/// file (`paths.is_one_file ⇒ threads=1`); this is the parallelism it
/// structurally can't use. Each interior boundary is advanced to the next line
/// START (`\n`+1) so every shard owns whole lines and no matching line straddles
/// two shards. Returns `n+1` offsets (`[0]=0`, `[n]=body.len`), or null when the
/// body is below the parallel floor, one core, or collapses to a single range.
fn lineShardBounds(body: []const u8, term: u8, a: std.mem.Allocator) ?[]const usize {
    if (body.len < par.min_bytes) return null;
    const cores = std.Thread.getCpuCount() catch 1;
    const nthr = @min(@min(cores, body.len / par.min_bytes), par.max_shards);
    if (nthr < 2) return null;
    const cuts = a.alloc(usize, nthr + 1) catch return null;
    cuts[0] = 0;
    var n: usize = 1;
    var i: usize = 1;
    while (i < nthr) : (i += 1) {
        const approx = body.len / nthr * i;
        const nl = simd.memchr(body, approx, term) orelse break; // no terminator ahead → last shard swallows the tail
        const start = nl + 1;
        if (start >= body.len) break;
        if (start > cuts[n - 1]) {
            cuts[n] = start;
            n += 1;
        }
    }
    cuts[n] = body.len;
    n += 1;
    if (n < 3) return null; // fewer than two real shards → keep it serial
    return cuts[0..n];
}

/// Single-file data parallelism for the line-free literal fast path — the win
/// ripgrep leaves on the table for a lone big file. Splits `f`'s body into
/// line-aligned shards (`lineShardBounds`), runs `Emitter.fileLit` on each in
/// parallel over the SHARED global body (so byte offsets, the unterminated tail,
/// and `-n` line numbers via each shard's precomputed base are all global), then
/// merges: emit modes concatenate the shard buffers in line order; count modes
/// SUM the partials and print one `path:N`. Returns false (caller falls back to
/// the serial `renderFile`) when the file is binary, below the shard floor, or
/// otherwise ineligible. Byte-identical to the serial fast path — same
/// `fileLit`, just cut at line boundaries and folded back in order.
fn emitFileSharded(gpa: std.mem.Allocator, a: std.mem.Allocator, out: *std.ArrayList(u8), em: *Emitter, re: *const Matcher, o: Opts, use_color: bool, needle: ?simd.Gate, f: InFile, matched_files: *usize, binary_detect: bool, show_name: bool) bool {
    const body = stripBom(f.bytes);
    if (body.len == 0) return false;
    // A NUL flips this file onto the binary path (summary/quit-at-NUL) — leave
    // that to the serial `renderFile`, which owns the binary decision.
    if (binary_detect and verify.firstNulWide(gpa, body) != null) return false;
    const cuts = lineShardBounds(body, o.term(), a) orelse return false;
    const nthr = cuts.len - 1;

    // `-n` needs each shard's starting (global) line number: a cumulative newline
    // count over the gaps (one SIMD pass total), paid only when line numbers show.
    const base_ln = a.alloc(usize, nthr) catch return false;
    if (o.line_num) {
        base_ln[0] = 0;
        for (1..nthr) |i| {
            base_ln[i] = base_ln[i - 1] + simd.countByte(body[cuts[i - 1]..cuts[i]], o.term());
        }
    } else @memset(base_ln, 0);

    const counting = o.count_only or o.count_matches;
    const Shard = struct {
        re: *const Matcher,
        o: Opts,
        use_color: bool,
        needle: ?simd.Gate,
        show_name: bool,
        path: []const u8,
        body: []const u8,
        base_addr: usize,
        end_addr: usize,
        lo: usize,
        hi: usize,
        base_lineno: usize,
        arena: std.heap.ArenaAllocator,
        buf: std.ArrayList(u8) = .empty,
        n: usize = 0,

        fn run(sh: *@This()) void {
            const sa = sh.arena.allocator();
            var sim: ?Matcher.Sim = Matcher.Sim.init(sa, sh.re) catch null;
            var e = Emitter{ .a = sa, .re = sh.re, .o = sh.o, .show_name = sh.show_name, .out = &sh.buf, .use_color = sh.use_color, .needle = sh.needle, .sim = if (sim) |*s| s else null, .base = sh.base_addr, .body_end = sh.end_addr };
            sh.n = e.fileLit(sh.path, sh.body, sh.lo, sh.hi, sh.base_lineno, false);
        }
    };

    const shards = a.alloc(Shard, nthr) catch return false;
    const base_addr = @intFromPtr(body.ptr);
    for (shards, 0..) |*sh, i| sh.* = .{
        .re = re,
        .o = o,
        .use_color = use_color,
        .needle = needle,
        .show_name = show_name,
        .path = f.path,
        .body = body,
        .base_addr = base_addr,
        .end_addr = base_addr + body.len,
        .lo = cuts[i],
        .hi = cuts[i + 1],
        .base_lineno = base_ln[i],
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = a.alloc(std.Thread, nthr) catch oom();
    par.fanOut(Shard, shards, threads, Shard.run);

    var total: usize = 0;
    for (shards) |*sh| total += sh.n;
    if (counting) {
        // One tally line for the whole file (`bufTally` honors `--include-zero`).
        _ = em.bufTally(f.path, total);
    } else {
        for (shards) |*sh| out.appendSlice(a, sh.buf.items) catch oom();
    }
    if (total > 0) matched_files.* += 1;
    return true;
}

/// One file's `--files-without-match` verdict + emit: skip a detected binary,
/// else test whether the pattern appears anywhere (the `-U` whole-buffer tally
/// or the per-line scan) and print the path when it does NOT. `caps` is
/// irrelevant to a boolean hit — replacement text never changes the count — so,
/// like `anyMatch`, the buffer scan passes null: no shared capture VM to race
/// across shards. Shared by the serial loop and every parallel shard so the two
/// can't drift.
fn fileWithoutMatch(a: std.mem.Allocator, re: *const Matcher, o: Opts, em: *Emitter, lsim: *Matcher.Sim, wssp: ?*Matcher.SpanSim, needle: ?simd.Gate, f: InFile, out: *std.ArrayList(u8)) void {
    const body = stripBom(f.bytes);
    if (body.len > 0 and corpus_mod.isBinary(body) and !o.text and !o.binary) return;
    const any = if (o.multiline) bufferAnyHit(a, re, o, null, needle, f.path, body) else blk: {
        var lines: std.ArrayList([]const u8) = .empty;
        collectLines(a, body, o.term(), &lines);
        for (lines.items) |line| if (lineHit(em, lsim, wssp, needle, line)) break :blk true;
        break :blk false;
    };
    if (!any) out.print(a, "{s}{s}", .{ f.path, if (o.null_sep) "\x00" else o.outTerm() }) catch oom();
}

/// `--files-without-match`, data-parallel over `files`. Each file is independent
/// (a file lacking the pattern prints its path, in file order, with NO output
/// budget — the serial loop has none either), so shards render contiguous ranges
/// through the SAME `fileWithoutMatch` into per-arena buffers with their own
/// boolean `Sim` / (word) `SpanSim` / `Emitter`, then the driver concatenates the
/// buffers in file order — byte-identical to the serial loop. Merges into `out`.
fn filesWithoutSharded(gpa: std.mem.Allocator, a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, o: Opts, needle: ?simd.Gate, files: []const InFile, bounds: []const usize) void {
    const nthr = bounds.len - 1;
    const Shard = struct {
        re: *const Matcher,
        o: Opts,
        needle: ?simd.Gate,
        files: []const InFile,
        arena: std.heap.ArenaAllocator,
        buf: std.ArrayList(u8) = .empty,

        fn run(sh: *@This()) void {
            const sa = sh.arena.allocator();
            var lsim = Matcher.Sim.init(sa, sh.re) catch die("engine init failed\n", .{});
            var wss: ?Matcher.SpanSim = if (sh.o.word) (Matcher.SpanSim.init(sa, sh.re) catch null) else null;
            const wssp: ?*Matcher.SpanSim = if (wss) |*s| s else null;
            var em = Emitter{ .a = sa, .re = sh.re, .o = sh.o, .show_name = false, .out = &sh.buf, .needle = sh.needle };
            for (sh.files) |f| fileWithoutMatch(sa, sh.re, sh.o, &em, &lsim, wssp, sh.needle, f, &sh.buf);
        }
    };

    const shards = a.alloc(Shard, nthr) catch oom();
    for (shards, 0..) |*sh, i| sh.* = .{
        .re = re,
        .o = o,
        .needle = needle,
        .files = files[bounds[i]..bounds[i + 1]],
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = a.alloc(std.Thread, nthr) catch oom();
    par.fanOut(Shard, shards, threads, Shard.run);
    for (shards) |*sh| out.appendSlice(a, sh.buf.items) catch oom();
}

/// Mirror ripgrep's exit 2 when a `-P` search tripped a resource limit mid-run
/// (catastrophic backtracking hitting the match/depth limit, a JIT stack
/// overflow): the PCRE2 arm latched the fault and returned a silent no-match to
/// the emitter, so any accumulated stdout is flushed first (earlier files'
/// genuine matches, exactly as rg leaves them) and then the run exits 2 rather
/// than reporting a bogus no-match. A no-op for the linear engine (always 0).
/// `pub`: the parallel engine folds the same process-global latch into its own
/// exit through this one renderer, so the two engines' fault text can't drift.
pub fn pcreFaultExit(re: *const Matcher) void {
    if (re.matchError() == 0) return;
    var buf: [256]u8 = undefined;
    std.debug.print("gist: PCRE2: error matching: {s}\n", .{pcre2.matchErrorMessage(&buf)});
    std.process.exit(2);
}

/// One line's match verdict — the CRLF trim, the required-literal SIMD gate,
/// then the `-w`-aware word hit or the plain engine hit (the same wss-gated
/// classify the per-line emit path applies): shared by --files-without-match
/// and the -q/--quiet scan so the two can't drift. Inline: it sits in those
/// modes' per-line loops.
inline fn lineHit(em: *Emitter, sim: *Matcher.Sim, wss: ?*Matcher.SpanSim, needle: ?simd.Gate, line: []const u8) bool {
    const mv = if (em.o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
    return (needle == null or needle.?.in(mv)) and (if (wss) |s| em.lineHitWord(s, mv) else em.re.lineMatch(sim, mv));
}

/// `-U` whole-buffer boolean: render into a throwaway buffer and reuse the
/// multiline emitter's tally (invert/word/zero-width baked in). Shared by the
/// --files-without-match and -q/--quiet scans so the two can't drift.
fn bufferAnyHit(a: std.mem.Allocator, re: *const Matcher, o: Opts, caps: ?*Caps, needle: ?simd.Gate, path: []const u8, body: []const u8) bool {
    var scratch: std.ArrayList(u8) = .empty;
    var em = Emitter{ .a = a, .re = re, .o = o, .show_name = false, .out = &scratch, .base = @intFromPtr(body.ptr), .caps = caps, .needle = needle };
    return em.buffer(path, body) > 0;
}

/// `-q/--quiet`: true as soon as any file matches (short-circuits). Under `-U` the
/// whole-buffer emitter's tally (invert/word/zero-width baked in) is the boolean;
/// otherwise the per-line scan against the (possibly inverted) line selection.
fn anyMatch(a: std.mem.Allocator, re: *const Matcher, o: Opts, needle: ?simd.Gate, files: []const InFile) bool {
    var sim = Matcher.Sim.init(a, re) catch return false;
    defer sim.deinit();
    var wss: ?Matcher.SpanSim = if (o.word) (Matcher.SpanSim.init(a, re) catch null) else null;
    defer if (wss) |*s| s.deinit();
    const wssp: ?*Matcher.SpanSim = if (wss) |*s| s else null;
    var em = Emitter{ .a = a, .re = re, .o = o, .show_name = false, .out = undefined };
    // Pure-literal presence short-circuit (`-q`'s early-exit twin of `-l`): a
    // literal carries no terminator, so it always lands inside some line, and
    // `litFastEligible` guarantees that line matches — hence a match EXISTS iff
    // any literal occurs. One `indexOfAnyPos` sweep stops at the first hit
    // instead of materializing every line of a huge body (the `collectLines`
    // tail that made `-q` scan the whole file). `-v` is excluded by eligibility.
    const lit_fast = !o.multiline and em.litFastEligible();
    const lits = re.lits();
    for (files) |f| {
        const body = stripBom(f.bytes);
        if (body.len == 0 or (corpus_mod.isBinary(body) and !o.text and !o.binary)) continue;
        if (lit_fast) {
            if (simd.indexOfAnyPos(body, 0, lits) != null) return true;
            continue;
        }
        if (o.multiline) {
            if (bufferAnyHit(a, re, o, null, needle, f.path, body)) return true;
            continue;
        }
        var lines: std.ArrayList([]const u8) = .empty;
        collectLines(a, body, o.term(), &lines);
        for (lines.items) |line| if (lineHit(&em, &sim, wssp, needle, line) != o.invert) return true;
    }
    return false;
}

// The dying arms (`(?u)`, `(?x)`, mixed demands) exit the process by design,
// so tests cover the honor/strip/decline paths; build.zig's black-box guard
// covers the end-to-end exit codes.
test "sort comparator: path + time keys, ascending and reversed, path-tiebroken" {
    const t = std.testing;
    const a = InFile{ .path = "a.zig", .bytes = "", .sort_time = 100 };
    const b = InFile{ .path = "b.zig", .bytes = "", .sort_time = 200 };
    const c = InFile{ .path = "c.zig", .bytes = "", .sort_time = 100 }; // ties a on time

    // Path key: separator-aware order (see pathLess); reverse is the exact mirror.
    try t.expect(cmpFiles(.{ .key = .path, .reverse = false }, a, b));
    try t.expect(!cmpFiles(.{ .key = .path, .reverse = false }, b, a));
    try t.expect(cmpFiles(.{ .key = .path, .reverse = true }, b, a));

    // Time key: earlier stamp sorts first; equal stamps fall back to path so the
    // order is total (a before c even though both are t=100).
    try t.expect(cmpFiles(.{ .key = .modified, .reverse = false }, a, b));
    try t.expect(!cmpFiles(.{ .key = .modified, .reverse = false }, b, a));
    try t.expect(cmpFiles(.{ .key = .modified, .reverse = false }, a, c));
    try t.expect(!cmpFiles(.{ .key = .modified, .reverse = false }, c, a));
    // Reversed time is the full mirror, tiebreak included.
    try t.expect(cmpFiles(.{ .key = .modified, .reverse = true }, c, a));

    // A full sort lands the expected total order and its reverse.
    var asc = [_]InFile{ b, c, a };
    std.mem.sort(InFile, &asc, SortCtx{ .key = .modified, .reverse = false }, cmpFiles);
    try t.expectEqualStrings("a.zig", asc[0].path);
    try t.expectEqualStrings("c.zig", asc[1].path);
    try t.expectEqualStrings("b.zig", asc[2].path);
    var desc = [_]InFile{ a, c, b };
    std.mem.sort(InFile, &desc, SortCtx{ .key = .modified, .reverse = true }, cmpFiles);
    try t.expectEqualStrings("b.zig", desc[0].path);
    try t.expectEqualStrings("c.zig", desc[1].path);
    try t.expectEqualStrings("a.zig", desc[2].path);
}

test "sort path: ascending is per-root walk order, descending is global (rg parity)" {
    const t = std.testing;
    // argv `zz aa`: zz's files sort within zz, aa's within aa, roots keep argv
    // order — rg's walker sort. Descending ignores roots entirely (global
    // collect-and-sort with `.reverse()`).
    const z0 = InFile{ .path = "zz/0.txt", .bytes = "", .root = 0 };
    const z2 = InFile{ .path = "zz/2.txt", .bytes = "", .root = 0 };
    const a1 = InFile{ .path = "aa/1.txt", .bytes = "", .root = 1 };
    var asc = [_]InFile{ a1, z2, z0 };
    std.mem.sort(InFile, &asc, SortCtx{ .key = .path, .reverse = false }, cmpFiles);
    try t.expectEqualStrings("zz/0.txt", asc[0].path);
    try t.expectEqualStrings("zz/2.txt", asc[1].path);
    try t.expectEqualStrings("aa/1.txt", asc[2].path);
    var desc = [_]InFile{ a1, z2, z0 };
    std.mem.sort(InFile, &desc, SortCtx{ .key = .path, .reverse = true }, cmpFiles);
    try t.expectEqualStrings("zz/2.txt", desc[0].path);
    try t.expectEqualStrings("zz/0.txt", desc[1].path);
    try t.expectEqualStrings("aa/1.txt", desc[2].path);
}

test "pathLess: separator ranks below every byte (ripgrep Path::cmp parity)" {
    const t = std.testing;
    // The adversarial collision `--sortr path` surfaced against rg: a raw byte
    // compare puts `.`(0x2e) < `/`(0x2f), but ripgrep compares component-wise, so
    // the directory `warroom/…` sorts before the file `warroom.go`.
    try t.expect(pathLess("dir/warroom/service.go", "dir/warroom.go"));
    try t.expect(!pathLess("dir/warroom.go", "dir/warroom/service.go"));
    // A prefix path still sorts before its extension, and before a deeper child.
    try t.expect(pathLess("a/b", "a/b.go"));
    try t.expect(pathLess("a/b", "a/b/c"));
    // Non-separator bytes keep their natural order; equal paths are not `<`.
    try t.expect(pathLess("a/x.go", "a/y.go"));
    try t.expect(!pathLess("a/x.go", "a/x.go"));
    // A full sort of the collision set is the exact mirror under reverse.
    const wr = InFile{ .path = "svc/warroom.go", .bytes = "", .sort_time = 0 };
    const ws = InFile{ .path = "svc/warroom/service.go", .bytes = "", .sort_time = 0 };
    var asc = [_]InFile{ wr, ws };
    std.mem.sort(InFile, &asc, SortCtx{ .key = .path, .reverse = false }, cmpFiles);
    try t.expectEqualStrings("svc/warroom/service.go", asc[0].path);
    try t.expectEqualStrings("svc/warroom.go", asc[1].path);
    var desc2 = [_]InFile{ ws, wr };
    std.mem.sort(InFile, &desc2, SortCtx{ .key = .path, .reverse = true }, cmpFiles);
    try t.expectEqualStrings("svc/warroom.go", desc2[0].path);
    try t.expectEqualStrings("svc/warroom/service.go", desc2[1].path);
}

test "stripLeadingFlags honors i/-i and strips the directive" {
    const t = std.testing;
    const ci = stripLeadingFlags("(?i)Foo.*bar").?;
    try t.expectEqualStrings("Foo.*bar", ci.rest);
    try t.expectEqual(@as(?bool, true), ci.caseless);
    const cs = stripLeadingFlags("(?-i)Foo").?;
    try t.expectEqualStrings("Foo", cs.rest);
    try t.expectEqual(@as(?bool, false), cs.caseless);
    const both = stripLeadingFlags("(?i-s)x").?; // `-` negates only what follows it
    try t.expectEqual(@as(?bool, true), both.caseless);
    try t.expectEqualStrings("x", both.rest);
}

test "stripLeadingFlags resolves m/s flags; u/-u select Unicode mode" {
    const t = std.testing;
    // `(?sm)` turns dotall + line anchors ON; `-` negates only what follows it.
    const sf = stripLeadingFlags("(?sm)^func$").?;
    try t.expectEqualStrings("^func$", sf.rest);
    try t.expectEqual(@as(?bool, null), sf.caseless);
    try t.expectEqual(@as(?bool, null), sf.unicode);
    try t.expectEqual(@as(?bool, true), sf.dotall);
    try t.expectEqual(@as(?bool, true), sf.line_anchors);
    // `(?-m)` clears line anchors (rg's whole-buffer `^`/`$`-at-BOF), dotall untouched.
    const nm = stripLeadingFlags("(?-m)^baz").?;
    try t.expectEqualStrings("^baz", nm.rest);
    try t.expectEqual(@as(?bool, false), nm.line_anchors);
    try t.expectEqual(@as(?bool, null), nm.dotall);
    // `(?-s)` clears dotall only.
    const ns = stripLeadingFlags("(?-s).").?;
    try t.expectEqual(@as(?bool, false), ns.dotall);
    try t.expectEqual(@as(?bool, null), ns.line_anchors);
    // `(?-u)` selects the byte/ASCII engine; `(?u)` re-selects the default.
    const nu = stripLeadingFlags("(?-u)\\w+").?;
    try t.expectEqualStrings("\\w+", nu.rest);
    try t.expectEqual(@as(?bool, null), nu.caseless);
    try t.expectEqual(@as(?bool, false), nu.unicode);
    const yu = stripLeadingFlags("(?u)\\w+").?;
    try t.expectEqualStrings("\\w+", yu.rest);
    try t.expectEqual(@as(?bool, true), yu.unicode);
    // Combined with case: `(?i-u)` is caseless + ASCII (the `-` negates only `u`).
    const iu = stripLeadingFlags("(?i-u)Foo").?;
    try t.expectEqual(@as(?bool, true), iu.caseless);
    try t.expectEqual(@as(?bool, false), iu.unicode);
}

test "stripLeadingFlags declines non-directive groups (parser decides)" {
    const t = std.testing;
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?i:foo)bar")); // scoped group
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?=foo)")); // lookahead
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?P<n>a)")); // named group
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?)x")); // empty directive
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("foo(?i)")); // not leading
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?i")); // unclosed
}

test "required literal gate reuses sound regex analysis" {
    const t = std.testing;
    var decl = Matcher{ .linear = try Regex.compile(t.allocator, "func\\s+\\w+\\(") };
    defer decl.deinit();
    try t.expectEqualStrings("func", requiredLiteralGate(t.allocator, .{}, "func\\s+\\w+\\(", &decl).?.bytes);

    var short = Matcher{ .linear = try Regex.compile(t.allocator, "[0-9a-f]{8}-[0-9a-f]{4}") };
    defer short.deinit();
    try t.expectEqualStrings("-", requiredLiteralGate(t.allocator, .{}, "[0-9a-f]{8}-[0-9a-f]{4}", &short).?.bytes);

    var common = Matcher{ .linear = try Regex.compile(t.allocator, "(foo|bar)baz") };
    defer common.deinit();
    try t.expectEqualStrings("baz", requiredLiteralGate(t.allocator, .{}, "(foo|bar)baz", &common).?.bytes);

    var alternatives = Matcher{ .linear = try Regex.compile(t.allocator, "(?:foo)|(?:bar)") };
    defer alternatives.deinit();
    try t.expect(requiredLiteralGate(t.allocator, .{}, "(?:foo)|(?:bar)", &alternatives) == null);
}

test "caseless gate: fold-closed literal, lowered spelling, pure-literal equivalence" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A pure literal with an ASCII-closed fold: gate present, lowered, equiv.
    var lit = Matcher{ .linear = try Regex.compileOpts(a, "WalletProvider", .{ .caseless = true, .unicode = true }) };
    const g = requiredLiteralGate(a, .{ .caseless = true }, "WalletProvider", &lit).?;
    try t.expect(g.ci);
    try t.expect(g.equiv);
    try t.expectEqualStrings("walletprovider", g.bytes);

    // A regex body keeps the gate (fold-closed required literal) without equiv.
    var rex = Matcher{ .linear = try Regex.compileOpts(a, "provider\\d+", .{ .caseless = true, .unicode = true }) };
    const gr = requiredLiteralGate(a, .{ .caseless = true }, "provider\\d+", &rex).?;
    try t.expect(gr.ci and !gr.equiv);
    try t.expectEqualStrings("provider", gr.bytes);

    // Kelvin/long-s orbits split the window under Unicode fold: "task" gates
    // on its "ta" prefix (containment only, never equivalence)…
    var risky = Matcher{ .linear = try Regex.compileOpts(a, "task", .{ .caseless = true, .unicode = true }) };
    const gk = requiredLiteralGate(a, .{ .caseless = true }, "task", &risky).?;
    try t.expect(gk.ci and !gk.equiv);
    try t.expectEqualStrings("ta", gk.bytes);
    // …an all-escaping literal declines entirely…
    var sks = Matcher{ .linear = try Regex.compileOpts(a, "sks", .{ .caseless = true, .unicode = true }) };
    try t.expect(requiredLiteralGate(a, .{ .caseless = true }, "sks", &sks) == null);
    // …and ASCII fold admits the whole literal, equivalence included.
    var ascii = Matcher{ .linear = try Regex.compileOpts(a, "task", .{ .caseless = true, .unicode = false }) };
    const ga = requiredLiteralGate(a, .{ .caseless = true, .unicode = false }, "task", &ascii).?;
    try t.expect(ga.ci and ga.equiv);
    try t.expectEqualStrings("task", ga.bytes);
}

test "whole-file gate preserves all-byte modes" {
    const t = std.testing;
    const needle: ?simd.Gate = .{ .bytes = "func" };
    try t.expectEqualStrings("func", wholeFileLiteralGate(.{}, needle).?.bytes);
    try t.expect(wholeFileLiteralGate(.{ .passthru = true }, needle) == null);
    try t.expect(wholeFileLiteralGate(.{ .stats = true }, needle) == null);
    try t.expect(wholeFileLiteralGate(.{ .json = true }, needle) == null);
    try t.expect(wholeFileLiteralGate(.{ .files_without = true }, needle) == null);
}

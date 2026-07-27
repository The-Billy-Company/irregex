//! gist — the descent: one worker's whole life, from popping a directory to
//! handing each admitted file to the per-file search.
//!
//! `workerMain` is this module's entire surface. Underneath it: the live
//! listing (one `getattrlistbulk` batch, with a portable readdir fallback on a
//! freshly reopened handle), the phantom-snapshot listing that serves a
//! provably-unchanged directory's membership from a mapping in ONE syscall, the
//! immutable per-directory ignore chain, the admission gauntlet every entry
//! runs (ignore → hidden → glob/type → depth → index elision → content shard),
//! and the deferral backlog for files walked before the elide oracle landed.
//!
//! Admission parity with the serial walker is by construction: every verdict
//! comes from the same `ignore.zig` rule core, applied in the same order.

const std = @import("std");
const args = @import("../../argv/args.zig");
const bulkstat = @import("../../../../../corpus/tree/bulkstat.zig");
const corpus_mod = @import("../../../../../corpus/tree/corpus.zig");
const crew = @import("crew.zig");
const inode = @import("../../read/inode.zig");
const notice = @import("../../quarry/notice.zig");
const ignore = @import("../../../../../corpus/tree/ignore.zig");
const paths_mod = @import("../../../../../corpus/scope/paths.zig");
const queue = @import("queue.zig");
const sift = @import("sift.zig");
const treemap = @import("../../../../../corpus/index/phantom/treemap.zig");
const portal = @import("../../../../../portal.zig");

const Cfg = crew.Cfg;
const Dir = std.Io.Dir;
const DirTask = queue.DirTask;
const Queue = queue.Queue;
const Worker = crew.Worker;
const joinPath = paths_mod.join;
const oom = args.oom;
const replaceSep = paths_mod.replaceSep;
const searchFile = sift.searchFile;
const searchShardBody = sift.searchShardBody;
const stripDot = paths_mod.stripDot;

// ─────────────────────────── ignore chain ───────────────────────────

// The per-directory ignore CHAIN (immutable, worker-arena-lived) and its
// build/fold helpers live in `ignore.zig` — one rule core so the serial walker,
// this search engine, and the fused corpus loader (`corpus/tree/loadpar.zig`)
// cannot drift. Aliased here so every existing call site reads unchanged.
const IgNode = ignore.IgNode;
const applyChain = ignore.applyChain;
const readIgnoreFile = ignore.readIgnoreFile;
const appendRules = ignore.appendRules;
const IgPresent = ignore.IgPresent;
const loadNode = ignore.loadNode;
const noteIgnoreFile = ignore.noteIgnoreFile;

/// The full skip decision for one walked entry: frozen-base verdict —
/// `Compiled.matchRank` (hash-probing fast tier) when available, else
/// `decideAt` — overridden by the per-directory chain, then the shared
/// `.git`/hidden folding (`skipFromVerdict`). Threads the same ripgrep
/// whitelist-override pair (`Filter.whitelists`/`whitelistsHidden`) the serial
/// engine's `walkDirLinked` computes per entry — see `Ignore.shouldSkip`'s doc
/// comment for the asymmetry (`-g`/`--iglob` bypasses `.git`+ignore, a `-t`
/// type match only un-hides) this engine must reproduce byte-for-byte.
fn shouldSkip(cfg: *const Cfg, chain: ?*const IgNode, a: std.mem.Allocator, task: DirTask, rel: []const u8, scope_rel: []const u8, is_dir: bool, basename: []const u8) bool {
    const ig = cfg.ig;
    // Both tiers are scoped to the repository that encloses this entry: a
    // `.gitignore` above a nested checkout's `.git` is not this entry's repo's
    // business (`ignore.boundary`).
    const bound = ignore.boundary(ig, chain, rel);
    var v = ignore.baseVerdict(ig, cfg.compiled, rel, is_dir, task.root_depth, bound);
    applyChain(chain, a, ig.o.ignore_case_insensitive, task.root_depth, rel, is_dir, bound, &v);
    const wl_ig = cfg.o.filter.whitelists(a, scope_rel);
    const wl_hid = cfg.o.filter.whitelistsHidden(a, scope_rel);
    return ig.skipFromVerdict(v, basename, wl_ig, wl_hid);
}
/// A listed directory entry, normalized across the two listing backends and
/// the phantom snapshot. Snapshot entries (`from_snap`) carry no fd to resolve
/// against and no timestamps — `handleEntry` resolves them from CWD and, when
/// index elision could use freshness, learns the clocks with one lstat.
const Entry = struct {
    name: []const u8,
    is_dir: bool,
    is_file: bool,
    mtime_ns: ?i128,
    ctime_ns: ?i128,
    snap_ix: u32 = treemap.not_walked,
    from_snap: bool = false,
};

pub fn workerMain(w: *Worker) void {
    const a = w.arena.allocator();
    const scratch = w.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
    defer w.gpa.free(scratch);
    // Private LIFO stack: depth-first over directories this worker discovered
    // (parent listing still cache-warm), zero shared-queue traffic while it
    // has work. The shared queue is touched only to account (`noteDiscovered`
    // inside `processDir`, `done` here), to donate when a peer is parked, and
    // to blocking-pop when the local stack runs dry.
    var local: std.ArrayList(DirTask) = .empty;
    // Per-DIRECTORY scratch. A directory's bulk listing and entry array are dead
    // the instant `processDir` returns — every path that outlives it is COPIED
    // into the worker arena by `joinRel`/`joinPath` — so they recycle here rather
    // than accumulating O(entries in the tree) in the never-reset worker arena
    // for the whole walk. Residency becomes the widest single directory, not the
    // tree's size; the retain limit releases a pathological outlier's chunk
    // instead of pinning it for every directory that follows.
    var dirs: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer dirs.deinit();
    while (true) {
        if (w.q.aborted.load(.monotonic)) break; // downstream pipe closed — unwind now, not at tree's end
        const task = local.pop() orelse w.q.pop() orelse break;
        processDir(w, a, dirs.allocator(), scratch, task, &local);
        _ = dirs.reset(.{ .retain_with_limit = dir_scratch_retain });
        w.q.done();
        if (local.items.len > 1 and w.q.starving.load(.monotonic) > 0) {
            // Give away the SHALLOWEST half — the oldest entries fan out the
            // widest subtrees, which is what a starving peer wants.
            const give = local.items.len / 2;
            w.q.donate(local.items[0..give]);
            std.mem.copyForwards(DirTask, local.items[0 .. local.items.len - give], local.items[give..]);
            local.items.len -= give;
        }
        flushPending(w, a, scratch, false);
    }
    // The walk is over (or cancelled); resolve whatever is still deferred
    // (see the policy note on `flushPending`) — unless the pipe is already
    // gone, in which case there's nothing left to search FOR.
    if (!w.q.aborted.load(.monotonic)) {
        flushPending(w, a, scratch, true);
        w.flushFiles(); // drain the tail of this worker's coalesced path list
    }
}

/// Elide-or-search every deferred file. In-walk (`final=false`): only runs
/// once the loader has finished, retried after every directory. End-of-walk
/// (`final=true`): NEVER idles — but re-polls the loader per file as it drains
/// (see the loop), so a loader that lands mid-drain still elides the backlog's
/// tail. This keeps the "don't block on the oracle" contract (idling measured
/// 1.5x slower on warm `libs`-sized scopes) while recovering the cold-page-
/// cache race, where the 39 MiB index faults in after the fast metadata walk
/// has already deferred everything and the drain is long enough (disk-bound
/// reads) for the oracle to catch it.
fn flushPending(w: *Worker, a: std.mem.Allocator, scratch: []u8, final: bool) void {
    if (w.pending.items.len == 0) return;
    const lz = w.cfg.lazy.?; // pending is only ever fed when a loader exists
    var ready = lz.ready.load(.acquire);
    if (!ready and !final) return;
    const o = w.cfg.o;
    for (w.pending.items) |d| {
        // The oracle may still land while we drain: re-poll per file so its late
        // arrival elides the remaining tail instead of forfeiting every leftover
        // read. A cheap acquire load guarding an open+read, and it never idles —
        // a page-cache-warm reread just reads until the flip, so warm is untouched.
        if (final and !ready) ready = lz.ready.load(.acquire);
        if (ready) if (lz.val) |*el| if (el.skip(stripDot(d.rel), d.mtime_ns, d.ctime_ns)) {
            // Index proves no match: `--files-without-match` emits the path
            // without reading (the invert of `-l`'s elide-and-skip).
            if (o.mode.negated()) {
                const dpath = if (o.path_sep) |sep| replaceSep(a, d.rel, sep) else d.rel;
                w.bufferPath(dpath, if (o.null_sep) "\x00" else o.outTerm());
            }
            continue;
        };
        const dpath = if (o.path_sep) |sep| replaceSep(a, d.rel, sep) else d.rel;
        if (w.cfg.shard) |sh| if (sh.slice(stripDot(d.rel), d.mtime_ns, d.ctime_ns)) |bytes| {
            searchShardBody(w, a, dpath, bytes);
            continue;
        };
        searchFile(w, a, scratch, portal.cwd(), d.disk, dpath, d.disk);
    }
    w.pending.clearRetainingCapacity();
}

/// Display/ignore join: an explicit `.` root KEEPS its `./` prefix on every
/// emitted path (serial `relPath` / rg parity); only the implicit whole-CWD
/// walk ("" prefix) emits bare paths.
fn joinRel(a: std.mem.Allocator, prefix: []const u8, name: []const u8) []const u8 {
    // The result must be OWNED by `a` on both arms: `name` points into the
    // per-directory listing scratch `workerMain` recycles, while a path built
    // here can outlive its directory (a queued/donated `DirTask`, a deferred
    // `pending` row, a `--sort` record). The empty-prefix arm is the walk root's
    // own children only, so the copy is one directory's worth, not the tree's.
    return if (prefix.len == 0) (a.dupe(u8, name) catch oom()) else std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, name }) catch oom();
}

/// Ceiling on the recycled per-directory scratch a worker keeps warm between
/// directories. Big enough that an ordinary directory never re-enters the page
/// allocator, small enough that one 100k-entry directory does not pin its peak
/// for the rest of the walk.
const dir_scratch_retain: usize = 256 * 1024;

/// This directory's own ignore rules chained onto the parent's — unless the
/// frozen base already holds them (the CWD root, loaded by `Ignore.init`;
/// keyed by stripped rel). Shared by the live and phantom listings.
fn dirChain(cfg: *const Cfg, a: std.mem.Allocator, task: DirTask, present: IgPresent) ?*const IgNode {
    if (!cfg.o.no_ignore and (present.gitignore or present.dotignore or present.rgignore or present.dotgit) and
        !cfg.ig.loaded.contains(task.rel) and !cfg.ig.loaded.contains(stripDot(task.rel)))
        return loadNode(cfg.ig, a, task.chain, task.disk, task.rel, present) catch oom();
    return task.chain;
}

/// Everything the parallel descent can fail with: the raw `openat` this engine
/// uses instead of `std.Io` on a worker thread, and iterating a directory it
/// already opened. Naming the set instead of taking `anyerror` (ADR-373 law 2)
/// makes a widened std set a build failure here, where the walk can decide what
/// it means, rather than a mystery string on a user's stderr. It is a subset of
/// `notice.WalkFault`, so it coerces into the shared renderer.
const WalkFault = std.posix.OpenError || Dir.Iterator.Error;

/// The same walk-error contract `serial.zig`'s `reportWalkError` enforces
/// (rendering shared via `notice.printWalkError`), for the parallel engine:
/// a directory this walk discovered but could not open/descend is a POTENTIAL
/// false negative that MUST be signaled, never dropped in silence just because
/// a peer worker is mid-flight. Thread-safe (any worker may call concurrently).
fn reportWalkError(q: *Queue, rel: []const u8, e: WalkFault) void {
    notice.printWalkError(rel, e);
    q.walk_error.store(true, .release);
}

/// `a` is the worker arena — everything that outlives this directory. `sa` is the
/// per-directory scratch `workerMain` recycles after this call returns, and holds
/// exactly the two structures that die with the directory: the bulk listing and
/// the entry array built over it.
fn processDir(w: *Worker, a: std.mem.Allocator, sa: std.mem.Allocator, scratch: []u8, task: DirTask, local: *std.ArrayList(DirTask)) void {
    const cfg = w.cfg;

    // Phantom walk: a recorded directory whose lstat proves BOTH clocks
    // predate the snapshot anchor has byte-exact recorded membership (POSIX
    // bumps a directory's mtime+ctime on any direct create/delete/rename) —
    // serve its listing from the mapping for ONE syscall instead of
    // openat+getattrlistbulk+close. A stale, unstat-able, or unrecorded
    // directory falls through to the live listing below unchanged.
    if (cfg.snap) |v| if (task.snap_ix != treemap.not_walked) {
        if (inode.lstatPath(task.disk)) |st| if (!bulkstat.needsLiveRead(v.anchor_ns, st.mtime_ns, st.ctime_ns)) {
            servePhantomDir(w, a, scratch, task, local, v);
            return;
        };
    };

    // Raw `openat` (worker-thread safe, no std.Io indirection) — the fd feeds
    // `getattrlistbulk` directly and is wrapped in a `Dir` only for the
    // portable fallback. An unreadable/EACCES directory is a walk error, not a
    // silent prune (rg parity — see `reportWalkError`).
    const fd = portal.openDir(portal.cwd(), task.disk) catch |e| {
        reportWalkError(w.q, task.rel, e);
        return;
    };
    var dir: Dir = .{ .handle = fd };
    var closed = false;
    defer if (!closed) {
        portal.close(dir.handle);
    };

    // List the whole directory FIRST — the names tell us which ignore files
    // exist here, so the chain build below never blind-probes the disk.
    var entries: std.ArrayList(Entry) = .empty;
    var present: IgPresent = .{};
    const bulk_ok = bulkstat.supported and blk: {
        // With index elision live, each entry's mtime+ctime ride the bulk
        // listing for free; without it, names+types via getdirentries is cheaper.
        const listing = if (freshnessWanted(cfg)) bulkstat.listOneLevel(sa, dir.handle) else bulkstat.listNamesOnly(sa, dir.handle);
        // Declining routes to the portable fallback below; OOM is a fault and
        // takes this walk's one canonical exit rather than being mistaken for it.
        const listed = switch (listing catch oom()) {
            .declined => break :blk false,
            .got => |v| v,
        };
        // The listing already knows the count, so the entry array is sized once
        // instead of geometrically regrown (in an arena every regrowth abandons
        // the previous buffer, so growth churn is retained, not reused).
        entries.ensureTotalCapacityPrecise(sa, listed.len) catch oom();
        for (listed) |e| {
            noteIgnoreFile(&present, e.name, e.is_file);
            entries.appendAssumeCapacity(.{ .name = e.name, .is_dir = e.is_dir, .is_file = e.is_file, .mtime_ns = e.mtime_ns, .ctime_ns = e.ctime_ns });
        }
        break :blk true;
    };
    if (!bulk_ok) {
        if (bulkstat.supported) {
            // Bulk listing is all-or-nothing but shares the fd offset with
            // readdir — reopen a fresh handle before the portable fallback.
            portal.close(dir.handle);
            closed = true;
            const fd2 = portal.openDir(portal.cwd(), task.disk) catch |e| {
                reportWalkError(w.q, task.rel, e);
                return;
            };
            dir = .{ .handle = fd2 };
            closed = false;
        }
        var it = dir.iterate();
        while (true) {
            // A `next` error is this directory's iteration failing after it was
            // opened (deleted mid-walk, FS error): report it and STOP iterating
            // THIS directory (the reader's cursor never advances past a failed
            // read — see std.Io.Dir.Reader.next / SelectiveWalker.next's own
            // "all future `next` calls would likely just fail with the same
            // error" comment — so a `continue` here would spin forever on the
            // same errno). The walk still finishes every OTHER directory; rg's
            // own "keep walking past an error" behavior is preserved at the
            // per-directory grain via the queue draining other tasks.
            const maybe = it.next(w.io) catch |e| {
                reportWalkError(w.q, task.rel, e);
                break;
            };
            const e = maybe orelse break;
            if (e.kind != .file and e.kind != .directory) continue;
            var mtime: ?i128 = null;
            var ctime: ?i128 = null;
            // Change timestamps are only consulted for elision candidates;
            // stat lazily there. A failed stat leaves both unknown, forcing read.
            if (e.kind == .file and freshnessWanted(cfg)) if (dir.statFile(w.io, e.name, .{}) catch null) |st| {
                mtime = st.mtime.nanoseconds;
                ctime = st.ctime.nanoseconds;
            };
            // The iterator's name buffer is reused on the next `next()` — this
            // directory's entry array holds the copy, and every path built from
            // it is itself copied into the worker arena by `joinRel`/`joinPath`.
            const name = sa.dupe(u8, e.name) catch oom();
            noteIgnoreFile(&present, name, e.kind == .file);
            entries.append(sa, .{ .name = name, .is_dir = e.kind == .directory, .is_file = e.kind == .file, .mtime_ns = mtime, .ctime_ns = ctime }) catch oom();
        }
    }

    // A live-listed directory that HAS a snapshot record (its own clocks were
    // stale) still hands each child directory ITS record, so phantom serving
    // resumes immediately below the one changed level.
    if (cfg.snap) |v| if (task.snap_ix != treemap.not_walked) {
        for (entries.items) |*e| {
            if (!e.is_dir) continue;
            for (v.children(task.snap_ix)) |ent| {
                if (ent.isDir() and std.mem.eql(u8, v.name(ent), e.name)) {
                    e.snap_ix = ent.dir_ix;
                    break;
                }
            }
        }
    };

    const chain = dirChain(cfg, a, task, present);

    // Children go on the worker's own stack; only the COUNT touches the
    // shared queue (accounting must precede this task's `done`).
    const before = local.items.len;
    for (entries.items) |e| handleEntry(w, a, scratch, dir.handle, task, chain, local, e);
    w.q.noteDiscovered(local.items.len - before);
}

/// The phantom twin of `processDir`'s listing half: children come straight
/// from the snapshot mapping (names + kinds — the lstat in `processDir`
/// just proved them current), the ignore chain builds from the recorded
/// ignore-file NAMES with rule CONTENT read live from disk, and every child
/// then flows through the same `handleEntry` the live listing feeds. Snapshot
/// entries resolve from CWD (`from_snap`) since no directory fd is open.
fn servePhantomDir(w: *Worker, a: std.mem.Allocator, scratch: []u8, task: DirTask, local: *std.ArrayList(DirTask), v: *const treemap.View) void {
    const cfg = w.cfg;
    const kids = v.children(task.snap_ix);
    var present: IgPresent = .{};
    for (kids) |ent| noteIgnoreFile(&present, v.name(ent), !ent.isDir());
    const chain = dirChain(cfg, a, task, present);
    const before = local.items.len;
    for (kids) |ent| handleEntry(w, a, scratch, portal.cwd(), task, chain, local, .{
        .name = v.name(ent),
        .is_dir = ent.isDir(),
        .is_file = !ent.isDir(),
        .mtime_ns = null,
        .ctime_ns = null,
        .snap_ix = ent.dir_ix,
        .from_snap = true,
    });
    w.q.noteDiscovered(local.items.len - before);
}

/// Before the loader decides, both timestamps are needed for deferred elision.
/// Once it declines a dense/small index, switch later directories back to the
/// cheaper names-only listing immediately.
fn needsElisionMetadata(cfg: *const Cfg) bool {
    const lazy = cfg.lazy orelse return false;
    if (!lazy.ready.load(.acquire)) return true;
    return lazy.val != null;
}

/// Whether the walk should learn each file's mtime+ctime — for index elision
/// (above) OR to let the content shard prove a file unchanged before serving
/// its bytes from the mapping. The shard turns a full-scan query (no elision)
/// from names-only listing back to the clock-bearing `listOneLevel`, trading a
/// per-directory bulk-attr call for ~20k avoided file opens.
fn freshnessWanted(cfg: *const Cfg) bool {
    return needsElisionMetadata(cfg) or cfg.shard != null or cfg.freshness_meta;
}

fn handleEntry(w: *Worker, a: std.mem.Allocator, scratch: []u8, dirfd: std.posix.fd_t, task: DirTask, chain: ?*const IgNode, children: *std.ArrayList(DirTask), e: Entry) void {
    const cfg = w.cfg;
    const o = cfg.o;
    if (!e.is_dir and !e.is_file) return; // symlinks & specials — never followed here
    const depth = task.depth + 1;
    const rel = joinRel(a, task.rel, e.name);
    const scope_rel = joinRel(a, task.scope, e.name);
    if (shouldSkip(cfg, chain, a, task, rel, scope_rel, e.is_dir, e.name)) return;
    if (e.is_dir) {
        if (o.max_depth != 0 and depth >= o.max_depth) return;
        children.append(a, .{ .disk = joinPath(a, task.disk, e.name) catch oom(), .rel = rel, .scope = scope_rel, .depth = depth, .root_depth = task.root_depth, .chain = chain, .snap_ix = e.snap_ix }) catch oom();
        return;
    }
    if (o.max_depth != 0 and depth > o.max_depth) return;
    if (o.filter.active() and !o.filter.admits(a, scope_rel)) return;
    // Admitted: every filter that decides "would rg have searched this file"
    // has passed. Flag BEFORE index elision — an elided file still counts as
    // walked for the implicit-path nothing-searched heuristic (see `Queue`).
    if (!w.q.files_seen.load(.monotonic)) w.q.files_seen.store(true, .monotonic);
    // A snapshot-served file carries no clocks; when elision could use them,
    // one lstat learns the SAME conservative freshness pair the bulk listing
    // returns — and only for files every earlier filter already admitted
    // (a glob-rejected file never pays it; the bulk path pays for all).
    var mtime = e.mtime_ns;
    var ctime = e.ctime_ns;
    if (e.from_snap and freshnessWanted(cfg)) if (inode.lstatPath(joinPath(a, task.disk, e.name) catch oom())) |st| {
        mtime = st.mtime_ns;
        ctime = st.ctime_ns;
    };
    if (cfg.lazy) |lz| {
        if (lz.ready.load(.acquire)) {
            if (lz.val) |*el| if (el.skip(stripDot(scope_rel), mtime, ctime)) {
                // Index proves no match: `--files-without-match` emits without
                // reading (invert of `-l`'s elide-and-skip). `--stats` never
                // arms the oracle (see `want_elision`), so it can't land here.
                if (o.mode.negated()) {
                    const dpath = if (o.path_sep) |sep| replaceSep(a, rel, sep) else rel;
                    w.bufferPath(dpath, if (o.null_sep) "\x00" else o.outTerm());
                }
                return;
            };
        } else {
            // Oracle still loading — hold the file back so it can still be
            // elided (the walk races ahead; deferring costs three slices + metadata).
            w.pending.append(a, .{ .disk = joinPath(a, task.disk, e.name) catch oom(), .rel = rel, .mtime_ns = mtime, .ctime_ns = ctime }) catch oom();
            return;
        }
    }

    const dpath = if (o.path_sep) |sep| replaceSep(a, rel, sep) else rel;
    if (cfg.files_mode) {
        // `collectFileSet`: carry the walk-time clocks with the path so the
        // daemon's reconcile reads freshness off the walk (no per-file stat).
        if (cfg.freshness_meta) {
            w.recs.append(w.gpa, .{ .path = dpath, .kind = .text_hit, .buf = "", .mtime_ns = mtime, .ctime_ns = ctime }) catch oom();
            return;
        }
        // Coalesced into the worker's path-list buffer — one locked write per
        // ~64 KiB chunk instead of a lock+syscall per listed file.
        w.bufferPath(dpath, if (o.null_sep) "\x00" else "\n");
        return;
    }
    // Content shard: an unchanged corpus file's bytes are already mmap'd, so
    // serve them straight into the match/emit tail instead of opening the file
    // (the whole point on a full-scan query). A miss (changed, new, binary,
    // oversize, out-of-scope) falls through to the live open below.
    if (cfg.shard) |sh| if (sh.slice(stripDot(rel), mtime, ctime)) |bytes| {
        searchShardBody(w, a, dpath, bytes);
        return;
    };
    // The parent directory is still open in `processDir` — resolve one
    // component (`e.name`) against its fd instead of the full path from CWD.
    // A snapshot-served entry has no open parent; it resolves from CWD like a
    // deferred read. `rel` is the CWD-openable path a `-z` external-codec
    // subprocess re-opens.
    if (e.from_snap)
        searchFile(w, a, scratch, portal.cwd(), joinPath(a, task.disk, e.name) catch oom(), dpath, rel)
    else
        searchFile(w, a, scratch, dirfd, e.name, dpath, rel);
}

//! The descent: one worker's whole life, from popping a directory to
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

// MONOLITHIC: the two ways to obtain a directory's children — the live listing and
// the phantom-snapshot serving — are one admission contract, not two modules: both
// must reach `handleEntry` with entries carrying identical verdicts, and the
// snapshot half additionally decides on cost whether to serve at all. Splitting
// the halves apart would make `handleEntry`/`dirChain`/`freshnessWanted` public to
// hide 80 lines, widening this module's surface to serve a line count. The real cut
// is to lift the per-child admission pipeline into its own module that BOTH halves
// import; see the registry row's fix note.

const std = @import("std");
const bulkstat = @import("../../../../corpus/tree/bulkstat.zig");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const crew = @import("crew.zig");
const haystack = @import("../../../../corpus/tree/haystack.zig");
const inode = @import("../../../../corpus/read/inode.zig");
const notice = @import("../../quarry/notice.zig");
const ignore = @import("../../../../corpus/tree/ignore.zig");
const paths_mod = @import("../../../../corpus/scope/paths.zig");
const queue = @import("queue.zig");
const sift = @import("sift.zig");
const treemap = @import("../../../../corpus/index/phantom/treemap.zig");
const portal = @import("../../../../portal.zig");

const Cfg = crew.Cfg;
const Dir = std.Io.Dir;
const DirTask = queue.DirTask;
const Opts = @import("../../argv/args.zig").Opts;
const Queue = queue.Queue;
const Worker = crew.Worker;
const joinPath = paths_mod.join;
const oom = @import("../../../../surface/cli/outcome.zig").oom;
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
///
/// Charter / `<prefix>SKIP` / `skips.list` directory basenames are pruned first and
/// unconditionally: they size the corpus, so `-uu`/`-g` cannot un-hide them
/// (see `haystack.isPolicySkip`). The generic baseline (`.git`, `node_modules`,
/// …) is deliberately not consulted here — ripgrep parity requires `-uu` to
/// enter those.
fn shouldSkip(cfg: *const Cfg, chain: ?*const IgNode, a: std.mem.Allocator, task: DirTask, rel: []const u8, scope_rel: []const u8, is_dir: bool, basename: []const u8) bool {
    if (is_dir and haystack.isPolicySkip(basename)) return true;
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
        // This walk may not be the walk the pool was sized for — a directory
        // boundary is where a worker can cheaply notice that and hire (`consider`
        // is one relaxed load once the crew is at its ceiling, which it is for
        // every walk that never widens).
        if (w.crew) |c| c.consider(w.q);
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
    for (w.pending.items) |d| {
        // The oracle may still land while we drain: re-poll per file so its late
        // arrival elides the remaining tail instead of forfeiting every leftover
        // read. A cheap acquire load guarding an open+read, and it never idles —
        // a page-cache-warm reread just reads until the flip, so warm is untouched.
        if (final and !ready) ready = lz.ready.load(.acquire);
        if (ready) if (lz.val) |*el| if (el.skip(stripDot(d.rel), d.mtime_ns, d.ctime_ns)) {
            emitElided(w, a, d.rel);
            continue;
        };
        const dpath = shownPath(w.cfg.o, a, d.rel);
        if (servedFromShard(w, a, d.rel, dpath, d.mtime_ns, d.ctime_ns)) continue;
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

/// The path as EMITTED. `--path-separator` rewrites every separator, and the
/// rewrite is a copy, so it is built only when the flag is set — the unflagged
/// run borrows `rel` and allocates nothing. Both the walk and the deferred
/// backlog render through here, which is what keeps a `-l` listing and its
/// elided twin spelling the same path.
inline fn shownPath(o: Opts, a: std.mem.Allocator, rel: []const u8) []const u8 {
    return if (o.path_sep) |sep| replaceSep(a, rel, sep) else rel;
}

/// This entry's CWD-openable path, owned by `a`. Built only where one is
/// genuinely needed — a queued child directory, a deferred read, a
/// snapshot-served file with no open parent fd — since a live-listed file
/// resolves its single component against the still-open directory instead.
inline fn diskPath(a: std.mem.Allocator, task: DirTask, e: Entry) []const u8 {
    return joinPath(a, task.disk, e.name) catch oom();
}

/// A file the index proved cannot match. Under a negated mode
/// (`--files-without-match`) that verdict IS the output, so the path is emitted
/// without ever opening the file — the invert of `-l`'s elide-and-skip. Every
/// other mode emits nothing and the file is simply gone from the walk.
/// `--stats` never arms the oracle (see `want_elision`), so it cannot land here.
inline fn emitElided(w: *Worker, a: std.mem.Allocator, rel: []const u8) void {
    const o = w.cfg.o;
    if (!o.mode.negated()) return;
    w.bufferPath(shownPath(o, a, rel), if (o.null_sep) "\x00" else o.outTerm());
}

/// Content shard: an unchanged corpus file's bytes are already mmap'd, so serve
/// them straight into the match/emit tail instead of opening the file — the
/// whole point on a full-scan query. False ⇒ a miss (changed, new, binary,
/// oversize, out of scope) that the caller must read live, byte-identically.
inline fn servedFromShard(w: *Worker, a: std.mem.Allocator, rel: []const u8, dpath: []const u8, mtime: ?i128, ctime: ?i128) bool {
    const sh = w.cfg.shard orelse return false;
    const bytes = sh.slice(stripDot(rel), mtime, ctime) orelse return false;
    searchShardBody(w, a, dpath, bytes);
    return true;
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
/// already opened. Naming the set instead of taking `anyerror` (fault-channel law 2)
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
    // directory falls through to the live listing below unchanged, as does one
    // the snapshot would lose money on (see `servePhantomDir`).
    if (cfg.snap) |v| if (task.snap_ix != treemap.not_walked) {
        if (servePhantomDir(w, a, sa, scratch, task, local, v)) return;
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
    // Attempt the batched listing only where it beats the portable iterator. With
    // index elision live it always does — the timestamps ride along, so no
    // candidate file needs its own stat. Without it the question is per platform,
    // and on Windows the answer is no: `Dir.Iterator` there is already the same
    // `NtQueryDirectoryFile`, so the drain would buy an owned array and a copy for
    // nothing (`bulkstat.names_undercut_iterator`).
    const try_bulk = bulkstat.supported and (freshnessWanted(cfg) or bulkstat.names_undercut_iterator);
    const bulk_ok = try_bulk and blk: {
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
        if (try_bulk) {
            // Bulk listing is all-or-nothing but shares the fd offset with
            // readdir — reopen a fresh handle before the portable fallback. Gated
            // on the ATTEMPT, not on `supported`: a platform that skipped the
            // drain never moved the cursor, and on Windows an open is the one
            // operation every filesystem filter driver is interposed on.
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
    for (entries.items) |e| handleEntry(w, a, sa, scratch, dir.handle, task, chain, local, e);
    w.q.noteDiscovered(local.items.len - before);
}

/// The phantom twin of `processDir`'s listing half: children come straight from
/// the snapshot mapping (names + kinds), the ignore chain builds from the
/// recorded ignore-file NAMES with rule CONTENT read live from disk, and every
/// child then flows through the same `handleEntry` the live listing feeds.
/// Snapshot entries resolve from CWD (`from_snap`) since no directory fd is open.
/// False ⇒ nothing was served and `processDir` must list this directory live.
///
/// The single pass over `kids` is doing three jobs at once, and that fusion is
/// the point: it notes which ignore files exist, decides each file child's
/// path-filter verdict, and counts the admitted files — because that count,
/// against `phantom_stat_budget`, is what says whether serving pays at all.
/// Only filters that are pure functions of the path are consulted, so the count
/// is an upper BOUND: ignore rules can admit strictly fewer files, never more,
/// and overestimating merely routes a directory to a live listing that answers
/// identically. Declining costs no syscall — the probing `lstat` is spent only
/// once serving is known to be worth it.
fn servePhantomDir(w: *Worker, a: std.mem.Allocator, sa: std.mem.Allocator, scratch: []u8, task: DirTask, local: *std.ArrayList(DirTask), v: *const treemap.View) bool {
    const cfg = w.cfg;
    const kids = v.children(task.snap_ix);
    // Clocks are what make serving cost anything: without them (`--files`, a
    // declined oracle and no shard) there is no per-file stat to budget, so every
    // child is served and the filter stays `handleEntry`'s sole business.
    const wants_clocks = freshnessWanted(cfg);
    const filter = cfg.o.filter;
    const filtered = filter.active();
    // Which file children survive the path filter, for the ≤ budget of them a
    // served directory may hold. `handleEntry` re-decides only the ones it is
    // handed, so this is the whole filter cost the phantom path pays — one
    // evaluation per child, not the two a separate cost pre-pass would charge.
    var admitted: [phantom_stat_budget]u32 = undefined;
    var n_admitted: usize = 0;
    var present: IgPresent = .{};
    // `admits` allocates only for `--iglob`'s case fold, and the joined path
    // never outlives its iteration — so both ride reset-per-child stack buffers
    // rather than the worker arena. `--iglob` folds BOTH the glob and the path
    // per pattern, and its `lowerDup` aborts rather than reporting a short
    // buffer, so the fold has to be proven wide enough BEFORE the call. Iglob
    // spellings are fixed per run; only the path length varies per child.
    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    var foldbuf: [std.fs.max_path_bytes]u8 = undefined;
    var fold = std.heap.FixedBufferAllocator.init(&foldbuf);
    var iglob_bytes: usize = 0;
    for (filter.iglobs) |g| iglob_bytes += g.len;
    for (kids, 0..) |ent, i| {
        const name = v.name(ent);
        const is_dir = ent.isDir();
        noteIgnoreFile(&present, name, !is_dir);
        if (is_dir or !wants_clocks) continue; // a child dir is queued, never stat'd here
        if (filtered) {
            const scope_rel = if (task.scope.len == 0) name else std.fmt.bufPrint(&pathbuf, "{s}/{s}", .{ task.scope, name }) catch return false;
            if (iglob_bytes + filter.iglobs.len * scope_rel.len > foldbuf.len) return false;
            fold.reset();
            if (!filter.admits(fold.allocator(), scope_rel)) continue;
        }
        if (n_admitted == phantom_stat_budget) return false; // the live listing is cheaper
        admitted[n_admitted] = @intCast(i);
        n_admitted += 1;
    }

    // Worth serving — now spend the one syscall that proves the recorded
    // membership current. A stale or unstat-able directory declines to live.
    const st = inode.lstatPath(task.disk) orelse return false;
    if (bulkstat.needsLiveRead(v.anchor_ns, st.mtime_ns, st.ctime_ns)) return false;

    const chain = dirChain(cfg, a, task, present);
    const before = local.items.len;
    var next: usize = 0;
    for (kids, 0..) |ent, i| {
        const is_dir = ent.isDir();
        // A file the filter already rejected would return from `handleEntry` at
        // its own identical filter check, before it can flag `files_seen` or emit
        // anything — so skipping it here is byte-invisible and saves the walk a
        // second verdict on every non-matching child.
        if (wants_clocks and !is_dir) {
            if (next >= n_admitted or admitted[next] != i) continue;
            next += 1;
        }
        handleEntry(w, a, sa, scratch, portal.cwd(), task, chain, local, .{
            .name = v.name(ent),
            .is_dir = is_dir,
            .is_file = !is_dir,
            .mtime_ns = null,
            .ctime_ns = null,
            .snap_ix = ent.dir_ix,
            .from_snap = true,
        });
    }
    w.q.noteDiscovered(local.items.len - before);
    return true;
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
///
/// A corpus-wide certificate (`fresh.Certificate`) answers ahead of all of them,
/// and it answers for the whole corpus at once: once the journal has proven every
/// corpus file predates the anchor, there is nothing a per-file measurement could
/// add, so the walk stays on the names-only listing and the phantom snapshot
/// stops declining directories it would otherwise have to buy clocks for. The
/// verdict is always settled before the first directory opens (`swarm` waits for
/// it), so this reads a fixed value for the whole walk rather than a race.
///
/// `freshness_meta` is exempt — the daemon's `collectFileSet` wants the clocks
/// THEMSELVES as data to carry forward, not a freshness verdict, and a
/// certificate cannot supply a measurement it never made.
fn freshnessWanted(cfg: *const Cfg) bool {
    if (cfg.freshness_meta) return true;
    if (cfg.cert != null) return false;
    return needsElisionMetadata(cfg) or cfg.shard != null;
}

/// The clock pair a file's freshness decision reads. Ordinarily the walk's own —
/// from the bulk listing, or one `lstat` for a snapshot-served entry that carries
/// none. Under a corpus-wide certificate there is nothing left to measure: the
/// journal already proved every corpus file predates that anchor, so the pair IS
/// the certificate, rendered in the one currency `needsLiveRead` reads. That
/// keeps a single freshness predicate in the system instead of a second parallel
/// decision path that could drift from it.
///
/// Dating the pair at the CERTIFICATE's own anchor is what makes it safe against
/// a consumer carrying a different one. The content shard is self-anchored, so
/// both directions matter: a shard built AFTER this anchor still serves (nothing
/// changed since the anchor, so nothing changed before the shard's either), while
/// an OLDER shard is refused by `needsLiveRead` and reads live — slower, never
/// wrong. A file the certificate cannot speak for at all (never indexed, hence in
/// neither the path table nor the shard) is refused on MEMBERSHIP by
/// `Oracle.skip` / `shard.slice` before these clocks are ever consulted.
fn freshnessOf(cfg: *const Cfg, a: std.mem.Allocator, task: DirTask, e: Entry) struct { ?i128, ?i128 } {
    if (cfg.cert) |ns| return .{ ns - 1, ns - 1 };
    // Only a snapshot-served entry can still be missing its clocks here, and
    // only then is the path join worth building — a bulk-listed entry already
    // carries the pair, and a certificate needs no path at all.
    if (e.from_snap and freshnessWanted(cfg)) if (inode.lstatPath(diskPath(a, task, e))) |st| return .{ st.mtime_ns, st.ctime_ns };
    return .{ e.mtime_ns, e.ctime_ns };
}

/// Membership is free from the mapping either way. CLOCKS are not: a served
/// entry carries none, so under `freshnessWanted` every admitted file pays its
/// own path-resolving `lstat` (`handleEntry`), where the live listing recovers
/// every child's clocks inside the one `getattrlistbulk` it was already making.
/// So the trade inverts with the shape of the query — it is why a fresh snapshot
/// is not automatically worth serving, and the measurements are in
/// `corpus/index/phantom/README.md` rather than duplicated here.
///
/// The most admitted files a snapshot-served directory may carry before the live
/// listing is cheaper — MEASURED, not derived.
///
/// This was `listing_syscalls - 1` = 2, reasoning that a listing is three
/// syscalls and the probing `lstat` spends one of them. That model prices a
/// listing as three fixed syscalls, but `getattrlistbulk` resolves attributes for
/// EVERY entry in the directory, so a listing's real cost scales with the
/// directory's width while serving's scales with how many files the query wants.
/// Counting syscalls conflates the two, and it undercounted by ~3x.
///
/// Priced two ways, agreeing. From the primitives (min-of-9 over four corpora,
/// 538 to 15k directories): a path-resolving `lstat` runs 1.6–2.7 µs and one
/// listed entry 1.9–2.7 µs, putting break-even at 6.1, 6.8, 6.9 and 8.8 admitted
/// files. End-to-end on a 20k-file corpus (min-of-15, settings in rotating order
/// so drift on a loaded box cannot land on one): 1→46.1 ms, 2→39.6, 3→35.4,
/// 4→32.2, **6→30.1**, 8→30.2, 12→30.2. The knee is 6 and the plateau past it is
/// flat, so 6 buys the whole win without serving directories whose stats stop
/// paying for themselves. Worth 1.18–1.38x there across six query shapes ×
/// `-l`/`-n`, output md5-identical to both the previous constant and a
/// `--no-index` full read (the phantom parity gate covers that generally).
///
/// HOW MUCH this is worth is corpus-shaped, and the same sweep over llvm-project
/// (175k indexed files, wide C++ directories) says so: every cap from 1 to 16
/// lands inside noise there, 0.85–1.16x, with 6 at 0.96–1.08x across four query
/// shapes. The win needs directories holding 3–6 admitted files — the band the
/// old constant excluded. A tree of mostly generated and ignored siblings has
/// many; a tree where each directory is 10–50 source files has few, because those
/// exceed any small cap either way. So 6 is a clear win on one real corpus and
/// neutral on another, which is why it is a constant and not a tuned curve.
///
/// Do NOT re-derive this by counting syscalls. Two refinements were tried and
/// measured WORSE, recorded so they are not re-attempted: gating on directory
/// width (serve only when `1 + admitted < kids.len`) cost 0.82–0.84x across five
/// queries, because a served entry resolves its path from CWD through every
/// component and allocates the join, where a listed entry rides an already-open
/// dirfd; and a cap of 1 cost 0.90x.
const phantom_stat_budget: usize = 6;

fn handleEntry(w: *Worker, a: std.mem.Allocator, sa: std.mem.Allocator, scratch: []u8, dirfd: std.posix.fd_t, task: DirTask, chain: ?*const IgNode, children: *std.ArrayList(DirTask), e: Entry) void {
    const cfg = w.cfg;
    const o = cfg.o;
    if (!e.is_dir and !e.is_file) return; // symlinks & specials — never followed here
    const depth = task.depth + 1;
    // Which allocator this entry's paths and rendered bytes belong to. A path
    // outlives its directory on exactly three branches — a child directory's
    // queued task (any worker may pop it), a `--sort` record held for the ordered
    // replay, the daemon's collected file set — and those take the worker arena.
    // Every other entry is dead the moment it is rendered and emitted, so it
    // rides the per-directory scratch `workerMain` recycles. Charging all of them
    // to the worker arena made its growth track the TREE's file count rather than
    // the widest directory's: 29.4 MiB of retained path copies on a 175k-file
    // corpus that a scan never reads twice, which is most of what put our
    // owned scanner footprint above ripgrep's for identical work.
    const pa: std.mem.Allocator = if (e.is_dir or cfg.collect_sorted or cfg.freshness_meta) a else sa;
    // The display path and the scope-relative path are the SAME bytes on the
    // rootless whole-CWD walk and on any root whose scope prefix matches its
    // display prefix — which is every walk but an explicitly-rooted one. Joining
    // twice bought two copies of one string for every entry in the tree; one
    // prefix compare per entry replaces the second copy and the second join.
    const rel = joinRel(pa, task.rel, e.name);
    const scope_rel = if (std.mem.eql(u8, task.rel, task.scope)) rel else joinRel(pa, task.scope, e.name);
    if (shouldSkip(cfg, chain, pa, task, rel, scope_rel, e.is_dir, e.name)) return;
    if (e.is_dir) {
        if (o.max_depth != 0 and depth >= o.max_depth) return;
        children.append(a, .{ .disk = diskPath(a, task, e), .rel = rel, .scope = scope_rel, .depth = depth, .root_depth = task.root_depth, .chain = chain, .snap_ix = e.snap_ix }) catch oom();
        return;
    }
    if (o.max_depth != 0 and depth > o.max_depth) return;
    if (o.filter.active() and !o.filter.admits(pa, scope_rel)) return;
    // Admitted: every filter that decides "would rg have searched this file"
    // has passed. Flag BEFORE index elision — an elided file still counts as
    // walked for the implicit-path nothing-searched heuristic (see `Queue`).
    if (!w.q.files_seen.load(.monotonic)) w.q.files_seen.store(true, .monotonic);
    // A snapshot-served file carries no clocks; when elision could use them,
    // one lstat learns the SAME conservative freshness pair the bulk listing
    // returns — and only for files every earlier filter already admitted
    // (a glob-rejected file never pays it; the bulk path pays for all). Under a
    // corpus-wide certificate nobody pays it — see `freshnessOf`.
    const mtime, const ctime = freshnessOf(cfg, pa, task, e);
    if (cfg.lazy) |lz| {
        if (lz.ready.load(.acquire)) {
            if (lz.val) |*el| if (el.skip(stripDot(scope_rel), mtime, ctime)) {
                emitElided(w, pa, rel);
                return;
            };
        } else {
            // Oracle still loading — hold the file back so it can still be
            // elided (the walk races ahead; deferring costs three slices + metadata).
            // This is the one file branch that outlives its directory, so its path
            // is COPIED into the worker arena rather than left in the scratch
            // `workerMain` recycles the moment `processDir` returns.
            w.pending.append(a, .{ .disk = diskPath(a, task, e), .rel = a.dupe(u8, rel) catch oom(), .mtime_ns = mtime, .ctime_ns = ctime }) catch oom();
            return;
        }
    }

    const dpath = shownPath(o, pa, rel);
    if (cfg.files_mode) {
        // `collectFileSet`: carry the walk-time clocks with the path so the
        // daemon's reconcile reads freshness off the walk (no per-file stat).
        if (cfg.freshness_meta) {
            // `pa == a` on this branch (see above): the collected set is the daemon's
            // return value and outlives the walk entirely.
            w.recs.append(w.gpa, .{ .path = dpath, .kind = .text_hit, .buf = "", .mtime_ns = mtime, .ctime_ns = ctime }) catch oom();
            return;
        }
        // Coalesced into the worker's path-list buffer — one locked write per
        // ~64 KiB chunk instead of a lock+syscall per listed file.
        w.bufferPath(dpath, if (o.null_sep) "\x00" else "\n");
        return;
    }
    if (servedFromShard(w, pa, rel, dpath, mtime, ctime)) return;
    // The parent directory is still open in `processDir` — resolve one
    // component (`e.name`) against its fd instead of the full path from CWD.
    // A snapshot-served entry has no open parent; it resolves from CWD like a
    // deferred read. `rel` is the CWD-openable path a `-z` external-codec
    // subprocess re-opens.
    if (e.from_snap)
        searchFile(w, pa, scratch, portal.cwd(), diskPath(pa, task, e), dpath, rel)
    else
        searchFile(w, pa, scratch, dirfd, e.name, dpath, rel);
}

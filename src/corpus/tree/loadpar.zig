//! irregex — the fused parallel walk+read corpus loader (`corpus.load`'s
//! default path). The serial loader (`corpus.load`'s fallback) walks one
//! directory at a time, opening each, listing it, then reading its files, with
//! a single cursor for the whole tree — a walk that is ~⅓ the index-build wall
//! clock but leaves every core but one idle. This loader fuses walking and
//! reading into ONE work-stealing pipeline: each worker pops a directory,
//! opens it ONCE, and reads that directory's member files through the still-open
//! directory fd (`openat(dirfd, name)` — one-component namei) before donating
//! its surplus subdirectories to idle peers. On the working corpus that turns a
//! ~575 ms serial load into ~170 ms (measured against the search engine's own
//! whole-tree walk+read, which this mirrors), and it accelerates every build
//! verb that funnels through `corpus.load` (`gist index`, `relate index`,
//! `codex build`).
//!
//! Membership parity with the serial `haystack.Walker` is by construction, not
//! coincidence:
//!   • the ignore verdict for every entry comes from the SAME `ignore.zig`
//!     rule core — a frozen base `Ignore` (root/ancestor tiers loaded once)
//!     plus the immutable per-directory `ignore.IgNode` chain each worker
//!     builds as it descends (the parallel walker cannot mutate the shared
//!     `Ignore` per directory, so it carries the chain instead — the exact
//!     shape the search engine uses);
//!   • directory pruning applies `haystack.isSkipDir` THEN the ignore verdict,
//!     the same order `haystack.Walker.next` uses;
//!   • file admission reuses the shared predicates (`corpus.per_file_cap`,
//!     `corpus.isBinary`) so the empty / oversize / binary rejection is
//!     identical to `corpus.readMember` — only the read MECHANISM differs
//!     (raw POSIX, worker-thread safe, like the search engine's reads; the file
//!     content bytes and cap boundary are byte-for-byte the same).
//!
//! A frozen `Ignore` is read-only from every worker (no `loadDir`/`scopeToRoot`
//! after fan-out; `decideAt`/`skipFromVerdict`/`loaded.contains` only read), and
//! default `Options` (`ignore_case_insensitive = false`) means no allocation on
//! the shared `Ignore`'s allocator during the walk — the thread-safety contract
//! the serial build never needed but this one depends on.

const std = @import("std");
const ignore = @import("ignore.zig");
const haystack = @import("haystack.zig");
const bulkstat = @import("bulkstat.zig");
const corpus = @import("corpus.zig");
const inode = @import("../read/inode.zig");
const paths = @import("../scope/paths.zig");
const assay = @import("../../assay/assay.zig");
const fault = @import("../../fault.zig");
const portal = @import("../../portal.zig");

const Dir = std.Io.Dir;
const joinPath = paths.join;
const stripDot = paths.stripDot;
const rootDepth = paths.rootDepth;
const AT = std.posix.AT;

/// Allocation failure RETURNS here rather than exiting the process: this loader
/// is what `corpus.load` fuses on, and `corpus.load` stands up the corpus behind
/// every FFI entry, where an `exit(2)` would take the embedding host down with
/// it instead of yielding `IRGX_OOM` (fault-channel law 1).
///
/// An error cannot cross a thread boundary, so a worker that runs out of memory
/// records it in `Worker.oom` and then keeps RETIRING tasks without doing their
/// work: `Queue.pop` parks peers until `live` drains, so a worker that simply
/// stopped would deadlock the fan-out instead of failing it. `load` reads the
/// flags after the join and returns `error.OutOfMemory` for the whole walk — a
/// partial corpus is never handed back as if it were complete.
const Oom = std.mem.Allocator.Error;

/// A directory the walk has discovered but not yet processed. `disk` is
/// openable from CWD; `rel` is its root-joined display/ignore path (the
/// `haystack.joinRoot` shape — bare under a `.` root, `root/...` otherwise);
/// `chain` is the ignore-rule chain in effect at this directory (its parent's).
const DirTask = struct {
    disk: []const u8,
    rel: []const u8,
    root_depth: usize,
    chain: ?*const ignore.IgNode,
};

/// One listing entry — name owned by the lister's arena, kind bits only (the
/// build needs no timestamps: it reads every member unconditionally).
const Entry = struct { name: []const u8, is_dir: bool, is_file: bool };

/// The shared side of the work-stealing walk (the search engine's `Queue`,
/// trimmed to the build: no streaming abort, no walk-error signal, no
/// files-seen tripwire). Workers keep discovered directories on a private LIFO
/// stack and touch this only to account (`noteDiscovered`/`done`), to DONATE
/// surplus when a peer is `starving`, and to `pop` when their own stack drains.
const Queue = struct {
    mu: std.Io.Mutex = .init,
    cv: std.Io.Condition = .init,
    items: std.ArrayList(DirTask) = .empty,
    head: usize = 0,
    waiting: usize = 0,
    live: std.atomic.Value(usize) = .init(0),
    avail: std.atomic.Value(usize) = .init(0),
    starving: std.atomic.Value(u32) = .init(0),
    gpa: std.mem.Allocator,
    io: std.Io,

    fn wakeParked(q: *Queue) void {
        q.mu.lockUncancelable(q.io);
        const any = q.waiting > 0;
        q.mu.unlock(q.io);
        if (any) q.cv.broadcast(q.io);
    }

    fn noteDiscovered(q: *Queue, n: usize) void {
        if (n != 0) _ = q.live.fetchAdd(n, .acq_rel);
    }

    /// On OOM the tasks stay with the caller (still counted in `live`), so the
    /// donor must keep draining them itself rather than assume the handoff.
    fn donate(q: *Queue, tasks: []const DirTask) Oom!void {
        if (tasks.len == 0) return;
        q.mu.lockUncancelable(q.io);
        const appended = q.items.appendSlice(q.gpa, tasks);
        q.avail.store(q.items.items.len - q.head, .release);
        const wake = @min(tasks.len, q.waiting);
        q.mu.unlock(q.io);
        if (wake == 1) q.cv.signal(q.io) else if (wake > 1) q.cv.broadcast(q.io);
        return appended;
    }

    fn push(q: *Queue, tasks: []const DirTask) Oom!void {
        q.noteDiscovered(tasks.len);
        return q.donate(tasks);
    }

    fn pop(q: *Queue) ?DirTask {
        _ = q.starving.fetchAdd(1, .acq_rel);
        defer _ = q.starving.fetchSub(1, .acq_rel);
        var spins: u32 = 0;
        while (true) {
            if (q.avail.load(.acquire) != 0) {
                q.mu.lockUncancelable(q.io);
                if (q.head < q.items.items.len) {
                    const t = q.items.items[q.head];
                    q.head += 1;
                    q.avail.store(q.items.items.len - q.head, .release);
                    q.mu.unlock(q.io);
                    return t;
                }
                q.mu.unlock(q.io);
            }
            if (q.live.load(.acquire) == 0) return null;
            spins += 1;
            if (spins < 1 << 18) {
                std.atomic.spinLoopHint();
                continue;
            }
            q.mu.lockUncancelable(q.io);
            while (q.head >= q.items.items.len and q.live.load(.acquire) != 0) {
                q.waiting += 1;
                q.cv.waitUncancelable(q.io, &q.mu);
                q.waiting -= 1;
            }
            q.mu.unlock(q.io);
            spins = 0;
        }
    }

    fn done(q: *Queue) void {
        if (q.live.fetchSub(1, .acq_rel) == 1) q.wakeParked();
    }
};

/// One walker: its private arena owns everything it accumulates (doc bytes,
/// rel paths, ignore-chain nodes) and must outlive the whole walk, since a
/// donated task can carry chain/rel pointers into a peer's arena — every
/// worker arena stays alive until after `join`, then travels into the `Corpus`.
const Worker = struct {
    q: *Queue,
    io: std.Io,
    ig: *const ignore.Ignore,
    arena: std.heap.ArenaAllocator,
    docs: std.ArrayList([]const u8) = .empty,
    paths: std.ArrayList([]const u8) = .empty,
    bytes: u64 = 0,
    /// This worker hit an allocation failure; `load` fails the whole walk.
    oom: bool = false,
};

fn workerMain(w: *Worker) void {
    const a = w.arena.allocator();
    var local: std.ArrayList(DirTask) = .empty;
    while (true) {
        const task = local.pop() orelse w.q.pop() orelse break;
        // Once out of memory this loop retires the remaining backlog WITHOUT
        // doing its work: the corpus is already doomed, but `live` must still
        // drain to zero or the parked peers never wake (see `Oom` above).
        if (!w.oom) processDir(w, a, task, &local) catch {
            w.oom = true;
        };
        w.q.done();
        // Hand the widest half of the backlog (the deepest, most recently
        // discovered subtrees) to a hunting peer — same load-balancing the
        // search walk uses.
        if (local.items.len > 1 and w.q.starving.load(.monotonic) > 0) {
            const give = local.items.len / 2;
            if (w.q.donate(local.items[0..give])) {
                std.mem.copyForwards(DirTask, local.items[0 .. local.items.len - give], local.items[give..]);
                local.items.len -= give;
            } else |_| w.oom = true; // handoff failed → keep and drain them here
        }
    }
}

fn processDir(w: *Worker, a: std.mem.Allocator, task: DirTask, local: *std.ArrayList(DirTask)) Oom!void {
    const ig = w.ig;
    // Raw `openat` (worker-thread safe) — an unreadable/EACCES directory is
    // skipped (best-effort walk-on); the serial build surfaces it, but a
    // mid-build unreadable directory is pathological and a silent prune keeps
    // the parallel result a subset never a crash.
    const fd = portal.openDir(portal.cwd(), task.disk) catch return;
    var dir = Dir{ .handle = fd };
    var closed = false;
    defer if (!closed) {
        portal.close(dir.handle);
    };

    // List once — the names tell us which ignore files exist here, so the chain
    // build never blind-probes the disk. Names+types only (no timestamps): the
    // build reads every member regardless of freshness.
    var entries: std.ArrayList(Entry) = .empty;
    var present = ignore.IgPresent{};
    // Names alone, always — so this walk only wants the drain where the drain
    // undercuts the platform's own iterator. It does not on Windows, where
    // `Dir.Iterator` is already `NtQueryDirectoryFile` and the owned listing would
    // be a second array for the same syscall.
    const try_bulk = bulkstat.supported and bulkstat.names_undercut_iterator;
    var bulk_ok = false;
    if (try_bulk) {
        // The bulk-stat→readdir seam: a listing failure is this accelerator
        // declining, not a fault — `bulk_ok` stays false and the portable
        // fallback below does the same work, slower. Typed since fault-channel law 1,
        // so an OutOfMemory here propagates instead of masquerading as "this
        // platform has no getdirentries" and quietly retrying the slow path.
        switch (try bulkstat.listNamesOnly(a, dir.handle)) {
            .declined => {},
            .got => |listed| {
                for (listed) |e| {
                    ignore.noteIgnoreFile(&present, e.name, e.is_file);
                    try entries.append(a, .{ .name = e.name, .is_dir = e.is_dir, .is_file = e.is_file });
                }
                bulk_ok = true;
            },
        }
    }
    if (!bulk_ok) {
        if (try_bulk) {
            // Bulk listing shares the fd offset with readdir — reopen a fresh
            // handle before the portable fallback (same as the search walk).
            // Gated on the attempt: a platform that skipped the drain never moved
            // the cursor and must not pay a second open for nothing.
            portal.close(dir.handle);
            closed = true;
            const fd2 = portal.openDir(portal.cwd(), task.disk) catch return;
            dir = Dir{ .handle = fd2 };
            closed = false;
        }
        var it = dir.iterate();
        while (true) {
            const e = (it.next(w.io) catch break) orelse break;
            if (e.kind != .file and e.kind != .directory) continue;
            const name = try a.dupe(u8, e.name);
            ignore.noteIgnoreFile(&present, name, e.kind == .file);
            try entries.append(a, .{ .name = name, .is_dir = e.kind == .directory, .is_file = e.kind == .file });
        }
    }

    // This directory's own ignore rules — unless the frozen base already holds
    // them (the CWD/root tier `Ignore.init` loaded, keyed by stripped rel).
    var chain = task.chain;
    if (!ig.o.no_ignore and (present.gitignore or present.dotignore or present.rgignore or present.dotgit) and
        !ig.loaded.contains(task.rel) and !ig.loaded.contains(stripDot(task.rel)))
        chain = try ignore.loadNode(ig, a, task.chain, task.disk, task.rel, present);

    // Children accrue on the worker's own stack; only the COUNT touches the
    // shared queue, and it must be accounted before this task's `done` — on an
    // OOM mid-loop too, or the tasks already stacked would be retired against
    // a `live` that never counted them.
    const before = local.items.len;
    defer w.q.noteDiscovered(local.items.len - before);
    for (entries.items) |e| try handleEntry(w, a, dir.handle, task, chain, local, e);
}

fn handleEntry(w: *Worker, a: std.mem.Allocator, dirfd: std.posix.fd_t, task: DirTask, chain: ?*const ignore.IgNode, children: *std.ArrayList(DirTask), e: Entry) Oom!void {
    if (!e.is_dir and !e.is_file) return; // symlinks & specials — never followed
    const rel = try joinRel(a, task.rel, e.name);
    if (e.is_dir) {
        // Dir pruning: the corpus-only build/VCS skip list THEN the ignore
        // verdict — `haystack.Walker.next`'s exact order.
        if (haystack.isSkipDir(e.name) or shouldSkip(w.ig, chain, a, task.root_depth, rel, true, e.name)) return;
        try children.append(a, .{
            .disk = try joinPath(a, task.disk, e.name),
            .rel = rel,
            .root_depth = task.root_depth,
            .chain = chain,
        });
        return;
    }
    if (shouldSkip(w.ig, chain, a, task.root_depth, rel, false, e.name)) return;
    const buf = try readMemberRaw(a, dirfd, e.name) orelse return;
    try w.docs.append(a, buf);
    try w.paths.append(a, rel);
    w.bytes += buf.len;
}

/// The build's skip decision for one entry: the frozen base verdict, overridden
/// by the per-directory chain — both scoped to the repository that encloses this
/// entry (`ignore.boundary`) — then the shared `.git`/hidden folding. The corpus
/// walk uses default `Options`, so there is no `-g`/`-t` whitelist to thread
/// (both false, as `haystack.Walker` passes).
fn shouldSkip(ig: *const ignore.Ignore, chain: ?*const ignore.IgNode, a: std.mem.Allocator, root_depth: usize, rel: []const u8, is_dir: bool, basename: []const u8) bool {
    const bound = ignore.boundary(ig, chain, rel);
    var v = ignore.baseVerdict(ig, null, rel, is_dir, root_depth, bound);
    ignore.applyChain(chain, a, ig.o.ignore_case_insensitive, root_depth, rel, is_dir, bound, &v);
    return ig.skipFromVerdict(v, basename, false, false);
}

/// Read `name` (under the open `dirfd`) as a corpus member — the raw
/// worker-thread-safe twin of `corpus.readMember`, byte-identical membership:
/// null when unreadable, empty, reaches/exceeds `corpus.per_file_cap`
/// (`readFileAlloc(.limited)`'s `error.StreamTooLong` boundary — "reached or
/// exceeded"), or binary (`corpus.isBinary`).
///
/// The body is sized from the OPEN HANDLE and allocated ONCE. It used to grow an
/// `ArrayList` in 64 KiB steps, which is the single most expensive line the index
/// build ever had: the list lives in a worker ARENA, and an arena cannot reclaim
/// what a realloc abandons, so every doubling left its predecessor behind and the
/// walk retained ≈2x the corpus it was loading — 3.4 GiB of pure waste on a 3.4
/// GiB corpus, held for the whole build. Asking the handle its length also lets
/// an oversize member be refused before a single byte moves.
///
/// A file that CHANGES between the size question and the read is the one place a
/// sized read and a drained one differ, and both directions stay sound: a file
/// that grew yields its `size`-byte prefix, one that shrank yields what it had.
/// Either way its mtime now stands at/after the build anchor, so the freshness
/// gate re-reads it live on the next query rather than trusting these bytes.
fn readMemberRaw(a: std.mem.Allocator, dirfd: std.posix.fd_t, name: []const u8) Oom!?[]const u8 {
    const fd = portal.openFile(dirfd, name) catch return null;
    defer portal.close(fd);
    const body = switch (memberSize(fd)) {
        .rejected => return null,
        .sized => |size| blk: {
            const buf = try a.alloc(u8, size);
            break :blk buf[0..readFully(fd, buf)];
        },
        // Stat says zero but the handle may still yield bytes — procfs-shaped
        // files are the only things that answer this way, and the serial loader
        // drains them. Parity costs a growing read for a case a source tree
        // never contains, rather than a silently-dropped member if it does.
        .unsized => try drain(a, fd) orelse return null,
    };
    if (body.len == 0 or corpus.isBinary(body)) return null;
    return body;
}

/// What a handle's length says about membership before any content is read.
/// `unsized` is the honest third answer: stat reported nothing, so size has no
/// verdict to give and the bytes must be drained to find out.
const Size = union(enum) { sized: u32, unsized: void, rejected: void };

/// Judge a member by its length alone — at/past `corpus.per_file_cap` is out
/// (`readFileAlloc(.limited)`'s `error.StreamTooLong` boundary: "reached or
/// exceeded"), and so is anything that is not a regular file. Both harvests ask
/// this first, so "how big is it" and "is that a member's size" have one answer.
fn memberSize(fd: std.posix.fd_t) Size {
    const st = inode.statFd(fd) orelse return .rejected;
    if (st.kind != .file) return .rejected;
    if (st.size == 0) return .unsized;
    const size = std.math.cast(u32, st.size) orelse return .rejected;
    if (size >= corpus.per_file_cap) return .rejected;
    return .{ .sized = size };
}

/// Fill `buf` from `fd`, stopping at EOF or the first read error; returns how
/// much arrived. A short answer is not an error here — it is a file that shrank,
/// and the caller judges the bytes it got.
fn readFully(fd: std.posix.fd_t, buf: []u8) usize {
    var n: usize = 0;
    while (n < buf.len) {
        const r = portal.read(fd, buf[n..]) catch break;
        if (r == 0) break;
        n += r;
    }
    return n;
}

/// Drain a handle whose length nobody can state up front, enforcing the cap as
/// the bytes arrive. Null on an unreadable handle or a cap breach.
fn drain(a: std.mem.Allocator, fd: std.posix.fd_t) Oom!?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        const r = portal.read(fd, &tmp) catch return null;
        if (r == 0) return buf.items;
        try buf.appendSlice(a, tmp[0..r]);
        if (buf.items.len >= corpus.per_file_cap) return null; // StreamTooLong parity
    }
}

/// Root-joined path, `haystack.joinRoot` shape: a `.` root (prefix "") yields
/// bare CWD-relative paths, an explicit root keeps its `root/...` prefix.
fn joinRel(a: std.mem.Allocator, prefix: []const u8, name: []const u8) Oom![]const u8 {
    if (prefix.len == 0) return name;
    return joinPath(a, prefix, name);
}

const testing = std.testing;

test "fused parallel load has byte-identical membership to the serial walk" {
    // The whole point of `loadpar`: same corpus as `corpus.loadSerial`, faster.
    // Build a fixture exercising every membership rule — gitignore (anchored,
    // slash-less, negated), nested per-dir ignore, hidden skip, the build-dir
    // skip list, binary, empty, and oversize — then assert the two loaders
    // agree on the exact (path → bytes) set. Both loaders see identical inputs,
    // so this pins the parallel walk to the serial oracle, not to an assumption.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Both loaders consult the overlay, so an operator's cannot break PARITY —
    // but the fixture writes `sub/nested`, and an overlay naming either one
    // prunes it from both sides at once, so the must-be-present arm below stops
    // holding and the parity half goes vacuous over a corpus this test never
    // built. State the baseline so the membership rules are actually exercised.
    const scope = haystack.stateSkipOverlay(.none);
    defer scope.release();

    const root = "/tmp/gist_loadpar_parity_fixture";
    fault.spare("clear leftover parity fixture", Dir.cwd().deleteTree(io, root));
    defer fault.spare("remove parity fixture", Dir.cwd().deleteTree(io, root));
    try Dir.cwd().createDirPath(io, try joinPath(a, root, "sub/nested"));
    try Dir.cwd().createDirPath(io, try joinPath(a, root, "node_modules"));
    // The fixture is its own repository, because `.gitignore` only governs one.
    // Without this the VCS tier switches off whenever the test binary is launched
    // from outside a checkout (`Ignore`'s require-git rule, ripgrep's), and the
    // two gitignore assertions below pass for an ambient reason — where the
    // runner happened to be — rather than because this corpus says so. That
    // reads as green on a laptop and as `foo.log` surviving on a bare CI runner.
    try Dir.cwd().createDirPath(io, try joinPath(a, root, ".git"));

    const W = struct {
        fn f(io_: std.Io, a_: std.mem.Allocator, p: []const u8, data: []const u8) !void {
            try Dir.cwd().writeFile(io_, .{ .sub_path = p, .data = data });
            _ = a_;
        }
    };
    try W.f(io, a, try joinPath(a, root, "a.txt"), "alpha\n");
    try W.f(io, a, try joinPath(a, root, "sub/b.zig"), "const b = 1;\n");
    try W.f(io, a, try joinPath(a, root, "sub/nested/c.py"), "c = 2\n");
    // per-dir gitignore: anchored dir rule + negation
    try W.f(io, a, try joinPath(a, root, ".gitignore"), "*.log\n!keep.log\nignored.txt\n");
    try W.f(io, a, try joinPath(a, root, "foo.log"), "excluded by *.log\n");
    try W.f(io, a, try joinPath(a, root, "keep.log"), "re-included\n");
    try W.f(io, a, try joinPath(a, root, "sub/ignored.txt"), "excluded by slash-less rule at any depth\n");
    try W.f(io, a, try joinPath(a, root, ".hidden.txt"), "excluded: hidden dotfile\n");
    try W.f(io, a, try joinPath(a, root, "node_modules/dep.js"), "excluded: isSkipDir\n");
    try W.f(io, a, try joinPath(a, root, "empty.txt"), "");
    try W.f(io, a, try joinPath(a, root, "bin.dat"), "text\x00with-nul-byte\n");

    const roots: []const []const u8 = &.{root};
    var ser = try corpus.loadSerial(testing.allocator, io, roots);
    defer ser.deinit();
    var par = try load(testing.allocator, io, roots);
    defer par.deinit();

    // Compare as sorted (path,bytes) maps — the serial walk is DFS-ordered, the
    // parallel one path-sorted, so only the SET (and per-path content) must match.
    var expect = std.StringHashMap([]const u8).init(a);
    for (ser.paths, ser.docs) |p, d| try expect.put(p, d);
    try testing.expectEqual(ser.paths.len, par.paths.len);
    for (par.paths, par.docs) |p, d| {
        const want = expect.get(p) orelse {
            assay.diag("parallel admitted a path serial did not: {s}\n", .{p});
            return error.MembershipMismatch;
        };
        try testing.expectEqualStrings(want, d);
    }
    // The members that must be present, and the ones that must be pruned.
    try testing.expect(expect.get(try joinPath(a, root, "a.txt")) != null);
    try testing.expect(expect.get(try joinPath(a, root, "keep.log")) != null);
    try testing.expect(expect.get(try joinPath(a, root, "sub/nested/c.py")) != null);
    try testing.expect(expect.get(try joinPath(a, root, "foo.log")) == null);
    try testing.expect(expect.get(try joinPath(a, root, "sub/ignored.txt")) == null);
    try testing.expect(expect.get(try joinPath(a, root, ".hidden.txt")) == null);
    try testing.expect(expect.get(try joinPath(a, root, "node_modules/dep.js")) == null);
    try testing.expect(expect.get(try joinPath(a, root, "empty.txt")) == null);
    try testing.expect(expect.get(try joinPath(a, root, "bin.dat")) == null);
}

/// Worker count for the walk: `GIST_WORKERS` override, else one per core capped
/// at 8 — the walk+read is syscall/namei-bound (like the search walk), so more
/// threads add directory-fd and namei contention without shortening the tail.
fn workerCount() usize {
    if (assay.knob("WORKERS")) |v| {
        if (std.fmt.parseInt(usize, v, 10) catch null) |n| if (n > 0) return n;
    }
    const cpu = portal.cpuCount() catch 8;
    return @max(@as(usize, 1), @min(cpu, 8));
}

/// Fused parallel walk+read. Returns the assembled `Corpus`; the per-worker
/// arenas travel into it (`Corpus.shards`) so the doc/path bytes stay alive
/// until `Corpus.deinit`. Any spawn failure degrades to running that worker's
/// share inline, so the walk always completes.
pub fn load(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !corpus.Corpus {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // One frozen base `Ignore` for the whole invocation — the same construction
    // `haystack.Walker.initWithRoots` does per root (root/ancestor tiers loaded
    // once). Per-directory sub-ignores are folded in via the worker chains.
    var ig = try ignore.Ignore.init(a, io, .{}, roots);

    var q = Queue{ .gpa = gpa, .io = io };
    defer q.items.deinit(gpa);

    // Seed one task per root. `.` → prefix "" (bare paths); an explicit root
    // keeps its trimmed path. Each root's own ignore files are picked up by the
    // chain in `processDir` (parity with the serial `loadDir(root, rel)`), and
    // `scopeToRoot` is unneeded here — every task carries its own `root_depth`.
    var seeds: std.ArrayList(DirTask) = .empty;
    for (roots) |r| {
        const prefix = if (std.mem.eql(u8, r, ".")) "" else std.mem.trimEnd(u8, r, "/");
        try seeds.append(a, .{
            .disk = if (r.len == 0) "." else r,
            .rel = prefix,
            .root_depth = rootDepth(prefix),
            .chain = null,
        });
    }

    const n = workerCount();
    const workers = try gpa.alloc(Worker, n);
    defer gpa.free(workers);
    for (workers) |*w| w.* = .{ .q = &q, .io = io, .ig = &ig, .arena = std.heap.ArenaAllocator.init(gpa) };
    // The worker arenas travel into the `Corpus` on success; on any failure from
    // here on they are this function's to release.
    errdefer for (workers) |*w| w.arena.deinit();

    try q.push(seeds.items);

    const threads = try a.alloc(std.Thread, n);
    var spawned: usize = 0;
    for (workers[1..]) |*w| {
        threads[spawned] = std.Thread.spawn(.{}, workerMain, .{w}) catch break;
        spawned += 1;
    }
    // This thread is worker 0; any workers that failed to spawn run inline after.
    workerMain(&workers[0]);
    for (workers[1 + spawned ..]) |*w| workerMain(w);
    for (threads[0..spawned]) |t| t.join();

    // A worker that ran out of memory walked a strict subset of the tree. Fail
    // the load rather than hand back a corpus that silently omits files.
    for (workers) |*w| if (w.oom) return error.OutOfMemory;

    // Stitch: slice HEADERS land in the main arena; the doc/path bytes stay in
    // the worker arenas (kept alive in `Corpus.shards`). Doc ids are assigned by
    // sorting on PATH so the build is DETERMINISTIC (the work-stealing walk
    // finishes in nondeterministic order run-to-run; unsorted doc numbering
    // would make the persisted index vary byte-for-byte and defeat reproducible
    // builds / drift gates) — and path-locality tightens the posting-list delta
    // compression, matching the serial DFS build's index size.
    var total_docs: usize = 0;
    var total_bytes: u64 = 0;
    for (workers) |*w| {
        total_docs += w.docs.items.len;
        total_bytes += w.bytes;
    }
    const Pair = struct { path: []const u8, doc: []const u8 };
    var pairs = try a.alloc(Pair, total_docs);
    var k: usize = 0;
    for (workers) |*w| for (w.paths.items, w.docs.items) |p, d| {
        pairs[k] = .{ .path = p, .doc = d };
        k += 1;
    };
    std.mem.sortUnstable(Pair, pairs, {}, struct {
        fn lt(_: void, x: Pair, y: Pair) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    const docs = try a.alloc([]const u8, total_docs);
    const doc_paths = try a.alloc([]const u8, total_docs);
    for (pairs, docs, doc_paths) |pr, *dslot, *pslot| {
        dslot.* = pr.doc;
        pslot.* = pr.path;
    }

    const shards = try gpa.alloc(std.heap.ArenaAllocator, n);
    for (shards, workers) |*s, *w| s.* = w.arena;

    return .{
        .docs = docs,
        .paths = doc_paths,
        .bytes = total_bytes,
        .arena = arena,
        .shards = shards,
        .owner = gpa,
    };
}

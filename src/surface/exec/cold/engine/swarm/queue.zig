//! gist — the work-stealing directory queue the fused walk fans out over.
//!
//! The shared spine, and deliberately the ONLY mutable structure every worker
//! touches: discovered directories live on each worker's private LIFO stack
//! (depth-first, parent listing still cache-warm, zero synchronization), and a
//! worker reaches for this queue only to account for what it found, to DONATE
//! surplus when a peer is hunting, and to block when its own stack runs dry.
//! Three atomics carry the walk's terminal conditions — `live == 0` (complete),
//! `aborted` (a downstream reader hung up), `walk_error` (a directory the walk
//! discovered but could not descend) — plus the `files_seen` tripwire rg's
//! "no files were searched" heuristic needs.

const std = @import("std");
const args = @import("../../argv/args.zig");
const ignore = @import("../../../../../corpus/tree/ignore.zig");
const treemap = @import("../../../../../corpus/index/phantom/treemap.zig");

const IgNode = ignore.IgNode;
const oom = args.oom;

/// One directory awaiting a worker. `rel` is the display/ignore path (prefix-
/// joined, may be absolute); `scope` is its CWD-relative glob/index spelling;
/// `disk` is CWD-openable; `depth` counts components under the walk root
/// (root = 0); `root_depth` is the explicit positional root's own component
/// depth (see `Ignore.scopeToRoot`).
pub const DirTask = struct {
    disk: []const u8,
    rel: []const u8,
    scope: []const u8,
    depth: usize,
    root_depth: usize,
    chain: ?*const IgNode,
    /// This directory's record in the phantom `tree.map` snapshot
    /// (`treemap.not_walked` when it has none — new dir, never-descended dir,
    /// or no snapshot loaded). A recorded dir whose lstat proves it predates
    /// the snapshot anchor serves its listing from the mapping with ONE
    /// syscall instead of openat+getattrlistbulk+close.
    snap_ix: u32 = treemap.not_walked,
};

/// The shared side of the work-stealing walk. Workers keep discovered
/// directories on a private LIFO stack (depth-first — parent listing still
/// cache-warm, zero synchronization) and touch this queue only to account
/// (`noteDiscovered`/`done` — bare atomics), to DONATE surplus when
/// `starving` says a peer is hunting, and to `pop` when their own stack runs
/// dry. A dry worker spins briefly (donations arrive within microseconds
/// mid-walk), then PARKS on the condvar; donors wake exactly as many parked
/// peers as they have tasks, so there is no per-push thundering herd and no
/// yield-storm at the walk's tail. `live == 0` ⇔ walk complete; `aborted` is
/// the other way a walk ends — a downstream reader hanging up (`| head`)
/// mid-stream, detected as a failed write in `Sink.emit` — and is checked
/// everywhere `live == 0` is, so every worker (spinning, parked, or mid local
/// backlog) unwinds within microseconds instead of finishing the whole tree.
pub const Queue = struct {
    mu: std.Io.Mutex = .init,
    cv: std.Io.Condition = .init,
    items: std.ArrayList(DirTask) = .empty,
    head: usize = 0,
    waiting: usize = 0, // workers parked on `cv` (guarded by `mu`)
    live: std.atomic.Value(usize) = .init(0), // undone tasks anywhere (local stacks included)
    avail: std.atomic.Value(usize) = .init(0), // tasks sitting in `items` (maintained under `mu`)
    starving: std.atomic.Value(u32) = .init(0), // workers inside `pop` (spinning or parked)
    aborted: std.atomic.Value(bool) = .init(false), // set once; a broken output pipe cancels the walk
    // A directory the walk discovered but could not open/descend (unreadable /
    // EACCES) — set from any worker thread; `run` folds it into the exit code
    // (rg parity: an unsignaled walk gap must never present as a silent
    // "no match", see `reportWalkError`/`serial.zig`'s identical `walk_error`).
    walk_error: std.atomic.Value(bool) = .init(false),
    // Any file the walk ADMITTED past the ignore/type/glob/hidden filters
    // (pre index-elision — rg would still have opened it). Stays false ⇒ the
    // filters excluded everything, which on an implicit-path run triggers
    // rg's "No files were searched" stderr note + exit 2 (`run`, rg parity).
    files_seen: std.atomic.Value(bool) = .init(false),
    gpa: std.mem.Allocator,
    io: std.Io,

    /// Wake every parked worker. The predicate is read under `mu` (where the
    /// pop loop parks), so the no-missed-wakeup shape holds; both terminal
    /// transitions — broken pipe (`abort`) and last task done (`done`) — funnel
    /// through here.
    fn wakeParked(q: *Queue) void {
        q.mu.lockUncancelable(q.io);
        const any = q.waiting > 0;
        q.mu.unlock(q.io);
        if (any) q.cv.broadcast(q.io);
    }

    /// Cancel the walk: a `Sink.emit` write came back closed-pipe. Idempotent
    /// (the CAS-style swap only wakes parked peers on the transition), so
    /// concurrent workers hitting EPIPE at once never double-broadcast.
    pub fn abort(q: *Queue) void {
        if (!q.aborted.swap(true, .acq_rel)) q.wakeParked();
    }

    /// Account for `n` newly discovered tasks (wherever they live). Must
    /// precede the discovering task's own `done`, else `live` could graze 0
    /// mid-walk and every popper would quit early.
    pub fn noteDiscovered(q: *Queue, n: usize) void {
        if (n != 0) _ = q.live.fetchAdd(n, .acq_rel);
    }

    /// Move already-accounted tasks into the shared queue; spinners observe
    /// `avail` lock-free, parked peers get exactly-enough wakeups.
    pub fn donate(q: *Queue, tasks: []const DirTask) void {
        if (tasks.len == 0) return;
        q.mu.lockUncancelable(q.io);
        q.items.appendSlice(q.gpa, tasks) catch oom();
        q.avail.store(q.items.items.len - q.head, .release);
        const wake = @min(tasks.len, q.waiting);
        q.mu.unlock(q.io);
        if (wake == 1) q.cv.signal(q.io) else if (wake > 1) q.cv.broadcast(q.io);
    }

    /// Seed the queue with the root tasks (accounts + enqueues + wakes).
    pub fn push(q: *Queue, tasks: []const DirTask) void {
        q.noteDiscovered(tasks.len);
        q.donate(tasks);
    }

    pub fn pop(q: *Queue) ?DirTask {
        _ = q.starving.fetchAdd(1, .acq_rel);
        defer _ = q.starving.fetchSub(1, .acq_rel);
        var spins: u32 = 0;
        while (true) {
            if (q.aborted.load(.acquire)) return null;
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
            // A generous budget (~1ms of pause loops): mid-walk droughts last
            // microseconds, and every premature park costs two context
            // switches — measured at ~2.2k voluntary switches per run with a
            // 2k budget (ripgrep's spin-stealing workers log ~7).
            if (spins < 1 << 18) {
                std.atomic.spinLoopHint();
                continue;
            }
            // Park. The predicate is re-checked under `mu`, and both wakers
            // (`donate`, `done`, `abort`) publish under/after the same lock —
            // the classic no-missed-wakeup shape.
            q.mu.lockUncancelable(q.io);
            while (q.head >= q.items.items.len and q.live.load(.acquire) != 0 and !q.aborted.load(.acquire)) {
                q.waiting += 1;
                q.cv.waitUncancelable(q.io, &q.mu);
                q.waiting -= 1;
            }
            q.mu.unlock(q.io);
            spins = 0;
        }
    }

    pub fn done(q: *Queue) void {
        // Walk complete — release every parked worker so it can retire.
        if (q.live.fetchSub(1, .acq_rel) == 1) q.wakeParked();
    }
};

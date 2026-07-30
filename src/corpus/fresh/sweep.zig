//! gist T3 — the freshness SWEEP: a self-balancing, work-stealing metadata
//! walk that answers exactly one question for the freshness overlay in
//! `fresh.zig`: which files under `roots` report a change at/after a build
//! anchor?
//!
//! It is pure mechanism. It knows nothing of doc-ids, trigram candidates, the
//! persisted index, or the "index elides reads, never owns truth" contract
//! those encode — all of which live in `fresh.zig`. The sweep only reads
//! metadata (never file bytes), applies the same conservative dual-clock
//! predicate the overlay trusts (`bulkstat.needsLiveRead` — mtime OR ctime ≥
//! anchor, metadata-unknown counted as changed), and appends every candidate
//! path to `out`. The caller certifies that flat result through the ignore
//! engine before any path can widen a candidate set — admission is not this
//! module's concern.
//!
//! Load balancing is a BFS breadth-expansion (`buildWorkItems`) feeding a
//! work-stealing thread pool over a shared atomic cursor (Blumofe & Leiserson,
//! "Scheduling Multithreaded Computations by Work Stealing", JACM 1999),
//! chosen over a static one-shard-per-root split because this repo's subtree
//! sizes are heavily skewed. On Darwin the per-directory syscall is
//! `getattrlistbulk` (see `tree/bulkstat.zig`), degrading directory-by-directory
//! to the portable stat walk with the identical conservative decision.

const std = @import("std");
const portal = @import("../../portal.zig");
const haystack = @import("../tree/haystack.zig");
const bulkstat = @import("../tree/bulkstat.zig");
const ignore = @import("../tree/ignore.zig");
const path_utils = @import("../scope/paths.zig");
const Dir = std.Io.Dir;

/// Stat-walk every `root` for paths changed at/after `built_ns`, appending each
/// (strings allocated in `a`) into `out`. Enough work items are cut to keep
/// every core busy under a lopsided tree; the calling thread runs one worker
/// inline and only spawns the rest, so a small single-shard walk (the common
/// resident-reconcile case, hit on every non-clean query) spawns ZERO threads
/// instead of paying a spawn+join per query, while a multi-shard walk still
/// saturates every core (N-1 spawned + 1 inline) with the calling thread
/// participating rather than idling on join.
pub fn run(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, built_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    const ncpu = portal.cpuCount() catch 8;
    const items = try buildWorkItems(gpa, io, roots, built_ns, a, out, ncpu * 8);
    defer gpa.free(items);
    if (items.len == 0) return;

    const nworkers = @min(ncpu, items.len);
    const workers = try gpa.alloc(Worker, nworkers);
    defer gpa.free(workers);
    var cursor = std.atomic.Value(usize).init(0);
    for (workers) |*w| w.* = .{ .io = io, .items = items, .cursor = &cursor, .built_ns = built_ns, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer for (workers) |*w| w.arena.deinit();

    const threads = try gpa.alloc(std.Thread, nworkers - 1);
    defer gpa.free(threads);
    var spawned: usize = 0;
    for (workers[1..]) |*w| {
        threads[spawned] = std.Thread.spawn(.{}, workerRun, .{w}) catch break;
        spawned += 1;
    }
    for (workers[1 + spawned ..]) |*w| workerRun(w); // any unspawnable worker runs inline
    workerRun(&workers[0]); // calling thread takes a share instead of idling
    for (threads[0..spawned]) |t| t.join();

    for (workers) |*w| for (w.out.items) |p| try out.append(a, try a.dupe(u8, p));
}

/// A directory subtree still awaiting a full `visitItem` walk, tagged with the
/// positional root it descends from — `Ignore` scopes its ancestor tier per
/// root (`scopeToRoot`), so a shared engine needs to know which one it is
/// deciding under.
const WorkItem = struct { prefix: []const u8, root: []const u8 };

/// Would the ignore engine reject every path beneath `rel`? Mirrors the
/// ancestor discipline of `Ignore.admitsPath` — the post-filter this walk's
/// result is passed through (`fresh.zig::retainAdmitted`) — which rejects a
/// path as soon as ANY ancestor directory is skipped. Pruning that same
/// directory here can therefore only drop paths the post-filter was going to
/// drop anyway: the walk gets cheaper, the answer does not change.
///
/// Why it is worth the call: without it the sweep's corpus is the basename
/// skip-list only, so it pays metadata for every hidden and gitignored tree
/// and discards the result. On this repo that is 241.8k files walked to serve
/// a 21.1k-file corpus — `upstream/` alone (vendored upstream checkouts, hidden
/// and gitignored) is 206.3k of them.
///
/// A directory's OWN ignore file cannot un-ignore the directory, so the
/// verdict uses only rules already loaded from its ancestors — the same reason
/// `admitsPath` decides each component before `loadDir`-ing it.
fn prunedDir(ig: *ignore.Ignore, root: []const u8, rel: []const u8, basename: []const u8) bool {
    ig.scopeToRoot(root);
    return ig.shouldSkip(path_utils.stripDot(rel), true, basename, false, false);
}

/// One subtree's metadata-only walk (no reads), over the same skip-rules as the
/// indexed corpus, collecting paths that require a live read into `a`.
/// Per-file stat failures are collected conservatively; traversal failures are
/// surfaced by the query's primary live walk. This is the recursive leaf action
/// the work-stealing pool in `run` dispatches per `WorkItem`.
fn visitItem(io: std.Io, prefix: []const u8, built_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) void {
    // `getattrlistbulk` (Darwin-only — see `bulkstat.zig`) turns this from
    // O(files) `stat()` syscalls into O(directories) bulk calls, each
    // returning name+type+mtime+ctime for every sibling at once; it degrades
    // directory-by-directory back to the exact stat-based walk
    // (`bulkstat.fallbackWalk`) on any failure, preserving the same
    // conservative metadata decision.
    if (bulkstat.supported) {
        var dir = Dir.cwd().openDir(io, prefix, .{ .iterate = true }) catch return;
        defer dir.close(io);
        bulkstat.visitFresh(a, io, dir, prefix, built_ns, out);
        return;
    }
    // Non-Darwin: the same proven stat-based walk bulkstat degrades to —
    // one definition, so the two paths cannot drift (§Boilerplate).
    bulkstat.fallbackWalk(a, io, prefix, built_ns, out);
}

/// Bulk-list ONE level of `prefix` (macOS `getattrlistbulk`, all-or-nothing —
/// see `bulkstat.listOneLevel`), falling back to the portable
/// `std.Io.Dir.Iterator` on any failure or non-Darwin target. Every
/// non-skipped child directory becomes a new `WorkItem` (arena-owned prefix);
/// every child FILE is metadata-checked right here (cheap — a directory's
/// immediate files are a handful, not worth their own work item) and, if
/// fresh, appended straight to `out`. Returns `false` only when `prefix`
/// itself couldn't be opened (race: deleted between discovery and expansion,
/// or a permissions edge) — the caller then keeps it as its own leaf
/// `WorkItem`; the primary query walk remains responsible for reporting an
/// inaccessible subtree rather than presenting a complete result.
fn expandOneLevel(gpa: std.mem.Allocator, io: std.Io, item: WorkItem, built_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8), children: *std.ArrayList(WorkItem), ig: ?*ignore.Ignore) !bool {
    const prefix = item.prefix;
    // This directory's own ignore file governs its CHILDREN, so it is loaded
    // before any child verdict — the ordering `admitsPath` uses as it descends.
    // BFS guarantees every ancestor was expanded (and so loaded) first.
    if (ig) |g| {
        g.scopeToRoot(item.root);
        const rel = path_utils.stripDot(prefix);
        g.loadDir(rel, rel) catch {};
    }
    if (bulkstat.supported) blk: {
        var dir = Dir.cwd().openDir(io, prefix, .{ .iterate = true }) catch return false;
        defer dir.close(io);
        // Declining leaves the block for the portable iterator below; OOM
        // propagates, since a fallback that allocates just as hard cannot help.
        const entries = switch (try bulkstat.listOneLevel(gpa, dir.handle)) {
            .declined => break :blk,
            .got => |v| v,
        };
        defer {
            for (entries) |e| gpa.free(e.name);
            gpa.free(entries);
        }
        for (entries) |e| {
            if (e.is_dir) {
                if (haystack.isSkipDir(e.name)) continue;
                const sub = try haystack.joinRoot(a, prefix, e.name);
                if (ig) |g| if (prunedDir(g, item.root, sub, e.name)) continue;
                try children.append(gpa, .{ .prefix = sub, .root = item.root });
            } else if (e.is_file and bulkstat.needsLiveRead(built_ns, e.mtime_ns, e.ctime_ns)) {
                try out.append(a, try haystack.joinRoot(a, prefix, e.name));
            }
        }
        return true;
    }
    var dir = Dir.cwd().openDir(io, prefix, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .directory) {
            if (haystack.isSkipDir(e.name)) continue;
            const sub = try haystack.joinRoot(a, prefix, e.name);
            if (ig) |g| if (prunedDir(g, item.root, sub, e.name)) continue;
            try children.append(gpa, .{ .prefix = sub, .root = item.root });
        } else if (e.kind == .file) {
            const path = try haystack.joinRoot(a, prefix, e.name);
            const st = dir.statFile(io, e.name, .{}) catch {
                try out.append(a, path);
                continue;
            };
            if (bulkstat.needsLiveRead(built_ns, st.mtime.nanoseconds, st.ctime.nanoseconds)) try out.append(a, path);
        }
    }
    return true;
}

/// Breadth-expand `roots` into ≥ `target` fine-grained `WorkItem`s (a BFS over
/// `expandOneLevel`, an index cursor over a list that grows as it's walked —
/// classic queue-via-array). Why: a static one-shard-per-root split starves
/// under this repo's size skew (`services` + `clients` are >40× `contracts`
/// + `quality` combined — six threads means one or two of them are still
/// walking `services/backend` long after the other four have gone idle, so
/// wall time tracks the SLOWEST root, not the total work ÷ core count).
/// Expanding one directory level at a time until there's enough breadth to
/// actually saturate every core turns the walk into a self-balancing
/// work-stealing pool regardless of which subtree happens to be huge, and
/// costs only a handful of extra one-level list calls (µs each) up front.
/// Once `target` is reached, everything still queued — at whatever depth —
/// becomes a leaf `WorkItem`, so the BFS naturally stops subdividing
/// already-small subtrees while continuing to split large ones.
fn buildWorkItems(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, built_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8), target: usize) ![]WorkItem {
    var q: std.ArrayList(WorkItem) = .empty;
    defer q.deinit(gpa);
    for (roots) |r| try q.append(gpa, .{ .prefix = r, .root = r });

    var final: std.ArrayList(WorkItem) = .empty;
    errdefer final.deinit(gpa);

    // The same engine, options, and roots `retainAdmitted` certifies the result
    // with, so a directory pruned during the walk is one the post-filter would
    // have rejected path-by-path. Arena-owned (never deinit'd), matching that
    // post-filter's own lifetime discipline. A failure to build the matcher
    // leaves `ig` null and the walk simply stays unpruned — slower, never wrong.
    var ig: ?ignore.Ignore = ignore.Ignore.init(a, io, .{}, roots) catch null;

    var i: usize = 0;
    while (i < q.items.len) : (i += 1) {
        const item = q.items[i];
        const remaining = q.items.len - i; // includes `item` itself
        if (final.items.len + remaining >= target) {
            try final.append(gpa, item); // enough breadth already — stop subdividing
            continue;
        }
        var children: std.ArrayList(WorkItem) = .empty;
        defer children.deinit(gpa);
        const expanded = expandOneLevel(gpa, io, item, built_ns, a, out, &children, if (ig) |*g| g else null) catch false;
        if (!expanded) {
            try final.append(gpa, item); // unopenable: leave the whole subtree to visitItem
        } else {
            // The level's files are already in `out`; only child directories
            // continue. An all-files directory queues nothing — re-adding it
            // as a leaf would double-emit every fresh file it holds.
            try q.appendSlice(gpa, children.items);
        }
    }
    return final.toOwnedSlice(gpa);
}

/// One work-stealing pool member: pulls the next unclaimed `WorkItem` off the
/// shared atomic cursor and fully walks it into its own private page-backed
/// arena (no shared-allocator contention across threads, same principle the
/// old per-root shards used — just applied over many more, better-balanced
/// items instead of six static ones).
const Worker = struct {
    io: std.Io,
    items: []const WorkItem,
    cursor: *std.atomic.Value(usize),
    built_ns: i128,
    arena: std.heap.ArenaAllocator,
    out: std.ArrayList([]const u8) = .empty,
};

fn workerRun(w: *Worker) void {
    const a = w.arena.allocator();
    while (true) {
        const i = w.cursor.fetchAdd(1, .monotonic);
        if (i >= w.items.len) break;
        visitItem(w.io, w.items[i].prefix, w.built_ns, a, &w.out);
    }
}

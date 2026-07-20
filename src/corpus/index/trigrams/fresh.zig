//! gist T3 — local-filesystem freshness overlay. A persisted trigram index only
//! elides a live read when the path was indexed and both filesystem change
//! clocks prove it predates the build anchor. Every other file is read and
//! verified against live bytes before output.
//!
//! The anchor is captured before the index reads the corpus. A file is
//! conservatively fresh when mtime OR ctime is `>= anchor`, or either timestamp
//! is unavailable. ctime closes the ordinary preserved-mtime hole: writing or
//! replacing bytes advances status-change time even if a later `touch -r`
//! restores mtime. Equality is fresh so coarse clocks that collapse a
//! post-anchor write onto the anchor tick remain conservative.
//!
//! This is freshness-aware with no false negatives under the model documented
//! in `README.md`: a local filesystem whose reported ctime advances to the
//! anchor tick or later for a completed ordinary write, and a primary live walk
//! that reports traversal failures. Deliberately backdating both clocks,
//! network/cache incoherence, and writes racing the metadata/read window are
//! outside a snapshot guarantee. A racing query may resolve to the before- or
//! after-write state; the next query observes the advanced ctime. `git diff
//! HEAD` remains unsound because a coworker's committed change can differ from
//! the older index without appearing in the working-tree diff.

const std = @import("std");
const corpus_mod = @import("../../tree/corpus.zig");
const haystack = @import("../../tree/haystack.zig");
const ignore = @import("../../tree/ignore.zig");
const scope = @import("../../scope/glob.zig");
const path_utils = @import("../../scope/paths.zig");
const bulkstat = @import("../../tree/bulkstat.zig");
const persist = @import("persist.zig");
const Index = @import("trigram.zig").Index;
const Dir = std.Io.Dir;

const anchor_path = corpus_mod.ArtifactPath("built.ns");

/// Persist the build instant (wall-clock ns) as the freshness anchor. Atomic
/// (temp-then-rename, see `persist.writeAtomic`) so a concurrent reader never
/// observes a momentarily-truncated anchor file (which would silently disable
/// the freshness overlay for that one query — a soft correctness gap, not a
/// crash, but still avoidable at the same cost as the index/paths writes).
pub fn writeAnchor(io: std.Io, built_ns: i128) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, @intCast(built_ns), .little); // epoch-ns fits i64 until 2262
    try persist.writeAtomic(io, anchor_path.get(), &buf);
}

/// The anchor, or null when it is missing, truncated, or in the future. Query
/// callers fail closed to reading every walked file when this proof is absent.
/// `pub` so the `status` verb can report the build instant without a query.
pub fn readAnchor(gpa: std.mem.Allocator, io: std.Io) ?i128 {
    const b = Dir.cwd().readFileAlloc(io, anchor_path.get(), gpa, .limited(64)) catch return null;
    defer gpa.free(b);
    if (b.len < 8) return null;
    const built_ns: i128 = std.mem.readInt(i64, b[0..8], .little);
    if (built_ns > std.Io.Clock.now(.real, io).nanoseconds) return null;
    return built_ns;
}

/// Candidate doc-ids + a private arena owning any new-file paths appended to the
/// caller's `paths` list. Keep it alive until after the candidate read.
pub const Candidates = struct {
    ids: []u32,
    /// Doc ids the freshness walk proved changed at/after the anchor (every id
    /// the fresh-path fold touched, dedupe-independent). A doc listed here has
    /// live bytes the persisted per-doc artifacts (trigram postings, crest
    /// sidecar) no longer describe — content-conditioned pruning must skip it.
    fresh_ids: []u32,
    /// False when no trustworthy build anchor existed: NO doc is provably
    /// unchanged, so `ids` seeds everything and content pruning must stand down.
    anchored: bool,
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    pub fn deinit(self: *Candidates) void {
        self.gpa.free(self.fresh_ids);
        self.gpa.free(self.ids);
        self.arena.deinit();
    }
};

/// Base trigram candidates for `filters` UNIONed with every file whose mtime or
/// ctime is at/after the build anchor (plus metadata-unknown files). `filters`
/// is the prefilter set: a single mandatory
/// literal (`{required}`), an alternation cover set (`foo|bar` ⇒ {foo, bar}), or
/// empty ⇒ every doc. Each filter must be ≥3 B; an empty set or any short/failed
/// filter falls back to seeding every doc (sound — the verify pass still gates).
/// Files already in `paths` contribute their existing id (forced into the set
/// even if the trigram filter skipped them); brand-new files are appended to
/// `paths` (id = new index) so the caller's read path resolves them unchanged.
pub fn candidates(
    gpa: std.mem.Allocator,
    io: std.Io,
    idx: *const Index,
    paths: *std.ArrayList([]const u8),
    filters: []const []const u8,
    roots: []const []const u8,
) !Candidates {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(gpa);
    var fresh_ids: std.ArrayList(u32) = .empty;
    errdefer fresh_ids.deinit(gpa);
    var usable = filters.len > 0;
    for (filters) |f| usable = usable and f.len >= 3;
    if (usable) {
        if (idx.queryAny(gpa, filters)) |cand| {
            defer gpa.free(cand);
            try ids.appendSlice(gpa, cand);
        } else |_| try seedAll(gpa, &ids, paths.items.len);
    } else try seedAll(gpa, &ids, paths.items.len);

    var anchored = false;
    if (readAnchor(gpa, io)) |built_ns| {
        anchored = true;
        const a = arena.allocator();
        var freshlist: std.ArrayList([]const u8) = .empty; // arena-owned strings
        try walkFresh(gpa, io, roots, built_ns, a, &freshlist);
        if (freshlist.items.len > 0) try widen(gpa, paths, &ids, &fresh_ids, freshlist.items);
    } else {
        // Without a trustworthy anchor no indexed non-candidate is provably
        // unchanged. Seed all so the caller declines elision and live-reads.
        ids.clearRetainingCapacity();
        try seedAll(gpa, &ids, paths.items.len);
    }

    return .{ .ids = try ids.toOwnedSlice(gpa), .fresh_ids = try fresh_ids.toOwnedSlice(gpa), .anchored = anchored, .arena = arena, .gpa = gpa };
}

/// Paths under `roots` whose metadata says they changed at/after `since_ns` —
/// the same conservative stat walk the T3 overlay runs (mtime OR ctime ≥
/// anchor, metadata-unknown counted as changed), exposed for tiers that carry
/// their OWN build anchor (the codex shelf) instead of the trigram one.
/// Strings land in `a`; the caller owns their lifetime.
pub fn changedSince(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, since_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    try walkFresh(gpa, io, roots, since_ns, a, out);
}

/// `changedSince` reduced to its count — the honest staleness number every
/// anchor-carrying status/report surface prints. Walk errors read as 0:
/// staleness here is advisory, never load-bearing.
pub fn staleCount(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, since_ns: i128) usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var changed: std.ArrayList([]const u8) = .empty;
    changedSince(gpa, io, roots, since_ns, arena.allocator(), &changed) catch return 0;
    return changed.items.len;
}

fn seedAll(gpa: std.mem.Allocator, ids: *std.ArrayList(u32), total: usize) !void {
    try ids.ensureTotalCapacity(gpa, total);
    for (0..total) |i| ids.appendAssumeCapacity(@intCast(i));
}

/// Fold the fresh paths into `ids`: existing → its id, new → append to `paths`.
/// Dedup against the base set so a fresh file that's also a trigram candidate is
/// read once. Every fresh doc id ALSO lands in `fresh_ids` (dedupe-independent
/// of the base set — a fresh trigram candidate is still fresh), the set the
/// crest sieve consults before trusting a persisted per-doc vector.
/// The path→id map is built only when there *are* fresh files.
/// `pub` so the sibling `fresh_test.zig` can exercise it directly.
pub fn widen(gpa: std.mem.Allocator, paths: *std.ArrayList([]const u8), ids: *std.ArrayList(u32), fresh_ids: *std.ArrayList(u32), fresh: []const []const u8) !void {
    var seen = std.AutoHashMap(u32, void).init(gpa);
    defer seen.deinit();
    try seen.ensureTotalCapacity(@intCast(ids.items.len + fresh.len));
    for (ids.items) |d| seen.putAssumeCapacity(d, {});

    var fresh_seen = std.AutoHashMap(u32, void).init(gpa);
    defer fresh_seen.deinit();
    try fresh_seen.ensureTotalCapacity(@intCast(fresh.len));

    var by_path = std.StringHashMap(u32).init(gpa);
    defer by_path.deinit();
    try by_path.ensureTotalCapacity(@intCast(paths.items.len));
    for (paths.items, 0..) |pp, i| by_path.putAssumeCapacity(pp, @intCast(i));

    for (fresh) |fp| {
        const id = by_path.get(fp) orelse blk: {
            try paths.append(gpa, fp); // fp lives in the Candidates arena
            break :blk @as(u32, @intCast(paths.items.len - 1));
        };
        if (!(try fresh_seen.getOrPut(id)).found_existing) try fresh_ids.append(gpa, id);
        if ((try seen.getOrPut(id)).found_existing) continue;
        try ids.append(gpa, id);
    }
}

/// One subtree's metadata-only walk (no reads), over the same skip-rules as the
/// indexed corpus, collecting paths that require a live read into `a`.
/// Per-file stat failures are collected conservatively; traversal failures are
/// surfaced by the query's primary live walk. This is the recursive leaf action
/// the work-stealing pool in `walkFresh` dispatches per `WorkItem`.
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

/// A directory subtree still awaiting a full `visitItem` walk.
const WorkItem = struct { prefix: []const u8 };

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
fn expandOneLevel(gpa: std.mem.Allocator, io: std.Io, prefix: []const u8, built_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8), children: *std.ArrayList(WorkItem)) !bool {
    if (bulkstat.supported) blk: {
        var dir = Dir.cwd().openDir(io, prefix, .{ .iterate = true }) catch return false;
        defer dir.close(io);
        const entries = bulkstat.listOneLevel(gpa, dir.handle) catch break :blk;
        defer {
            for (entries) |e| gpa.free(e.name);
            gpa.free(entries);
        }
        for (entries) |e| {
            if (e.is_dir) {
                if (haystack.isSkipDir(e.name)) continue;
                try children.append(gpa, .{ .prefix = try haystack.joinRoot(a, prefix, e.name) });
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
            try children.append(gpa, .{ .prefix = try haystack.joinRoot(a, prefix, e.name) });
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
    for (roots) |r| try q.append(gpa, .{ .prefix = r });

    var final: std.ArrayList(WorkItem) = .empty;
    errdefer final.deinit(gpa);

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
        const expanded = expandOneLevel(gpa, io, item.prefix, built_ns, a, out, &children) catch false;
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

fn retainAdmitted(io: std.Io, roots: []const []const u8, a: std.mem.Allocator, out: *std.ArrayList([]const u8), start: usize) void {
    var ig = ignore.Ignore.init(a, io, .{}, roots);
    var write = start;
    for (out.items[start..]) |path| {
        for (roots) |root| {
            if (!scope.underRoot(path, path_utils.stripDot(root))) continue;
            if (ig.admitsPath(root, path)) {
                out.items[write] = path;
                write += 1;
                break;
            }
        }
    }
    out.items.len = write;
}

/// Stat-walk every root via a self-balancing work-stealing pool, then merge
/// fresh paths into `a`. Replaces the old static one-thread-per-root split
/// (see `buildWorkItems`'s doc comment for why): `target` asks for enough
/// breadth to keep every core busy regardless of how lopsided the tree is,
/// so this degrades gracefully both when the box is idle (more workers
/// actually run concurrently) and when it's contended (short, evenly-sized
/// work items mean one delayed thread stalls a sliver of the walk, not an
/// entire multi-thousand-file root).
fn walkFresh(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, built_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    const start = out.items.len;
    const ncpu = std.Thread.getCpuCount() catch 8;
    const items = try buildWorkItems(gpa, io, roots, built_ns, a, out, ncpu * 8);
    defer gpa.free(items);
    if (items.len == 0) return retainAdmitted(io, roots, a, out, start);

    const nworkers = @min(ncpu, items.len);
    const workers = try gpa.alloc(Worker, nworkers);
    defer gpa.free(workers);
    var cursor = std.atomic.Value(usize).init(0);
    for (workers) |*w| w.* = .{ .io = io, .items = items, .cursor = &cursor, .built_ns = built_ns, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer for (workers) |*w| w.arena.deinit();

    // The calling thread always runs worker[0] inline and only spawns the rest,
    // so a single-shard walk (a small tree — the common resident-reconcile case,
    // hit on every non-clean query) spawns ZERO threads instead of paying a
    // spawn+join per query, and a multi-shard walk still saturates every core
    // (N-1 spawned + 1 inline) with the calling thread participating rather than
    // idling on join.
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

    // Metadata traversal is deliberately optimized independently of content
    // loading; certify its flat result through the canonical ignore engine
    // before any new path can widen a persisted index candidate set.
    retainAdmitted(io, roots, a, out, start);
}

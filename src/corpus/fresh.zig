//! gist T3 — freshness overlay. Keeps a persisted index correct against a
//! working tree that many agents rewrite many times a minute WITHOUT rebuilding
//! and WITHOUT consulting git history (the fragile part under heavy, overlapping,
//! rebased commit churn).
//!
//! Why it can't break: the cold query already reads & VERIFIES every candidate
//! against live bytes, so a stale/edited/deleted match is never a false
//! *positive*. The only staleness gap is a false *negative* — a file that now
//! matches but wasn't a trigram candidate (a new file, or one that gained the
//! needle since build). So freshness only has to *widen* the candidate set with
//! files touched since the index was built; the existing verify does the rest.
//!
//! Anchor = the wall-clock instant of the build (`real` Io.Clock — the same
//! UTC-ns domain as file mtime). A file is fresh iff `mtime ≥ anchor`. This is
//! immune to commit chaos: rebases, overlapping branches, and racing commits
//! never change the fact that writing a file's bytes (incl. a `git
//! checkout`/merge/pull landing a coworker's commit) advances its mtime. It is a
//! strict over-approximation — re-reading a touched-but-unchanged file is
//! harmless (verify filters it) — so it has no false negatives and cannot break.
//! `git diff HEAD` is *unsound* here: a coworker's commit already in HEAD shows
//! no working-tree diff yet differs from our pre-commit index.

const std = @import("std");
const corpus_mod = @import("corpus.zig");
const haystack = @import("haystack.zig");
const bulkstat = @import("bulkstat.zig");
const persist = @import("../index/persist.zig");
const Index = @import("../index/trigram.zig").Index;
const Dir = std.Io.Dir;

const anchor_file = corpus_mod.out_dir ++ "/built.ns";

/// Persist the build instant (wall-clock ns) as the freshness anchor. Atomic
/// (temp-then-rename, see `persist.writeAtomic`) so a concurrent reader never
/// observes a momentarily-truncated anchor file (which would silently disable
/// the freshness overlay for that one query — a soft correctness gap, not a
/// crash, but still avoidable at the same cost as the index/paths writes).
pub fn writeAnchor(io: std.Io, built_ns: i128) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, @intCast(built_ns), .little); // epoch-ns fits i64 until 2262
    try persist.writeAtomic(io, anchor_file, &buf);
}

/// The anchor, or null when no index/anchor exists yet (⇒ freshness is skipped
/// and behavior is byte-identical to the pre-T3 cold path — backward compatible).
/// `pub` so the `status` verb can report the build instant without a query.
pub fn readAnchor(gpa: std.mem.Allocator, io: std.Io) ?i128 {
    const b = Dir.cwd().readFileAlloc(io, anchor_file, gpa, .limited(64)) catch return null;
    defer gpa.free(b);
    if (b.len < 8) return null;
    return std.mem.readInt(i64, b[0..8], .little);
}

/// Candidate doc-ids + a private arena owning any new-file paths appended to the
/// caller's `paths` list. Keep it alive until after the candidate read.
pub const Candidates = struct {
    ids: []u32,
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    pub fn deinit(self: *Candidates) void {
        self.gpa.free(self.ids);
        self.arena.deinit();
    }
};

/// Base trigram candidates for `filters` UNIONed with every file touched since
/// the index was built. `filters` is the prefilter set: a single mandatory
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
    var usable = filters.len > 0;
    for (filters) |f| if (f.len < 3) {
        usable = false;
        break;
    };
    if (usable) {
        if (idx.queryAny(gpa, filters)) |cand| {
            defer gpa.free(cand);
            try ids.appendSlice(gpa, cand);
        } else |_| try seedAll(gpa, &ids, paths.items.len);
    } else try seedAll(gpa, &ids, paths.items.len);

    if (readAnchor(gpa, io)) |built_ns| {
        const a = arena.allocator();
        var freshlist: std.ArrayList([]const u8) = .empty; // arena-owned strings
        try walkFresh(gpa, io, roots, built_ns, a, &freshlist);
        if (freshlist.items.len > 0) try widen(gpa, paths, &ids, freshlist.items);
    }

    return .{ .ids = try ids.toOwnedSlice(gpa), .arena = arena, .gpa = gpa };
}

/// How many files under `roots` have been touched since `built_ns` — the
/// index's *drift*. Runs the exact same work-stealing stat-walk the query
/// overlay uses (`walkFresh`), just counting instead of widening. The `index
/// --auto` drift gate calls this to decide whether a fold is even worth it, and
/// `status` reports it so an agent can see, without a query, how much live-scan
/// tax a stale index is currently paying. Deletions aren't counted (they can't
/// advance an mtime) — harmless: a dropped file's stale postings verify out.
pub fn driftCount(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, built_ns: i128) !usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try walkFresh(gpa, io, roots, built_ns, arena.allocator(), &out);
    return out.items.len;
}

fn seedAll(gpa: std.mem.Allocator, ids: *std.ArrayList(u32), total: usize) !void {
    try ids.ensureTotalCapacity(gpa, total);
    for (0..total) |i| ids.appendAssumeCapacity(@intCast(i));
}

/// Fold the fresh paths into `ids`: existing → its id, new → append to `paths`.
/// Dedup against the base set so a fresh file that's also a trigram candidate is
/// read once. The path→id map is built only when there *are* fresh files.
/// `pub` so the sibling `fresh_test.zig` can exercise it directly.
pub fn widen(gpa: std.mem.Allocator, paths: *std.ArrayList([]const u8), ids: *std.ArrayList(u32), fresh: []const []const u8) !void {
    var seen = std.AutoHashMap(u32, void).init(gpa);
    defer seen.deinit();
    try seen.ensureTotalCapacity(@intCast(ids.items.len + fresh.len));
    for (ids.items) |d| seen.putAssumeCapacity(d, {});

    var by_path = std.StringHashMap(u32).init(gpa);
    defer by_path.deinit();
    try by_path.ensureTotalCapacity(@intCast(paths.items.len));
    for (paths.items, 0..) |pp, i| by_path.putAssumeCapacity(pp, @intCast(i));

    for (fresh) |fp| {
        const id = by_path.get(fp) orelse blk: {
            try paths.append(gpa, fp); // fp lives in the Candidates arena
            break :blk @as(u32, @intCast(paths.items.len - 1));
        };
        if ((try seen.getOrPut(id)).found_existing) continue;
        try ids.append(gpa, id);
    }
}

/// One subtree's full stat-only walk (no reads), over the same skip-rules as
/// the indexed corpus, collecting paths whose mtime ≥ `built_ns` into `a`.
/// Failures degrade to "found nothing under this subtree" — never a false
/// match, only (at worst) a momentarily missed fresh file, self-healing on
/// its next touch. This is the recursive leaf action the work-stealing pool
/// in `walkFresh` below dispatches per `WorkItem`.
fn visitItem(io: std.Io, prefix: []const u8, built_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) void {
    // `getattrlistbulk` (Darwin-only — see `bulkstat.zig`) turns this from
    // O(files) `stat()` syscalls into O(directories) bulk calls, each
    // returning name+type+mtime for every sibling at once; it degrades
    // directory-by-directory back to the exact stat-based walk below on any
    // failure, so this can only ever be a speed trade, never a correctness one.
    if (bulkstat.supported) {
        var dir = Dir.cwd().openDir(io, prefix, .{ .iterate = true }) catch return;
        defer dir.close(io);
        bulkstat.visitFresh(a, io, dir, prefix, built_ns, out);
        return;
    }
    var w = haystack.Walker.init(io, a, prefix) catch return;
    defer w.deinit(io);
    while (w.next(io) catch return) |hay| {
        const st = hay.dir.statFile(io, hay.name, .{}) catch continue;
        if (st.mtime.nanoseconds < built_ns) continue;
        out.append(a, hay.path) catch return;
    }
}

/// A directory subtree still awaiting a full `visitItem` walk.
const WorkItem = struct { prefix: []const u8 };

/// Bulk-list ONE level of `prefix` (macOS `getattrlistbulk`, all-or-nothing —
/// see `bulkstat.listOneLevel`), falling back to the portable
/// `std.Io.Dir.Iterator` on any failure or non-Darwin target. Every
/// non-skipped child directory becomes a new `WorkItem` (arena-owned prefix);
/// every child FILE is mtime-checked right here (cheap — a directory's
/// immediate files are a handful, not worth their own work item) and, if
/// fresh, appended straight to `out`. Returns `false` only when `prefix`
/// itself couldn't be opened (race: deleted between discovery and expansion,
/// or a permissions edge) — the caller then keeps it as its own leaf
/// `WorkItem`, and `visitItem`'s own `catch return` degrades it to
/// "found nothing" exactly as before, so this can never drop a file, only
/// (at worst) fail to subdivide one node further.
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
                try children.append(gpa, .{ .prefix = try haystack.joinPath(a, prefix, e.name) });
            } else if (e.is_file and e.mtime_ns >= built_ns) {
                try out.append(a, try haystack.joinPath(a, prefix, e.name));
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
            try children.append(gpa, .{ .prefix = try haystack.joinPath(a, prefix, e.name) });
        } else if (e.kind == .file) {
            const st = dir.statFile(io, e.name, .{}) catch continue;
            if (st.mtime.nanoseconds >= built_ns) try out.append(a, try haystack.joinPath(a, prefix, e.name));
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
        if (!expanded or children.items.len == 0) {
            try final.append(gpa, item); // leaf: unopenable, empty, or all-files
        } else {
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

/// Stat-walk every root via a self-balancing work-stealing pool, then merge
/// fresh paths into `a`. Replaces the old static one-thread-per-root split
/// (see `buildWorkItems`'s doc comment for why): `target` asks for enough
/// breadth to keep every core busy regardless of how lopsided the tree is,
/// so this degrades gracefully both when the box is idle (more workers
/// actually run concurrently) and when it's contended (short, evenly-sized
/// work items mean one delayed thread stalls a sliver of the walk, not an
/// entire multi-thousand-file root).
fn walkFresh(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, built_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    const ncpu = std.Thread.getCpuCount() catch 8;
    const items = try buildWorkItems(gpa, io, roots, built_ns, a, out, ncpu * 8);
    defer gpa.free(items);
    if (items.len == 0) return;

    const nworkers = @min(ncpu, items.len);
    const workers = try gpa.alloc(Worker, nworkers);
    defer gpa.free(workers);
    var cursor = std.atomic.Value(usize).init(0);
    for (workers) |*w| w.* = .{ .io = io, .items = items, .cursor = &cursor, .built_ns = built_ns, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer for (workers) |*w| w.arena.deinit();

    const threads = try gpa.alloc(std.Thread, nworkers);
    defer gpa.free(threads);
    var spawned: usize = 0;
    for (workers) |*w| {
        threads[spawned] = std.Thread.spawn(.{}, workerRun, .{w}) catch break;
        spawned += 1;
    }
    for (workers[spawned..]) |*w| workerRun(w); // any unspawned workers run inline
    for (threads[0..spawned]) |t| t.join();

    for (workers) |*w| for (w.out.items) |p| try out.append(a, try a.dupe(u8, p));
}

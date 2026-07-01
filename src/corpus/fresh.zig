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
const Index = @import("../index/trigram.zig").Index;
const Dir = std.Io.Dir;

const anchor_file = corpus_mod.out_dir ++ "/built.ns";

/// Persist the build instant (wall-clock ns) as the freshness anchor.
pub fn writeAnchor(io: std.Io, built_ns: i128) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, @intCast(built_ns), .little); // epoch-ns fits i64 until 2262
    try Dir.cwd().writeFile(io, .{ .sub_path = anchor_file, .data = &buf });
}

/// The anchor, or null when no index/anchor exists yet (⇒ freshness is skipped
/// and behavior is byte-identical to the pre-T3 cold path — backward compatible).
fn readAnchor(gpa: std.mem.Allocator, io: std.Io) ?i128 {
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

/// One root's stat-only walk (no reads), over the same skip-rules as the indexed
/// corpus, collecting paths whose mtime ≥ `built_ns` into a private page-backed
/// arena. Failures degrade to "found nothing for this root" — never a false
/// match, only (at worst) a momentarily missed fresh file, self-healing on its
/// next touch. The discovery walk is the floor cost, so it fans across roots.
const WalkShard = struct {
    io: std.Io,
    root: []const u8,
    built_ns: i128,
    arena: std.heap.ArenaAllocator,
    out: std.ArrayList([]const u8) = .empty,
};

fn walkShard(sh: *WalkShard) void {
    const a = sh.arena.allocator();
    var root = Dir.cwd().openDir(sh.io, sh.root, .{ .iterate = true }) catch return;
    defer root.close(sh.io);
    var walker = root.walkSelectively(a) catch return;
    defer walker.deinit();
    while (walker.next(sh.io) catch return) |entry| {
        if (entry.kind == .directory) {
            if (!corpus_mod.isSkipDir(entry.basename)) walker.enter(sh.io, entry) catch return;
            continue;
        }
        if (entry.kind != .file) continue;
        const st = entry.dir.statFile(sh.io, entry.basename, .{}) catch continue;
        if (st.mtime.nanoseconds < sh.built_ns) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ sh.root, entry.path }) catch return;
        sh.out.append(a, full) catch return;
    }
}

/// Stat-walk every root in parallel (one thread each, private page-backed arenas
/// ⇒ no shared-allocator contention), then merge fresh paths into `a`.
fn walkFresh(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, built_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    const shards = try gpa.alloc(WalkShard, roots.len);
    defer gpa.free(shards);
    for (roots, 0..) |r, i| shards[i] = .{ .io = io, .root = r, .built_ns = built_ns, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = try gpa.alloc(std.Thread, roots.len);
    defer gpa.free(threads);
    var spawned: usize = 0;
    for (shards) |*sh| {
        threads[spawned] = std.Thread.spawn(.{}, walkShard, .{sh}) catch break;
        spawned += 1;
    }
    for (shards[spawned..]) |*sh| walkShard(sh); // any unspawned roots run inline
    for (threads[0..spawned]) |t| t.join();

    for (shards) |*sh| for (sh.out.items) |p| try out.append(a, try a.dupe(u8, p));
}

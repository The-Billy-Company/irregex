//! relate resident retrieval session — the warm compression-search engine
//! (ADR-352 rung 2.5).
//!
//! A `RetrievalSession` holds one repository's mmap'd trigram index + doc→path
//! table warm across many retrieval queries — a `relate similar <text>` probe or
//! a `pack` — so an eligible request pays neither the per-process index map nor
//! the O(tree) freshness stat walk, the two costs that dominate a cold one. It answers
//! through the SAME `retrieval.WarmQuery` kernel the one-shot CLI uses, handed
//! a `.resident` `Source`, so warm and cold answers cannot drift: the only
//! difference is who owns the index and whether the freshness walk runs.
//!
//! ## Freshness is anchor-based, so the overlay is cacheable
//!
//! Unlike gist's resident session — which mirrors live corpus BYTES and
//! reconciles a moving cursor — relate never holds file contents. Its freshness
//! is the persisted index's build ANCHOR (`fresh.readAnchor`): the set of files
//! whose mtime/ctime advanced at/after the build is exactly the set whose
//! persisted postings are stale. That set is a pure function of (index, tree
//! state), so it is recomputed only when the tree actually changes and reused
//! verbatim while the watcher proves the roots quiescent. The changed paths are
//! folded into an extension of the borrowed path table (session-owned strings)
//! exactly as the one-shot `fresh.widen` folds them, so `fresh_ids` name the
//! same docs a cold retrieval would live-verify — warm==cold parity.
//!
//! ## Fail-closed, like every rung of this ladder
//!
//! The watcher is a pure accelerator (`watch.zig`): without one, or on any
//! doubt (queue overflow, an unwatchable new directory), the session simply
//! recomputes the overlay on every query — slower, never stale. A rebuilt index
//! (`pair.gen` drift) re-maps under the lock; a map failure leaves the session
//! intact and the query is declined (`freshness_unprovable` → the client
//! answers cold).
//! Concurrent queries overlap under a shared `Ward` lease
//! (`kernel/math/lease.zig`) on the watcher-clean fast path while a
//! recompute runs alone under the exclusive lease; the watcher only ever touches
//! the shared `Seqlock` (`seqlock.zig`) + the `dirty_log`, so the barrier is a
//! lock-free seqlock over a ward-guarded overlay.

const std = @import("std");
const assay = @import("../../../assay/assay.zig");
const fault = @import("../../../fault.zig");
const fresh = @import("../../../corpus/fresh/fresh.zig");
const persist = @import("../../../corpus/index/trigrams/persist.zig");
const dirtylog = @import("../reconcile/dirty.zig");
const Seqlock = @import("../reconcile/seqlock.zig").Seqlock;
const Ward = @import("../../../kernel/math/lease.zig").Ward;
const retrieval = @import("../../retrieval/retrieval.zig");
const Dir = std.Io.Dir;

pub const Result = retrieval.Result;
pub const PackResult = retrieval.PackResult;
const QueryError = error{OutOfMemory};

/// The resident tier's fail-CLOSED fold: anything that stopped us from PROVING
/// the overlay current means the warm answer is unsound, so the query declines
/// to the cold path rather than answering from a stale mapping. OOM alone stays
/// a fault — it is the one failure re-running cold cannot fix.
///
/// `anyerror` is deliberate here, and the opposite of `notice.pathErrNote`'s
/// named `WalkFault` (ADR-373 law 2): nothing downstream renders this error, so
/// a widened std set cannot become a mystery string. It can only ever mean
/// "freshness unprovable" — which is already the safe answer. Naming the union
/// of four inferred sets would buy a compile error where the fold is total by
/// construction.
///
/// What the widening WOULD cost is diagnosability, so the discarded fault goes
/// to the `.fault` lens on its way out (`GIST_TRACE=fault`) — the same channel
/// `fault.spare` uses. Without it, "why did the daemon answer cold?" is
/// invisible: the decline is correct, silent, and microseconds long.
fn freshnessFailure(comptime T: type, err: anyerror) QueryError!fault.Answer(T) {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    assay.trace(.fault, "resident declined: freshness unprovable ({t})\n", .{err});
    return .{ .declined = .freshness_unprovable };
}

pub const RetrievalSession = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    roots_arena: std.heap.ArenaAllocator,
    /// The roots the watcher covers (the CLI's cwd-rooted walk). `.` when empty,
    /// resolved by the watcher itself; queries carry their OWN roots argument.
    roots: []const []const u8,

    /// The warm, mmap'd index + doc→path table. Its `paths` list is EXTENDED in
    /// place past `base_len` with the freshness overlay's new-file paths (owned
    /// by `overlay_arena`); everything through `base_len` aliases the mmap.
    persisted: persist.Persisted,
    base_len: usize,
    /// Owns the changed-path strings appended to `persisted.paths`; reset (and
    /// its appends truncated away) at the head of every recompute.
    overlay_arena: std.heap.ArenaAllocator,
    /// Doc ids (into the extended path table) the freshness walk proved stale —
    /// the injected `Source.resident.fresh_ids` every query folds live. Cached
    /// across the whole clean window.
    fresh_ids: std.ArrayList(u32) = .empty,

    /// The index build instant; null when no trustworthy anchor exists (then no
    /// doc is provably fresh and the query trusts the index, exactly as the
    /// one-shot `fresh.candidates` no-anchor branch does).
    anchor_ns: ?assay.Anchor,
    /// The published `pair.gen` this session bound to ("" = legacy/none); a
    /// change triggers a re-map.
    index_gen: []u8,

    /// The reader/writer discipline shared with gist's `ResidentSession`
    /// (`kernel/math/lease.zig`): concurrent `search`/`pack` overlap under a
    /// shared lease on the watcher-clean fast path, while a recompute runs alone
    /// under the exclusive lease. `Ward.readReconciled` owns the double-checked
    /// upgrade dance — this session just supplies `seqlock.skip()` + `reconcile`.
    ward: Ward = .{},
    /// The freshness barrier shared with gist's `ResidentSession` — the
    /// watcher-driven seqlock whose memory ordering lives once in `seqlock.zig`.
    /// Without a live watcher it never proves clean, so every query recomputes
    /// the overlay (correct, just not microsecond-fast).
    seqlock: Seqlock = .{},
    /// The watcher's completeness hand-off. Relate's overlay is recomputed
    /// wholesale from the anchor, so the exact drained paths give no advantage
    /// over the clean/dirty bit — the log is drained (to consume it) and
    /// discarded. It exists to satisfy the shared watcher's contract.
    dirty_log: dirtylog.DirtyLog,
    daemon_gen: u64 = 0,

    /// Map the index warm. `null` when no index is built yet (the one expected
    /// miss — the client then answers cold).
    pub fn init(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !?RetrievalSession {
        var roots_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer roots_arena.deinit();
        const ra = roots_arena.allocator();
        const owned_roots = try ra.alloc([]const u8, roots.len);
        for (roots, 0..) |r, i| owned_roots[i] = try ra.dupe(u8, r);

        const p = (persist.loadQuiet(gpa, io) catch return null) orelse return null;
        const gen = readGen(gpa, io) catch {
            var tmp = p;
            tmp.deinit();
            return null;
        };
        return .{
            .gpa = gpa,
            .io = io,
            .roots_arena = roots_arena,
            .roots = owned_roots,
            .persisted = p,
            .base_len = p.paths.items.len,
            .overlay_arena = std.heap.ArenaAllocator.init(gpa),
            .anchor_ns = fresh.readAnchor(gpa, io),
            .index_gen = gen,
            .dirty_log = dirtylog.DirtyLog.init(gpa),
        };
    }

    pub fn deinit(self: *RetrievalSession) void {
        self.dirty_log.deinit();
        self.fresh_ids.deinit(self.gpa);
        self.gpa.free(self.index_gen);
        self.persisted.paths.shrinkRetainingCapacity(self.base_len); // drop overlay-arena aliases first
        self.overlay_arena.deinit();
        self.persisted.deinit();
        self.roots_arena.deinit();
    }

    // ── watcher hooks (called from the watch thread; lock-free) ──

    pub fn markDirty(self: *RetrievalSession) void {
        self.seqlock.markDirty();
    }

    pub fn markDoubtForever(self: *RetrievalSession) void {
        self.seqlock.markDoubtForever();
    }

    pub fn armWatcher(self: *RetrievalSession) void {
        self.seqlock.arm();
    }

    /// The watcher released its coverage on purpose (`watch.zig::shed`): the
    /// cached overlay stops being trustable without a reconcile, and the
    /// exactness promise lapses with the backend that made it. Reversible —
    /// `armWatcher` reopens the path after a fresh covering pass.
    pub fn disarmWatcher(self: *RetrievalSession) void {
        self.seqlock.disarm();
        self.dirty_log.disarmExact();
    }

    // ── freshness overlay ──

    /// Re-map the index when its on-disk generation advanced (someone ran `gist
    /// index`). Rare; holds the caller's lock. On failure the session keeps its
    /// old mapping and the query is declined, so a rebuild never corrupts a live
    /// session.
    fn maybeReload(self: *RetrievalSession) QueryError!fault.Answer(void) {
        const cur = readGen(self.gpa, self.io) catch |err| return freshnessFailure(void, err);
        defer self.gpa.free(cur);
        if (std.mem.eql(u8, cur, self.index_gen)) return .{ .got = {} };

        var np = (persist.loadQuiet(self.gpa, self.io) catch |err| return freshnessFailure(void, err)) orelse
            return .{ .declined = .freshness_unprovable };
        errdefer np.deinit();
        const next_gen = self.gpa.dupe(u8, cur) catch return error.OutOfMemory;
        // The old mapping's overlay aliases go first (they index the old table).
        self.persisted.paths.shrinkRetainingCapacity(self.base_len);
        _ = self.overlay_arena.reset(.free_all);
        self.fresh_ids.clearRetainingCapacity();
        self.persisted.deinit();
        self.gpa.free(self.index_gen);

        self.persisted = np;
        self.base_len = np.paths.items.len;
        self.anchor_ns = fresh.readAnchor(self.gpa, self.io);
        self.index_gen = next_gen;
        self.markDirty();
        return .{ .got = {} };
    }

    /// Bring the freshness overlay current. No-op on the watcher-clean fast path
    /// (the microsecond win — the cached `fresh_ids` still name every stale
    /// doc). Otherwise recompute: truncate the path table back to its mmap base,
    /// walk the anchor-relative changed set, and fold it back in exactly as the
    /// one-shot `fresh.candidates` does — so a resident answer and a cold
    /// retrieval verify the identical doc set.
    fn reconcile(self: *RetrievalSession) QueryError!fault.Answer(void) {
        switch (try self.maybeReload()) {
            .declined => |why| return .{ .declined = why },
            .got => {},
        }
        if (self.seqlock.skip()) return .{ .got = {} };

        const seq0 = self.seqlock.enter();
        var drained = self.dirty_log.drain(self.gpa); // consume; anchor recompute ignores the paths
        drained.deinit(self.gpa);

        self.persisted.paths.shrinkRetainingCapacity(self.base_len);
        _ = self.overlay_arena.reset(.retain_capacity);
        self.fresh_ids.clearRetainingCapacity();
        if (self.anchor_ns) |anchor| {
            const a = self.overlay_arena.allocator();
            var changed: std.ArrayList([]const u8) = .empty;
            fresh.changedSince(self.gpa, self.io, self.queryRoots(), anchor.ns(), a, &changed) catch |err|
                return freshnessFailure(void, err);
            if (changed.items.len > 0) {
                var scratch_ids: std.ArrayList(u32) = .empty;
                defer scratch_ids.deinit(self.gpa);
                fresh.widen(self.gpa, &self.persisted.paths, &scratch_ids, &self.fresh_ids, changed.items) catch |err|
                    return freshnessFailure(void, err);
            }
        }

        self.seqlock.commit(seq0);
        return .{ .got = {} };
    }

    /// The roots the freshness walk covers: the index's own build roots (the
    /// sound superset the overlay always folds over), never a re-derived guess.
    fn queryRoots(self: *const RetrievalSession) []const []const u8 {
        return self.persisted.roots.items;
    }

    fn source(self: *RetrievalSession) retrieval.Source {
        return .{ .resident = .{ .persisted = &self.persisted, .fresh_ids = self.fresh_ids.items } };
    }

    // ── the queries ──

    /// Answer a text-probe retrieval over the warm index — the warm→cold seam for
    /// relate (ADR-373 law 1). `roots` scopes the query (must be covered by the
    /// index); the caller owns the returned `Result`.
    ///
    /// The two negatives are DIFFERENT facts and the type says so: a `declined`
    /// answer means this session could not prove its overlay current, so the
    /// client must re-ask cold; a `got` of `null` is the shared retrieval
    /// kernel's own "nothing to report" (a sub-trigram query, roots outside the
    /// index) — the same answer a cold run would give, so re-asking is waste.
    pub fn search(self: *RetrievalSession, gpa: std.mem.Allocator, query: []const u8, roots: []const []const u8, top: usize) !fault.Answer(?Result) {
        const lease = switch (try self.beginRead()) {
            .declined => |why| return .{ .declined = why },
            .got => |lease| lease,
        };
        defer lease.release();
        return .{ .got = try retrieval.retrieve(gpa, self.io, query, roots, top, self.source()) };
    }

    /// Answer `relate pack` over the warm index (see `search`).
    pub fn pack(self: *RetrievalSession, gpa: std.mem.Allocator, query: []const u8, roots: []const []const u8, top: usize) !fault.Answer(?PackResult) {
        const lease = switch (try self.beginRead()) {
            .declined => |why| return .{ .declined = why },
            .got => |lease| lease,
        };
        defer lease.release();
        return .{ .got = try retrieval.pack(gpa, self.io, query, roots, top, self.source()) };
    }

    /// Acquire the session for READING over a fresh overlay: the watcher-clean
    /// fast path answers under a shared lease (concurrent queries overlap);
    /// otherwise `Ward.readReconciled` drops to exclusive, recomputes the overlay
    /// (`reconcile`, which re-checks `seqlock.skip()` — the double-checked
    /// upgrade), and downgrades back to shared. The `retrieval` lane it guards is
    /// read-only over `persisted`/`fresh_ids` (`queryLiteral` takes `*const`), so
    /// overlapping readers are sound. Freshness inability stays a typed decline
    /// through this boundary; allocation exhaustion remains `error.OutOfMemory`.
    fn beginRead(self: *RetrievalSession) QueryError!fault.Answer(Ward.Read) {
        const lease = self.ward.read(self.io);
        if (self.seqlock.skip()) return .{ .got = lease };
        lease.release();

        const held = self.ward.write(self.io);
        errdefer held.release();
        switch (try self.reconcile()) {
            .declined => |why| {
                held.release();
                return .{ .declined = why };
            },
            .got => return .{ .got = held.downgrade() },
        }
    }
};

const readGen = persist.readPublishedGeneration;

test "resident session satisfies the shared freshness watcher contract" {
    // A compile-time proof that ONE generic watcher (`watch.zig`) drives both
    // gist's `ResidentSession` and this retrieval session: `refAllDecls` forces
    // the instantiation's method bodies to be analyzed against this session's
    // change-tracking surface (`roots`, `armWatcher`, `disarmWatcher`,
    // `markDirty`, `markDoubtForever`, `dirty_log.{armExact,disarmExact,note,
    // noteDoubt}`). Missing or mis-typed any of them and this would not compile.
    const watch = @import("../watch/watch.zig");
    std.testing.refAllDecls(watch.Watcher(RetrievalSession));
}

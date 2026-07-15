//! gist resident session — the warm, in-memory search engine (ADR-352 rung 2.5).
//!
//! A `ResidentSession` owns the corpus bytes + trigram index for one repository,
//! held warm across many queries so an eligible request (`request.zig`) answers
//! without re-paying the process + index-mmap + candidate-read startup the cold
//! subprocess pays every call. It lowers each request through the shared search
//! core (`engine/query.zig`) — the SAME compile → trigram-prefilter → match
//! kernels the cold CLI is built on — driven directly over the warm corpus, so
//! the warm and cold answers cannot drift. Because that core **returns errors**
//! (`error.Unsupported`) instead of calling `die()`, a bad request surfaces here
//! as `error.Stale` (→ cold fallback) and can never terminate the daemon — the
//! exact hazard ADR-352 defers the C FFI on.
//!
//! ## Read-your-writes: a fail-closed reconcile barrier
//!
//! The invariant is `resident matches == gist --no-index matches == rg matches`.
//! It holds because both the base corpus and every reconcile re-derive their file
//! set from the cold path's OWN certified walk (`commands/ripgrep/run.zig::
//! defaultFileSet` — hidden-file exclusion, `.gitignore`/`.ignore` precedence,
//! `.git` skip, root scope), never `haystack`'s coarse superset. The warm set is
//! therefore byte-identical to what a rootless `gist <pattern>` would walk:
//!
//!   - A query is answered from resident bytes directly ONLY when the freshness
//!     barrier proves the roots quiescent since the last reconcile — a
//!     watcher-clean window (`markClean`/`markDirty`, driven by inotify on Linux
//!     / FSEvents on macOS; `src/session/watch.zig`). This is the microsecond path.
//!   - Otherwise (no watcher, any pending event, first query) the session
//!     RECONCILES: it re-walks the authoritative set and diffs it against
//!     base + overlay — a path that left the set (deleted, or newly
//!     hidden/ignored) is tombstoned; a new path is read in; a known path whose
//!     mtime/ctime advanced past the freshness cursor is re-read — then answers
//!     over (base ∪ overlay) − tombstones. Fail-closed: a rebuilt index
//!     (`pair.gen` drift) or a reconcile allocation failure surfaces as
//!     `error.Stale` and the daemon declines, so the client falls back to the
//!     certified cold path. (A catastrophic OOM inside the shared walk itself
//!     exits the daemon via `die()`; the client's dropped connection then falls
//!     back cold and the next query re-spawns a fresh daemon — fail-open too.)
//!
//! Queries are serialized by `mutex`; the watcher only ever touches the atomic
//! `dirty_seq`/`clean` pair, never the overlay, so the barrier is a lock-free
//! seqlock over a mutex-guarded engine.

const std = @import("std");
const corpus_mod = @import("../corpus/corpus.zig");
const bulkstat = @import("../corpus/bulkstat.zig");
// The resident file set is the certified rg-default walk the cold path uses, NOT
// `haystack`'s coarse superset — this is what makes `resident == --no-index ==
// rg` true for hidden files, `.gitignore` precedence, and root scope. `session`
// depending on `commands/ripgrep` is a one-way edge (run.zig never imports
// session), so no import cycle.
const run = @import("../commands/ripgrep/run.zig");
const persist = @import("../index/persist.zig");
const Index = @import("../index/trigram.zig").Index;
const query_mod = @import("../engine/query.zig");
const CompiledQuery = query_mod.CompiledQuery;
const Scratch = query_mod.Scratch;
const request = @import("request.zig");
const Dir = std.Io.Dir;

pub const Mode = request.Mode;
pub const Request = request.Request;

pub const QueryError = error{
    /// The session cannot prove freshness (no valid build anchor, or the index
    /// was rebuilt out from under it and could not be reloaded) — answer cold.
    Stale,
    OutOfMemory,
};

/// One eligible query's answer. `files` aliases session-owned path strings
/// (corpus path table or overlay keys) valid until the next reconcile; the
/// caller (daemon frame builder / test) copies them out under the session lock.
pub const Result = struct {
    mode: Mode,
    files: []const []const u8 = &.{},
    count: u64 = 0,
};

/// A base doc's live substitute: replacement bytes, or a tombstone (deleted, or
/// no longer a searchable doc — became empty/binary). Bytes are gpa-owned.
const Overlay = union(enum) { bytes: []u8, tombstone };

pub const ResidentSession = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    roots_arena: std.heap.ArenaAllocator,
    roots: []const []const u8,

    corpus: corpus_mod.Corpus,
    idx: Index,
    /// doc-id lookup for overlay substitution (aliases `corpus.paths`).
    by_path: std.StringHashMap(u32),

    /// The published index generation this session bound to ("" = legacy/none),
    /// gpa-owned; a `pair.gen` change triggers a reload.
    index_gen: []u8,
    /// Freshness cursor: files touched at/after this instant are reconciled on
    /// the next non-clean query. Starts at the build anchor, advances to the
    /// pre-walk instant after each reconcile (incremental catch-up).
    fresh_ns: i128,

    /// path (gpa-owned key) → mutation overlay. Accumulates across reconciles;
    /// bounded because a re-touched path replaces its entry in place.
    overlay: std.StringHashMap(Overlay),

    mutex: std.Io.Mutex = .init,
    /// Set by a watcher that is actively proving quiescence; without one the
    /// session reconciles on every query (correct, just not microsecond-fast).
    watcher_active: bool = false,
    /// Bumped by the watcher on every filesystem event (seqlock counter).
    dirty_seq: std.atomic.Value(u64) = .init(0),
    /// True only when a watcher has proven no event since the last reconcile.
    clean: std.atomic.Value(bool) = .init(false),

    /// Monotonic per-daemon-boot id, echoed to clients so they can detect a
    /// restarted daemon and re-handshake. Assigned by the server.
    daemon_gen: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !ResidentSession {
        var roots_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer roots_arena.deinit();
        const ra = roots_arena.allocator();
        const owned_roots = try ra.alloc([]const u8, roots.len);
        for (roots, 0..) |r, i| owned_roots[i] = try ra.dupe(u8, r);

        // The freshness cursor is captured BEFORE the corpus read so a write
        // racing the load is caught by the first reconcile, never baked silently
        // into stale base bytes (no false negatives). The session builds its OWN
        // in-memory index over these live bytes, so its baseline is this load
        // instant — NOT the persisted index's on-disk anchor, which belongs to a
        // different index and predates any tree touched since the last `gist
        // index` (using it would re-read the whole corpus on every query).
        const load_ns = std.Io.Clock.now(.real, io).nanoseconds;
        // Select the corpus with the certified rg-default walk (hidden-file
        // exclusion + `.gitignore` precedence + root scope) and read exactly that
        // set — so the resident base matches cold's live walk byte-for-byte,
        // never `haystack`'s coarse superset. A short-lived arena owns the path
        // list just for the read.
        var sel_arena = std.heap.ArenaAllocator.init(gpa);
        const sel_paths = run.defaultFileSet(sel_arena.allocator(), io, owned_roots);
        var corpus = corpus_mod.loadPaths(gpa, io, sel_paths) catch |e| {
            sel_arena.deinit();
            return e;
        };
        sel_arena.deinit();
        errdefer corpus.deinit();
        var idx = try Index.build(gpa, corpus.docs);
        errdefer idx.deinit();

        var by_path = std.StringHashMap(u32).init(gpa);
        errdefer by_path.deinit();
        try by_path.ensureTotalCapacity(@intCast(corpus.paths.len));
        for (corpus.paths, 0..) |p, i| by_path.putAssumeCapacity(p, @intCast(i));

        const gen = try readGen(gpa, io);
        errdefer gpa.free(gen);

        return .{
            .gpa = gpa,
            .io = io,
            .roots_arena = roots_arena,
            .roots = owned_roots,
            .corpus = corpus,
            .idx = idx,
            .by_path = by_path,
            .index_gen = gen,
            .fresh_ns = load_ns,
            .overlay = std.StringHashMap(Overlay).init(gpa),
        };
    }

    pub fn deinit(self: *ResidentSession) void {
        self.clearOverlay();
        self.overlay.deinit();
        self.gpa.free(self.index_gen);
        self.by_path.deinit();
        self.idx.deinit();
        self.corpus.deinit();
        self.roots_arena.deinit();
    }

    fn clearOverlay(self: *ResidentSession) void {
        var it = self.overlay.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            switch (e.value_ptr.*) {
                .bytes => |b| self.gpa.free(b),
                .tombstone => {},
            }
        }
        self.overlay.clearRetainingCapacity();
    }

    /// Set the overlay for `path`, freeing any prior value and reusing the key.
    fn putOverlay(self: *ResidentSession, path: []const u8, ov: Overlay) !void {
        const gop = try self.overlay.getOrPut(path);
        if (gop.found_existing) {
            switch (gop.value_ptr.*) {
                .bytes => |b| self.gpa.free(b),
                .tombstone => {},
            }
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, path) catch |e| {
                _ = self.overlay.remove(path);
                return e;
            };
        }
        gop.value_ptr.* = ov;
    }

    // ── watcher hooks (called from the watch thread; lock-free) ──

    /// A filesystem event arrived: the next query must reconcile.
    pub fn markDirty(self: *ResidentSession) void {
        _ = self.dirty_seq.fetchAdd(1, .monotonic);
        self.clean.store(false, .release);
    }

    /// Declare that a watcher is live and proving quiescence.
    pub fn armWatcher(self: *ResidentSession) void {
        self.watcher_active = true;
    }

    // ── freshness + reload ──

    /// Rebuild the resident corpus/index when the on-disk index generation has
    /// advanced (someone ran `gist index`). Heavy but rare; holds the caller's
    /// lock. On rebuild failure the session keeps its old state and reports
    /// `error.Stale` so the query is answered cold.
    fn maybeReload(self: *ResidentSession) QueryError!void {
        const cur = readGen(self.gpa, self.io) catch return QueryError.Stale;
        defer self.gpa.free(cur);
        if (std.mem.eql(u8, cur, self.index_gen)) return;

        var fresh_session = ResidentSession.init(self.gpa, self.io, self.roots) catch return QueryError.Stale;
        // Preserve identity fields the server owns.
        fresh_session.daemon_gen = self.daemon_gen;
        fresh_session.watcher_active = self.watcher_active;
        // Swap: tear down the stale engine, keep the fresh one's arenas/maps.
        // (roots_arena is rebuilt by init from self.roots, which lived in the
        // OLD roots_arena — init dupes it before we free anything below.)
        self.clearOverlay();
        self.overlay.deinit();
        self.gpa.free(self.index_gen);
        self.by_path.deinit();
        self.idx.deinit();
        self.corpus.deinit();
        self.roots_arena.deinit();
        const daemon_gen = self.daemon_gen;
        self.* = fresh_session;
        self.daemon_gen = daemon_gen;
        self.markDirty(); // a rebuilt index demands a reconcile pass
    }

    /// Bring the overlay current against the certified rg-default walk. No-op on
    /// the watcher-clean fast path. Re-derives the authoritative file set the
    /// cold path would walk RIGHT NOW and diffs it against the resident base +
    /// overlay: a file that left the set (deleted, or newly hidden/ignored) is
    /// tombstoned; a new file is read in; a file whose mtime/ctime advanced past
    /// the freshness cursor is re-read. This is the whole read-your-writes
    /// barrier — the set comes from the SAME walk as cold, so warm answers can't
    /// drift from `gist --no-index`/`rg`. A reconcile allocation failure surfaces
    /// as `error.Stale` (→ cold fallback); see the module header on walk OOM.
    fn reconcile(self: *ResidentSession) QueryError!void {
        try self.maybeReload();
        if (self.watcher_active and self.clean.load(.acquire)) return;

        const seq0 = self.dirty_seq.load(.acquire);
        const now = std.Io.Clock.now(.real, self.io).nanoseconds;

        var walk_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer walk_arena.deinit();
        const cur = run.defaultFileSet(walk_arena.allocator(), self.io, self.roots);

        var cur_set = std.StringHashMap(void).init(self.gpa);
        defer cur_set.deinit();
        try cur_set.ensureTotalCapacity(@intCast(cur.len));
        for (cur) |p| cur_set.putAssumeCapacity(p, {});

        for (cur) |p| try self.reconcileOne(p);
        try self.tombstoneVanished(&cur_set);

        self.fresh_ns = now;
        // Only trust the clean short-circuit if a watcher is live AND no event
        // raced this reconcile (seqlock recheck). Without a watcher, stay dirty.
        if (self.watcher_active and self.dirty_seq.load(.acquire) == seq0)
            self.clean.store(true, .release);
    }

    /// Fold one currently-authoritative path into the overlay. A new or
    /// reappeared (previously tombstoned) path is read unconditionally; an
    /// already-known path is re-read only when its mtime/ctime advanced past the
    /// freshness cursor — the incremental catch-up that keeps reconcile from
    /// re-reading an unchanged corpus every query.
    fn reconcileOne(self: *ResidentSession, p: []const u8) QueryError!void {
        if (self.overlay.get(p)) |ov| switch (ov) {
            .tombstone => return self.readInto(p), // reappeared since its delete
            .bytes => {}, // already substituted — fall through to the mtime gate
        } else if (!self.by_path.contains(p)) {
            return self.readInto(p); // brand-new file, not in the base corpus
        }
        const st = Dir.cwd().statFile(self.io, p, .{}) catch return self.readInto(p);
        if (bulkstat.needsLiveRead(self.fresh_ns, st.mtime.nanoseconds, st.ctime.nanoseconds))
            return self.readInto(p);
    }

    /// Read `p` into an overlay entry: its live bytes, or a tombstone when it is
    /// gone/unreadable or no longer a searchable doc (empty/binary) — the exact
    /// per-file admission `corpus.loadPaths`/cold apply, so a file that turned
    /// binary drops out of both warm and cold identically.
    fn readInto(self: *ResidentSession, p: []const u8) QueryError!void {
        const raw = Dir.cwd().readFileAlloc(self.io, p, self.gpa, .limited(corpus_mod.per_file_cap)) catch
            return self.putOverlay(p, .tombstone);
        if (raw.len == 0 or corpus_mod.isBinary(raw)) {
            self.gpa.free(raw);
            return self.putOverlay(p, .tombstone);
        }
        return self.putOverlay(p, .{ .bytes = raw });
    }

    /// Tombstone every base doc or overlaid file that is no longer in the
    /// authoritative set (deleted, or newly hidden/gitignored). Removals are
    /// collected before mutating `overlay` (no mutation mid-iteration).
    fn tombstoneVanished(self: *ResidentSession, cur_set: *const std.StringHashMap(void)) QueryError!void {
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(self.gpa);
        for (self.corpus.paths) |p| {
            if (cur_set.contains(p)) continue;
            if (self.overlay.get(p)) |ov| if (ov == .tombstone) continue; // already gone
            try gone.append(self.gpa, p);
        }
        var it = self.overlay.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .bytes => if (!cur_set.contains(e.key_ptr.*)) try gone.append(self.gpa, e.key_ptr.*),
            .tombstone => {},
        };
        for (gone.items) |p| try self.putOverlay(p, .tombstone);
    }

    /// Effective bytes for base doc `id`: overlay substitute, tombstone (→ null),
    /// or the resident bytes.
    fn docBytes(self: *const ResidentSession, id: u32) ?[]const u8 {
        if (self.overlay.get(self.corpus.paths[id])) |ov| return switch (ov) {
            .bytes => |b| b,
            .tombstone => null,
        };
        return self.corpus.docs[id];
    }

    // ── the query ──

    /// Answer an eligible request over the warm engine. `arena` owns the
    /// returned `files` slice (the path strings themselves alias session memory,
    /// stable until the next reconcile — copy under the lock if needed).
    pub fn query(self: *ResidentSession, arena: std.mem.Allocator, req: Request) QueryError!Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.reconcile();

        // Lower the request through the shared search core (`engine/query.zig`):
        // the SAME compile → prefilter → match kernels the cold CLI is built on,
        // but returning errors instead of `die()`ing. A pattern outside the
        // linear-time syntax surfaces as `error.Stale` → certified cold fallback.
        var cq = CompiledQuery.compile(self.gpa, .{
            .pattern = req.pattern,
            .mode = req.mode,
            .fixed = req.fixed,
            .ignore_case = req.ignore_case,
        }) catch return QueryError.Stale;
        defer cq.deinit(self.gpa);
        var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
        defer sc.deinit();

        // The reconcile walk-diff already tombstones any delete it observes, but a
        // file can vanish in the race between that walk and this report. On the
        // watcher-clean path a live watcher has tombstoned every delete, so trust
        // it (microsecond no-stat path); otherwise confirm each matched path still
        // exists (a cheap stat per hit) so a just-removed file is never reported.
        var acc = Accumulator{
            .mode = req.mode,
            .arena = arena,
            .io = self.io,
            .verify_existence = !self.clean.load(.acquire),
        };
        try self.answer(&acc, &cq, &sc);

        if (req.mode == .files) std.mem.sort([]const u8, acc.files.items, {}, lessPath);
        return .{ .mode = req.mode, .files = acc.files.items, .count = acc.count };
    }

    /// Prune candidates with the compiled query's sound trigram prefilter (a
    /// single required literal → `queryLiteral`; an alternation cover →
    /// `queryAny`; nothing prunable → every doc), then verify each with the
    /// shared match kernel. Overlay docs (changed/new since the build) are always
    /// verified directly — the index is stale for exactly those.
    fn answer(self: *ResidentSession, acc: *Accumulator, cq: *const CompiledQuery, sc: *Scratch) QueryError!void {
        var one: [1][]const u8 = undefined;
        const pf = cq.prefilter(&one);
        var cand_buf: ?[]u32 = null;
        defer if (cand_buf) |c| self.gpa.free(c);
        const cand: []const u32 = blk: {
            if (pf.len == 1) {
                if (self.idx.queryLiteral(self.gpa, pf[0])) |c| {
                    cand_buf = c;
                    break :blk c;
                } else |_| {}
            } else if (pf.len > 1) {
                if (self.idx.queryAny(self.gpa, pf)) |c| {
                    cand_buf = c;
                    break :blk c;
                } else |_| {}
            }
            break :blk try self.allDocIds(&cand_buf);
        };

        for (cand) |id| {
            if (self.overlay.contains(self.corpus.paths[id])) continue; // handled below
            try acc.consider(self.corpus.paths[id], self.corpus.docs[id], cq, sc, acc.verify_existence);
        }
        try self.considerOverlay(acc, cq, sc);
    }

    /// Verify the mutation overlay (changed base docs + brand-new files) directly
    /// — the index is stale for exactly these, so they never rely on it.
    fn considerOverlay(self: *ResidentSession, acc: *Accumulator, cq: *const CompiledQuery, sc: *Scratch) QueryError!void {
        var it = self.overlay.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .tombstone => {},
            // A reconcile tombstones any overlay path that left the walk set, but
            // (as for base docs) a delete can still race the walk→report window.
            // Off the watcher-clean path, existence-check the match (same
            // fail-closed stat-per-hit the base docs use); the clean path already
            // tombstoned any delete, so it keeps the microsecond no-stat path.
            .bytes => |b| try acc.consider(e.key_ptr.*, b, cq, sc, acc.verify_existence),
        };
    }

    fn allDocIds(self: *ResidentSession, buf: *?[]u32) QueryError![]const u32 {
        const all = try self.gpa.alloc(u32, self.corpus.docs.len);
        for (all, 0..) |*x, i| x.* = @intCast(i);
        buf.* = all;
        return all;
    }
};

/// Folds matched docs into either the file-path set (`-l`) or the matching-line
/// total (`-c`), so both eligible modes share one candidate walk. The match
/// decision itself is the shared `CompiledQuery` kernel (`engine/query.zig`).
const Accumulator = struct {
    mode: Mode,
    arena: std.mem.Allocator,
    io: std.Io,
    verify_existence: bool,
    files: std.ArrayList([]const u8) = .empty,
    count: u64 = 0,

    fn consider(self: *Accumulator, path: []const u8, bytes: []const u8, cq: *const CompiledQuery, sc: *Scratch, check_exists: bool) QueryError!void {
        switch (self.mode) {
            .files => {
                if (!cq.docMatches(bytes, sc)) return;
                if (check_exists and !self.exists(path)) return;
                try self.files.append(self.arena, path);
            },
            .count => {
                const n = cq.countLines(bytes, sc);
                if (n == 0) return;
                if (check_exists and !self.exists(path)) return;
                self.count += n;
            },
        }
    }

    fn exists(self: *Accumulator, path: []const u8) bool {
        _ = Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return true;
    }
};

fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The published `pair.gen` (gpa-owned; "" when absent). A rebuilt index changes
/// this, triggering `maybeReload`.
fn readGen(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const buf = Dir.cwd().readFileAlloc(io, persist.generation_file, gpa, .limited(128)) catch
        return gpa.alloc(u8, 0);
    const trimmed = std.mem.trimEnd(u8, buf, "\r\n");
    if (trimmed.len == buf.len) return buf;
    defer gpa.free(buf);
    return gpa.dupe(u8, trimmed);
}

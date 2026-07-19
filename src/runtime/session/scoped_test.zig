//! gist resident session — the O(changed) scoped-reconcile adversarial suite.
//!
//! `freshness_test.zig` hardens the reconcile-always barrier; this file attacks
//! the SCOPED path (`dirty.zig` + `delta.zig` + `reconcileScoped`) — the one
//! new skip decision this engine makes: "these exact watcher paths are the only
//! places the tree can differ from my overlay". Every test drives the session
//! through the same three-call backend contract the real macOS FSEvents
//! backend honors (`dirty_log.armExact()`, `note(abs)` before `markDirty()`),
//! then asserts the answers against an INDEPENDENT on-disk oracle (a naive
//! re-read + substring scan that never runs the engine — sins.mdc Sin #2), so
//! a scoped-path bug can't grade its own homework.
//!
//! The suite is double-sided:
//!
//!   - where the scoped path IS sound (exact per-file notes covering every
//!     mutation), it must both answer correctly AND actually take the scoped
//!     path (`scoped_reconciles` advances; a silent full-walk fallback would
//!     make the whole feature vacuous and this suite would catch the
//!     regression);
//!   - where it is NOT provably sound (an ignore-source edit, a doubted batch,
//!     an overflowed log, a poisoned watcher, a batch with zero exactness
//!     promise), it must refuse — `full_reconciles` advances — and the full
//!     walk restores truth even for mutations the log never heard about.

const std = @import("std");
const resident = @import("resident.zig");
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;

/// A throwaway on-disk tree plus the live-file bookkeeping the oracle needs.
/// `canon` is the tree root's realpath — the spelling a real FSEvents stream
/// prefixes every delivered event with (on macOS `/tmp` is a firmlink to
/// `/private/tmp`, so the two differ), which is exactly how the tests must
/// spell their `note`s to simulate the backend faithfully.
const Corpus = struct {
    root: []const u8,
    canon: []const u8,
    io: std.Io,
    a: std.mem.Allocator,
    live: std.ArrayList([]const u8) = .empty, // relative names currently on disk

    fn init(a: std.mem.Allocator, io: std.Io, tag: []const u8, seed: usize) !Corpus {
        const root = try std.fmt.allocPrint(a, "/tmp/gist_scoped_{s}_{x}", .{ tag, seed });
        Dir.cwd().deleteTree(io, root) catch {};
        try Dir.cwd().createDirPath(io, root);
        const rootz = try a.dupeZ(u8, root);
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const resolved = std.c.realpath(rootz, &buf) orelse return error.Unexpected;
        return .{ .root = root, .canon = try a.dupe(u8, std.mem.sliceTo(resolved, 0)), .io = io, .a = a };
    }

    fn deinit(self: *Corpus) void {
        Dir.cwd().deleteTree(self.io, self.root) catch {};
        self.live.deinit(self.a);
    }

    fn abs(self: *Corpus, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
    }

    /// The event-spelling of `rel`: canonical-root-prefixed, as FSEvents would
    /// deliver it.
    fn event(self: *Corpus, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.canon, rel });
    }

    fn write(self: *Corpus, rel: []const u8, data: []const u8) !void {
        try Dir.cwd().writeFile(self.io, .{ .sub_path = try self.abs(rel), .data = data });
        for (self.live.items) |n| if (std.mem.eql(u8, n, rel)) return;
        try self.live.append(self.a, try self.a.dupe(u8, rel));
    }

    fn mkdir(self: *Corpus, rel: []const u8) !void {
        try Dir.cwd().createDirPath(self.io, try self.abs(rel));
    }

    fn remove(self: *Corpus, rel: []const u8) !void {
        try Dir.cwd().deleteFile(self.io, try self.abs(rel));
        self.dropLive(rel);
    }

    fn removeTree(self: *Corpus, rel: []const u8) !void {
        try Dir.cwd().deleteTree(self.io, try self.abs(rel));
        var i: usize = 0;
        while (i < self.live.items.len) {
            const n = self.live.items[i];
            const under = n.len > rel.len and std.mem.startsWith(u8, n, rel) and n[rel.len] == '/';
            if (under or std.mem.eql(u8, n, rel)) {
                _ = self.live.orderedRemove(i);
            } else i += 1;
        }
    }

    fn dropLive(self: *Corpus, rel: []const u8) void {
        for (self.live.items, 0..) |n, i| if (std.mem.eql(u8, n, rel)) {
            _ = self.live.orderedRemove(i);
            return;
        };
    }

    /// Independent oracle: abs paths of live files whose bytes contain `needle`.
    fn oracleFiles(self: *Corpus, out: *std.ArrayList([]const u8), needle: []const u8) !void {
        for (self.live.items) |rel| {
            const bytes = Dir.cwd().readFileAlloc(self.io, try self.abs(rel), self.a, .limited(1 << 20)) catch continue;
            defer self.a.free(bytes);
            if (std.mem.indexOf(u8, bytes, needle) != null) try out.append(self.a, try self.abs(rel));
        }
        std.mem.sort([]const u8, out.items, {}, lessPath);
    }
};

fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A short sleep so a coarse filesystem clock records a strictly-newer
/// mtime/ctime past the session's freshness cursor.
fn advanceClock(io: std.Io) !void {
    try io.sleep(.fromNanoseconds(60 * std.time.ns_per_ms), .real);
}

fn assertMatchesOracle(session: *ResidentSession, corpus: *Corpus, gpa: std.mem.Allocator, needle: []const u8) !void {
    var q = std.heap.ArenaAllocator.init(gpa);
    defer q.deinit();
    const qa = q.allocator();
    var want: std.ArrayList([]const u8) = .empty;
    try corpus.oracleFiles(&want, needle);
    const got = try session.query(qa, .{ .pattern = needle, .mode = .files, .fixed = true });
    try std.testing.expectEqual(want.items.len, got.files.len);
    const sorted = try qa.dupe([]const u8, got.files);
    std.mem.sort([]const u8, sorted, {}, lessPath);
    for (want.items, sorted) |w, g| try std.testing.expectEqualStrings(w, g);
}

/// Boot a session over `corpus`, simulate the exact backend arming, and run
/// the covering first query (the full pass scoped reconciles build on).
fn bootExact(session: *ResidentSession, corpus: *Corpus, gpa: std.mem.Allocator) !void {
    session.dirty_log.armExact();
    session.armWatcher();
    try assertMatchesOracle(session, corpus, gpa, "needle");
    try std.testing.expect(session.full_pass_done);
}

/// One simulated exact-backend event burst: note every path, then bump the seq
/// — the same ordering the FSEvents callback honors.
fn fire(session: *ResidentSession, paths: []const []const u8) void {
    for (paths) |p| session.dirty_log.note(p);
    session.markDirty();
}

test "scoped: exact add/modify/delete answers match the oracle WITHOUT a full walk" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var corpus = try Corpus.init(fa, io, "crud", @intFromPtr(&threaded));
    defer corpus.deinit();
    try corpus.write("a.txt", "needle alpha\n");
    try corpus.write("b.txt", "no match here\n");
    try corpus.write("c.txt", "needle gamma\n");

    var session = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer session.deinit();
    try bootExact(&session, &corpus, gpa);
    const full0 = session.full_reconciles;

    // Modify (content edit: the dir's mtime does NOT change — the classic trap
    // a dir-mtime pruner falls into; the per-file note must carry it).
    try advanceClock(io);
    try corpus.write("b.txt", "a needle appears\n");
    fire(&session, &.{try corpus.event("b.txt")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");

    // Add.
    try corpus.write("d.txt", "needle delta\n");
    fire(&session, &.{try corpus.event("d.txt")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");

    // Delete.
    try corpus.remove("c.txt");
    fire(&session, &.{try corpus.event("c.txt")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");

    // Rename (FSEvents delivers both spellings as separate item events).
    try Dir.cwd().rename(try corpus.abs("a.txt"), Dir.cwd(), try corpus.abs("z.txt"), io);
    corpus.dropLive("a.txt");
    try corpus.write("z.txt", "needle alpha\n"); // rewrite: same bytes, registers live
    fire(&session, &.{ try corpus.event("a.txt"), try corpus.event("z.txt") });
    try assertMatchesOracle(&session, &corpus, gpa, "needle");

    // Every mutation above must have reconciled SCOPED: the full-walk counter
    // may not have moved, and the scoped counter must cover all four bursts.
    try std.testing.expectEqual(full0, session.full_reconciles);
    try std.testing.expect(session.scoped_reconciles >= 4);
}

test "scoped: a directory event folds in its whole admitted subtree, create and destroy" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var corpus = try Corpus.init(fa, io, "tree", @intFromPtr(&threaded));
    defer corpus.deinit();
    try corpus.write("base.txt", "needle base\n");

    var session = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer session.deinit();
    try bootExact(&session, &corpus, gpa);
    const full0 = session.full_reconciles;

    // A new nested subtree, noted ONLY by its topmost directory (FSEvents may
    // coalesce the children into the ancestor's event).
    try corpus.mkdir("sub/inner");
    try corpus.write("sub/inner/x.txt", "needle nested\n");
    try corpus.write("sub/y.txt", "nothing\n");
    fire(&session, &.{try corpus.event("sub")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");

    // Destroy the subtree; again only the topmost directory is noted.
    try corpus.removeTree("sub");
    fire(&session, &.{try corpus.event("sub")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");

    try std.testing.expectEqual(full0, session.full_reconciles);
    try std.testing.expect(session.scoped_reconciles >= 2);
}

test "scoped: an ignore-source edit refuses the scope and the full walk restores truth" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var corpus = try Corpus.init(fa, io, "ign", @intFromPtr(&threaded));
    defer corpus.deinit();
    try corpus.write("keep.txt", "needle keeps\n");
    try corpus.write("drop.txt", "needle drops\n");

    var session = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer session.deinit();
    try bootExact(&session, &corpus, gpa);
    const full0 = session.full_reconciles;

    // Writing `.gitignore` flips the admission verdict of a file the log never
    // noted (`drop.txt`) — only the full walk is sound, and the session must
    // know that from the PATH CLASS alone.
    try advanceClock(io);
    try corpus.write(".gitignore", "drop.txt\n");
    corpus.dropLive(".gitignore"); // hidden: never in the walked set
    corpus.dropLive("drop.txt"); // now ignored: oracle must not count it
    fire(&session, &.{try corpus.event(".gitignore")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
    try std.testing.expect(session.full_reconciles > full0);

    // And deleting it un-ignores: same refusal, opposite direction.
    try advanceClock(io);
    try Dir.cwd().deleteFile(io, try corpus.abs(".gitignore"));
    try corpus.live.append(fa, try fa.dupe(u8, "drop.txt"));
    fire(&session, &.{try corpus.event(".gitignore")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
}

test "scoped: doubt, overflow, and a non-exact backend all force the covering full walk" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var corpus = try Corpus.init(fa, io, "doubt", @intFromPtr(&threaded));
    defer corpus.deinit();
    try corpus.write("a.txt", "needle one\n");
    try corpus.write("b.txt", "quiet\n");

    var session = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer session.deinit();
    try bootExact(&session, &corpus, gpa);

    // 1. A doubted batch: the backend saw a flag it couldn't attribute, and the
    //    actual mutation was NEVER noted. Only the full walk can find it.
    try advanceClock(io);
    try corpus.write("b.txt", "a needle sneaks in\n");
    session.dirty_log.noteDoubt();
    session.markDirty();
    const full_before_doubt = session.full_reconciles;
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
    try std.testing.expect(session.full_reconciles > full_before_doubt);

    // 2. Overflow: shrink the bound and note more distinct paths than fit; the
    //    log must degrade to doubt, and the UN-noted mutation still surfaces.
    session.dirty_log.cap = 2;
    try advanceClock(io);
    try corpus.write("c.txt", "needle three\n"); // never noted
    session.dirty_log.note(try corpus.event("a.txt"));
    session.dirty_log.note(try corpus.event("b.txt"));
    session.dirty_log.note(try corpus.event("x.txt")); // over the bound → doubt
    session.markDirty();
    const full_before_ovf = session.full_reconciles;
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
    try std.testing.expect(session.full_reconciles > full_before_ovf);
    session.dirty_log.cap = 4096;

    // 3. A non-exact backend (Linux inotify shape): dirty bumps with NO note
    //    and NO exactness — construct a second session that never arms exact.
    var coarse = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer coarse.deinit();
    coarse.armWatcher();
    try assertMatchesOracle(&coarse, &corpus, gpa, "needle");
    try advanceClock(io);
    try corpus.write("d.txt", "needle four\n");
    coarse.markDirty();
    const full_before = coarse.full_reconciles;
    try assertMatchesOracle(&coarse, &corpus, gpa, "needle");
    try std.testing.expect(coarse.full_reconciles > full_before);
    try std.testing.expectEqual(@as(u64, 0), coarse.scoped_reconciles);
}

test "scoped: a poisoned watcher reconciles every query and never trusts the scope" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var corpus = try Corpus.init(fa, io, "poison", @intFromPtr(&threaded));
    defer corpus.deinit();
    try corpus.write("a.txt", "needle one\n");

    var session = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer session.deinit();
    try bootExact(&session, &corpus, gpa);

    // The watcher lost coverage (queue overflow / unwatchable dir). From here
    // on, mutations arrive with NO note and NO markDirty — the poisoned
    // session must reconcile anyway and still see them.
    session.markDoubtForever();
    try advanceClock(io);
    try corpus.write("ghost.txt", "needle unseen by any event\n");
    const scoped0 = session.scoped_reconciles;
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
    try std.testing.expectEqual(scoped0, session.scoped_reconciles);

    // Even a fully-noted exact batch may not re-enable scoping: poison is
    // permanent (the backend already proved it can lie by omission).
    try advanceClock(io);
    try corpus.write("late.txt", "needle late\n");
    fire(&session, &.{try corpus.event("late.txt")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
    try std.testing.expectEqual(scoped0, session.scoped_reconciles);
}

test "scoped: write racing the scoped reconcile is re-read, never lost" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var corpus = try Corpus.init(fa, io, "race", @intFromPtr(&threaded));
    defer corpus.deinit();
    try corpus.write("hot.txt", "needle v0\n");

    var session = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer session.deinit();
    try bootExact(&session, &corpus, gpa);

    // The seqlock discipline under the scoped path: a note+dirty that lands
    // AFTER the reconcile's pre-drain seq read must keep the session dirty, so
    // the NEXT query drains it. Simulate the interleaving deterministically:
    // note+dirty for v1, query (drains v1's path), then note+dirty for v2
    // exactly as a racing writer would, then verify v2 is visible.
    for (1..6) |v| {
        try advanceClock(io);
        try corpus.write("hot.txt", try std.fmt.allocPrint(fa, "needle v{d}\n", .{v}));
        fire(&session, &.{try corpus.event("hot.txt")});
        try assertMatchesOracle(&session, &corpus, gpa, try std.fmt.allocPrint(fa, "needle v{d}", .{v}));
    }
}

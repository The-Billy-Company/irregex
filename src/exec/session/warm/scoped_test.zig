//! gist resident session — the O(changed) scoped-reconcile adversarial suite.
//!
//! `freshness_test.zig` hardens the reconcile-always barrier; this file attacks
//! the SCOPED path (`dirty.zig` + `delta.zig` + `reconcileScoped`) — the one
//! new skip decision this engine makes: "these exact watcher paths are the only
//! places the tree can differ from my overlay". Every test drives the session
//! through the same three-call backend contract every real backend honors
//! (`dirty_log.armExact()`, `note(abs)` before `markDirty()`),
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
const builtin = @import("builtin");
const resident = @import("resident.zig");
const truth = @import("truth.zig");
const fault = @import("../../../fault.zig");
const portal = @import("../../../portal.zig");
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;

/// A throwaway on-disk tree plus the live-file bookkeeping the oracle needs.
/// `canon` is the tree root's realpath — the spelling a real backend prefixes
/// every delivered event with (on macOS `/tmp` is a firmlink to
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
        fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));
        try Dir.cwd().createDirPath(io, root);
        const rootz = try a.dupeZ(u8, root);
        var buf: [portal.max_path]u8 = undefined;
        const resolved = portal.realpath(rootz, &buf) orelse return error.Unexpected;
        return .{ .root = root, .canon = try a.dupe(u8, resolved), .io = io, .a = a };
    }

    fn deinit(self: *Corpus) void {
        fault.spare("remove fixture", Dir.cwd().deleteTree(self.io, self.root));
        self.live.deinit(self.a);
    }

    fn abs(self: *Corpus, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
    }

    /// The event-spelling of `rel`: canonical-root-prefixed, as a backend would
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
};

/// A short sleep so a coarse filesystem clock records a strictly-newer
/// mtime/ctime past the session's freshness cursor.
fn advanceClock(io: std.Io) !void {
    try io.sleep(.fromNanoseconds(60 * std.time.ns_per_ms), .real);
}

fn assertMatchesOracle(session: *ResidentSession, corpus: *Corpus, gpa: std.mem.Allocator, needle: []const u8) !void {
    try truth.expectFiles(session, corpus, gpa, needle);
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
/// — the same ordering a real backend's drain honors.
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
    const full0 = session.full_reconciles.load(.monotonic);

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

    // Rename (a backend reports both spellings — kqueue as two directory events).
    try Dir.cwd().rename(try corpus.abs("a.txt"), Dir.cwd(), try corpus.abs("z.txt"), io);
    corpus.dropLive("a.txt");
    try corpus.write("z.txt", "needle alpha\n"); // rewrite: same bytes, registers live
    fire(&session, &.{ try corpus.event("a.txt"), try corpus.event("z.txt") });
    try assertMatchesOracle(&session, &corpus, gpa, "needle");

    // Every mutation above must have reconciled SCOPED: the full-walk counter
    // may not have moved, and the scoped counter must cover all four bursts.
    try std.testing.expectEqual(full0, session.full_reconciles.load(.monotonic));
    try std.testing.expect(session.scoped_reconciles.load(.monotonic) >= 4);
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
    const full0 = session.full_reconciles.load(.monotonic);

    // A new nested subtree, noted ONLY by its topmost directory (a backend may
    // report just the ancestor — kqueue never had a watch on the new children).
    try corpus.mkdir("sub/inner");
    try corpus.write("sub/inner/x.txt", "needle nested\n");
    try corpus.write("sub/y.txt", "nothing\n");
    fire(&session, &.{try corpus.event("sub")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");

    // Destroy the subtree; again only the topmost directory is noted.
    try corpus.removeTree("sub");
    fire(&session, &.{try corpus.event("sub")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");

    try std.testing.expectEqual(full0, session.full_reconciles.load(.monotonic));
    try std.testing.expect(session.scoped_reconciles.load(.monotonic) >= 2);
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
    const full0 = session.full_reconciles.load(.monotonic);

    // Writing `.gitignore` flips the admission verdict of a file the log never
    // noted (`drop.txt`) — only the full walk is sound, and the session must
    // know that from the PATH CLASS alone.
    try advanceClock(io);
    try corpus.write(".gitignore", "drop.txt\n");
    corpus.dropLive(".gitignore"); // hidden: never in the walked set
    corpus.dropLive("drop.txt"); // now ignored: oracle must not count it
    fire(&session, &.{try corpus.event(".gitignore")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
    try std.testing.expect(session.full_reconciles.load(.monotonic) > full0);

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
    const full_before_doubt = session.full_reconciles.load(.monotonic);
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
    try std.testing.expect(session.full_reconciles.load(.monotonic) > full_before_doubt);

    // 2. Overflow: shrink the bound and note more distinct paths than fit; the
    //    log must degrade to doubt, and the UN-noted mutation still surfaces.
    session.dirty_log.cap = 2;
    try advanceClock(io);
    try corpus.write("c.txt", "needle three\n"); // never noted
    session.dirty_log.note(try corpus.event("a.txt"));
    session.dirty_log.note(try corpus.event("b.txt"));
    session.dirty_log.note(try corpus.event("x.txt")); // over the bound → doubt
    session.markDirty();
    const full_before_ovf = session.full_reconciles.load(.monotonic);
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
    try std.testing.expect(session.full_reconciles.load(.monotonic) > full_before_ovf);
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
    const full_before = coarse.full_reconciles.load(.monotonic);
    try assertMatchesOracle(&coarse, &corpus, gpa, "needle");
    try std.testing.expect(coarse.full_reconciles.load(.monotonic) > full_before);
    try std.testing.expectEqual(@as(u64, 0), coarse.scoped_reconciles.load(.monotonic));
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
    const scoped0 = session.scoped_reconciles.load(.monotonic);
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
    try std.testing.expectEqual(scoped0, session.scoped_reconciles.load(.monotonic));

    // Even a fully-noted exact batch may not re-enable scoping: poison is
    // permanent (the backend already proved it can lie by omission).
    try advanceClock(io);
    try corpus.write("late.txt", "needle late\n");
    fire(&session, &.{try corpus.event("late.txt")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
    try std.testing.expectEqual(scoped0, session.scoped_reconciles.load(.monotonic));
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

// ── Workstream D: non-ASCII paths scope instead of forcing the full walk ──
//
// These live on a case-INsensitive filesystem (macOS APFS/HFS+), the only place
// the Unicode aliasing the non-ASCII sweep guards against exists. Each renames a
// non-ASCII corpus key to an ALIASING spelling the fs treats as the same file,
// delivers ONLY the new (current) spelling — so the raw-key rename detector
// can't see the stale twin (raw == canon) and the closing `sweepNonAscii` is the
// sole line of defense — then asserts the answer stays oracle-exact AND the pass
// stayed SCOPED (a `.needs_full` refusal would make the whole workstream vacuous).
// A skip guards the rare case-sensitive volume where the twin never aliases.

/// True on a case-insensitive fs: after a rename, the OLD non-ASCII spelling
/// must still resolve to the (renamed) file. When it doesn't, the twin never
/// aliased and the sweep scenario can't be staged — the caller skips.
fn twinAliases(corpus: *Corpus, old_rel: []const u8) bool {
    _ = Dir.cwd().statFile(corpus.io, corpus.abs(old_rel) catch return false, .{}) catch return false;
    return true;
}

/// Rename `old_rel` → `new_rel` (an aliasing non-ASCII spelling), deliver only
/// the current spelling as an exact burst, and assert the stale twin was swept
/// out scoped. Skips where the twin doesn't alias (case-sensitive volume).
fn expectTwinSwept(session: *ResidentSession, corpus: *Corpus, gpa: std.mem.Allocator, io: std.Io, fa: std.mem.Allocator, old_rel: []const u8, new_rel: []const u8) !void {
    const full0 = session.full_reconciles.load(.monotonic);
    const scoped0 = session.scoped_reconciles.load(.monotonic);
    try advanceClock(io);
    try Dir.cwd().rename(try corpus.abs(old_rel), Dir.cwd(), try corpus.abs(new_rel), io);
    if (!twinAliases(corpus, old_rel)) return error.SkipZigTest;
    corpus.dropLive(old_rel);
    try corpus.live.append(fa, try fa.dupe(u8, new_rel));

    fire(session, &.{try corpus.event(new_rel)});
    try assertMatchesOracle(session, corpus, gpa, "needle");
    try std.testing.expectEqual(full0, session.full_reconciles.load(.monotonic));
    try std.testing.expect(session.scoped_reconciles.load(.monotonic) > scoped0);
}

test "scoped: a non-ASCII case-rename sweeps the stale twin without a full walk" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var corpus = try Corpus.init(fa, io, "unicase", @intFromPtr(&threaded));
    defer corpus.deinit();
    try corpus.write("caf\u{e9}.txt", "needle accented\n"); // café.txt (lower é, U+00E9)
    try corpus.write("plain.txt", "needle plain\n");

    var session = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer session.deinit();
    try bootExact(&session, &corpus, gpa);

    // café.txt → CAFÉ.txt (É = U+00C9): a Unicode case-rename the ASCII fold
    // can't equate (é/É are non-ASCII), so only the sweep retires the old key.
    try expectTwinSwept(&session, &corpus, gpa, io, fa, "caf\u{e9}.txt", "CAF\u{c9}.txt");
}

test "scoped: an NFC↔NFD normalization twin is swept without a full walk" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var corpus = try Corpus.init(fa, io, "uninorm", @intFromPtr(&threaded));
    defer corpus.deinit();
    try corpus.write("caf\u{e9}.txt", "needle nfc\n"); // NFC: single é (U+00E9)
    try corpus.write("plain.txt", "needle plain\n");

    var session = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer session.deinit();
    try bootExact(&session, &corpus, gpa);

    // Re-normalize café.txt to NFD (e + combining acute U+0301): a normalization
    // twin APFS aliases but neither byte- nor ASCII-fold matching can equate.
    try expectTwinSwept(&session, &corpus, gpa, io, fa, "caf\u{e9}.txt", "cafe\u{301}.txt");
}

test "scoped: delete-then-recreate under another normalization leaves no ghost" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var corpus = try Corpus.init(fa, io, "unighost", @intFromPtr(&threaded));
    defer corpus.deinit();
    try corpus.write("r\u{e9}sum\u{e9}.md", "needle before\n"); // résumé.md, NFC
    try corpus.write("plain.txt", "needle plain\n");

    var session = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer session.deinit();
    try bootExact(&session, &corpus, gpa);
    const full0 = session.full_reconciles.load(.monotonic);
    const scoped0 = session.scoped_reconciles.load(.monotonic);

    // Physically delete the NFC file and recreate it in NFD with new content.
    // The fresh NFD spelling is what the exact burst carries; the stale NFC key
    // must be swept, not double-counted as a ghost sibling.
    try advanceClock(io);
    try corpus.remove("r\u{e9}sum\u{e9}.md"); // NFC gone from disk + ledger
    try corpus.write("re\u{301}sume\u{301}.md", "needle after\n"); // NFD twin
    if (!twinAliases(&corpus, "r\u{e9}sum\u{e9}.md")) return error.SkipZigTest;

    fire(&session, &.{try corpus.event("re\u{301}sume\u{301}.md")});
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
    try std.testing.expectEqual(full0, session.full_reconciles.load(.monotonic));
    try std.testing.expect(session.scoped_reconciles.load(.monotonic) > scoped0);
}

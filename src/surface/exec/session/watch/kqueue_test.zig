//! gist resident session — the macOS kqueue barrier, driven end-to-end (ADR-372).
//!
//! `scoped_test.zig` attacks the scoped reconcile by SIMULATING a backend's
//! three-call contract (`armExact` → `note` → `markDirty`). This file removes the
//! simulation: it boots the real `Watcher`, mutates a real tree, crosses the real
//! `flushSync` barrier exactly where `serve.zig` crosses it (before dispatch),
//! and grades every answer against the same independent on-disk oracle
//! (`truth.zig` — a naive re-read that never runs the engine, so a backend bug
//! cannot grade its own homework).
//!
//! Each case is a hazard the design had to answer, not a paraphrase of the code:
//!
//!   - an IN-PLACE content edit, which a directory-granular watcher cannot see at
//!     all (a directory does not change when a file's bytes do) — the finding
//!     that forced one descriptor per file;
//!   - a file created after arming, then EDITED AGAIN, which passes only if the
//!     directory event actually registered the newcomer's own descriptor. A
//!     blind spot here answers the first mutation correctly and the second one
//!     staler than the disk;
//!   - the same for a whole directory created after arming;
//!   - a CROSS-DIRECTORY move, where one rename touches two watched directories;
//!   - a CASE-ONLY rename, the aliasing that keeps Linux from ever arming exact
//!     on a casefolded root and which kqueue's descriptor keying sidesteps;
//!   - a deletion, which must leave the corpus and stay gone;
//!   - an entry added directly to a SERVED ROOT, the one shape that deliberately
//!     declines to scope (`delta.resolve` → `.needs_full`): a subtree verdict on
//!     a root re-enumerates the whole tree serially, which is strictly worse than
//!     the parallel full walk it would be standing in for.
//!
//! Every scopeable case also asserts the reconcile was SCOPED, because an answer
//! that is merely correct proves nothing here — a silent fall back to the full
//! walk would be correct too, and would make the entire barrier vacuous. Mutations
//! therefore land under a subdirectory: the root itself is the documented
//! full-walk shape, pinned by its own case rather than dodged.
//!
//! macOS-only by construction; every case returns immediately elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const resident = @import("../warm/resident.zig");
const truth = @import("../warm/truth.zig");
const watch = @import("watch.zig");
const fault = @import("../../../../fault.zig");
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;
const is_macos = builtin.os.tag == .macos;

/// A throwaway on-disk tree plus the live-file ledger the oracle re-reads. Only
/// the fields `truth.zig` names are public surface; the mutators keep the ledger
/// in step so the oracle always describes the disk, never the engine's belief.
const Tree = struct {
    root: []const u8,
    io: std.Io,
    a: std.mem.Allocator,
    live: std.ArrayList([]const u8) = .empty,

    fn init(a: std.mem.Allocator, io: std.Io, tag: []const u8, seed: usize) !Tree {
        const root = try std.fmt.allocPrint(a, "/tmp/gist_kq_{s}_{x}", .{ tag, seed });
        fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));
        try Dir.cwd().createDirPath(io, root);
        return .{ .root = root, .io = io, .a = a };
    }

    fn deinit(self: *Tree) void {
        fault.spare("remove fixture", Dir.cwd().deleteTree(self.io, self.root));
        self.live.deinit(self.a);
    }

    fn abs(self: *Tree, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
    }

    fn write(self: *Tree, rel: []const u8, data: []const u8) !void {
        try Dir.cwd().writeFile(self.io, .{ .sub_path = try self.abs(rel), .data = data });
        try self.admit(rel);
    }

    /// Write a file an ignore rule keeps OUT of the walked set: it exists on
    /// disk, so a watcher that ignores the rules would find it, and the oracle
    /// must not expect it until a rule change admits it.
    fn writeIgnored(self: *Tree, rel: []const u8, data: []const u8) !void {
        try Dir.cwd().writeFile(self.io, .{ .sub_path = try self.abs(rel), .data = data });
        self.dropLive(rel);
    }

    /// Record that `rel` is (now) part of the walked set.
    fn admit(self: *Tree, rel: []const u8) !void {
        for (self.live.items) |n| if (std.mem.eql(u8, n, rel)) return;
        try self.live.append(self.a, try self.a.dupe(u8, rel));
    }

    fn mkdir(self: *Tree, rel: []const u8) !void {
        try Dir.cwd().createDirPath(self.io, try self.abs(rel));
    }

    fn remove(self: *Tree, rel: []const u8) !void {
        try Dir.cwd().deleteFile(self.io, try self.abs(rel));
        self.dropLive(rel);
    }

    /// A real `rename(2)`, so the kernel reports exactly what it reports in
    /// production (both directories plus the moved vnode).
    fn move(self: *Tree, from: []const u8, to: []const u8) !void {
        try Dir.renameAbsolute(try self.abs(from), try self.abs(to), self.io);
        self.dropLive(from);
        try self.live.append(self.a, try self.a.dupe(u8, to));
    }

    fn dropLive(self: *Tree, rel: []const u8) void {
        for (self.live.items, 0..) |n, i| if (std.mem.eql(u8, n, rel)) {
            _ = self.live.orderedRemove(i);
            return;
        };
    }
};

/// One live session + its real watcher over `tree`, already through the covering
/// full pass a scoped reconcile is only sound downstream of. Returns null when the
/// watcher did not arm exact — a machine whose descriptor budget or `/tmp` shape
/// refuses coverage is a legitimate fail-closed outcome, not a test failure, and
/// the caller skips rather than asserting against the baseline.
const Rig = struct {
    session: *ResidentSession,
    watcher: *watch.Watcher(ResidentSession),
    tree: *Tree,
    gpa: std.mem.Allocator,

    fn boot(
        gpa: std.mem.Allocator,
        session: *ResidentSession,
        watcher: *watch.Watcher(ResidentSession),
        tree: *Tree,
    ) !?Rig {
        watcher.start();
        if (!session.seqlock.armed() or !session.dirty_log.exact) return null;
        var rig = Rig{ .session = session, .watcher = watcher, .tree = tree, .gpa = gpa };
        // The covering first pass: full by construction (`full_pass_done` is
        // false until it completes), which is exactly why arming mid-registration
        // is sound.
        try rig.expectOracle("needle");
        try std.testing.expect(session.full_pass_done);
        return rig;
    }

    /// Cross the read-your-writes barrier the way `serve.zig` does — drain the
    /// queue, then answer — and assert the answer matched the disk AND that the
    /// reconcile behind it was scoped, not a full walk.
    fn expectScopedOracle(self: *Rig, needle: []const u8) !void {
        const before = self.session.scoped_reconciles.load(.monotonic);
        try std.testing.expect(self.watcher.flushSync());
        try self.expectOracle(needle);
        try std.testing.expect(self.session.scoped_reconciles.load(.monotonic) > before);
    }

    /// The same barrier crossing for a mutation the resolver declines to scope:
    /// the answer must still match the disk, via the full walk.
    fn expectFullOracle(self: *Rig, needle: []const u8) !void {
        const before = self.session.scoped_reconciles.load(.monotonic);
        try std.testing.expect(self.watcher.flushSync());
        try self.expectOracle(needle);
        try std.testing.expectEqual(before, self.session.scoped_reconciles.load(.monotonic));
    }

    fn expectOracle(self: *Rig, needle: []const u8) !void {
        try truth.expectFiles(self.session, self.tree, self.gpa, needle);
    }
};

/// A short sleep so a coarse filesystem clock records a strictly-newer
/// mtime/ctime past the session's freshness cursor (the same discipline
/// `scoped_test.zig` keeps).
fn advanceClock(io: std.Io) !void {
    try io.sleep(.fromNanoseconds(60 * std.time.ns_per_ms), .real);
}

/// The tree every case starts from: one matching file at the root, one in a
/// subdirectory, and a second watched directory that exists BEFORE arming, so a
/// cross-directory move has two scopeable endpoints (a root entry would decline
/// to scope).
fn seedTree(tree: *Tree) !void {
    try tree.write("a.txt", "needle here\n");
    try tree.mkdir("sub");
    try tree.write("sub/b.txt", "needle in sub\n");
    try tree.mkdir("two");
    try tree.write("two/z.txt", "quiet here\n");
}

fn withRig(tag: []const u8, body: *const fn (*Rig) anyerror!void) !void {
    return withSeededRig(tag, seedTree, body);
}

/// Boilerplate every case shares: a threaded `Io`, a fixture arena, a `seed`ed
/// tree, a session, and a watcher. `body` receives a booted rig, or is skipped
/// when the watcher legitimately declined to arm.
fn withSeededRig(
    tag: []const u8,
    seed: *const fn (*Tree) anyerror!void,
    body: *const fn (*Rig) anyerror!void,
) !void {
    if (comptime !is_macos) return;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, tag, @intFromPtr(&threaded));
    defer tree.deinit();
    try seed(&tree);

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();
    var watcher = watch.Watcher(ResidentSession).init(gpa, io, &session);
    defer watcher.stop();

    var rig = (try Rig.boot(gpa, &session, &watcher, &tree)) orelse return;
    try body(&rig);
}

test "kqueue: an in-place content edit is seen — the blindness a dir-only watch has" {
    try withRig("inplace", struct {
        fn run(rig: *Rig) !void {
            // No entry is added or removed here, so the parent directory's vnode
            // never changes: only the file's own descriptor can report this.
            try advanceClock(rig.tree.io);
            try rig.tree.write("a.txt", "needle rewritten\n");
            try rig.expectScopedOracle("needle");

            // And the reverse direction: the match must LEAVE when the bytes do.
            try advanceClock(rig.tree.io);
            try rig.tree.write("a.txt", "nothing to find\n");
            try rig.expectScopedOracle("needle");
        }
    }.run);
}

test "kqueue: a file created after arming is covered for its LATER edits too" {
    try withRig("newfile", struct {
        fn run(rig: *Rig) !void {
            try advanceClock(rig.tree.io);
            try rig.tree.write("sub/c.txt", "needle newborn\n");
            try rig.expectScopedOracle("needle");

            // The real assertion: edit the newcomer IN PLACE. Its parent cannot
            // report this, so it passes only if the directory event registered the
            // new file's own descriptor. A coverage gap answers the create right
            // and this edit stale.
            try advanceClock(rig.tree.io);
            try rig.tree.write("sub/c.txt", "gone quiet\n");
            try rig.expectScopedOracle("needle");
        }
    }.run);
}

test "kqueue: a directory created after arming is covered for in-place edits inside it" {
    try withRig("newdir", struct {
        fn run(rig: *Rig) !void {
            try advanceClock(rig.tree.io);
            try rig.tree.mkdir("sub/fresh/deeper");
            try rig.tree.write("sub/fresh/deeper/d.txt", "needle deep\n");
            try rig.expectScopedOracle("needle");

            // Coverage must have recursed: an in-place edit two levels below a
            // directory that did not exist at arm time.
            try advanceClock(rig.tree.io);
            try rig.tree.write("sub/fresh/deeper/d.txt", "silent now\n");
            try rig.expectScopedOracle("needle");
        }
    }.run);
}

test "kqueue: a cross-directory move is reported by both directories" {
    try withRig("crossmove", struct {
        fn run(rig: *Rig) !void {
            // One rename, two watched directories, one moved vnode: the source
            // must stop matching and the destination must start, in one batch.
            try advanceClock(rig.tree.io);
            try rig.tree.move("sub/b.txt", "two/b.txt");
            try rig.expectScopedOracle("needle");

            // The moved file keeps its coverage under the new parent.
            try advanceClock(rig.tree.io);
            try rig.tree.write("two/b.txt", "moved and muted\n");
            try rig.expectScopedOracle("needle");
        }
    }.run);
}

test "kqueue: a case-only rename resolves to exactly one current spelling" {
    try withRig("caserename", struct {
        fn run(rig: *Rig) !void {
            try advanceClock(rig.tree.io);
            try rig.tree.write("sub/Mixed.txt", "needle cased\n");
            try rig.expectScopedOracle("needle");

            // On a case-INSENSITIVE volume both spellings name one file, so a
            // path-keyed watcher would alias them; the oracle's ledger holds only
            // the new spelling, so a surviving twin fails the count.
            try advanceClock(rig.tree.io);
            try rig.tree.move("sub/Mixed.txt", "sub/mixed.txt");
            try rig.expectScopedOracle("needle");
        }
    }.run);
}

test "kqueue: an entry added to a served root declines to scope, and is still right" {
    try withRig("rootentry", struct {
        fn run(rig: *Rig) !void {
            // `delta.resolve` refuses a root-scoped verdict on purpose, so this
            // is the full walk — and the answer must be correct anyway. Pinned
            // because the alternative (enumerating a root subtree serially) would
            // look scoped while costing more than the walk it replaced.
            try advanceClock(rig.tree.io);
            try rig.tree.write("root_born.txt", "needle at root\n");
            try rig.expectFullOracle("needle");

            // The newcomer's own descriptor still got registered: an in-place
            // edit of it is scopeable even though its birth was not.
            try advanceClock(rig.tree.io);
            try rig.tree.write("root_born.txt", "hushed\n");
            try rig.expectScopedOracle("needle");
        }
    }.run);
}

test "kqueue: a deletion leaves the corpus and stays gone" {
    try withRig("delete", struct {
        fn run(rig: *Rig) !void {
            try advanceClock(rig.tree.io);
            try rig.tree.remove("sub/b.txt");
            try rig.expectScopedOracle("needle");

            // A retired descriptor must not resurrect the file, and re-creating
            // the same path must be picked up again.
            try advanceClock(rig.tree.io);
            try rig.tree.write("sub/b.txt", "needle reborn\n");
            try rig.expectScopedOracle("needle");
        }
    }.run);
}

test "kqueue: an ignore-rule edit re-derives the admitted set AND the watch set" {
    try withSeededRig("ignorerule", struct {
        fn seed(tree: *Tree) !void {
            try seedTree(tree);
            // The rule file is hidden, so the visibility rule alone would leave
            // it unwatched — and an edit to it would change what the walk admits
            // with nothing to report it.
            try tree.write(".gitignore", "shy.txt\n");
            try tree.writeIgnored("sub/shy.txt", "needle unseen\n");
        }
    }.seed, struct {
        fn run(rig: *Rig) !void {
            // On disk, matching, and correctly absent: an ignored file is not a
            // member of the walked set, so it is not watched either.
            try rig.expectOracle("needle");

            // Rewrite the rule. The path is `.semantics` to `delta.classify`, so
            // the answer comes from the full walk — the cheap half of the fix.
            try advanceClock(rig.tree.io);
            try rig.tree.write(".gitignore", "nothing.txt\n");
            try rig.tree.admit("sub/shy.txt");
            try rig.expectFullOracle("needle");

            // The half that a fresh policy alone would not buy: the newly-admitted
            // file must now be WATCHED. Its bytes change without its directory
            // changing, so a watch set still selected by the OLD rules answers
            // this staler than the disk while claiming the session is clean.
            try advanceClock(rig.tree.io);
            try rig.tree.write("sub/shy.txt", "quiet at last\n");
            try rig.expectScopedOracle("needle");
        }
    }.run);
}

test "kqueue: a shed watch set answers from the baseline, and re-arming re-covers the gap" {
    try withRig("shed", struct {
        fn run(rig: *Rig) !void {
            try std.testing.expect(rig.watcher.held() > 0);

            // Shedding gives every descriptor back and withdraws all three
            // scoped-path preconditions with the stream that justified them.
            rig.watcher.shed();
            try std.testing.expectEqual(@as(usize, 0), rig.watcher.held());
            try std.testing.expect(!rig.session.seqlock.armed());
            try std.testing.expect(!rig.session.dirty_log.exact);
            try std.testing.expect(!rig.session.full_pass_done);
            // No backend, so no barrier to cross — a `flushSync` that claimed to
            // have drained one would be a licence to trust a dead stream.
            try std.testing.expect(!rig.watcher.flushSync());

            // The adverse case: an IN-PLACE content edit with nothing watching.
            // Its directory never changes, so only the reconcile-always baseline
            // can catch it — which is exactly what shedding falls back to.
            try advanceClock(rig.tree.io);
            try rig.tree.write("sub/b.txt", "needle rewritten while shed\n");
            try rig.expectOracle("needle");

            // And one more change inside the shed window that NOTHING has
            // observed by the time the watcher comes back.
            try advanceClock(rig.tree.io);
            try rig.tree.write("sub/b.txt", "quiet while shed\n");

            rig.watcher.start();
            try std.testing.expect(rig.session.seqlock.armed());
            try std.testing.expect(rig.watcher.held() > 0);
            // The first pass under the new stream must be the FULL one. A scoped
            // pass here would drain an empty note set — nothing was noted while
            // shed — and answer the disk staler than it is, which is precisely
            // what a `full_pass_done` surviving the shed would allow.
            try rig.expectFullOracle("needle");
            try std.testing.expect(rig.session.full_pass_done);

            // The rebuilt set is a real one, not a husk: an in-place edit scopes
            // again, so re-arming restored coverage rather than just the flag.
            try advanceClock(rig.tree.io);
            try rig.tree.write("sub/b.txt", "needle back\n");
            try rig.expectScopedOracle("needle");
        }
    }.run);
}

test "kqueue: stop() releases the watch set and the session survives it" {
    if (comptime !is_macos) return;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "teardown", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "needle here\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();
    var watcher = watch.Watcher(ResidentSession).init(gpa, io, &session);
    watcher.start();
    watcher.stop();
    // A stopped watcher must not leave a barrier that claims to have drained
    // anything, and the session must still answer (reconcile-always).
    try std.testing.expect(!watcher.flushSync());
    try truth.expectFiles(&session, &tree, gpa, "needle");
    watcher.stop(); // idempotent — the deinit path runs twice in fail-fast callers
}

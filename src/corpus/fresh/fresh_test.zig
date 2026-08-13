//! irregex T3 freshness-overlay test — split from `fresh.zig`. Pulled into
//! `zig build test` via `bench.zig`'s test block. Exercises `widen`'s set
//! algebra in isolation (no filesystem): an existing-but-trigram-skipped file is
//! forced into the candidate ids by its existing id, a brand-new file is
//! appended to `paths` and id'd once, and duplicates collapse — each doc exactly
//! once.
//!
//! Then the part `widen` cannot speak to: the MODEL in `README.md` § The model,
//! which is what every "no false negatives" claim about a stale index rests
//! on. Each assumption there is one test here, driving real files through the
//! production sweep rather than asserting a hand-computed set — the interesting
//! failures (a filesystem that does not advance ctime, a walk that loses a
//! subtree) are exactly the ones a mocked stat cannot have.

const std = @import("std");
const fresh = @import("fresh.zig");
const sweep = @import("sweep.zig");
const bulkstat = @import("../tree/bulkstat.zig");
const fault = @import("../../fault.zig");
const portal = @import("../../portal.zig");
const Dir = std.Io.Dir;

/// A throwaway tree plus the two clocks the model is stated in terms of. The
/// gap around the anchor is real sleep because it has to be: the claim is about
/// what the FILESYSTEM records, and a filesystem whose timestamp granularity is
/// coarser than the gap would make the test lie in the engine's favor.
const Fixture = struct {
    const gap_ns = 25 * std.time.ns_per_ms;

    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    anchor_ns: i128 = 0,

    fn init(gpa: std.mem.Allocator, io: std.Io, tag: []const u8, salt: usize) !Fixture {
        var fx: Fixture = .{ .gpa = gpa, .io = io, .arena = std.heap.ArenaAllocator.init(gpa), .root = "" };
        var scratch: [portal.max_path]u8 = undefined;
        fx.root = try std.fmt.allocPrint(fx.arena.allocator(), "{s}/gist_fresh_model_{s}_{x}", .{ portal.scratchDir(&scratch), tag, salt });
        fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, fx.root));
        try Dir.cwd().createDirPath(io, fx.root);
        return fx;
    }

    fn deinit(fx: *Fixture) void {
        fault.spare("remove fixture", Dir.cwd().deleteTree(fx.io, fx.root));
        fx.arena.deinit();
    }

    fn path(fx: *Fixture, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(fx.arena.allocator(), "{s}/{s}", .{ fx.root, name });
    }

    fn write(fx: *Fixture, name: []const u8, data: []const u8) ![]const u8 {
        const p = try fx.path(name);
        try Dir.cwd().writeFile(fx.io, .{ .sub_path = p, .data = data });
        return p;
    }

    /// Stamp the anchor the way a build does — after reading the corpus it is
    /// describing, and with a real gap on each side so "strictly before" and
    /// "at or after" are facts about recorded metadata, not about clock skew.
    fn stampAnchor(fx: *Fixture) !void {
        try fx.io.sleep(.fromNanoseconds(gap_ns), .real);
        fx.anchor_ns = std.Io.Timestamp.now(fx.io, .real).nanoseconds;
        try fx.io.sleep(.fromNanoseconds(gap_ns), .real);
    }

    /// Rewind one clock below the anchor — `touch -r old new`, which is the only
    /// half of the pair a portable call can move.
    fn rewindMtime(fx: *Fixture, p: []const u8) !void {
        try Dir.cwd().setTimestamps(fx.io, p, .{
            .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(fx.anchor_ns - 10 * std.time.ns_per_s) } },
        });
    }

    /// What the production freshness walk reports for this tree — the same
    /// `sweep.run` the overlay calls once the journal fast path declines.
    fn swept(fx: *Fixture, out: *std.ArrayList([]const u8)) !void {
        try sweep.run(fx.gpa, fx.io, &.{fx.root}, fx.anchor_ns, fx.arena.allocator(), out);
    }

    fn surfaced(out: *const std.ArrayList([]const u8), p: []const u8) bool {
        for (out.items) |got| if (std.mem.eql(u8, got, p)) return true;
        return false;
    }

    /// The two clocks as the filesystem reports them, for asserting WHICH one
    /// carried a change rather than just that something did.
    fn clocks(fx: *Fixture, p: []const u8) !struct { mtime: i128, ctime: i128 } {
        const st = try Dir.cwd().statFile(fx.io, p, .{ .follow_symlinks = false });
        return .{ .mtime = st.mtime.nanoseconds, .ctime = st.ctime.nanoseconds };
    }
};

test "widen: new file is appended + id'd; existing fresh file is forced once" {
    const gpa = std.testing.allocator;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    try paths.appendSlice(gpa, &.{ "a/x.zig", "a/y.zig" }); // ids 0,1

    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    try ids.append(gpa, 0); // base candidate: only doc 0

    var fresh_ids: std.ArrayList(u32) = .empty;
    defer fresh_ids.deinit(gpa);

    // y.zig (existing, trigram-skipped) + z.zig (brand new) both changed.
    try fresh.widen(gpa, &paths, &ids, &fresh_ids, &.{ "a/y.zig", "a/z.zig", "a/y.zig" });

    try std.testing.expectEqual(@as(usize, 3), paths.items.len); // z.zig appended once
    try std.testing.expectEqualStrings("a/z.zig", paths.items[2]);
    // ids: 0 (base) + 1 (y forced) + 2 (z new), each exactly once.
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, ids.items);
    // fresh_ids: exactly the changed docs (y, z), deduped, base-independent.
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, fresh_ids.items);
}

test "the model: an ordinary write after the anchor is surfaced, an untouched file is not" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(gpa, io, "write", @intFromPtr(&threaded));
    defer fx.deinit();
    const quiet = try fx.write("quiet.txt", "indexed and never touched again");
    try fx.stampAnchor();
    const edited = try fx.write("edited.txt", "written after the build read the corpus");

    var out: std.ArrayList([]const u8) = .empty;
    try fx.swept(&out);

    // The whole claim in one line: the file whose bytes moved is offered back to
    // the caller for a live read, and the one that did not is left elidable.
    try std.testing.expect(Fixture.surfaced(&out, edited));
    try std.testing.expect(!Fixture.surfaced(&out, quiet));
}

test "the model: rewinding mtime below the anchor cannot hide a write — ctime carries it" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(gpa, io, "rewind", @intFromPtr(&threaded));
    defer fx.deinit();
    const p = try fx.write("preserved.txt", "the bytes the index knows");
    try fx.stampAnchor();
    // The naive attack on a single-clock overlay, and the ordinary accident:
    // rewrite the bytes, then restore the old modification time.
    try Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "DIFFERENT BYTES, ANCIENT MTIME" });
    try fx.rewindMtime(p);

    // Prove the mechanism, not just the outcome — mtime really is behind the
    // anchor, so ctime is the only reason this file can still be surfaced.
    const c = try fx.clocks(p);
    try std.testing.expect(c.mtime < fx.anchor_ns);
    try std.testing.expect(c.ctime >= fx.anchor_ns);
    try std.testing.expect(bulkstat.needsLiveRead(fx.anchor_ns, c.mtime, c.ctime));

    var out: std.ArrayList([]const u8) = .empty;
    try fx.swept(&out);
    try std.testing.expect(Fixture.surfaced(&out, p));
}

test "the model: a rename over an indexed path is surfaced, though the index is path-keyed" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(gpa, io, "rename", @intFromPtr(&threaded));
    defer fx.deinit();
    const indexed = try fx.write("indexed.txt", "the bytes the index knows");
    const usurper = try fx.write("usurper.txt", "COMPLETELY OTHER BYTES");
    try fx.stampAnchor();

    // The path-key hole as an attack: move a different inode onto the indexed
    // path and backdate the one clock a portable call can move. `rename(2)` is
    // required to mark the moved file's ctime, which is what closes it.
    try fx.rewindMtime(usurper);
    try Dir.cwd().rename(usurper, Dir.cwd(), indexed, io);

    const c = try fx.clocks(indexed);
    try std.testing.expect(c.mtime < fx.anchor_ns);
    try std.testing.expect(c.ctime >= fx.anchor_ns);

    var out: std.ArrayList([]const u8) = .empty;
    try fx.swept(&out);
    try std.testing.expect(Fixture.surfaced(&out, indexed));
    try std.testing.expect(!Fixture.surfaced(&out, usurper)); // the old name is gone, not "changed"
}

test "the model: a file the walk cannot stat is conservatively fresh, never quietly elidable" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(gpa, io, "unknown", @intFromPtr(&threaded));
    defer fx.deinit();
    try fx.stampAnchor();

    // Assumption 3 of the model: metadata is either reported or reported-absent.
    // `confirmChanged` is the one path that takes an externally-sourced path list
    // (the resident daemon's annals) and holds it to the walk's own predicate, so
    // it is where "unstattable" has to mean "read it".
    const vanished = try fx.path("vanished.txt");
    var out: std.ArrayList([]const u8) = .empty;
    try std.testing.expect(fresh.confirmChanged(gpa, io, &.{fx.root}, fx.anchor_ns, &.{vanished}, fx.arena.allocator(), &out));
    try std.testing.expect(Fixture.surfaced(&out, vanished));
}

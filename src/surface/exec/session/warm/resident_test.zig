//! gist resident session — the warm-engine correctness suite (ADR-352 rung 2.5).
//!
//! The one invariant the resident path must never break is
//! `resident matches == gist --no-index matches == rg matches`. Freshness has a
//! single unforgivable failure mode — a false result after the tree changed
//! under a warm session — so these tests drive a REAL directory tree through a
//! live `ResidentSession` and prove, over live syscalls: (1) the eligible
//! file-set / count answers match ground truth, (2) a write is visible to the
//! next query (read-your-writes via the reconcile barrier), (3) a deletion is
//! never reported, and (4) the regex + caseless paths agree with the literal
//! one. Assertions pin the expected shape, not a self-run of the engine.

const std = @import("std");
const builtin = @import("builtin");
const resident = @import("resident.zig");
const request = @import("../answer/request.zig");
const fault = @import("../../../../fault.zig");
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;

/// A throwaway on-disk tree the session searches, with an absolute root so no
/// test ever depends on (or mutates) the process cwd.
const Tree = struct {
    root: []const u8,
    io: std.Io,
    a: std.mem.Allocator,

    fn init(a: std.mem.Allocator, io: std.Io, tag: []const u8, seed: usize) !Tree {
        const root = try std.fmt.allocPrint(a, "/tmp/gist_resident_{s}_{x}", .{ tag, seed });
        fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));
        try Dir.cwd().createDirPath(io, root);
        return .{ .root = root, .io = io, .a = a };
    }

    fn deinit(self: *Tree) void {
        fault.spare("remove fixture", Dir.cwd().deleteTree(self.io, self.root));
    }

    fn write(self: *Tree, rel: []const u8, data: []const u8) !void {
        const p = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
        if (std.fs.path.dirnamePosix(p)) |dir| try Dir.cwd().createDirPath(self.io, dir);
        try Dir.cwd().writeFile(self.io, .{ .sub_path = p, .data = data });
    }

    fn remove(self: *Tree, rel: []const u8) !void {
        const p = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
        try Dir.cwd().deleteFile(self.io, p);
    }

    fn abs(self: *Tree, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
    }
};

/// Coarse filesystem clocks can collapse a write onto the previous reconcile
/// tick; a short sleep guarantees the mtime/ctime strictly advance so
/// `changedSince` flags the change (the same 50ms idiom `bulkstat_test` uses).
fn advanceClock(io: std.Io) !void {
    try io.sleep(.fromNanoseconds(60 * std.time.ns_per_ms), .real);
}

/// Assert the files-mode result is exactly `rels` (order-independent set match).
fn expectFileSet(tree: *Tree, files: []const []const u8, rels: []const []const u8) !void {
    try std.testing.expectEqual(rels.len, files.len);
    for (rels) |rel| {
        const want = try tree.abs(rel);
        var found = false;
        for (files) |got| if (std.mem.eql(u8, got, want)) {
            found = true;
            break;
        };
        if (!found) {
            std.debug.print("resident files result missing {s} (got {d} files):\n", .{ want, files.len });
            for (files) |got| std.debug.print("  - {s}\n", .{got});
            return error.TestUnexpectedFileSet;
        }
    }
}

fn queryFiles(session: *ResidentSession, arena: std.mem.Allocator, req: request.Request) ![]const []const u8 {
    const r = (try session.query(arena, req)).got;
    return r.files;
}

test "resident: files + count match ground truth over a warm tree" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "parity", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "alpha\nneedle one\n"); // 1 matching line
    try tree.write("b.txt", "needle two\nneedle three\n"); // 2 matching lines
    try tree.write("c.txt", "no match here\n"); // 0

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    var q1 = std.heap.ArenaAllocator.init(gpa);
    defer q1.deinit();
    const files = try queryFiles(&session, q1.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
    try expectFileSet(&tree, files, &.{ "a.txt", "b.txt" });

    var q2 = std.heap.ArenaAllocator.init(gpa);
    defer q2.deinit();
    const counted = (try session.query(q2.allocator(), .{ .pattern = "needle", .mode = .count, .fixed = true })).got;
    try std.testing.expectEqual(@as(u64, 3), counted.count);
}

test "resident: a write is visible to the next query (read-your-writes)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "ryw", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "needle here\n");
    try tree.write("c.txt", "not yet\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
        try expectFileSet(&tree, files, &.{"a.txt"});
    }

    try advanceClock(io);
    try tree.write("c.txt", "not yet\nneedle appeared\n"); // c now matches

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
        try expectFileSet(&tree, files, &.{ "a.txt", "c.txt" });
    }
}

test "resident: a deleted file is never reported" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "delete", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "needle stays\n");
    try tree.write("b.txt", "needle goes\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
        try expectFileSet(&tree, files, &.{ "a.txt", "b.txt" });
    }

    try advanceClock(io);
    try tree.remove("b.txt");

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
        try expectFileSet(&tree, files, &.{"a.txt"});
    }
}

test "resident: the file set is the rg-default walk (hidden/gitignore/binary/empty excluded)" {
    // The parity contract: the resident corpus is selected by the SAME rg-default
    // walk cold uses, so hidden files, `.gitignore`/nested-`.gitignore` matches,
    // `.git`, binary, and empty files are all absent — never `haystack`'s coarse
    // superset. A false POSITIVE here (reporting a file rg would exclude) is the
    // exact warm-vs-cold drift this whole refactor closes.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "ignore", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("visible.txt", "needle here\n"); // kept
    try tree.write("sub/ok.txt", "needle nested\n"); // kept
    try tree.write(".hidden.txt", "needle hidden\n"); // excluded: hidden file
    try tree.write(".config/d.txt", "needle hidden dir\n"); // excluded: hidden dir
    try tree.write(".git/config", "needle in git\n"); // excluded: .git
    try tree.write("ignored/x.txt", "needle ignored\n"); // excluded: .gitignore dir
    try tree.write("skip.log", "needle log\n"); // excluded: .gitignore glob
    try tree.write("nested/drop/y.txt", "needle dropped\n"); // excluded: nested .gitignore
    try tree.write("nested/keep/z.txt", "needle kept\n"); // kept
    try tree.write("bin.dat", "needle\x00\x00binary\n"); // excluded: binary
    try tree.write("empty.txt", ""); // excluded: empty
    try tree.write(".gitignore", "ignored/\n*.log\n");
    try tree.write("nested/.gitignore", "drop/\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    var q = std.heap.ArenaAllocator.init(gpa);
    defer q.deinit();
    const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
    try expectFileSet(&tree, files, &.{ "visible.txt", "sub/ok.txt", "nested/keep/z.txt" });
}

test "resident: queryLines renders the cold default frame (path:text, -n, RYW)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "lines", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "alpha\nneedle one\n");
    try tree.write("b.txt", "needle two\nno\nneedle three"); // no trailing \n
    try tree.write("c.txt", "nothing here\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // Default piped frame: `path:text`, files in cold's pathLess order, final
    // unterminated line still gets its newline (the cold Emitter's own rule).
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const ans = (try session.queryLines(q.allocator(), .{ .pattern = "needle", .mode = .lines, .fixed = true })).got;
        try std.testing.expect(ans.matched);
        const want = try std.fmt.allocPrint(q.allocator(), "{s}/a.txt:needle one\n{s}/b.txt:needle two\n{s}/b.txt:needle three\n", .{ tree.root, tree.root, tree.root });
        try std.testing.expectEqualStrings(want, ans.out);
    }

    // `-n` prefixes each row with its 1-based line number.
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const ans = (try session.queryLines(q.allocator(), .{ .pattern = "needle", .mode = .lines, .fixed = true, .line_num = true })).got;
        const want = try std.fmt.allocPrint(q.allocator(), "{s}/a.txt:2:needle one\n{s}/b.txt:1:needle two\n{s}/b.txt:3:needle three\n", .{ tree.root, tree.root, tree.root });
        try std.testing.expectEqualStrings(want, ans.out);
    }

    // Read-your-writes holds for the lines face too.
    try advanceClock(io);
    try tree.write("c.txt", "needle late\n");
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const ans = (try session.queryLines(q.allocator(), .{ .pattern = "needle late", .mode = .lines, .fixed = true })).got;
        try std.testing.expect(ans.matched);
        const want = try std.fmt.allocPrint(q.allocator(), "{s}/c.txt:needle late\n", .{tree.root});
        try std.testing.expectEqualStrings(want, ans.out);
    }

    // No match: empty output, matched=false (cold's exit-1 shape).
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const ans = (try session.queryLines(q.allocator(), .{ .pattern = "absent-needle", .mode = .lines, .fixed = true })).got;
        try std.testing.expect(!ans.matched);
        try std.testing.expectEqualStrings("", ans.out);
    }

    // The fold face refuses the lines shape (it would emit the wrong frame).
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        try std.testing.expectEqual(
            fault.Decline.freshness_unprovable,
            (try session.query(q.allocator(), .{ .pattern = "needle", .mode = .lines, .fixed = true })).declined,
        );
    }
}

test "resident: binary docs follow cold's per-mode NUL policy (faithful mirror)" {
    // Cold does NOT skip a walked binary file wholesale: `-l` observes complete
    // 64 KiB buffers before the one holding the first NUL; `-c` suppresses the
    // file entirely; the default line search emits pre-cut matches + WARNING.
    // The old 8 KiB-window corpus skip diverged on all three — this pins the fix.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "binary", @intFromPtr(&threaded));
    defer tree.deinit();
    // NUL in the first buffer: cold `-l` sees zero visible lines → excluded.
    try tree.write("early.dat", "needle\x00tail");
    // Match in a complete buffer BEFORE the NUL one (nul past 64 KiB): cold
    // `-l` REPORTS this file; `-c` still suppresses it.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendSlice(gpa, "needle early\n");
    try big.appendNTimes(gpa, 'x', 65536);
    try big.append(gpa, 0);
    try tree.write("late.dat", big.items);
    try tree.write("plain.txt", "needle plain\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
        try expectFileSet(&tree, files, &.{ "late.dat", "plain.txt" });
    }
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const counted = (try session.query(q.allocator(), .{ .pattern = "needle", .mode = .count, .fixed = true })).got;
        try std.testing.expectEqual(@as(u64, 1), counted.count); // plain.txt only
    }
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const ans = (try session.queryLines(q.allocator(), .{ .pattern = "needle", .mode = .lines, .fixed = true })).got;
        try std.testing.expect(ans.matched);
        const late = try tree.abs("late.dat");
        const plain = try tree.abs("plain.txt");
        const head = try std.fmt.allocPrint(q.allocator(), "{s}:needle early\n", .{late});
        try std.testing.expect(std.mem.startsWith(u8, ans.out, head));
        try std.testing.expect(std.mem.indexOf(u8, ans.out, "WARNING: stopped searching binary file") != null);
        const tail = try std.fmt.allocPrint(q.allocator(), "{s}:needle plain\n", .{plain});
        try std.testing.expect(std.mem.endsWith(u8, ans.out, tail));
        // early.dat contributes nothing in any mode.
        try std.testing.expect(std.mem.indexOf(u8, ans.out, "early.dat") == null);
    }
}

test "resident: UTF-16 and >4MiB docs are searched warm (BOM decode, no cap)" {
    // Two former warm gaps the faithful mirror closes: a UTF-16 file (its
    // encoding NULs used to mis-sniff it binary) and a text file past the old
    // 4 MiB indexing cap (used to be silently absent from every warm answer).
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "ingest", @intFromPtr(&threaded));
    defer tree.deinit();
    // "needle\n" as UTF-16 LE with BOM.
    try tree.write("u16.txt", "\xFF\xFEn\x00e\x00e\x00d\x00l\x00e\x00\n\x00");
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendNTimes(gpa, 'x', (4 << 20) + 64); // past the old per_file_cap
    big.items[big.items.len - 8] = '\n';
    try big.appendSlice(gpa, "needle at the end\n");
    try tree.write("big.txt", big.items);

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    var q = std.heap.ArenaAllocator.init(gpa);
    defer q.deinit();
    const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
    try expectFileSet(&tree, files, &.{ "u16.txt", "big.txt" });
}

test "resident: regex and caseless paths agree with the literal path" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "regex", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("lower.txt", "the needle is here\n");
    try tree.write("upper.txt", "the Needle is HERE\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // Case-sensitive regex `n.edle` matches only the lowercase file.
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "n.edle", .mode = .files });
        try expectFileSet(&tree, files, &.{"lower.txt"});
    }

    // Caseless literal `needle` matches both.
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true, .ignore_case = true });
        try expectFileSet(&tree, files, &.{ "lower.txt", "upper.txt" });
    }
}

/// A `search`-face sink that only counts records and verifies they arrive in
/// strictly ascending (path, line_number) order — the exact property the
/// sharded record stream must preserve across its per-shard buffer feed. The
/// key is duped (a record's `path` is valid only during the `emit` call).
const OrderSink = struct {
    a: std.mem.Allocator,
    n: usize = 0,
    last: []const u8 = "",
    ordered: bool = true,

    pub fn emit(self: *OrderSink, rec: resident.MatchRecord) bool {
        const key = std.fmt.allocPrint(self.a, "{s}\x00{d:0>12}", .{ rec.path, rec.line_number }) catch return true;
        if (self.n > 0 and !std.mem.lessThan(u8, self.last, key)) self.ordered = false;
        self.last = key;
        self.n += 1;
        return false;
    }
};

/// A `search` sink that carries a cooperative `runBudget` (a shared cancel
/// token) and counts its emits. It distinguishes the DOC GATHER honoring the
/// budget (emit never reached) from the old record-boundary-only stop (emit
/// reached once): a sink that lacks `runBudget` leaves the gather unbounded, so
/// exposing it is exactly what the hosted collector does.
const BudgetSink = struct {
    cancel: *const resident.CancelToken,
    emits: usize = 0,

    pub fn emit(self: *BudgetSink, rec: resident.MatchRecord) bool {
        _ = rec;
        self.emits += 1;
        return true; // halt at once — only whether emit was reached matters
    }

    pub fn runBudget(self: *const BudgetSink) resident.RunBudget {
        return .{ .cancel = self.cancel };
    }
};

test "resident: the sharded positive faces answer ground truth over a >256KiB corpus" {
    // Cross `render.par_min_bytes` (256 KiB) so the `-l`/`-c` fold, the lines
    // emit, and the FFI record stream all take the PARALLEL path (on any host
    // with ≥2 cores; a 1-core host falls through to the identical serial core).
    // Expected values are computed from the fixture generator, never a self-run:
    // 300 files × 10 matching lines each = a set of 300, a count of 3000, a
    // stream of 3000 ascending records — the sharded merge must reproduce them.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var tree = try Tree.init(fa, io, "shard", @intFromPtr(&threaded));
    defer tree.deinit();

    const n_files = 300;
    const lines_per = 40; // l%4==0 ⇒ "needle" ⇒ 10 matching lines/file
    var f: usize = 0;
    while (f < n_files) : (f += 1) {
        var body: std.ArrayList(u8) = .empty;
        var l: usize = 0;
        while (l < lines_per) : (l += 1) {
            if (l % 4 == 0)
                try body.print(fa, "needle marker line number {d} of file\n", .{l})
            else
                try body.print(fa, "plain filler content on line {d} here\n", .{l});
        }
        try tree.write(try std.fmt.allocPrint(fa, "d{d:0>4}.txt", .{f}), body.items);
    }
    // A rare token in just one file ⇒ small candidate byte set ⇒ the SAME faces
    // fall through to the serial core, proving the floor gate both ways. This
    // also drops d0000 to a single matching line (folded into the totals below).
    try tree.write("d0000.txt", "zebra rare\nneedle marker line number 0 of file\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // ── -l fold (sharded): all 300 files, in ascending path order ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
        try std.testing.expectEqual(@as(usize, n_files), files.len);
        for (files[1..], files[0 .. files.len - 1]) |cur, prev|
            try std.testing.expect(std.mem.lessThan(u8, prev, cur)); // merge stays path-sorted
    }
    // ── -c fold (sharded): exact sum across shards ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        // d0000 rewritten to 1 matching line; the other 299 keep 10 ⇒ 2991.
        const counted = (try session.query(q.allocator(), .{ .pattern = "needle", .mode = .count, .fixed = true })).got;
        try std.testing.expectEqual(@as(u64, 299 * 10 + 1), counted.count);
        // Per-file cap composes with the shard merge: min(hits,2) summed.
        const capped = (try session.query(q.allocator(), .{ .pattern = "needle", .mode = .count, .fixed = true, .max_count = 2 })).got;
        try std.testing.expectEqual(@as(u64, 299 * 2 + 1), capped.count);
    }
    // ── FFI record stream (sharded): 2991 records, strictly ascending order ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        var sink = OrderSink{ .a = q.allocator() };
        const any = (try session.search(q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true }, &sink)).got;
        try std.testing.expect(any);
        try std.testing.expect(sink.ordered);
        try std.testing.expectEqual(@as(usize, 299 * 10 + 1), sink.n);
    }
    // ── lines emit (sharded): one row per matching line, still path-ordered ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const ans = (try session.queryLines(q.allocator(), .{ .pattern = "needle", .mode = .lines, .fixed = true })).got;
        try std.testing.expect(ans.matched);
        try std.testing.expectEqual(@as(usize, 299 * 10 + 1), std.mem.count(u8, ans.out, "\n"));
    }
    // ── rare token ⇒ serial fall-through, same ground truth ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "zebra", .mode = .files, .fixed = true });
        try expectFileSet(&tree, files, &.{"d0000.txt"});
    }
}

test "resident: a hosted cancel bounds the doc gather before the first emit" {
    // The gather-phase cooperative halt: a `search` sink that exposes a tripped
    // `runBudget` cancel stops the doc gather CLEANLY — no docs gathered, so no
    // record reaches `emit` — rather than scanning the whole matching set and
    // stopping only at the first record boundary. Distinct from the daemon's
    // `query_budget_ns` ceiling, it raises no `Stale`. The un-tripped baseline
    // (emit reached once) vs the tripped run (emit never reached) is the exact
    // observable difference the gather wiring makes.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "cancel", 0xB0);
    defer tree.deinit();
    try tree.write("a.txt", "needle one\nneedle two\n");
    try tree.write("b.txt", "needle three\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    var q = std.heap.ArenaAllocator.init(gpa);
    defer q.deinit();
    const req = request.Request{ .pattern = "needle", .mode = .files, .fixed = true };

    // Baseline: an un-tripped budget ⇒ the stream reaches emit (halts at #1).
    var token = resident.CancelToken{};
    var live = BudgetSink{ .cancel = &token };
    const any_live = (try session.search(q.allocator(), req, &live)).got;
    try std.testing.expectEqual(@as(usize, 1), live.emits);
    try std.testing.expect(any_live);

    // Tripped cancel ⇒ the gather stops before appending any doc, so emit is
    // never reached — a clean empty result, no error, no crash.
    token.cancel();
    var cancelled = BudgetSink{ .cancel = &token };
    const any_cancelled = (try session.search(q.allocator(), req, &cancelled)).got;
    try std.testing.expectEqual(@as(usize, 0), cancelled.emits);
    try std.testing.expect(!any_cancelled);
}

/// A `search`-face sink that renders each record as `path:lineno:text [s,e)…`
/// so a test pins the FULL record stream (paths, line numbers, span offsets).
const RecSink = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    pub fn emit(self: *RecSink, rec: resident.MatchRecord) bool {
        self.out.print(self.a, "{s}:{d}:{s}", .{ rec.path, rec.line_number, rec.text }) catch return true;
        for (rec.spans) |sp| self.out.print(self.a, " [{d},{d})", .{ sp.start, sp.end }) catch return true;
        self.out.append(self.a, '\n') catch return true;
        return false;
    }
};

test "resident: -w applies cold's exact word rule on every answer face" {
    // Expected values are derived from ripgrep's post-match word rule as cold
    // implements it (`output.zig::wordOk`/`nextSpan`), verified against a live
    // cold `gist -w` run over these fixtures — never from the warm engine:
    //   - a word-REJECTED occurrence keeps scanning its line (`rerun run`);
    //   - a doc can boolean-match with ZERO word-valid lines (b.txt) and must
    //     vanish from every face;
    //   - Unicode neighbors kill a span (`érun`, `中run`);
    //   - a punctuation-only match is still a word match (`a . b`);
    //   - `-F` adjacent repeats scan leftmost non-overlapping (`aa` in `aaa`);
    //   - a zero-width match counts where non-word bytes bound it, and only
    //     there — so a letters-only line stays out (`x*` on `yy`).
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "word", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "run runner\nrerun run\n"); // line 1 valid at [0,3); line 2 valid only at [6,9)
    try tree.write("b.txt", "runner rerun\n"); // boolean-matches `run`, zero word-valid spans
    try tree.write("c.txt", "\xc3\xa9run \xe4\xb8\xadrun\n"); // érun · 中run — both rejected
    try tree.write("d.txt", "RUN loud\n"); // case-composition fixture
    try tree.write("e.txt", "a . b\n.dot\n"); // punctuation-only match; `.dot` rejected
    try tree.write("f.txt", " aa aaa\naaaa\n"); // -F adjacent repeats; line 2 has no valid occurrence
    try tree.write("g.txt", "x x\nyy\n"); // zero-width-adjacent regex fixture

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // ── files face (-l) ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const w = try queryFiles(&session, q.allocator(), .{ .pattern = "run", .mode = .files, .fixed = true, .word = true });
        try expectFileSet(&tree, w, &.{"a.txt"});
        // Without -w the same pattern reaches the substring/Unicode-neighbor docs.
        const plain = try queryFiles(&session, q.allocator(), .{ .pattern = "run", .mode = .files, .fixed = true });
        try expectFileSet(&tree, plain, &.{ "a.txt", "b.txt", "c.txt" });
    }
    // ── count face (-c): word-valid LINES, zero-width never counts ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const counted = (try session.query(q.allocator(), .{ .pattern = "run", .mode = .count, .fixed = true, .word = true })).got;
        try std.testing.expectEqual(@as(u64, 2), counted.count); // a.txt both lines
        const punct = (try session.query(q.allocator(), .{ .pattern = "\\.", .mode = .count, .word = true })).got;
        try std.testing.expectEqual(@as(u64, 1), punct.count); // `a . b` yes, `.dot` no
        const rep = (try session.query(q.allocator(), .{ .pattern = "aa", .mode = .count, .fixed = true, .word = true })).got;
        try std.testing.expectEqual(@as(u64, 1), rep.count); // ` aa aaa` yes, `aaaa` no
        const star = (try session.query(q.allocator(), .{ .pattern = "x*", .mode = .count, .word = true })).got;
        // Only g.txt holds an `x`, so the other three lines are carried by a
        // word-valid EMPTY match — `rg -n -w 'x*'` over this fixture tree:
        //   e.txt:1 `a . b` · e.txt:2 `.dot` · f.txt:1 ` aa aaa` · g.txt:1 `x x`
        // Every other line's gaps all touch a word byte (`yy`, `run runner`, …).
        try std.testing.expectEqual(@as(u64, 4), star.count);
    }
    // ── case composition: -w with -i / smart-case; word runs on original bytes ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const folded = try queryFiles(&session, q.allocator(), .{ .pattern = "run", .mode = .files, .fixed = true, .ignore_case = true, .word = true });
        try expectFileSet(&tree, folded, &.{ "a.txt", "d.txt" }); // RUN now word-valid; érun/中run still rejected
        const smart = try queryFiles(&session, q.allocator(), .{ .pattern = "run", .mode = .files, .fixed = true, .smart_case = true, .word = true });
        try expectFileSet(&tree, smart, &.{ "a.txt", "d.txt" }); // lowercase -S folds like -i
        const smart_upper = try queryFiles(&session, q.allocator(), .{ .pattern = "RUN", .mode = .files, .fixed = true, .smart_case = true, .word = true });
        try expectFileSet(&tree, smart_upper, &.{"d.txt"}); // uppercase -S stays sensitive
    }
    // ── lines face: rendered through the cold Emitter with o.word set ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const ans = (try session.queryLines(q.allocator(), .{ .pattern = "run", .mode = .lines, .fixed = true, .word = true })).got;
        try std.testing.expect(ans.matched);
        const want = try std.fmt.allocPrint(q.allocator(), "{s}/a.txt:run runner\n{s}/a.txt:rerun run\n", .{ tree.root, tree.root });
        try std.testing.expectEqualStrings(want, ans.out);
    }
    // ── search face (FFI record stream): word-filtered spans, byte offsets ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        var sink = RecSink{ .a = q.allocator() };
        const any = (try session.search(q.allocator(), .{ .pattern = "run", .mode = .files, .fixed = true, .word = true }, &sink)).got;
        try std.testing.expect(any);
        // b.txt/c.txt boolean-match but emit NO records and never flip `any`;
        // a.txt line 2's rejected `rerun` span is absent, only ` run` remains.
        const want = try std.fmt.allocPrint(q.allocator(), "{s}/a.txt:1:run runner [0,3)\n{s}/a.txt:2:rerun run [6,9)\n", .{ tree.root, tree.root });
        try std.testing.expectEqualStrings(want, sink.out.items);
    }
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        var sink = RecSink{ .a = q.allocator() };
        const any = (try session.search(q.allocator(), .{ .pattern = "aa", .mode = .files, .fixed = true, .word = true }, &sink)).got;
        try std.testing.expect(any);
        // ` aa aaa`: [1,3) valid; the `aaa` occurrence [4,6) is word-rejected and
        // the non-overlapping scan finds nothing after it. `aaaa` emits nothing.
        const want = try std.fmt.allocPrint(q.allocator(), "{s}/f.txt:1: aa aaa [1,3)\n", .{tree.root});
        try std.testing.expectEqualStrings(want, sink.out.items);
    }
    // A pattern whose EVERY occurrence is word-rejected (`unner` always has a
    // word char before it): the stream emits nothing and reports no match.
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        var sink = RecSink{ .a = q.allocator() };
        const any = (try session.search(q.allocator(), .{ .pattern = "unner", .mode = .files, .fixed = true, .word = true }, &sink)).got;
        try std.testing.expect(!any);
        try std.testing.expectEqualStrings("", sink.out.items);
    }
}

test "resident: -w composes with the binary pre-NUL slice per mode" {
    // The word check runs WITHIN the mode's gated bytes: `-l` observes complete
    // buffers before the NUL one, `-c` suppresses an implicit binary entirely,
    // the lines face emits pre-cut matches + WARNING — all with word-filtered
    // spans, exactly cold's composition of the two rules.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "wordbin", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("early.dat", "run\x00tail"); // NUL in the first buffer ⇒ invisible to -l
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendSlice(gpa, "run early\nrunner noise\n");
    try big.appendNTimes(gpa, 'z', 65536);
    try big.append(gpa, 0);
    try tree.write("late.dat", big.items); // word-valid match in a complete pre-NUL buffer
    try tree.write("plain.txt", "a run here\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "run", .mode = .files, .fixed = true, .word = true });
        try expectFileSet(&tree, files, &.{ "late.dat", "plain.txt" });
    }
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const counted = (try session.query(q.allocator(), .{ .pattern = "run", .mode = .count, .fixed = true, .word = true })).got;
        try std.testing.expectEqual(@as(u64, 1), counted.count); // plain.txt only (binaries suppressed)
    }
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const ans = (try session.queryLines(q.allocator(), .{ .pattern = "run", .mode = .lines, .fixed = true, .word = true })).got;
        try std.testing.expect(ans.matched);
        const late = try tree.abs("late.dat");
        const head = try std.fmt.allocPrint(q.allocator(), "{s}:run early\n", .{late});
        try std.testing.expect(std.mem.startsWith(u8, ans.out, head));
        try std.testing.expect(std.mem.indexOf(u8, ans.out, "runner noise") == null); // word-rejected line never prints
        try std.testing.expect(std.mem.indexOf(u8, ans.out, "WARNING: stopped searching binary file") != null);
    }
}

test "resident: -q is an early-halting existence query (rg's quiet contract)" {
    // rg `-q`: true the instant ANY line matches, false otherwise — no output.
    // Expected values are rg's quiet semantics: existence composes with -i/-w
    // exactly like the other faces, and `-w` NARROWS (a plain substring hit
    // that is not word-valid must go false). `-m0` matches nothing everywhere.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "quiet", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "alpha needle\n");
    try tree.write("b.txt", "beta only\n");
    try tree.write("w.txt", "rerunner\n"); // holds `run` as a substring, never word-valid

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // A present pattern exists; an absent one does not.
    try std.testing.expect((try session.queryExists(.{ .pattern = "needle", .mode = .lines, .fixed = true })).got);
    try std.testing.expect(!(try session.queryExists(.{ .pattern = "absent-token", .mode = .lines, .fixed = true })).got);
    // `-q -i`: the fold makes an uppercase pattern find the lowercase file.
    try std.testing.expect((try session.queryExists(.{ .pattern = "NEEDLE", .mode = .lines, .fixed = true, .ignore_case = true })).got);
    // `-q -w`: `run` is only a substring of `rerunner` (no word boundary), so
    // the word gate flips a plain-true existence to false — the halt honors -w.
    try std.testing.expect((try session.queryExists(.{ .pattern = "run", .mode = .lines, .fixed = true })).got);
    try std.testing.expect(!(try session.queryExists(.{ .pattern = "run", .mode = .lines, .fixed = true, .word = true })).got);
    // `-q -m0`: rg matches nothing regardless of the pattern's presence.
    try std.testing.expect(!(try session.queryExists(.{ .pattern = "needle", .mode = .lines, .fixed = true, .max_count = 0 })).got);
}

test "resident: -m N caps matching lines per file (count total, lines emit; -m0 nothing)" {
    // rg `-m N`: stop after N matching lines PER FILE. Expected values are that
    // per-file cap applied to rg's line model, verified by hand from the
    // fixtures (never a self-run): the count face sums min(hits, N) per file;
    // the lines face emits at most N rows per file (cold's Emitter cap); `-m0`
    // matches nothing in every mode (cold exits 1 before searching).
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "maxcount", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "needle a1\nneedle a2\nneedle a3\n"); // 3 matching lines
    try tree.write("b.txt", "needle b1\n"); // 1 matching line
    try tree.write("c.txt", "no match here\n"); // 0

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // ── count face: corpus total of the per-file cap ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        // Uncapped: 3 + 1 = 4.
        try std.testing.expectEqual(@as(u64, 4), (try session.query(q.allocator(), .{ .pattern = "needle", .mode = .count, .fixed = true })).got.count);
        // -m2: min(3,2) + min(1,2) = 3.
        try std.testing.expectEqual(@as(u64, 3), (try session.query(q.allocator(), .{ .pattern = "needle", .mode = .count, .fixed = true, .max_count = 2 })).got.count);
        // -m1: 1 + 1 = 2 (each file capped to its first hit).
        try std.testing.expectEqual(@as(u64, 2), (try session.query(q.allocator(), .{ .pattern = "needle", .mode = .count, .fixed = true, .max_count = 1 })).got.count);
        // -m0: match nothing — total 0, no files.
        const zero = (try session.query(q.allocator(), .{ .pattern = "needle", .mode = .count, .fixed = true, .max_count = 0 })).got;
        try std.testing.expectEqual(@as(u64, 0), zero.count);
    }
    // ── files face: N≥1 leaves the set unchanged; -m0 empties it ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const capped = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true, .max_count = 2 });
        try expectFileSet(&tree, capped, &.{ "a.txt", "b.txt" });
        const zero = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true, .max_count = 0 });
        try std.testing.expectEqual(@as(usize, 0), zero.len);
    }
    // ── lines face: at most N rows per file, per-file reset ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const ans = (try session.queryLines(q.allocator(), .{ .pattern = "needle", .mode = .lines, .fixed = true, .max_count = 2 })).got;
        try std.testing.expect(ans.matched);
        // a.txt capped to its first 2 lines; b.txt's 1 line unaffected.
        const want = try std.fmt.allocPrint(q.allocator(), "{s}/a.txt:needle a1\n{s}/a.txt:needle a2\n{s}/b.txt:needle b1\n", .{ tree.root, tree.root, tree.root });
        try std.testing.expectEqualStrings(want, ans.out);
        // -m1: exactly one row per matching file.
        const one = (try session.queryLines(q.allocator(), .{ .pattern = "needle", .mode = .lines, .fixed = true, .max_count = 1 })).got;
        const want1 = try std.fmt.allocPrint(q.allocator(), "{s}/a.txt:needle a1\n{s}/b.txt:needle b1\n", .{ tree.root, tree.root });
        try std.testing.expectEqualStrings(want1, one.out);
        // -m0: nothing, no match.
        const zero = (try session.queryLines(q.allocator(), .{ .pattern = "needle", .mode = .lines, .fixed = true, .max_count = 0 })).got;
        try std.testing.expect(!zero.matched);
        try std.testing.expectEqualStrings("", zero.out);
    }
}

test "resident: smart-case resolves like cold's fold on every answer face" {
    // A lowercase pattern under -S answers exactly like -i; any uppercase in
    // the pattern keeps it case-sensitive. The resolution happens once in
    // `Request.effectiveIgnoreCase`, so the fold faces (files/count) and the
    // lines renderer must all agree with it.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "smartcase", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("lower.txt", "the needle is here\n");
    try tree.write("upper.txt", "the Needle is HERE\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // -S + all-lowercase pattern ⇒ folds caseless: both files, like -i.
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true, .smart_case = true });
        try expectFileSet(&tree, files, &.{ "lower.txt", "upper.txt" });
    }
    // -S + uppercase pattern ⇒ stays case-sensitive: only the exact match.
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "Needle", .mode = .files, .fixed = true, .smart_case = true });
        try expectFileSet(&tree, files, &.{"upper.txt"});
    }
    // The count face resolves through the same seam.
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const counted = (try session.query(q.allocator(), .{ .pattern = "needle", .mode = .count, .fixed = true, .smart_case = true })).got;
        try std.testing.expectEqual(@as(u64, 2), counted.count);
    }
    // The lines renderer folds identically (both rows, cold's frame).
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const ans = (try session.queryLines(q.allocator(), .{ .pattern = "needle", .mode = .lines, .fixed = true, .smart_case = true })).got;
        try std.testing.expect(ans.matched);
        const want = try std.fmt.allocPrint(q.allocator(), "{s}/lower.txt:the needle is here\n{s}/upper.txt:the Needle is HERE\n", .{ tree.root, tree.root });
        try std.testing.expectEqualStrings(want, ans.out);
    }
    // Regex smart-case: the resolved caseless drives the compiled query (and
    // its trigram-prefilter decline), not just the literal path.
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "n.edle", .mode = .files, .smart_case = true });
        try expectFileSet(&tree, files, &.{ "lower.txt", "upper.txt" });
    }
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "N.edle", .mode = .files, .smart_case = true });
        try expectFileSet(&tree, files, &.{"upper.txt"});
    }
}

test "resident: -P serves the PCRE2 engine warm on every answer face" {
    // The warm-PCRE contract end to end: a `Request{ .pcre = true }` flows
    // through the SAME session path a `-P` daemon query rides — classify →
    // `compileFor` (Spec.pcre) → the PCRE2 arm of the `Matcher` seam → match
    // over the live in-memory corpus. Every pattern here uses a construct the
    // linear engine DECLINES (lookahead, backreference), so a passing warm
    // answer proves the PCRE2 backend did the work — expectations are
    // hand-derived from PCRE semantics, never a self-run of the engine.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "pcre", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("look.txt", "foobar here\n"); // foo(?=bar) ✓
    try tree.write("nolook.txt", "foobaz here\n"); // foo(?=bar) ✗ (both hold `foo`)
    try tree.write("dup.txt", "hello hello world\nsingle line\n"); // (\w+) \1 → 1 line
    try tree.write("nodup.txt", "alpha beta gamma\n"); // (\w+) \1 → 0

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // ── files face: lookahead admits only the file whose assertion holds ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{ .pattern = "foo(?=bar)", .mode = .files, .pcre = true });
        try expectFileSet(&tree, files, &.{"look.txt"});
    }
    // ── count face: a backreference counts only the doubled-word line ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const counted = (try session.query(q.allocator(), .{ .pattern = "(\\w+) \\1", .mode = .count, .pcre = true })).got;
        try std.testing.expectEqual(@as(u64, 1), counted.count); // dup.txt line 1 only
    }
    // ── lines face: the PCRE2 body renders through the cold default frame ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const ans = (try session.queryLines(q.allocator(), .{ .pattern = "foo(?=bar)", .mode = .lines, .pcre = true })).got;
        try std.testing.expect(ans.matched);
        const want = try std.fmt.allocPrint(q.allocator(), "{s}/look.txt:foobar here\n", .{tree.root});
        try std.testing.expectEqualStrings(want, ans.out);
    }
    // ── -w composes with the PCRE2 engine: the lookahead span is word-gated ──
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        try tree.write("w1.txt", "bar! ok\n"); // bar(?=!) span [0,3) — word-valid
        try tree.write("w2.txt", "rebar! no\n"); // `bar` preceded by `e` — word-rejected
        try advanceClock(io);
        // Without -w both files match the lookahead.
        const plain = try queryFiles(&session, q.allocator(), .{ .pattern = "bar(?=!)", .mode = .files, .pcre = true });
        try expectFileSet(&tree, plain, &.{ "w1.txt", "w2.txt" });
        // With -w only the word-bounded span survives.
        const worded = try queryFiles(&session, q.allocator(), .{ .pattern = "bar(?=!)", .mode = .files, .pcre = true, .word = true });
        try expectFileSet(&tree, worded, &.{"w1.txt"});
    }
}

// ── concurrency (ADR-352 rung 2.5 Workstream A2): the reader/writer session ──
//
// The RwLock discipline promises two things the single-thread daemon never
// had to prove: (1) many answer faces may read the immutable mirror+overlay AT
// ONCE without a torn or wrong answer, and (2) a reconcile writer racing those
// readers (the drop-to-write / double-checked-upgrade / drop-to-read dance in
// `beginRead`) never corrupts an in-flight answer. Both assert PARITY with the
// serial answer — the exact set/count a single-threaded replay produces — so a
// data race that flipped a bit would surface as a wrong count, not just a
// sanitizer note.

test "resident: concurrent readers on the clean fast path all answer with serial parity" {
    if (builtin.single_threaded) return;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "concurrent_read", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "alpha\nneedle one\n"); // 1 matching line
    try tree.write("b.txt", "needle two\nneedle three\n"); // 2
    try tree.write("c.txt", "no match here\n"); // 0
    try tree.write("d.txt", "needle four\n"); // 1

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // Arm the watcher and run one warm-up query so the seqlock publishes CLEAN
    // over the quiescent tree: every subsequent query then takes `beginRead`'s
    // shared-lock fast path (no reconcile, no write lock), so the N readers
    // genuinely OVERLAP on the read lock — the concurrency this workstream buys.
    session.armWatcher();
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        _ = try session.query(q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true });
    }
    try std.testing.expect(session.seqlock.skip()); // fast path is open

    const Reader = struct {
        session: *ResidentSession,
        gpa: std.mem.Allocator,
        iters: usize,
        failed: bool = false,

        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < self.iters) : (i += 1) {
                var q = std.heap.ArenaAllocator.init(self.gpa);
                defer q.deinit();
                const a = q.allocator();
                // files: exactly {a,b,d}; count: 1+2+0+1 = 4 matching lines;
                // lines: renders and matches. Any torn read breaks one of these.
                const fr = (self.session.query(a, .{ .pattern = "needle", .mode = .files, .fixed = true }) catch {
                    self.failed = true;
                    return;
                }).got;
                if (fr.files.len != 3) {
                    self.failed = true;
                    return;
                }
                const cr = (self.session.query(a, .{ .pattern = "needle", .mode = .count, .fixed = true }) catch {
                    self.failed = true;
                    return;
                }).got;
                if (cr.count != 4) {
                    self.failed = true;
                    return;
                }
                const ln = (self.session.queryLines(a, .{ .pattern = "needle", .mode = .lines, .fixed = true }) catch {
                    self.failed = true;
                    return;
                }).got;
                if (!ln.matched) {
                    self.failed = true;
                    return;
                }
            }
        }
    };

    const n = 8;
    var readers: [n]Reader = undefined;
    for (&readers) |*r| r.* = .{ .session = &session, .gpa = gpa, .iters = 300 };
    var threads: [n]std.Thread = undefined;
    for (&threads, &readers) |*t, *r| t.* = try std.Thread.spawn(.{}, Reader.run, .{r});
    for (threads) |t| t.join();
    for (readers) |r| try std.testing.expect(!r.failed);
}

test "resident: a churning writer never corrupts a concurrent reader's answer" {
    if (builtin.single_threaded) return;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "concurrent_churn", @intFromPtr(&threaded));
    defer tree.deinit();
    // Stable set: three files that ALWAYS match `NEEDLE` and are never touched.
    try tree.write("stable/s0.txt", "NEEDLE\n");
    try tree.write("stable/s1.txt", "NEEDLE\n");
    try tree.write("stable/s2.txt", "NEEDLE\n");
    // Churn set: pre-created so the writer only REWRITES them (no create/delete
    // that could error the walk). Their filler content never contains NEEDLE,
    // so the `NEEDLE` files-mode answer is invariant under any amount of churn.
    try tree.write("churn/c0.txt", "filler\n");
    try tree.write("churn/c1.txt", "filler\n");
    const churn = [_][]const u8{ try tree.abs("churn/c0.txt"), try tree.abs("churn/c1.txt") };

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();
    // No watcher: every query reconciles (full walk), so readers exercise the
    // drop-to-write / reconcile / drop-to-read path repeatedly while the writer
    // mutates the tree underneath them — the write path under concurrency.

    var stop = std.atomic.Value(bool).init(false);

    const Writer = struct {
        io: std.Io,
        paths: []const []const u8,
        stop: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            var buf: [64]u8 = undefined;
            var n: usize = 0;
            while (!self.stop.load(.monotonic)) : (n +%= 1) {
                const body = std.fmt.bufPrint(&buf, "filler {d}\n", .{n}) catch continue;
                Dir.cwd().writeFile(self.io, .{ .sub_path = self.paths[n % self.paths.len], .data = body }) catch {};
            }
        }
    };

    const Reader = struct {
        session: *ResidentSession,
        gpa: std.mem.Allocator,
        iters: usize,
        failed: bool = false,

        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < self.iters) : (i += 1) {
                var q = std.heap.ArenaAllocator.init(self.gpa);
                defer q.deinit();
                const answer = self.session.query(q.allocator(), .{ .pattern = "NEEDLE", .mode = .files, .fixed = true }) catch {
                    self.failed = true;
                    return;
                };
                // Heavy churn can momentarily race the walk into a typed
                // declinature — the client would answer cold. Sound, not a
                // corruption; only a WRONG set fails the test.
                const fr = switch (answer) {
                    .declined => continue,
                    .got => |got| got,
                };
                if (fr.files.len != 3) {
                    self.failed = true;
                    return;
                }
            }
        }
    };

    var writer = Writer{ .io = io, .paths = &churn, .stop = &stop };
    const wt = try std.Thread.spawn(.{}, Writer.run, .{&writer});

    const n = 6;
    var readers: [n]Reader = undefined;
    for (&readers) |*r| r.* = .{ .session = &session, .gpa = gpa, .iters = 250 };
    var threads: [n]std.Thread = undefined;
    for (&threads, &readers) |*t, *r| t.* = try std.Thread.spawn(.{}, Reader.run, .{r});
    for (threads) |t| t.join();
    stop.store(true, .monotonic);
    wt.join();
    for (readers) |r| try std.testing.expect(!r.failed);
}

// ── the Extra gap: `-t`/`-g` un-hide/un-ignore parity (serial.zig `Extra`) ──
//
// The default walk drops hidden dotfiles and gitignored leaves, so the warm
// mirror cannot hold them — yet a `-t`/`-g` query un-hides/un-ignores exactly
// those files in cold/rg. The session records the reachable file-level skips as
// `extras` and DECLINES (→ certified cold) any filtered query that would surface
// one, restoring the flagship "index changes speed, never results" claim. These
// prove the decline fires when (and only when) it must.

test "resident: a -t query declines when the type would un-hide a hidden file" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "extra_hidden", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("keep.zig", "const needle = 1;\n"); // walked normally
    try tree.write(".hidden.zig", "hidden needle\n"); // file-level dotfile skip → an Extra

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    var q = std.heap.ArenaAllocator.init(gpa);
    defer q.deinit();
    // `-t zig` (its glob is `*.zig`) un-hides `.hidden.zig`, which the mirror
    // lacks — the warm path must refuse and let the client answer cold.
    try std.testing.expectEqual(fault.Decline.freshness_unprovable, (try session.query(q.allocator(), .{
        .pattern = "needle",
        .mode = .files,
        .fixed = true,
        .filter = .{ .exts = &.{"*.zig"} },
    })).declined);
}

test "resident: a -t query stays warm when no extra matches the type (no over-decline)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "extra_precise", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("keep.zig", "const needle = 1;\n");
    try tree.write(".notes.md", "hidden needle\n"); // a hidden Extra, but NOT a .zig

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // `-t zig` cannot surface `.notes.md`, so the query stays warm and returns
    // the real set — the decline is exact, never a blanket cold-fallback for `-t`.
    var q = std.heap.ArenaAllocator.init(gpa);
    defer q.deinit();
    const files = try queryFiles(&session, q.allocator(), .{
        .pattern = "needle",
        .mode = .files,
        .fixed = true,
        .filter = .{ .exts = &.{"*.zig"} },
    });
    try expectFileSet(&tree, files, &.{"keep.zig"});
}

test "resident: -g un-ignores (declines) but -t never un-ignores (stays warm)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "extra_ignore", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("keep.zig", "const needle = 1;\n");
    try tree.write("secret.zig", "ignored needle\n");
    try tree.write(".ignore", "secret.zig\n"); // gitignore-dialect, honored without git

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // `-g '*.zig'` un-ignores `secret.zig` (mirror lacks it) → decline.
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        try std.testing.expectEqual(fault.Decline.freshness_unprovable, (try session.query(q.allocator(), .{
            .pattern = "needle",
            .mode = .files,
            .fixed = true,
            .filter = .{ .includes = &.{"*.zig"} },
        })).declined);
    }
    // `-t zig` never un-ignores, so the warm answer (only `keep.zig`) matches cold.
    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const files = try queryFiles(&session, q.allocator(), .{
            .pattern = "needle",
            .mode = .files,
            .fixed = true,
            .filter = .{ .exts = &.{"*.zig"} },
        });
        try expectFileSet(&tree, files, &.{"keep.zig"});
    }
}

// ── the pruned-root gap: an explicitly named PATH the default walk dropped ──
//
// Naming a root is naming intent: cold exempts an explicitly given PATH from the
// ignore and hidden rules (`walk.zig::gather` → `Ignore.scopeToRoot`), exactly as
// rg does, so `gist needle ign/` searches a gitignored subtree. The mirror's
// whole-tree walk pruned that directory, and — unlike a file-level skip — it
// leaves no `Extra` behind, because the walk stops descending AT the directory.
// `rootsCovered` is the guard: a root the mirror holds no file under declines.
// A hidden root never reaches here (the classifier refuses it syntactically —
// see request_test); a gitignored one is only knowable from the corpus.

test "resident: a query rooted in a gitignored subtree declines (no Extra can reveal it)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "pruned_root", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("keep.zig", "const needle = 1;\n"); // walked normally
    try tree.write("ign/sub/deep.zig", "ignored needle\n"); // whole dir pruned
    try tree.write(".ignore", "ign/\n"); // gitignore-dialect, honored without git

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // Both the pruned root itself and a path INTO it: cold walks each (rg does
    // too), the mirror holds neither, so the warm path must refuse.
    for ([_][]const u8{ "ign", "ign/sub" }) |rel| {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        try std.testing.expectEqual(fault.Decline.freshness_unprovable, (try session.query(q.allocator(), .{
            .pattern = "needle",
            .mode = .files,
            .fixed = true,
            .filter = .{ .roots = &.{try tree.abs(rel)} },
        })).declined);
    }
}

test "resident: a covered root stays warm (the pruned-root guard never over-declines)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "covered_root", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("src/keep.zig", "const needle = 1;\n");
    try tree.write("other/skip.zig", "needle elsewhere\n");
    try tree.write("ign/sub/deep.zig", "ignored needle\n");
    try tree.write(".ignore", "ign/\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();

    // An ordinary root the mirror covers answers warm with the real subset —
    // the decline is exact, never a blanket cold-fallback for every rooted query.
    var q = std.heap.ArenaAllocator.init(gpa);
    defer q.deinit();
    const files = try queryFiles(&session, q.allocator(), .{
        .pattern = "needle",
        .mode = .files,
        .fixed = true,
        .filter = .{ .roots = &.{try tree.abs("src")} },
    });
    try expectFileSet(&tree, files, &.{"src/keep.zig"});
}

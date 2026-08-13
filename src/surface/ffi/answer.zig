//! A materialized analytic answer, and your position in it.
//!
//! Substrate, because the *walking* is the same question no matter who
//! produced the rows: the exact face sweeping patterns, the kinship face
//! measuring kinship, and the composed face joining the two all hand a host the
//! same thing — a run of self-describing rows plus the answer-level facts no
//! row carries. Only the producing is per-package. So each library exports its
//! own `…_run`, and every one of them returns THIS, walked by the one set of
//! `irgx_rows_*` symbols.
//!
//! That split is what keeps a host from learning three cursor protocols to ask
//! three questions, and it costs nothing to arrange: an `Answer` holds an
//! arena, the rows built into it, and a read offset. There is no producer
//! interface to implement and no vtable to dispatch through — a dispatch arm
//! fills the arena and hands the answer over, finished.
//!
//! Ownership is the arena's: every row, every string a row points at, and every
//! nested row array live in it, so `close` is one free and a row borrowed past
//! it is a use-after-free the header names outright.

const std = @import("std");
const contract = @import("contract.zig");
const rows = @import("rows.zig");

const Status = contract.Status;
const Row = rows.Row;
const gpa = std.heap.c_allocator;

/// A finished run of rows plus the read position into it. Heap-stable on
/// purpose: the arena's allocator interface captures `&self.arena`, so the
/// struct must not move after the first row is built into it.
pub const Answer = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Row,
    at: usize = 0,
    stats: rows.Stats,

    /// An empty answer with a live arena — what a dispatch arm builds into.
    /// Separate from `finish` because the rows must be allocated in the arena
    /// this owns, which means the answer exists before its contents do.
    pub fn begin() error{OutOfMemory}!*Answer {
        const self = try gpa.create(Answer);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .items = &.{},
            .stats = .{ .struct_size = @sizeOf(rows.Stats) },
        };
        return self;
    }

    /// Hand over the built rows. Called once, by the producer, before the host
    /// ever sees the pointer.
    pub fn finish(self: *Answer, items: []const Row, st: rows.Stats) void {
        self.items = items;
        self.stats = st;
        self.stats.struct_size = @sizeOf(rows.Stats);
    }

    pub fn deinit(self: *Answer) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// Write the next row. `.match` when one was written, `.ok` at the end.
pub fn next(cursor: *Answer, out: ?*Row) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (cursor.at >= cursor.items.len) return .ok;
    slot.* = cursor.items[cursor.at];
    cursor.at += 1;
    return .match;
}

/// Fill up to `cap` rows. One crossing amortized over N rows — the whole reason
/// a binding batches. `.match` when at least one landed, `.ok` at the end.
pub fn nextBatch(cursor: *Answer, out_ptr: ?[*]Row, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const count = written orelse return .invalid;
    count.* = 0;
    if (cap == 0) return .ok;
    const out = (out_ptr orelse return .invalid)[0..cap];

    const take = @min(cap, cursor.items.len - cursor.at);
    @memcpy(out[0..take], cursor.items[cursor.at..][0..take]);
    cursor.at += take;
    count.* = take;
    return if (take == 0) .ok else .match;
}

/// Answer-level facts no row carries — the tier that answered, the freshness
/// fold, and `foreign`, which is how a caller tells "not in this corpus" from
/// "no results".
pub fn stats(cursor: *Answer, out: ?*rows.Stats) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (slot.struct_size != @sizeOf(rows.Stats)) return .invalid;
    const size = slot.struct_size;
    slot.* = cursor.stats;
    slot.struct_size = size;
    return .ok;
}

/// Free a cursor and everything its rows borrow.
pub fn close(cursor: *Answer) void {
    cursor.deinit();
}

test "the cursor walks once, batches the same rows, and ends cleanly" {
    const t = std.testing;
    const answer = try Answer.begin();
    defer close(answer);

    const arena = answer.arena.allocator();
    var built: std.ArrayList(Row) = .empty;
    for (0..3) |i| {
        var b = try rows.Builder.begin(arena, .pattern_count);
        b.set(rows.Value.text("p"));
        b.set(rows.Value.int(@intCast(i)));
        try built.append(arena, b.end());
    }
    answer.finish(try built.toOwnedSlice(arena), .{ .struct_size = @sizeOf(rows.Stats) });

    var one: Row = undefined;
    try t.expectEqual(Status.match, next(answer, &one));
    // A batch resumes where the single step left off — one position, not two.
    var batch: [4]Row = undefined;
    var got: usize = 0;
    try t.expectEqual(Status.match, nextBatch(answer, &batch, 4, &got));
    try t.expectEqual(@as(usize, 2), got);
    // Exhausted is `.ok` with nothing written, repeatably — not an error.
    try t.expectEqual(Status.ok, next(answer, &one));
    try t.expectEqual(Status.ok, nextBatch(answer, &batch, 4, &got));
    try t.expectEqual(@as(usize, 0), got);
}

test "the cursor surface fails closed on every argument it cannot trust" {
    const t = std.testing;
    const answer = try Answer.begin();
    defer close(answer);
    answer.finish(&.{}, .{ .struct_size = @sizeOf(rows.Stats) });

    var got: usize = 0;
    var batch: [1]Row = undefined;
    try t.expectEqual(Status.invalid, next(answer, null));
    try t.expectEqual(Status.invalid, nextBatch(answer, &batch, 1, null));
    try t.expectEqual(Status.invalid, nextBatch(answer, null, 1, &got));
    // A zero-width batch is a legitimate no-op, not a null-pointer bug.
    try t.expectEqual(Status.ok, nextBatch(answer, null, 0, &got));

    var st: rows.Stats = undefined;
    st.struct_size = 0;
    try t.expectEqual(Status.invalid, stats(answer, &st));
    try t.expectEqual(Status.invalid, stats(answer, null));
    // The caller's declared size survives the copy — that is what lets an
    // older host read a newer library's prefix instead of misreading it.
    st.struct_size = @sizeOf(rows.Stats);
    try t.expectEqual(Status.ok, stats(answer, &st));
    try t.expectEqual(@as(u32, @sizeOf(rows.Stats)), st.struct_size);
}

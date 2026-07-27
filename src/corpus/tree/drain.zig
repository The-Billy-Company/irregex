//! The stdout drain — *when* result bytes leave the process, and in how many
//! syscalls.
//!
//! `corpus.writeStdout` is the one seam every result byte crosses, and until
//! this module it crossed as one `write(2)` per producer fragment: whatever the
//! serial loop had accumulated at the end of the run, or one syscall per file
//! from the parallel sink. That is a policy — an unstated one — and it is the
//! wrong one at both ends. A terminal wants a matching line the moment it is
//! found; a pipe being fed ten thousand small files wants those fragments
//! coalesced, not ten thousand trips through the kernel.
//!
//! ripgrep names the same two ends (`--line-buffered` / `--block-buffered`) and
//! implements them with the Rust standard library's writers: `LineWriter` pays
//! one `write(2)` **per line**, `BufWriter` a fixed 8 KiB block. gist keeps both
//! promises and pays less for each:
//!
//!   * **line** — a complete line is never held, but every complete line
//!     already in hand leaves in ONE syscall. A file yielding two hundred
//!     matches is one `write(2)` here and two hundred under rg, with the same
//!     interactivity, because "never hold a finished line" does not oblige
//!     anyone to write them one at a time. The boundary is the run's real line
//!     terminator, so `--null-data` records flush on `\0` (rg's line writer
//!     only ever knows `\n`, and holds NUL-terminated output until its buffer
//!     fills).
//!   * **block** — coalesced into a buffer whose size is the caller's
//!     (`--buffer-size`; rg's 8 KiB is a constant), and which *ramps*: the
//!     first fragment of a run is never held, and the flush threshold then
//!     doubles from 1 KiB up to the ceiling. So `gist … | head -1` still gets
//!     its line back immediately and still learns about the closed pipe within
//!     a kilobyte, while a full-corpus dump settles into whole-buffer writes.
//!     A plain `BufWriter` holds the first byte just as long as the last one.
//!
//! The drain owns the buffer and the policy; it does not own the file
//! descriptor. `arm` is handed the sink that performs the actual write, which
//! is what keeps the budget accounting, the carbon copy, and the partial-write
//! retry loop in `corpus.zig` where they belong — and what lets the tests below
//! count syscalls against a capture sink instead of a terminal.

const std = @import("std");
const ward = @import("../../kernel/primitives/ward.zig");

/// What the drain owes the reader.
///
///   relay  write through untouched — the pre-policy behavior, and what an
///          unarmed process (a warm-served answer, `--schema`, an index verb)
///          keeps, since a single pre-rendered blob has nothing to coalesce.
///   line   never hold a complete line; emit every complete line in hand at once.
///   block  coalesce up to the ramped threshold, then emit.
pub const Policy = enum { relay, line, block };

/// Performs one write to the destination; `false` ⇒ the destination is gone
/// (a closed pipe) or refused, and the drain stops holding anything for it.
pub const Sink = *const fn (bytes: []const u8) bool;

/// The block ceiling when the caller names none. 64 KiB is a Linux pipe's
/// default capacity and the size the parallel walker's path-list batcher
/// already settled on, so a full buffer is one pipe-sized handoff.
pub const default_capacity: usize = 64 << 10;

/// The first rung the ramp climbs to after the priming write. Small enough that
/// a reader who has already left (`| head -1`) is discovered within a kilobyte
/// of further output, large enough that the climb to the ceiling costs a
/// handful of syscalls, not a per-fragment one.
const ramp_floor: usize = 1 << 10;

pub const Drain = struct {
    policy: Policy = .relay,
    /// Installed by the write that supplies it, never by construction — the
    /// destination arrives WITH the bytes, so there is no state in which a
    /// drain holds a policy but not somewhere to put the output. Null means
    /// nothing has ever been written here, which is also why a flush before
    /// the first write is a no-op rather than a hazard.
    sink: ?Sink = null,
    /// The held bytes. Empty ⇒ `relay`, or an arm whose allocation failed.
    buf: []u8 = &.{},
    len: usize = 0,
    /// The current flush threshold. Zero is the priming rung: the first
    /// fragment of a run is written the moment it arrives.
    rung: usize = 0,
    /// The line terminator `line` splits on — `\n`, or `\0` under `--null-data`.
    term: u8 = '\n',

    /// Fold `bytes` into the drain, writing whatever the policy says is due.
    /// `false` ⇒ the sink refused (closed pipe); anything still held is dropped,
    /// because there is no longer anywhere to put it.
    pub fn write(d: *Drain, sink: Sink, bytes: []const u8) bool {
        if (bytes.len == 0) return true;
        d.sink = sink;
        return switch (d.policy) {
            .relay => sink(bytes),
            .line => d.writeLines(bytes),
            .block => d.writeBlock(bytes),
        };
    }

    /// Emit everything held. Idempotent, and safe on a drain that was never
    /// armed or never written — which is why every exit path can call it
    /// unconditionally.
    pub fn flush(d: *Drain) bool {
        return d.release();
    }

    // ── block ──────────────────────────────────────────────────────────────

    fn writeBlock(d: *Drain, bytes: []const u8) bool {
        // A fragment that already justifies a syscall on its own — or that will
        // not fit beside what is held — goes out in order rather than through
        // the buffer: release what is held, then hand the fragment to the sink
        // whole. Copying a megabyte into a 64 KiB buffer 16 times over would
        // buy nothing.
        if (bytes.len >= d.rung or bytes.len > d.buf.len - d.len) {
            if (!d.release()) return false;
            if (bytes.len >= d.rung) return d.emit(bytes);
        }
        d.hold(bytes);
        return d.len < d.rung or d.release();
    }

    // ── line ───────────────────────────────────────────────────────────────

    /// Everything through the last terminator in `bytes` is complete lines and
    /// leaves now, coalesced with any partial line held from a previous
    /// fragment; the unterminated tail is held for the fragment that finishes it.
    fn writeLines(d: *Drain, bytes: []const u8) bool {
        const cut = std.mem.lastIndexOfScalar(u8, bytes, d.term) orelse {
            // No boundary at all. Hold the tail — unless it cannot fit, in
            // which case a single line is longer than the whole buffer and the
            // only honest move is to start writing it.
            if (bytes.len <= d.buf.len - d.len) {
                d.hold(bytes);
                return true;
            }
            return d.release() and d.emit(bytes);
        };
        const whole = bytes[0 .. cut + 1];
        // One syscall for held-tail + whole lines when they fit together; two
        // when they do not. Either way no finished line waits for the next
        // fragment.
        if (d.len != 0 and whole.len > d.buf.len - d.len) {
            if (!d.release()) return false;
        }
        if (d.len != 0) {
            d.hold(whole);
            if (!d.release()) return false;
        } else if (!d.emit(whole)) return false;
        // The buffer is empty by now (emitted or released), so the only tail that
        // cannot be held is one longer than the whole buffer — an unterminated
        // line bigger than the ceiling, which is written rather than dropped.
        const tail = bytes[cut + 1 ..];
        if (tail.len == 0) return true;
        if (tail.len > d.buf.len) return d.emit(tail);
        d.hold(tail);
        return true;
    }

    // ── the three primitives the two policies are written in ───────────────

    /// Copy into the buffer. The callers above have already proven it fits.
    fn hold(d: *Drain, bytes: []const u8) void {
        @memcpy(d.buf[d.len..][0..bytes.len], bytes);
        d.len += bytes.len;
    }

    /// Write the held bytes, if any. Held bytes are surrendered either way: a
    /// refused sink has nowhere left to take them.
    fn release(d: *Drain) bool {
        if (d.len == 0) return true;
        const held = d.buf[0..d.len];
        d.len = 0;
        return d.emit(held);
    }

    /// One write, then one step up the ramp. The ramp only ever climbs on a
    /// successful write, so a run that never produces enough to fill a rung
    /// never widens the window it holds output in.
    fn emit(d: *Drain, bytes: []const u8) bool {
        // Unreachable with a null sink: bytes can only be held by a `write`,
        // which installs one. Written as a no-op rather than an unwrap because
        // "nothing was ever written here" is genuinely nothing to emit.
        const sink = d.sink orelse return true;
        if (!sink(bytes)) return false;
        d.rung = if (d.rung == 0) @min(ramp_floor, d.buf.len) else @min(d.rung *| 2, d.buf.len);
        return true;
    }
};

// ── the process drain ────────────────────────────────────────────────────────
//
// One destination (fd 1), one policy, one buffer. `corpus.writeStdout` is
// already serialized by the parallel sink's lock, but the latch costs an
// uncontended atomic and removes the standing question of whether some future
// caller writes results from two threads — a torn buffer would corrupt output,
// not merely reorder it.

var mu: ward.Latch = .{};
var process_drain: Drain = .{};

/// Install `policy` for the rest of this process, buffering through `capacity`
/// bytes (0 ⇒ `default_capacity`) and splitting lines on `term`.
///
/// Fail-open by construction: if the buffer cannot be allocated the drain stays
/// in `relay`, so the worst outcome of an arming failure is the syscall count
/// gist had before this module existed — never a lost or reordered byte. The
/// buffer is process-lifetime (this is a one-shot CLI; every terminal path
/// exits) and deliberately never freed.
pub fn arm(policy: Policy, capacity: usize, term: u8) void {
    mu.lock();
    defer mu.unlock();
    _ = process_drain.flush();
    process_drain = .{ .term = term };
    if (policy == .relay) return;
    const want = if (capacity == 0) default_capacity else capacity;
    process_drain.buf = std.heap.page_allocator.alloc(u8, want) catch return;
    process_drain.policy = policy;
}

/// Hand `bytes` to the armed policy, writing through `sink`. An unarmed drain
/// relays straight through, which is what every non-search verb keeps.
pub fn write(sink: Sink, bytes: []const u8) bool {
    mu.lock();
    defer mu.unlock();
    return process_drain.write(sink, bytes);
}

/// Emit anything held. Every process exit runs this; it is a no-op on a relay
/// drain and on an empty buffer, so calling it twice — or before the drain was
/// ever armed — costs one uncontended latch.
pub fn flush() bool {
    mu.lock();
    defer mu.unlock();
    return process_drain.flush();
}

/// Does the armed policy owe the reader output *during* the run? True only for
/// `line`: the serial engine renders a whole run into one buffer and flushes it
/// at the end, which satisfies `block` exactly (it is one very large block) and
/// makes a nonsense of `line`. The engine reads this to decide whether to push
/// each file's rendered bytes as it finishes it.
pub fn streams() bool {
    mu.lock();
    defer mu.unlock();
    return process_drain.policy == .line;
}

// ── tests ────────────────────────────────────────────────────────────────────

/// A sink that counts trips and keeps the bytes, so a test can assert the two
/// things a buffering policy is allowed to change (how many writes, and when)
/// and the one thing it may never change (which bytes, in which order).
const Recorder = struct {
    var writes: usize = 0;
    var bytes: std.ArrayList(u8) = .empty;
    var refuse_after: usize = std.math.maxInt(usize);

    fn reset() void {
        writes = 0;
        bytes.clearRetainingCapacity();
        refuse_after = std.math.maxInt(usize);
    }
    fn sink(b: []const u8) bool {
        // A capture that cannot be stored is a destination that cannot take
        // the bytes — exactly what a refusal means to the drain, so the
        // recorder reports it as one rather than asserting it away.
        if (writes >= refuse_after) return false;
        bytes.appendSlice(std.testing.allocator, b) catch return false;
        writes += 1;
        return true;
    }
    fn deinit() void {
        bytes.deinit(std.testing.allocator);
        // A `Sink` is a bare function pointer, so the recorder has to be
        // process state — which means every test in this file shares it. Put
        // it back to `.empty`: a freed list that keeps its stale capacity
        // would let the next test's `clearRetainingCapacity` append into
        // memory it no longer owns.
        bytes = .empty;
    }
};

fn testDrain(policy: Policy, capacity: usize, term: u8) !Drain {
    return .{
        .policy = policy,
        .buf = try std.testing.allocator.alloc(u8, capacity),
        .term = term,
    };
}

test "drain line: every complete line leaves at once, in one write per fragment" {
    const t = std.testing;
    Recorder.reset();
    defer Recorder.deinit();
    var d = try testDrain(.line, 4096, '\n');
    defer t.allocator.free(d.buf);

    // Twelve lines in one fragment is ONE syscall — ripgrep's LineWriter pays
    // twelve. The bytes are identical; only the trip count differs.
    try t.expect(d.write(Recorder.sink, "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n"));
    try t.expectEqual(@as(usize, 1), Recorder.writes);
    try t.expectEqualStrings("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n", Recorder.bytes.items);
}

test "drain line: a partial line waits for its terminator and never for longer" {
    const t = std.testing;
    Recorder.reset();
    defer Recorder.deinit();
    var d = try testDrain(.line, 4096, '\n');
    defer t.allocator.free(d.buf);

    try t.expect(d.write(Recorder.sink, "half"));
    try t.expectEqual(@as(usize, 0), Recorder.writes); // nothing complete yet
    try t.expect(d.write(Recorder.sink, "-done\nnext-half"));
    try t.expectEqualStrings("half-done\n", Recorder.bytes.items); // the finished line, whole
    try t.expectEqual(@as(usize, 1), Recorder.writes);
    try t.expect(d.flush()); // the tail is owed at exit
    try t.expectEqualStrings("half-done\nnext-half", Recorder.bytes.items);
}

test "drain line: --null-data splits on the run's real terminator" {
    const t = std.testing;
    Recorder.reset();
    defer Recorder.deinit();
    var d = try testDrain(.line, 4096, 0);
    defer t.allocator.free(d.buf);

    // A NUL-terminated record stream carries no `\n`; splitting on one (as rg's
    // line writer does) would hold the whole thing.
    try t.expect(d.write(Recorder.sink, "rec-one\x00rec-two\x00part"));
    try t.expectEqualStrings("rec-one\x00rec-two\x00", Recorder.bytes.items);
}

test "drain line: a line longer than the whole buffer is written, never dropped" {
    const t = std.testing;
    Recorder.reset();
    defer Recorder.deinit();
    var d = try testDrain(.line, 64, '\n');
    defer t.allocator.free(d.buf);

    // Both shapes of "does not fit": an unterminated fragment on its own, and
    // an unterminated TAIL riding behind a finished line. Holding either would
    // be a buffer overrun, so the drain stops holding and starts writing.
    const long = "y" ** 300;
    try t.expect(d.write(Recorder.sink, long));
    try t.expect(d.write(Recorder.sink, "done\n" ++ long));
    try t.expect(d.flush());
    try t.expectEqualStrings(long ++ "done\n" ++ long, Recorder.bytes.items);
}

test "drain block: the first fragment is never held, then the ramp climbs to the ceiling" {
    const t = std.testing;
    Recorder.reset();
    defer Recorder.deinit();
    var d = try testDrain(.block, 4096, '\n');
    defer t.allocator.free(d.buf);

    // The priming write: a reader on the far end of a pipe sees output before
    // any threshold is reached, which is what keeps `| head -1` cheap.
    try t.expect(d.write(Recorder.sink, "first\n"));
    try t.expectEqual(@as(usize, 1), Recorder.writes);
    try t.expectEqualStrings("first\n", Recorder.bytes.items);

    // Now it coalesces: 512 further 8-byte fragments (4096 bytes) cross the
    // 1 KiB, 2 KiB and 4 KiB rungs — four writes total, not 513.
    for (0..512) |_| try t.expect(d.write(Recorder.sink, "12345678"));
    try t.expect(d.flush());
    try t.expect(Recorder.writes <= 5);
    try t.expectEqual(@as(usize, 6 + 4096), Recorder.bytes.items.len);
}

test "drain block: a fragment larger than the ceiling goes straight out, in order" {
    const t = std.testing;
    Recorder.reset();
    defer Recorder.deinit();
    var d = try testDrain(.block, 1024, '\n');
    defer t.allocator.free(d.buf);

    try t.expect(d.write(Recorder.sink, "prime\n")); // spend the priming rung
    try t.expect(d.write(Recorder.sink, "held\n"));
    const big = "x" ** 4096;
    try t.expect(d.write(Recorder.sink, big));
    // Held bytes are released ahead of the oversized fragment — order is the
    // one thing buffering may never change.
    try t.expectEqualStrings("prime\nheld\n" ++ big, Recorder.bytes.items);
}

test "drain: a refused sink is reported and surrenders what it was holding" {
    const t = std.testing;
    Recorder.reset();
    defer Recorder.deinit();
    var d = try testDrain(.block, 1024, '\n');
    defer t.allocator.free(d.buf);

    Recorder.refuse_after = 1; // the priming write lands; the next is a closed pipe
    try t.expect(d.write(Recorder.sink, "prime\n"));
    try t.expect(!d.write(Recorder.sink, "a" ** 2048));
    // Nothing is retained for a destination that is gone, so a later flush
    // cannot resurrect it onto a reopened fd.
    try t.expectEqual(@as(usize, 0), d.len);
    try t.expect(d.flush());
}

test "drain relay: byte-for-byte pass-through, one write per fragment" {
    const t = std.testing;
    Recorder.reset();
    defer Recorder.deinit();
    var d = Drain{ .policy = .relay };

    try t.expect(d.write(Recorder.sink, "one\n"));
    try t.expect(d.write(Recorder.sink, "two\n"));
    try t.expectEqual(@as(usize, 2), Recorder.writes);
    try t.expectEqualStrings("one\ntwo\n", Recorder.bytes.items);
    try t.expect(d.flush());
}

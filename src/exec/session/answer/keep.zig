//! The answer keep — rendered answers held against a corpus epoch.
//!
//! The warm tiers below this one make an expensive question *cheaper*: the
//! trigram index skips files a pattern cannot be in, the kinship atlas skips
//! fingerprints the corpus already knows. Some questions have no such skip.
//! "Which units here have no kin at all?" is a claim about every other unit, so
//! it cannot be answered from seed buckets — it is inherently a full sweep, and
//! on this corpus a full sweep is seconds. The only thing left to elide is the
//! sweep itself, and the only sound way to elide it is to have already done it
//! over the same bytes.
//!
//! So this keep holds **rendered answers**, not intermediates: the exact stdout
//! a verb produced, plus its exit code, plus the change epoch the corpus was at
//! when it was produced. A recall is served only when the epoch still matches,
//! which means the answer is not "probably still right" — it is the same answer
//! the same code would compute from the same bytes.
//!
//! ## What it deliberately does not do
//!
//! * **No partial credit.** One epoch covers the whole corpus, because the
//!   questions cached here read the whole corpus. A single file's change
//!   invalidates every entry, and that is correct rather than conservative:
//!   there is no subset of a corpus-wide answer that survives.
//! * **No computation.** The keep never runs a verb. A client computes cold and
//!   offers the result; the daemon decides only whether the offer is still
//!   valid and whether it has room. A store that cannot recompute cannot serve
//!   a wrong answer from a bug in its own recomputation.
//! * **No persistence.** The keep dies with the daemon. Its whole soundness
//!   argument rests on a live watcher's epoch, and a file on disk outlives the
//!   watcher that vouched for it.
//!
//! Eviction is least-recently-used against a byte ceiling, and an oversized
//! answer is refused outright rather than evicting a working set to hold one
//! firehose.

const std = @import("std");
const ward = @import("../../../kernel/math/lease.zig");

/// Largest single answer worth holding. Above this the entry would evict most
/// of the working set to serve one caller, and the caller is dumping a corpus
/// rather than asking a question.
pub const max_answer_bytes: usize = 8 << 20;

/// Total bytes of held answers. Sized for a working set of the expensive
/// kinship shapes over a large repo, not for a corpus mirror.
pub const max_total_bytes: usize = 64 << 20;

/// One held answer: what the verb wrote, how it exited, and the epoch it was
/// computed at.
const Held = struct {
    epoch: u64,
    code: u8,
    answer: []u8,
    /// LRU clock reading at the last recall (or at retention).
    touched: u64,
};

/// What a recall found. `stale` and `absent` are the same instruction to the
/// client — compute it — but they are different facts about the keep, and the
/// operator note reports them apart.
pub const Recalled = union(enum) {
    hit: struct { code: u8, answer: []const u8 },
    stale,
    absent,
};

/// Keyed rendered answers under one corpus epoch. Guarded by its own mutex:
/// pool workers recall and retain concurrently, and neither touches the
/// session.
pub const Keep = struct {
    gpa: std.mem.Allocator,
    mu: ward.Latch = .{},
    map: std.StringHashMapUnmanaged(Held) = .empty,
    held_bytes: usize = 0,
    clock: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    /// The two ceilings, as fields rather than constants so a test can drive
    /// the eviction path on a handful of bytes instead of sixty-four megabytes.
    entry_ceiling: usize = max_answer_bytes,
    ceiling: usize = max_total_bytes,

    pub fn init(gpa: std.mem.Allocator) Keep {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Keep) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.answer);
        }
        self.map.deinit(self.gpa);
        self.* = undefined;
    }

    /// The answer for `key` if one was computed at `epoch`. A stale entry is
    /// dropped on the way out rather than left to age — nothing else will ever
    /// serve it, and holding it costs the next retention its room.
    ///
    /// The returned bytes are the keep's, valid until the next mutating call.
    /// Every caller writes them to a socket before returning, under the same
    /// worker that recalled them.
    pub fn recall(self: *Keep, key: []const u8, epoch: u64) Recalled {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.map.getEntry(key) orelse {
            self.misses += 1;
            return .absent;
        };
        if (e.value_ptr.epoch != epoch) {
            self.misses += 1;
            self.release(e.key_ptr.*);
            return .stale;
        }
        self.clock += 1;
        e.value_ptr.touched = self.clock;
        self.hits += 1;
        return .{ .hit = .{ .code = e.value_ptr.code, .answer = e.value_ptr.answer } };
    }

    /// Hold `answer` for `key` as of `epoch`. Silently declines an oversized
    /// answer or an allocation failure: a keep that cannot hold something is a
    /// slower keep, never a wrong one. Replacing an existing key is how a
    /// re-run after a corpus change refreshes its entry.
    pub fn retain(self: *Keep, key: []const u8, epoch: u64, code: u8, answer: []const u8) void {
        if (answer.len > self.entry_ceiling) return;
        self.mu.lock();
        defer self.mu.unlock();

        const owned = self.gpa.dupe(u8, answer) catch return;
        self.clock += 1;
        const held: Held = .{ .epoch = epoch, .code = code, .answer = owned, .touched = self.clock };

        if (self.map.getEntry(key)) |e| {
            self.held_bytes -= e.value_ptr.answer.len;
            self.gpa.free(e.value_ptr.answer);
            e.value_ptr.* = held;
        } else {
            const key_owned = self.gpa.dupe(u8, key) catch {
                self.gpa.free(owned);
                return;
            };
            self.map.put(self.gpa, key_owned, held) catch {
                self.gpa.free(key_owned);
                self.gpa.free(owned);
                return;
            };
        }
        self.held_bytes += owned.len;
        // Never evict the entry just retained: a ceiling below one answer means
        // that answer simply isn't holdable, and spinning the working set out to
        // discover that would cost every other caller their hit.
        while (self.held_bytes > self.ceiling and self.map.count() > 1) if (!self.evictOldest()) break;
    }

    /// Drop every entry — the reset a reconciled session takes when it can no
    /// longer vouch for the epoch it handed out.
    pub fn clear(self: *Keep) void {
        self.mu.lock();
        defer self.mu.unlock();
        _ = self.drop();
    }

    /// Give every held byte back to the memory ration, or nothing at all.
    ///
    /// This is what the keep is FOR, seen from the other side: every entry is
    /// rendered output the daemon can recompute, which is exactly what made it
    /// cacheable, so it is the first thing a session under memory pressure
    /// should surrender (`warden/warden.zig`).
    ///
    /// The lock is TRIED, never taken. The warden calls this from inside a
    /// failing allocation, on whichever thread met the ceiling — and that may be
    /// a thread already inside `retain`, which allocates while holding `mu`.
    /// Taking the lock there would deadlock the daemon on itself; trying it
    /// reports zero reclaimable bytes instead, and the allocation is refused.
    /// The cost of that pessimism is one query answered cold.
    pub fn surrender(self: *Keep) usize {
        if (!self.mu.tryLock()) return 0;
        defer self.mu.unlock();
        return self.drop();
    }

    /// Free every entry and report the bytes released. Caller holds `mu`.
    fn drop(self: *Keep) usize {
        const freed = self.held_bytes;
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.answer);
        }
        self.map.clearRetainingCapacity();
        self.held_bytes = 0;
        return freed;
    }

    /// Held entries and bytes, for the daemon's operator note.
    pub fn census(self: *Keep) struct { entries: usize, bytes: usize, hits: u64, misses: u64 } {
        self.mu.lock();
        defer self.mu.unlock();
        return .{ .entries = self.map.count(), .bytes = self.held_bytes, .hits = self.hits, .misses = self.misses };
    }

    /// Free one entry by key. Called under `mu`.
    fn release(self: *Keep, key: []const u8) void {
        const e = self.map.fetchRemove(key) orelse return;
        self.held_bytes -= e.value.answer.len;
        self.gpa.free(e.key);
        self.gpa.free(e.value.answer);
    }

    /// Evict the least-recently-recalled entry. False when the keep is empty
    /// (the ceiling is smaller than one entry — the caller stops rather than
    /// spinning). Called under `mu`.
    fn evictOldest(self: *Keep) bool {
        var oldest: ?[]const u8 = null;
        var oldest_touch: u64 = std.math.maxInt(u64);
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.touched >= oldest_touch) continue;
            oldest_touch = e.value_ptr.touched;
            oldest = e.key_ptr.*;
        }
        const victim = oldest orelse return false;
        self.release(victim);
        return true;
    }
};

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

test "an answer recalls only under the epoch it was computed at" {
    var keep = Keep.init(t.allocator);
    defer keep.deinit();

    try t.expect(keep.recall("q", 7) == .absent);
    keep.retain("q", 7, 0, "rows\n");
    switch (keep.recall("q", 7)) {
        .hit => |h| {
            try t.expectEqualStrings("rows\n", h.answer);
            try t.expectEqual(@as(u8, 0), h.code);
        },
        else => return error.ExpectedHit,
    }
    // One corpus change later the same question is a different question.
    try t.expect(keep.recall("q", 8) == .stale);
    // …and the stale entry is gone rather than lingering to be re-rejected.
    try t.expect(keep.recall("q", 8) == .absent);
}

test "the exit code rides with the bytes, so a clean miss stays a clean miss" {
    var keep = Keep.init(t.allocator);
    defer keep.deinit();
    keep.retain("empty", 1, 1, "");
    switch (keep.recall("empty", 1)) {
        .hit => |h| {
            try t.expectEqual(@as(u8, 1), h.code);
            try t.expectEqual(@as(usize, 0), h.answer.len);
        },
        else => return error.ExpectedHit,
    }
}

test "re-retaining a key replaces it without leaking its old answer" {
    var keep = Keep.init(t.allocator);
    defer keep.deinit();
    keep.retain("q", 1, 0, "old");
    keep.retain("q", 2, 0, "newer");
    try t.expectEqual(@as(usize, 1), keep.census().entries);
    try t.expectEqual(@as(usize, 5), keep.census().bytes);
    try t.expect(keep.recall("q", 1) == .stale);
}

test "an oversized answer is refused, not held at the cost of the working set" {
    var keep = Keep.init(t.allocator);
    defer keep.deinit();
    keep.entry_ceiling = 8;
    keep.retain("huge", 1, 0, "nine char");
    try t.expectEqual(@as(usize, 0), keep.census().entries);
    keep.retain("fits", 1, 0, "eight ch");
    try t.expectEqual(@as(usize, 1), keep.census().entries);
}

test "the ceiling evicts least-recently-RECALLED, not least-recently-written" {
    var keep = Keep.init(t.allocator);
    defer keep.deinit();
    keep.ceiling = 20; // room for two ten-byte answers, not three
    keep.retain("a", 1, 0, "0123456789");
    keep.retain("b", 1, 0, "0123456789");
    _ = keep.recall("a", 1); // `a` is freshest by USE; `b` was written later
    keep.retain("c", 1, 0, "0123456789");
    // `b` goes — written after `a` but never recalled since.
    try t.expect(keep.recall("b", 1) == .absent);
    try t.expect(keep.recall("a", 1) == .hit);
    try t.expect(keep.recall("c", 1) == .hit);
    try t.expectEqual(@as(usize, 20), keep.census().bytes);
}

test "clear drops everything the epoch can no longer vouch for" {
    var keep = Keep.init(t.allocator);
    defer keep.deinit();
    keep.retain("a", 1, 0, "x");
    keep.retain("b", 1, 0, "y");
    keep.clear();
    try t.expectEqual(@as(usize, 0), keep.census().entries);
    try t.expectEqual(@as(usize, 0), keep.census().bytes);
    // Still usable after a clear.
    keep.retain("c", 2, 0, "z");
    try t.expect(keep.recall("c", 2) == .hit);
}

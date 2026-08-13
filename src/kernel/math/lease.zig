//! irregex — Ward: the shared reader/writer discipline both engines and the warm
//! session ride, instead of hand-rolling `std.Io.RwLock` lock/unlock pairs at
//! each call site. Pure `std.Io` plumbing with no search, index, or corpus
//! knowledge — the peer of `parallel.zig` on the concurrency axis.
//!
//! Two things a raw `RwLock` makes easy to get wrong, gathered into one place:
//!
//!   1. **Lease guards** (`Read` / `Write`) pair acquisition with release: you
//!      hold a value whose `release()` drops exactly the mode you took, so a
//!      `defer lease.release()` can never unbalance a shared vs. exclusive
//!      unlock. `tryRead` / `tryWrite` return the same guard or null.
//!
//!   2. **`readReconciled`** — the read-mostly "answer over an immutable
//!      snapshot, refresh on a miss" dance: enter shared and,
//!      when the snapshot is already fresh, answer under the shared lock so
//!      readers overlap; otherwise drop shared, take EXCLUSIVE, refresh, then
//!      **downgrade** back to shared to answer. This is textbook double-checked
//!      locking (Schmidt & Harrison, "Double-Checked Locking", PLoP '96): the
//!      writer re-verifies freshness under exclusivity, so a reader that lost the
//!      upgrade race and a writer that already refreshed both settle on one pass.
//!      The tricky invariant — on a refresh error NOTHING is held, so the
//!      caller's `defer …release()` (registered only after the `try`) never runs
//!      on the error path — lives here once rather than at every answer face.
//!      Its sibling **`reconcileHeld`** serves the mirror-image caller — one that
//!      already holds a `Read` lease under a `defer release()` and so must end
//!      holding a lease on EVERY path, error included — by returning the refresh
//!      error *beside* a still-live lease instead of in place of it.
//!
//! Writer-preferring, inherited from `std.Io.RwLock`: a pending writer parks new
//! readers on the mutex, so a stream of readers can't starve a queued refresh.
//!
//! Its smaller sibling `Latch` covers the case a `Ward` cannot: a critical
//! section entered from a thread that has no `std.Io` handle at all.

const std = @import("std");

/// Mutual exclusion for threads with **no `std.Io` handle** — an OS watcher
/// thread, a signal-adjacent callback, a process-lifetime symbol cache — where
/// `Ward`/`Io.Mutex` are simply unavailable. A plain atomic swap loop is then
/// the honest primitive, and it is honest ONLY under the discipline this type
/// enforces by existing: every critical section is a handful of map/field
/// operations, bounded and allocation-shaped at worst, never a syscall or a
/// wait. Callers get `lock`/`unlock` and never touch a raw ordering, so the
/// `.acquire`/`.release` pair lives here once instead of at each ledger.
///
/// Not recursive and not fair: taking it twice on one thread deadlocks, and a
/// contended waiter spins rather than parking. Both are correct for sections
/// this short and wrong for anything longer — reach for `Ward` there.
pub const Latch = struct {
    held: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *Latch) void {
        while (self.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    /// Take the latch if it is free, or report that it is not. The escape hatch
    /// for the one caller shape `lock` cannot serve: code reached from INSIDE a
    /// critical section — a memory-pressure hand called from a failing
    /// allocation, which may be an allocation this very latch is already held
    /// across. Since the latch is not recursive, such a caller must be able to
    /// decline instead of deadlocking on itself.
    pub fn tryLock(self: *Latch) bool {
        return !self.held.swap(true, .acquire);
    }

    pub fn unlock(self: *Latch) void {
        self.held.store(false, .release);
    }
};

/// The error set of a `refresh` callback (`fn (ctx) E!void`), lifted out so a
/// `reconcileHeld` result can carry `?E` beside a still-held lease.
fn RefreshError(comptime Refresh: type) type {
    return @typeInfo(@typeInfo(Refresh).@"fn".return_type.?).error_union.error_set;
}

pub const Ward = struct {
    rw: std.Io.RwLock = .init,

    /// A held SHARED lease: while alive the warded state is immutable to every
    /// holder, and many `Read` leases overlap. `{ *Ward, io }`-cheap; `release`
    /// drops the shared count. Never release twice.
    pub const Read = struct {
        ward: *Ward,
        io: std.Io,

        pub fn release(self: Read) void {
            self.ward.rw.unlockShared(self.io);
        }
    };

    /// A held EXCLUSIVE lease: sole access to the warded state. `release` drops
    /// it; `downgrade` trades it for a `Read` lease. Never release twice.
    pub const Write = struct {
        ward: *Ward,
        io: std.Io,

        pub fn release(self: Write) void {
            self.ward.rw.unlock(self.io);
        }

        /// Drop exclusivity and re-take shared, returning the `Read` lease. NOT
        /// atomic: a competing writer may slip into the release→reacquire gap, so
        /// only downgrade once every mutation this writer made is published and
        /// any staleness a racing writer could introduce is independently
        /// re-checked by the reader (the resident session's existence stat).
        pub fn downgrade(self: Write) Read {
            self.ward.rw.unlock(self.io);
            self.ward.rw.lockSharedUncancelable(self.io);
            return .{ .ward = self.ward, .io = self.io };
        }
    };

    /// Enter shared, blocking behind any active/pending writer. Pair with the
    /// returned lease's `release()`.
    pub fn read(self: *Ward, io: std.Io) Read {
        self.rw.lockSharedUncancelable(io);
        return .{ .ward = self, .io = io };
    }

    /// Enter exclusive, blocking until no reader or writer remains. Pair with the
    /// returned lease's `release()` (or `downgrade()`).
    pub fn write(self: *Ward, io: std.Io) Write {
        self.rw.lockUncancelable(io);
        return .{ .ward = self, .io = io };
    }

    /// Try to enter shared without blocking; null if a writer holds or is queued.
    pub fn tryRead(self: *Ward, io: std.Io) ?Read {
        return if (self.rw.tryLockShared(io)) .{ .ward = self, .io = io } else null;
    }

    /// Try to enter exclusive without blocking; null if any lease is held.
    pub fn tryWrite(self: *Ward, io: std.Io) ?Write {
        return if (self.rw.tryLock(io)) .{ .ward = self, .io = io } else null;
    }

    /// Double-checked read-mostly acquisition. Take shared and, if `fresh(ctx)`
    /// holds, return the `Read` lease immediately — the fast path where readers
    /// overlap with no writer and no refresh. Otherwise drop shared, take
    /// EXCLUSIVE, run `refresh(ctx)`, and downgrade back to shared, returning the
    /// `Read` lease. `refresh` OWNS the second freshness check (it runs under
    /// exclusivity, so a writer that raced us and already refreshed makes it a
    /// no-op) and any side effects the refresh entails. On a `refresh` error the
    /// error is propagated with NOTHING held. The inferred error set is exactly
    /// `refresh`'s, so a caller's typed error union threads straight through.
    pub fn readReconciled(
        self: *Ward,
        io: std.Io,
        ctx: anytype,
        comptime fresh: fn (@TypeOf(ctx)) bool,
        comptime refresh: anytype,
    ) !Read {
        const lease = self.read(io);
        if (fresh(ctx)) return lease;
        lease.release();
        const held = self.write(io);
        refresh(ctx) catch |err| {
            held.release();
            return err;
        };
        return held.downgrade();
    }

    /// Double-checked reconcile from an ALREADY-HELD shared lease, keeping a
    /// read lease on EVERY path — the variant for a caller whose
    /// `defer lease.release()` was registered before the reconcile and must stay
    /// balanced even when `refresh` fails. If `fresh(ctx)` holds, `held` is
    /// returned untouched (the fast path — no upgrade, readers overlap).
    /// Otherwise drop shared, take EXCLUSIVE, and re-check `fresh(ctx)`: a writer
    /// that raced us into the gap and already refreshed makes this a no-op
    /// (double-checked locking). On a genuine miss run `refresh(ctx)`, then
    /// downgrade back to shared. The returned `.lease` is ALWAYS live; `.err` is
    /// `refresh`'s error if it failed — surfaced *beside* the lease, since unlike
    /// `readReconciled` the lease is still held. This owns BOTH freshness checks,
    /// so `refresh` need only perform the update.
    pub fn reconcileHeld(
        self: *Ward,
        held: Read,
        ctx: anytype,
        comptime fresh: fn (@TypeOf(ctx)) bool,
        comptime refresh: anytype,
    ) struct { lease: Read, err: ?RefreshError(@TypeOf(refresh)) } {
        if (fresh(ctx)) return .{ .lease = held, .err = null };
        const io = held.io;
        held.release();
        const w = self.write(io);
        const err: ?RefreshError(@TypeOf(refresh)) = if (fresh(ctx)) null else e: {
            refresh(ctx) catch |x| break :e x;
            break :e null;
        };
        return .{ .lease = w.downgrade(), .err = err };
    }
};

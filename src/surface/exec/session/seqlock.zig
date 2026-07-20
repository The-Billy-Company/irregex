//! The freshness seqlock every resident session shares (ADR-352 rung 2.5).
//!
//! Both warm engines — gist's `ResidentSession` (mirrors corpus bytes) and
//! relate's `RetrievalSession` (caches an anchor overlay) — face the identical
//! concurrency problem: a watch thread reports filesystem events while a query
//! thread, under the session mutex, decides whether it may skip the reconcile
//! walk. The decision is a lock-free seqlock over three atomics + one plain
//! bool, and the memory ordering is subtle enough that it must live in ONE
//! place, not be re-derived per session. This is that place: it owns every
//! `.acquire`/`.release`/`.monotonic`, so no session ever touches a raw atomic.
//!
//! The payload — what "reconcile" actually recomputes — stays per session; the
//! barrier only tracks *whether* a recompute is owed. The protocol:
//!
//!   - watch thread: `markDirty` on every event, `markDoubtForever` when it
//!     loses coverage it cannot recover (fail-closed — the fast path is then
//!     permanently off), `arm` once a backend is proven live.
//!   - query thread (holding the session mutex): `skip` short-circuits the walk
//!     when a live watcher has proven quiescence; otherwise snapshot `enter`,
//!     recompute, then `commit` — which republishes "clean" ONLY if no event
//!     raced the recompute (the seqlock re-read). Without a watcher, `clean` is
//!     never set, so every query reconciles: correct, just not microsecond-fast.
//!
//! `clean` is set true only under `eligible`, and any event (`markDirty`, and
//! `markDoubtForever` calls it) clears it, so `provenClean` — the raw bit the
//! answer paths read to decide whether a hit still needs an existence stat —
//! is a sound "no untracked change since the last reconcile" witness on its own.

const std = @import("std");

/// Lock-free freshness barrier. Embed one per session; drive it from the
/// watcher (event thread) and the reconcile (query thread, under the mutex).
pub const Seqlock = struct {
    /// A watcher backend is live and proving quiescence. Written once by `arm`
    /// on the arming thread before any query reads it (never raced), so it needs
    /// no atomic; every trust decision also gates on the atomic `poison`/`clean`.
    active: bool = false,
    /// Event counter, bumped on every filesystem event — the seqlock sequence.
    seq: std.atomic.Value(u64) = .init(0),
    /// True only when a watcher has proven no event since the last reconcile.
    clean: std.atomic.Value(bool) = .init(false),
    /// Latched by a watcher that lost coverage it cannot recover (queue
    /// overflow, an unwatchable new directory): the clean fast path is disabled
    /// for the session's life and every query reconciles (fail-closed).
    poison: std.atomic.Value(bool) = .init(false),

    // ── watch thread (lock-free) ──

    /// An event arrived: the next query must reconcile. A path-reporting backend
    /// `note`s the exact paths into its `DirtyLog` BEFORE calling this, so any
    /// event counted by a reconcile's pre-drain `enter` is visible to that drain.
    pub fn markDirty(self: *Seqlock) void {
        _ = self.seq.fetchAdd(1, .monotonic);
        self.clean.store(false, .release);
    }

    /// Coverage is lost for good: permanently disable the clean fast path, then
    /// force a reconcile. Every later query reconciles — slower, never stale.
    pub fn markDoubtForever(self: *Seqlock) void {
        self.poison.store(true, .release);
        self.markDirty();
    }

    /// Declare a watcher live and proving quiescence (see `active`).
    pub fn arm(self: *Seqlock) void {
        self.active = true;
    }

    // ── query thread (holds the session mutex) ──

    /// A live, unpoisoned watcher — the precondition for ever trusting `clean`.
    pub fn eligible(self: *const Seqlock) bool {
        return self.active and !self.poison.load(.acquire);
    }

    /// The reconcile fast path: a live watcher has proven no event since the
    /// last reconcile, so the cached overlay/mirror is already current.
    pub fn skip(self: *const Seqlock) bool {
        return self.eligible() and self.clean.load(.acquire);
    }

    /// Snapshot the event counter before recomputing; hand it back to `commit`.
    pub fn enter(self: *const Seqlock) u64 {
        return self.seq.load(.acquire);
    }

    /// Republish "clean" iff a watcher is live, unpoisoned, and no event raced
    /// the recompute since `enter` returned `seq0`. Otherwise stay dirty.
    pub fn commit(self: *Seqlock, seq0: u64) void {
        if (self.eligible() and self.seq.load(.acquire) == seq0)
            self.clean.store(true, .release);
    }

    /// The raw clean witness the answer paths read to gate per-hit existence
    /// checks: true ⇒ nothing changed since the last reconcile, so a hit need
    /// not be re-stated for existence. Sound on its own (see the module header).
    pub fn provenClean(self: *const Seqlock) bool {
        return self.clean.load(.acquire);
    }
};

test "a fresh barrier is dirty and skips nothing" {
    var s: Seqlock = .{};
    try std.testing.expect(!s.skip());
    try std.testing.expect(!s.provenClean());
    try std.testing.expect(!s.eligible());
}

test "clean is trusted only under a live, unpoisoned watcher" {
    var s: Seqlock = .{};
    // No watcher: a completed reconcile never publishes clean.
    const seq0 = s.enter();
    s.commit(seq0);
    try std.testing.expect(!s.skip());

    // Armed + quiescent: commit publishes clean, the fast path opens.
    s.arm();
    const seq1 = s.enter();
    s.commit(seq1);
    try std.testing.expect(s.skip());
    try std.testing.expect(s.provenClean());

    // An event during the next reconcile window forbids re-publishing clean.
    const seq2 = s.enter();
    s.markDirty();
    try std.testing.expect(!s.skip());
    s.commit(seq2);
    try std.testing.expect(!s.skip());
}

test "doubt is permanent: the fast path never reopens" {
    var s: Seqlock = .{};
    s.arm();
    s.markDoubtForever();
    const seq0 = s.enter();
    s.commit(seq0);
    try std.testing.expect(!s.skip());
    try std.testing.expect(!s.eligible());
}

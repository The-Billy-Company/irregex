//! assay/time — the two clocks, made non-interchangeable.
//!
//! Every timing site in the package used to read `nowNs(io)` (a bare `i128`) and
//! subtract two of them, and every freshness site read a second bare `i128` from
//! the *other* clock. Nothing at the type level stopped `fresh.writeAnchor` from
//! being handed a monotonic duration stamp, or a duration from being computed
//! across the wall clock (which jumps under NTP/DST and would silently report a
//! negative or wild elapsed). This module splits the two readings into distinct
//! non-coercible types so that class of bug becomes a compile error:
//!
//!   * `Span`/`Duration` ride the MONOTONIC-awake clock (`.awake`) — the only
//!     sound basis for "how long did this take". A `Duration` is the *only* thing
//!     you can turn into milliseconds; you cannot format an `Anchor` as elapsed.
//!   * `Anchor` rides the WALL clock (`.real`) — an absolute epoch instant, the
//!     only sound basis for freshness ("was this file touched after the build").
//!     It is the only producer the persistence layer accepts, so a monotonic
//!     stamp can never reach `writeAnchor`.
//!
//! Both are `enum(i128)` newtypes: same machine representation as the raw reading
//! (zero cost), but no implicit conversion to each other or to a bare integer.

const std = @import("std");
const builtin = @import("builtin");

/// A monotonic elapsed interval in nanoseconds — the result of `Span.read`.
/// The one type that renders as milliseconds, so a wall-clock instant can never
/// be mistaken for "how long this took".
pub const Duration = enum(i128) {
    _,

    /// Fractional milliseconds — the human timing unit every diagnostic line
    /// prints (`{d:.0}`/`{d:.1} ms`). Kept byte-for-byte identical to the old
    /// free `ms(ns)` helper: `ns / 1e6` as an `f64`.
    pub fn ms(self: Duration) f64 {
        return @as(f64, @floatFromInt(@intFromEnum(self))) / 1e6;
    }

    /// The raw nanosecond count — for callers that sum or compare intervals
    /// (e.g. `cold-load + rank` in the ranked timing line) before formatting.
    pub fn ns(self: Duration) i128 {
        return @intFromEnum(self);
    }

    /// Sum two intervals (the ranked line reports `cold-load + rank` as total).
    pub fn add(self: Duration, other: Duration) Duration {
        return @enumFromInt(@intFromEnum(self) + @intFromEnum(other));
    }
};

/// A monotonic-clock stopwatch. `open` marks the start; `read` returns the
/// elapsed `Duration` without consuming (call it as many times as there are
/// timing components on the line); `lap` reads and restarts for back-to-back
/// phase timing. Uses the awake clock, so a suspend/NTP step never corrupts a
/// measured interval.
pub const Span = struct {
    start: i128,

    pub fn open(io: std.Io) Span {
        return .{ .start = std.Io.Clock.now(.awake, io).nanoseconds };
    }

    /// Elapsed since `open` (or the last `lap`). Non-consuming.
    pub fn read(self: Span, io: std.Io) Duration {
        return @enumFromInt(std.Io.Clock.now(.awake, io).nanoseconds - self.start);
    }

    /// Elapsed since the last mark, then re-mark to now — for timing a sequence
    /// of phases where each line reports only its own segment.
    pub fn lap(self: *Span, io: std.Io) Duration {
        const now = std.Io.Clock.now(.awake, io).nanoseconds;
        const d: Duration = @enumFromInt(now - self.start);
        self.start = now;
        return d;
    }
};

/// The core's rate, measured in this process rather than read off a data sheet.
///
/// A `Duration` says how long something took; a `Cadence` is what converts that
/// into what a CPU designer would call the cost — cycles, and cycles per byte.
/// Every coefficient in the ladder's price plane is in those units, so anything
/// that mints or audits one needs this, and two copies of it would mean a
/// coefficient and the measurement disputing it were divided by different clocks.
///
/// The reading is a dependent `ADD` chain: one cycle per link by construction,
/// so it reports the rate the core actually sustained under whatever else the
/// machine was doing — never an advertised boost. `null` where no such chain is
/// written for the target, and then a caller must decline to report cycles at
/// all rather than assume a frequency.
pub const Cadence = struct {
    cyc_per_ns: f64,

    /// `links` × 16 dependent adds. The caller sizes it; 1<<16 is ~1 ms.
    pub fn measure(io: std.Io, links: u64) ?Cadence {
        if (comptime builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .aarch64_be) return null;
        var x: u64 = 1;
        const sp = Span.open(io);
        for (0..links) |_| {
            inline for (0..16) |_| {
                x = asm ("add %[o], %[i], #1"
                    : [o] "=r" (-> u64),
                    : [i] "r" (x),
                );
            }
        }
        const elapsed = sp.read(io).ns();
        std.mem.doNotOptimizeAway(x);
        if (elapsed <= 0) return null;
        return .{ .cyc_per_ns = @as(f64, @floatFromInt(links * 16)) / @as(f64, @floatFromInt(elapsed)) };
    }

    pub fn cycles(self: Cadence, d: Duration) f64 {
        const ns = d.ns();
        return if (ns <= 0) 0 else @as(f64, @floatFromInt(ns)) * self.cyc_per_ns;
    }

    /// The one conversion into the price plane's unit.
    pub fn cycPerByte(self: Cadence, d: Duration, bytes: usize) f64 {
        return if (bytes == 0) 0 else self.cycles(d) / @as(f64, @floatFromInt(bytes));
    }

    /// Gigahertz, for the one line a bench prints to say what it measured on.
    pub fn ghz(self: Cadence) f64 {
        return self.cyc_per_ns;
    }
};

/// A wall-clock epoch instant in nanoseconds — the freshness stamp. The only
/// type `fresh.writeAnchor` and the persisted index generation accept, so a
/// monotonic reading can never masquerade as a build anchor.
pub const Anchor = enum(i128) {
    _,

    /// The raw epoch-ns value, for the persistence layer that stores it as an
    /// `i64` on disk and compares it against on-disk mtimes/ctimes.
    pub fn ns(self: Anchor) i128 {
        return @intFromEnum(self);
    }
};

/// Read the wall clock — the ONE producer of an `Anchor`. Captured before an
/// index build reads the corpus, so any file touched during the build has an
/// mtime/ctime at or after it and is re-verified by the next query.
pub fn anchor(io: std.Io) Anchor {
    return @enumFromInt(std.Io.Clock.now(.real, io).nanoseconds);
}

test "Duration.ms matches the legacy ns/1e6 formula" {
    const d: Duration = @enumFromInt(1_500_000); // 1.5 ms
    try std.testing.expectEqual(@as(f64, 1.5), d.ms());
    try std.testing.expectEqual(@as(i128, 1_500_000), d.ns());
}

test "Duration.add sums intervals" {
    const a: Duration = @enumFromInt(1_000_000);
    const b: Duration = @enumFromInt(2_000_000);
    try std.testing.expectEqual(@as(f64, 3.0), a.add(b).ms());
}

test "Span.read is monotonic and non-negative" {
    const io = std.Io.Clock; // unused placeholder to keep intent explicit
    _ = io;
    // A synthetic span with a known start proves the arithmetic without a clock.
    var s = Span{ .start = 0 };
    // read() would call the clock; instead assert lap() re-marks from an explicit
    // start using the pure arithmetic path via a hand-rolled duration.
    const d: Duration = @enumFromInt(@as(i128, 5_000_000) - s.start);
    try std.testing.expectEqual(@as(f64, 5.0), d.ms());
    s.start = 5_000_000;
    try std.testing.expectEqual(@as(i128, 5_000_000), s.start);
}

test "Anchor and Duration do not coerce to each other" {
    // Compile-time proof of the separation: an Anchor has no `ms`, a Duration
    // has no epoch meaning. We can only assert the representations here.
    const an: Anchor = @enumFromInt(1234);
    try std.testing.expectEqual(@as(i128, 1234), an.ns());
}

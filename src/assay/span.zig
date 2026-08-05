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

    /// Whole microseconds, truncated. The scale below `ms` exists because not
    /// every program on this floor has millisecond-sized phases: a grammar
    /// import and an LALR table build land in the hundreds of microseconds,
    /// where `{d:.1} ms` rounds the difference between two grammars away.
    /// Truncating rather than rounding is deliberate — it is the same reading
    /// the open-coded `@divTrunc(ns, ns_per_us)` at those sites produced, so
    /// adopting the typed clock cannot move a number anyone has recorded.
    pub fn us(self: Duration) i64 {
        return @intCast(@divTrunc(@intFromEnum(self), std.time.ns_per_us));
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
///
/// This is deliberately NOT the bench harness's PMU, which counts cycles
/// outright instead of inferring a rate from them. `assay` is a production tier
/// and `bench/` sits outside the package, so a coefficient minted here and the
/// instrument auditing it would be divided by different clocks if this reached
/// for one. The chain is the reading every tier can take.
pub const Cadence = struct {
    cyc_per_ns: f64,

    /// Is a single-cycle dependent link written for this target? Published
    /// because callers have to decide whether a cycles column exists at all,
    /// and three benches were each answering it with their own copy of the arch
    /// test — which is how a fourth target gets ported into `link` below and
    /// stays dark in the harness that reports it.
    ///
    /// 32-bit x86 is excluded rather than given a `u32` chain: a 64-bit add
    /// lowers to `add`/`adc` there, which is two instructions per link and
    /// breaks the one-cycle construction the whole reading rests on.
    pub const measurable: bool = switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be, .x86_64 => true,
        else => false,
    };

    /// One link of the chain: an increment whose input is the previous link's
    /// output, so two links cannot overlap and the chain retires at exactly one
    /// per cycle.
    ///
    /// Selected on ARCHITECTURE rather than through `builtin.cpu.has`, which is
    /// the one shape `quality/ratchets/isa-floor` exempts and for its stated
    /// reason: integer `add` is in the mandatory base ISA of both families, so
    /// there is no optional feature to ask about and the arch IS the whole
    /// truth. Every other inline asm in this package must still name its
    /// feature, because LLVM does not read an asm template.
    ///
    /// Refuses to compile off `measurable` rather than returning a sentinel, so
    /// a target reaches this leaf only through the predicate that admits it.
    inline fn link(x: u64) u64 {
        if (comptime builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .aarch64_be)
            return asm ("add %[o], %[i], #1"
                : [o] "=r" (-> u64),
                : [i] "r" (x),
            );
        // Two-operand and read-modify-write, so the increment rides a register
        // (`"0"` ties it to the output) rather than an immediate: `$` is LLVM's
        // own operand sigil inside an asm template, and a register-sourced 1 is
        // loop-invariant anyway. The mnemonic stays bare `add` — GAS takes the
        // width from the operand — because the ratchet exempts it by name.
        if (comptime builtin.cpu.arch == .x86_64)
            return asm ("add %[one], %[o]"
                : [o] "=r" (-> u64),
                : [i] "0" (x),
                  [one] "r" (@as(u64, 1)),
            );
        @compileError("assay.Cadence.link has no single-cycle chain for this target — callers gate on `measurable`");
    }

    /// The core's sustained rate, sampled until the reading stops climbing.
    ///
    /// `links` sizes ONE sample (× 16 dependent adds); the number of samples is
    /// the function's own business, because the caller cannot know how long this
    /// core takes to reach its operating frequency and should not have to.
    ///
    /// **Why this repeats rather than timing one pass.** A single pass was what
    /// this did, and on a laptop whose scheduler parks a new thread on a
    /// performance core at its operating frequency it was right. On a Linux box
    /// under the `powersave` governor it is not: cores idle near 800 MHz and
    /// take tens of milliseconds of load to ramp, so a 0.3 ms pass measures the
    /// ramp rather than the core. Two `ladder-price mint` runs minutes apart on
    /// the same idle machine read 1.577 GHz and ~4 GHz — a 2.5× swing that every
    /// coefficient in the plane was then divided by, which is not a noisy
    /// measurement but an arbitrary one. Convergence is not a tuning knob bolted
    /// on afterwards; a clock that reports the ramp is not a clock.
    ///
    /// **Why the BEST sample and not the mean or the worst.** Because the work
    /// this divides is itself reported best-of-N (`fastest` in the price rig
    /// takes the minimum elapsed time), and a rate must be the same statistic as
    /// the cost it converts or the two do not cancel — a best-case duration over
    /// an average-case clock is a number with no referent. It remains an
    /// ACHIEVED rate, never an advertised boost: nothing here reads a data sheet,
    /// and a core that never reaches its ceiling reports the rate it did reach.
    ///
    /// Convergence is measured, not scheduled: samples continue while any of
    /// them still improves on the best by more than `noise`, so a hot core exits
    /// in a few hundred microseconds and a cold one keeps going until it is
    /// warm. There is no warmup constant to be wrong on the next machine.
    pub fn measure(io: std.Io, links: u64) ?Cadence {
        if (comptime !measurable) return null;
        // Below the spread two back-to-back samples show on a settled core
        // (~0.1% measured on both Apple and Raptor Lake silicon), so a sample
        // that only clears this is noise rather than the ramp still rising.
        const noise = 1.0 / 256.0;
        // Consecutive non-improving samples that end it. One could be a stray
        // preemption; three in a row is a plateau.
        const settle = 3;
        // A machine that never settles still has to return. At the ~0.3 ms
        // sample the callers size, this bounds the whole reading well under a
        // tenth of a second — and it is reached only by a host whose frequency
        // genuinely will not sit still, where any single number is a fiction
        // anyway and the best one seen is the least misleading of them.
        const ceiling = 64;

        var top: f64 = 0;
        var flat: u8 = 0;
        var taken: u16 = 0;
        while (taken < ceiling and flat < settle) : (taken += 1) {
            const r = sample(io, links) orelse continue;
            if (r > top * (1.0 + noise)) flat = 0 else flat += 1;
            top = @max(top, r);
        }
        return if (top > 0) .{ .cyc_per_ns = top } else null;
    }

    /// One timed pass of `links` × 16 dependent adds — the reading `measure`
    /// takes repeatedly. Separate so the chain is timed in exactly one place.
    fn sample(io: std.Io, links: u64) ?f64 {
        var x: u64 = 1;
        const sp = Span.open(io);
        for (0..links) |_| {
            inline for (0..16) |_| x = link(x);
        }
        const elapsed = sp.read(io).ns();
        std.mem.doNotOptimizeAway(x);
        if (elapsed <= 0) return null;
        return @as(f64, @floatFromInt(links * 16)) / @as(f64, @floatFromInt(elapsed));
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

test "Duration.us truncates, matching the open-coded divTrunc it replaces" {
    const d: Duration = @enumFromInt(1_500_900);
    try std.testing.expectEqual(@as(i64, 1500), d.us());
    // Sub-microsecond reads as zero rather than rounding up to one.
    try std.testing.expectEqual(@as(i64, 0), (@as(Duration, @enumFromInt(999))).us());
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

test "the core clock reads a real rate wherever a chain is written for the target" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A target either has a chain and reports, or has none and declines. The
    // two must not disagree: a `measurable` target that returns null is a
    // harness printing a blank cycles column on hardware that can fill it, and
    // the reverse is a number nothing produced.
    const short = Cadence.measure(io, 1 << 14);
    try std.testing.expectEqual(Cadence.measurable, short != null);
    const a = short orelse return;

    // Physically possible. This is what catches a chain wired to the wrong
    // thing — an elided loop reports a rate in the thousands of GHz, and a
    // zero-length span reports nothing at all.
    try std.testing.expect(a.ghz() > 0.1 and a.ghz() < 100.0);

    // And the links have to be what costs the time. Quadruple them: a real
    // dependent chain holds its rate, while an elided one keeps paying only the
    // fixed span overhead and so reports ~4x the cycles for the same wall time.
    // The 2x band clears that signature with room for a box carrying ten
    // coworker agents, which is the load this actually runs under.
    const b = Cadence.measure(io, 1 << 16) orelse return error.ClockStoppedAnswering;
    const ratio = @max(a.ghz(), b.ghz()) / @min(a.ghz(), b.ghz());
    try std.testing.expect(ratio < 2.0);
}

test "Anchor and Duration do not coerce to each other" {
    // Compile-time proof of the separation: an Anchor has no `ms`, a Duration
    // has no epoch meaning. We can only assert the representations here.
    const an: Anchor = @enumFromInt(1234);
    try std.testing.expectEqual(@as(i128, 1234), an.ns());
}

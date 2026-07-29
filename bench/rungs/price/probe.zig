//! The price lane's INSTRUMENT: one clock, one haystack family, one timing
//! rule — shared by `mint` and `regret` so a coefficient and the regret it is
//! later judged by are measured the same way. Two harnesses that agree on a
//! number by coincidence prove nothing; this file is why they cannot disagree.
//!
//! Three deliberate choices, each of which is the difference between a number
//! and an anecdote:
//!
//!   * **The clock is measured, in this process, next to the row it divides.**
//!     A dependent `ADD` chain is one cycle per link by construction, so it
//!     reports what the core was actually doing under whatever load ten
//!     coworker agents are putting on the box — never the advertised boost.
//!   * **Min-of-N, and N rounds are interleaved by the caller.** The minimum is
//!     the only order statistic a contended machine cannot inflate; a mean
//!     measures the neighbors.
//!   * **Haystacks are synthetic and NON-MATCHING by construction.** A boolean
//!     scan returns at the first hit, so a matching haystack measures the match
//!     position rather than the kernel. The alphabet here holds no digit and no
//!     uppercase byte, so every probe pattern below is a guaranteed full scan —
//!     and a planted variant gives the skip a candidate density that is known
//!     rather than estimated, which is the whole reason `skip_verify` can be a
//!     per-candidate cost instead of a fudge.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");

pub const Span = gist.assay.Span;

const Regex = gist.regex.Regex;
const Settle = gist.regex_price.Settle;

/// The bytes a probe haystack is drawn from: lowercase `a`–`y` only. No digit,
/// no uppercase, no `z`. Every probe pattern carries one of those three, which
/// is what makes "this scan ran to the end" a property of the alphabet rather
/// than a hope about the pattern.
///
/// The draw is FLAT over those 25 bytes, and that was tested rather than assumed.
/// The sieve lane measures the same walks on the real corpus at ~0.8 cyc/B where
/// `dfa_step` mints at 1.37, and the obvious suspect was this alphabet: no spaces
/// to break a run, no skew for a branch predictor to learn. So the draw was
/// replaced with the corpus's own measured byte shape (its 3,034 non-binary files,
/// minus the three excluded classes, renormalized — still 77% of real corpus
/// mass) and every coefficient re-minted. `dfa_step` came back 1.397 against
/// 1.373: unmoved, inside the noise the clock already carries. Byte skew is not
/// where the corpus gap lives, and the shape that separates `dfa_line` and
/// `anchor_line` cleanly is worth more than a realism that buys nothing — those
/// two rows moved 2.7× and 2.3× under the corpus draw, because a haystack that is
/// 20% spaces changes how far a per-line search advances before it dies and puts
/// that variance on the axis those two are separated over. Flat stays.
const alphabet_len = 'y' - 'a' + 1;

/// The measured core rate. It lives in the engine's own instrumentation floor
/// (`assay.Cadence`) rather than here, because the corpus proof in
/// `bench/rungs/sieve/` audits these same coefficients against real files and the
/// two lanes must not divide by two different clocks. This lane keeps the `ns`
/// overloads, since `fastest` reports a raw min-of-N rather than a `Duration`.
pub const Clock = struct {
    inner: gist.assay.Cadence,

    pub fn measure(io: std.Io, links: u64) ?Clock {
        return .{ .inner = gist.assay.Cadence.measure(io, links) orelse return null };
    }

    /// The one conversion. Every coefficient in `price.zig` is cycles per byte,
    /// so every measurement arrives through here.
    pub fn cycPerByte(self: Clock, ns: i128, bytes: usize) f64 {
        return self.inner.cycPerByte(@enumFromInt(ns), bytes);
    }

    pub fn cycles(self: Clock, ns: i128) f64 {
        return self.inner.cycles(@enumFromInt(ns));
    }

    pub fn ghz(self: Clock) f64 {
        return self.inner.ghz();
    }
};

/// Min-of-N over anything with a `run` method. Generic on the context rather
/// than on a function pointer so the kernel under test inlines exactly as it
/// does in production — a call through a pointer would measure the pointer.
pub fn fastest(io: std.Io, rounds: usize, ctx: anytype) i128 {
    var lo: i128 = std.math.maxInt(i64);
    for (0..rounds) |_| {
        const sp = Span.open(io);
        const out = ctx.run();
        const ns = sp.read(io).ns();
        std.mem.doNotOptimizeAway(out);
        if (ns > 0 and ns < lo) lo = ns;
    }
    return lo;
}

/// An intercept and a slope, told apart by measuring the SAME kernel at two
/// settings of the thing the slope multiplies.
///
/// Two coefficients here are per-byte costs with a per-event term folded in — a
/// skipped walk pays for candidates, an anchored one pays per line — and a
/// single measurement of such a kernel is one equation in two unknowns. The
/// tempting shortcut is to measure the intercept separately and subtract it,
/// which is what `skip_verify` did: it swung 2.6× between two runs of the same
/// bench, because a small difference of two large timings carries both timings'
/// error. Two points on the same kernel cancel the intercept exactly instead,
/// and the slope is then an honest difference of things that genuinely differ.
///
/// `x` is the event rate (candidates per byte, lines per byte); both are clamped
/// at zero, since a negative cost is a measurement that lost its own noise.
pub fn separate(y: [2]f64, x: [2]f64) struct { intercept: f64, slope: f64 } {
    if (x[0] == x[1]) return .{ .intercept = @max(y[0], 0), .slope = 0 };
    const slope = @max((y[0] - y[1]) / (x[0] - x[1]), 0);
    return .{ .intercept = @max(y[1] - slope * x[1], 0), .slope = slope };
}

/// A synthetic haystack: `cols`-wide lines over the safe alphabet, deterministic
/// from `seed` so two runs on the same machine measure the same bytes.
///
/// Line breaks sit on the fixed `cols` grid rather than being drawn, because two
/// coefficients are separated by holding total bytes constant and varying only
/// how many lines those bytes are cut into (`anchor_scan`/`anchor_line`) — a
/// sampled terminator would put noise on the axis doing the separating.
pub const Hay = struct {
    bytes: []u8,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, len: usize, cols: usize, seed: u64) !Hay {
        const buf = try gpa.alloc(u8, len);
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        for (buf, 0..) |*b, i| {
            b.* = if ((i + 1) % cols == 0) '\n' else 'a' + rand.uintLessThan(u8, alphabet_len);
        }
        buf[len - 1] = '\n';
        return .{ .bytes = buf, .gpa = gpa };
    }

    /// The same haystack with `needle` written at a known spacing — a candidate
    /// density the harness KNOWS, which is what turns a skipped scan's total
    /// into a per-candidate verification cost by subtraction.
    pub fn plant(self: *Hay, needle: u8, every: usize) usize {
        var planted: usize = 0;
        var i: usize = every;
        while (i < self.bytes.len) : (i += every) {
            if (self.bytes[i] == '\n') continue;
            self.bytes[i] = needle;
            planted += 1;
        }
        return planted;
    }

    pub fn deinit(self: *Hay) void {
        self.gpa.free(self.bytes);
    }
};

/// Present a buffer as its lines, for the per-line grain. Borrows; the caller
/// owns the buffer and this list.
pub fn lines(gpa: std.mem.Allocator, buf: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |ln| if (ln.len != 0) try out.append(gpa, ln);
    return out.toOwnedSlice(gpa);
}

// ── the two kernels that answer ABOVE the ladder ─────────────────────────────
//
// These live here rather than in `mint` because both lanes need the same
// measurement of them for different reasons: `mint` turns one into a
// coefficient, and `regret` puts one in the field as an arm. A settled pattern
// is the one case where the machine that answers is not a bidder at all, so if
// the two lanes timed it differently the gate would be judging a fiction.

/// The kernel behind one of `Regex`'s optional accelerator fields. Reached
/// through the field rather than through a module, because the engine's seal
/// does not re-export these types — and does not need to: the struct that holds
/// one already says what it is.
pub fn Kernel(comptime field: []const u8) type {
    return @typeInfo(@FieldType(Regex, field)).optional.child;
}

/// A newline-free byte-exact class run decides any buffer. `[0-9]{40,}` is the
/// pattern the sieve lane caught being bid against a phantom DFA eight times
/// dearer than this — so this settler is the finding's own witness.
///
/// Two probes, because which block classifier a class gets is a property of the
/// class and not selectable: ≤4 contiguous ranges take the two-compare lanes,
/// and a fifth range tips it onto the truffle nibble tables. Neither probe's
/// class meets the safe alphabet, so both scans run to the last byte.
pub const ClassRunScan = struct {
    pub const kernel = "classrun";
    pub const probes = [_][]const u8{ "[0-9]{40,}", "[0-24-68A-CE-G]{40,}" };
    pub fn settles(k: *const Kernel(kernel)) ?Settle {
        if (!k.decides()) return null;
        return switch (k.backend) {
            .ranges => .class_ranges,
            .nibbles => .class_nibbles,
        };
    }

    k: *const Kernel(kernel),
    hay: []const u8,
    pub fn run(self: @This()) bool {
        return self.k.scan(self.hay) != .miss;
    }
};

/// An `.exact` literal set IS the pattern, so its verdict is final and nothing
/// below it runs. One needle takes a single anchored SIMD scan; three take a
/// Teddy bucket pass. Both probes carry `z`, which the safe alphabet excludes.
pub const LiteralScan = struct {
    pub const kernel = "literal_scan";
    pub const probes = [_][]const u8{ "zebra", "zebra|quartz|puzzle" };
    pub fn settles(k: *const Kernel(kernel)) ?Settle {
        if (k.authority != .exact) return null;
        return switch (k.arity()) {
            .one => .literal_one,
            .many => .literal_many,
        };
    }

    k: *const Kernel(kernel),
    hay: []const u8,
    pub fn run(self: @This()) bool {
        return switch (self.k.find(self.hay, 0)) {
            inline else => |p| p != null,
        };
    }
};

/// Every settler. One list, so a third kernel that can decide a pattern reaches
/// both lanes at once — `mint` measures its shapes and `regret` puts it in the
/// field, with neither file edited.
pub const settlers = .{ ClassRunScan, LiteralScan };

/// What a settler costs on one compiled pattern, and WHICH shape it turned out
/// to be. `narrows_only` is the load-bearing arm: a class run that merely
/// NARROWS has the same `scan` as one that decides and completely different
/// standing, so minting the former as the latter is the exact mistake these
/// coefficients exist to end.
pub const Settled = union(enum) {
    ok: struct { kind: Settle, cyc: f64 },
    no_compile,
    no_kernel,
    narrows_only,
};

/// The settler measured on one of its OWN probe patterns — `mint`'s shape, where
/// the coefficient is the point and the pattern is chosen to produce it.
pub fn settleProbe(
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: Clock,
    rounds: usize,
    hay: []const u8,
    pattern: []const u8,
    comptime S: type,
) Settled {
    var re = Regex.compileOpts(gpa, pattern, .{}) catch return .no_compile;
    defer re.deinit();
    return settleCost(io, clock, rounds, hay, &re, S);
}

pub fn settleCost(
    io: std.Io,
    clock: Clock,
    rounds: usize,
    hay: []const u8,
    re: *const Regex,
    comptime S: type,
) Settled {
    if (@field(re, S.kernel)) |*k| {
        const kind = S.settles(k) orelse return .narrows_only;
        return .{ .ok = .{
            .kind = kind,
            .cyc = clock.cycPerByte(fastest(io, rounds, S{ .k = k, .hay = hay }), hay.len),
        } };
    }
    return .no_kernel;
}

/// Whichever settler actually decides this pattern, timed — the shape `regret`
/// needs, since it holds a compiled pattern and wants to know what answers it.
pub fn settledBy(
    io: std.Io,
    clock: Clock,
    rounds: usize,
    hay: []const u8,
    re: *const Regex,
) ?@FieldType(Settled, "ok") {
    inline for (settlers) |S| switch (settleCost(io, clock, rounds, hay, re, S)) {
        .ok => |hit| return hit,
        else => {},
    };
    return null;
}

/// A measured coefficient beside the committed one. `want == 0` means the
/// committed plane has nothing to compare against (an unported target), which
/// `verify` reports rather than passing silently.
pub const Row = struct {
    name: []const u8,
    got: f64,
    want: f64,
    /// What the row is a quantity OF, so a reader can tell a per-byte number
    /// from a per-candidate one without consulting the plane.
    unit: []const u8,
    /// The measurement's own scale — bytes scanned, or candidates verified.
    /// Printed so a suspiciously cheap row can be recognized as a short one.
    scale: usize = 0,
    note: []const u8 = "",

    /// Relative disagreement with the committed number, or 0 when there is
    /// nothing committed.
    pub fn drift(self: Row) f64 {
        if (self.want == 0) return 0;
        return (self.got - self.want) / self.want;
    }
};

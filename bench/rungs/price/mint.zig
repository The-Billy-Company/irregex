//! MINTING: every coefficient the ladder bids with, each timed by itself.
//!
//! The rule this file exists to obey is that a coefficient must be a quantity
//! ONE kernel produces, measured while nothing else runs. That is what makes
//! `verify` a per-coefficient check rather than a whole-model refit, and it is
//! what the plane this replaced could not offer: `9_000 + stripe_ops/8` cannot
//! be re-measured, because no kernel produces `9_000`.
//!
//! Two measurement designs here are worth reading before trusting a row.
//!
//! **The skip is measured by subtraction, over a planted density.** A first-byte
//! skip's cost has two halves that no single haystack separates: scanning, and
//! verifying what the scan surfaced. So it is measured twice — once on a
//! haystack that contains no candidate at all (pure scan), then once on the same
//! bytes with the needle written at a KNOWN spacing. The difference, divided by
//! the candidate count, is the per-candidate verification. Nothing is estimated;
//! the density is authored.
//!
//! **The DFA's step is a measured sweep, not an assumed cache boundary.** Table
//! residency is the whole per-pattern variance in a walk (one loop-carried
//! dependent load), but which cache level answers it is a property of the HOST,
//! and a data sheet is not a measurement. So the sweep walks real patterns of
//! increasing determinized size, reads each table's true byte count, and lets
//! the shape of the curve name all three numbers: the floor, the ceiling, and
//! the largest table still at the floor. On a machine with a large L2 the curve
//! comes back flat, and then the model correctly stops pretending table size
//! matters much here — which is a finding, not a fudge.

const std = @import("std");
const gist = @import("irregex");
const probe = @import("probe.zig");

const price = gist.regex_price;
const Regex = gist.regex.Regex;
const Dfa = gist.regex_dfa.Dfa;
const Compose = gist.regex_compose.Compose;
const Width = gist.regex_compose.lanes.Width;
const Parabix = gist.regex_parabix.Parabix;
const Sieve = gist.regex_sieve.Sieve;
const stripe_width = gist.regex_parabix.plane_floor.stripe_width;

/// One point of the table-residency sweep, kept so the curve is printed rather
/// than summarized. A reader who disagrees with the three numbers derived from
/// it can see the shape they were derived from.
pub const Point = struct {
    pattern: []const u8,
    states: usize,
    table_bytes: usize,
    cyc_per_byte: f64,
};

pub const Report = struct {
    cal: price.Calibration,
    sweep: []Point,
    /// Coefficients no probe on this host could reach, named rather than
    /// silently left at whatever the committed plane said.
    missing: []const []const u8,

    pub fn deinit(self: *Report, gpa: std.mem.Allocator) void {
        gpa.free(self.sweep);
        gpa.free(self.missing);
    }
};

/// The whole slate. `rounds` is min-of-N per kernel; the caller sizes it.
pub fn measure(gpa: std.mem.Allocator, io: std.Io, clock: probe.Clock, rounds: usize) !Report {
    var hay = try probe.Hay.init(gpa, hay_len, 96, 0x9e3779b9);
    defer hay.deinit();
    const neutral = hay.bytes;

    const rows = try probe.lines(gpa, neutral);
    defer gpa.free(rows);

    var missing: std.ArrayList([]const u8) = .empty;
    errdefer missing.deinit(gpa);

    var cal = price.Calibration{
        .machine = "",
        .minted = "",
        .dfa_step = 0,
        .dfa_line = 0,
        .skip_scan = 0,
        .skip_verify = 0,
        .anchor_scan = 0,
        .anchor_line = 0,
        .settle_class_ranges = 0,
        .settle_class_nibbles = 0,
        .settle_literal_one = 0,
        .settle_literal_many = 0,
        .lazy_step = 0,
        .pike_step = 0,
        .compose16 = 0,
        .compose32 = 0,
        .compose_eol = 0,
        .parabix_op = 0,
        .sieve_line = .{ 0, 0 },
        .sieve_doc = .{ 0, 0 },
        .build_per_table_byte = 0,
        .build_per_instr = 0,
    };

    const sweep = try residency(gpa, io, clock, rounds, neutral, &cal);
    errdefer gpa.free(sweep);

    // The line view drops one terminator per row, so the byte count the per-line
    // rows are divided by is not the buffer's.
    const line_bytes = neutral.len - rows.len;
    try lineWalk(gpa, io, clock, rounds, rows, line_bytes, &cal, &missing);
    try anchor(gpa, io, clock, rounds, &cal, &missing);
    try settles(gpa, io, clock, rounds, neutral, &cal, &missing);
    try skip(gpa, io, clock, rounds, neutral, &cal, &missing);
    try walkers(gpa, io, clock, rounds, neutral, &cal, &missing);
    try vectors(gpa, io, clock, rounds, neutral, &cal, &missing);
    try sieves(gpa, io, clock, rounds, neutral, rows, &cal, &missing);
    try builds(gpa, io, clock, rounds, &cal, &missing);

    return .{ .cal = cal, .sweep = sweep, .missing = try missing.toOwnedSlice(gpa) };
}

/// Every probe scans this many bytes — well past any cache, so the haystack side
/// of the measurement is streaming for all of them and only the MACHINE differs
/// between rows.
const hay_len: usize = 8 << 20;

/// The rare byte the skip probe hunts. Outside `probe`'s alphabet, so a neutral
/// haystack holds none and a planted one holds exactly what was planted.
const needle: u8 = 'Q';

// ── the byte-at-a-time walk ──────────────────────────────────────────────────

/// Patterns of increasing determinized size, all of them dense walks by
/// construction: each starts on a class of ≥26 bytes, which is far past the
/// three-byte ceiling a first-byte skip arms under, so no accelerator is in the
/// measurement. Each carries a digit class, and the probe alphabet holds no
/// digit, so every scan runs to the last byte.
const sweep_patterns = [_]struct { pat: []const u8, unicode: bool = false }{
    .{ .pat = "[a-z][0-9]" },
    .{ .pat = "[a-z]{4}[0-9]{4}" },
    .{ .pat = "[a-z]{16}[0-9]{16}" },
    .{ .pat = "[a-c][d-f][g-i][j-l][m-o][p-r][s-u][v-y][0-9]" },
    .{ .pat = "\\w{16}[0-9]{16}" },
    .{ .pat = "\\p{L}{6}[0-9]{6}", .unicode = true },
    .{ .pat = "\\p{L}{12}\\p{N}{4}[0-9]{8}", .unicode = true },
};

fn residency(
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: probe.Clock,
    rounds: usize,
    hay: []const u8,
    cal: *price.Calibration,
) ![]Point {
    var pts: std.ArrayList(Point) = .empty;
    errdefer pts.deinit(gpa);
    for (sweep_patterns) |sp| {
        var re = Regex.compileOpts(gpa, sp.pat, .{ .force_dfa = true, .unicode = sp.unicode }) catch continue;
        defer re.deinit();
        const d = re.dfa orelse continue;
        if (d.start_dwell != null) continue; // an accelerated walk is a different row
        const ns = probe.fastest(io, rounds, Doc{ .d = d, .hay = hay });
        try pts.append(gpa, .{
            .pattern = sp.pat,
            .states = d.nstates,
            .table_bytes = d.tableBytes(),
            .cyc_per_byte = clock.cycPerByte(ns, hay.len),
        });
    }
    const points = try pts.toOwnedSlice(gpa);
    if (points.len == 0) return points;

    // The sweep once fitted a residency curve — a resident step, a spilled step,
    // and the footprint between them. It measured no such curve (a 1.4 MB table
    // and a 216-byte table walk the same), so it now yields ONE step and keeps
    // going as the standing evidence for that. `spread` is what a future host
    // would have to move for the axis to come back: `verify` reports it, and a
    // host where footprint really does matter will show it there before anything
    // silently misprices.
    std.mem.sortUnstable(Point, points, {}, struct {
        fn lt(_: void, x: Point, y: Point) bool {
            return x.cyc_per_byte < y.cyc_per_byte;
        }
    }.lt);

    // The median, not the floor: the floor is whichever pattern determinized
    // smallest (a 3-state walk that no interesting pattern gets), and pricing
    // every dense walk at the cheapest one the slate could find would flatter
    // the incumbent against every challenger.
    cal.dfa_step = points[points.len / 2].cyc_per_byte;
    return points;
}

/// How far apart the fastest and slowest dense walks on the sweep came in, and
/// across how wide a footprint range. Published rather than fitted: while this
/// stays near 1.0 across a range this wide, one `dfa_step` is the honest model.
pub fn spread(points: []const Point) struct { cost: f64, footprint: f64 } {
    if (points.len == 0) return .{ .cost = 1, .footprint = 1 };
    var lo = points[0];
    var hi = points[0];
    for (points) |p| {
        if (p.cyc_per_byte < lo.cyc_per_byte) lo = p;
        if (p.cyc_per_byte > hi.cyc_per_byte) hi = p;
    }
    var small = points[0].table_bytes;
    var big = points[0].table_bytes;
    for (points) |p| {
        small = @min(small, p.table_bytes);
        big = @max(big, p.table_bytes);
    }
    return .{
        .cost = hi.cyc_per_byte / @max(lo.cyc_per_byte, 1e-9),
        .footprint = @as(f64, @floatFromInt(big)) / @as(f64, @floatFromInt(@max(small, 1))),
    };
}

/// The same walk with one line in hand instead of four. `lineMatch` is the kernel
/// every per-LINE comparison is really against, and it is the SAME automaton and
/// the same haystack as the row above — so the quotient of the two is the overlap
/// the document form buys, measured rather than assumed.
fn lineWalk(
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: probe.Clock,
    rounds: usize,
    rows: []const []const u8,
    bytes: usize,
    cal: *price.Calibration,
    missing: *std.ArrayList([]const u8),
) !void {
    // The first sweep pattern that stays at the residency floor, so the quotient
    // isolates the grain and carries no cache difference.
    var re = Regex.compileOpts(gpa, sweep_patterns[0].pat, .{ .force_dfa = true }) catch {
        try missing.append(gpa, "dfa_line (probe failed to compile)");
        return;
    };
    defer re.deinit();
    const d = re.dfa orelse {
        try missing.append(gpa, "dfa_line (no DFA)");
        return;
    };
    cal.dfa_line = clock.cycPerByte(probe.fastest(io, rounds, Lines{ .d = d, .rows = rows }), bytes);
}

const Doc = struct {
    d: *const Dfa,
    hay: []const u8,
    pub fn run(self: Doc) bool {
        return self.d.docMatch(self.hay);
    }
};

const Lines = struct {
    d: *const Dfa,
    rows: []const []const u8,
    pub fn run(self: Lines) usize {
        var hits: usize = 0;
        for (self.rows) |ln| hits += @intFromBool(self.d.match(ln));
        return hits;
    }
};

/// The two line widths the anchored walk is separated over, and the two candidate
/// spacings the skipped one is. Each pair is far enough apart that the per-event
/// term dominates one point and has nearly vanished at the other — that spread is
/// what makes `probe.separate` a separation rather than a division of noise.
const anchor_cols = [2]usize{ 24, 512 };
const skip_spacing = [2]usize{ 16, 1024 };

/// An anchored walk, resolved into its two independent halves.
///
/// `^[a-z]{6}[0-9]` cannot match anywhere but a line start, and the alphabet
/// holds no digit, so every line dies after a handful of bytes and the engine
/// spends the rest of that line hunting `\n`. Its per-byte cost is therefore
/// `scan + line × (lines per byte)`, and one measurement cannot tell the two
/// apart. Two line widths can: the same kernel over the same total bytes,
/// differing only in how many lines those bytes are cut into.
fn anchor(
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: probe.Clock,
    rounds: usize,
    cal: *price.Calibration,
    missing: *std.ArrayList([]const u8),
) !void {
    var re = Regex.compileOpts(gpa, "^[a-z]{6}[0-9]", .{ .force_dfa = true }) catch {
        try missing.append(gpa, "anchor_scan/anchor_line (probe failed to compile)");
        return;
    };
    defer re.deinit();
    const d = re.dfa orelse {
        try missing.append(gpa, "anchor_scan/anchor_line (no DFA)");
        return;
    };

    var y: [2]f64 = undefined;
    var x: [2]f64 = undefined;
    for (anchor_cols, 0..) |cols, i| {
        var hay = try probe.Hay.init(gpa, hay_len, cols, 0xA0C + cols);
        defer hay.deinit();
        y[i] = clock.cycPerByte(probe.fastest(io, rounds, Doc{ .d = d, .hay = hay.bytes }), hay.bytes.len);
        x[i] = 1 / @as(f64, @floatFromInt(cols)); // lines per byte
    }
    const fit = probe.separate(y, x);
    cal.anchor_scan = fit.intercept;
    cal.anchor_line = fit.slope;
}

/// The two kernels that answer ABOVE the ladder, each timed on a pattern it
/// decides outright.
///
/// Every other row here prices a bidder. These two price the machine a bidder
/// sometimes has to be told it is not running against — so the probe's first job
/// is to prove authority, not speed: `decides()` and `authority == .exact` are
/// asserted before the clock starts, because a class run that only NARROWS and
/// an `.exact` one that IS the pattern have the same `scan` and completely
/// different standing. Measuring the former and committing it as the latter is
/// precisely the mistake this coefficient exists to end.
///
/// Both probes are guaranteed full scans by the alphabet (no digit, no `z`), so
/// each row is classification bandwidth over `hay_len` bytes and not the
/// distance to a lucky first hit.
fn settles(
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: probe.Clock,
    rounds: usize,
    hay: []const u8,
    cal: *price.Calibration,
    missing: *std.ArrayList([]const u8),
) !void {
    inline for (probe.settlers) |S| for (S.probes) |pattern| {
        switch (probe.settleProbe(gpa, io, clock, rounds, hay, pattern, S)) {
            // Which shape a probe lands on is a property of the pattern, not a
            // flag — so the slate is walked and each row files itself, exactly as
            // the sieve's conjunct counts do.
            .ok => |hit| switch (hit.kind) {
                inline else => |tag| @field(cal, "settle_" ++ @tagName(tag)) = hit.cyc,
            },
            .no_compile, .no_kernel, .narrows_only => {},
        }
    };
    inline for (comptime std.enums.values(price.Settle)) |tag| {
        if (@field(cal, "settle_" ++ @tagName(tag)) == 0)
            try missing.append(gpa, "settle_" ++ @tagName(tag) ++ " (no probe reached this classifier)");
    }
}

/// The two halves of a skipped walk, separated by candidate density.
///
/// One rare literal, so the start state exits on `Q` alone: the dwell arms and
/// the accelerated search runs. The tail is there so a candidate is REJECTED
/// after a byte or two — a verification, not a match. `skip_scan` comes from the
/// haystack that holds no `Q` at all; `skip_verify` is the SLOPE across two
/// planted densities, so it never inherits the scan row's error.
fn skip(
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: probe.Clock,
    rounds: usize,
    neutral: []const u8,
    cal: *price.Calibration,
    missing: *std.ArrayList([]const u8),
) !void {
    var re = Regex.compileOpts(gpa, "Qzxjvw", .{ .force_dfa = true }) catch {
        try missing.append(gpa, "skip_scan/skip_verify (probe failed to compile)");
        return;
    };
    defer re.deinit();
    const d = re.dfa orelse {
        try missing.append(gpa, "skip_scan/skip_verify (no DFA)");
        return;
    };
    if (d.start_dwell == null) {
        try missing.append(gpa, "skip_scan/skip_verify (probe armed no skip)");
        return;
    }
    cal.skip_scan = clock.cycPerByte(probe.fastest(io, rounds, Doc{ .d = d, .hay = neutral }), neutral.len);

    var y: [2]f64 = undefined;
    var x: [2]f64 = undefined;
    for (skip_spacing, 0..) |every, i| {
        var hay = try probe.Hay.init(gpa, hay_len, 96, 0x9e3779b9);
        defer hay.deinit();
        const planted = hay.plant(needle, every);
        if (planted == 0) {
            try missing.append(gpa, "skip_verify (nothing planted)");
            return;
        }
        y[i] = clock.cycPerByte(probe.fastest(io, rounds, Doc{ .d = d, .hay = hay.bytes }), hay.bytes.len);
        x[i] = @as(f64, @floatFromInt(planted)) / @as(f64, @floatFromInt(hay.bytes.len));
    }
    cal.skip_verify = probe.separate(y, x).slope;
}

/// The two dearer walkers. Neither is selectable by a flag — a pattern reaches
/// the lazy DFA by outgrowing the eager budget and the Pike VM by having no
/// automaton at all — so each is probed by a pattern that lands there, and the
/// row is skipped rather than faked if none does.
fn walkers(
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: probe.Clock,
    rounds: usize,
    hay: []const u8,
    cal: *price.Calibration,
    missing: *std.ArrayList([]const u8),
) !void {
    // Lazy: a wide Unicode class the eager determinizer declines to enumerate.
    for ([_][]const u8{ "\\p{L}{8}[0-9]{8}", "\\p{Han}{4}[0-9]{4}", "\\w{64}[0-9]{64}" }) |pat| {
        var re = Regex.compileOpts(gpa, pat, .{ .unicode = true }) catch continue;
        defer re.deinit();
        if (re.lazy == null) continue;
        var sim = try Regex.Sim.init(gpa, &re);
        defer sim.deinit();
        if (sim.lazy == null) continue;
        const Ctx = LazyCtx(@TypeOf(sim.lazy.?));
        cal.lazy_step = clock.cycPerByte(
            probe.fastest(io, rounds, Ctx{ .c = &sim.lazy.?, .hay = hay }),
            hay.len,
        );
        break;
    } else try missing.append(gpa, "lazy_step (no probe reached the lazy DFA)");

    // Pike: assertion-bearing `-U` has no automaton to determinize, so the
    // whole-buffer scan IS the VM. That is the same walker a pattern falls to
    // when everything above declines, which is what the row has to price.
    var re = Regex.compileOpts(gpa, "^[a-z][0-9]wxy$", .{ .multiline = true }) catch {
        try missing.append(gpa, "pike_step (probe failed to compile)");
        return;
    };
    defer re.deinit();
    if (re.dfa != null or re.lazy != null) {
        try missing.append(gpa, "pike_step (probe kept an automaton)");
        return;
    }
    var sim = try Regex.Sim.init(gpa, &re);
    defer sim.deinit();
    cal.pike_step = clock.cycPerByte(probe.fastest(io, rounds, Pike{
        .re = &re,
        .sim = &sim,
        .hay = hay,
    }), hay.len);
}

/// The lazy DFA's per-thread memo, reached through `Sim` rather than named — the
/// engine's seal does not re-export the cache type, and a bench does not need it
/// to: the scratch that holds it knows what it is.
fn LazyCtx(comptime Cache: type) type {
    return struct {
        c: *Cache,
        hay: []const u8,
        pub fn run(self: @This()) ?bool {
            return self.c.docMatch(self.hay);
        }
    };
}

const Pike = struct {
    re: *const Regex,
    sim: *Regex.Sim,
    hay: []const u8,
    pub fn run(self: Pike) bool {
        return self.re.bufMatch(self.sim, self.hay);
    }
};

// ── the vector rungs ─────────────────────────────────────────────────────────

fn vectors(
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: probe.Clock,
    rounds: usize,
    hay: []const u8,
    cal: *price.Calibration,
    missing: *std.ArrayList([]const u8),
) !void {
    // Composition, on the three axes it prices: 16 lanes, 32 lanes, and the
    // end-of-line index. `compose_eol` is a DIFFERENCE at one width, because
    // that is what the model adds it as — measuring it against a wider machine
    // would fold the width in and charge it twice.
    var narrow: f64 = 0;
    for ([_][]const u8{ "[a-z][0-9]wxy", "[a-z]{2}[0-9]{2}w", "[a-z]{4}[0-9]" }) |pat| {
        const got = (try composeAt(gpa, io, clock, rounds, hay, pat, .lanes16, false)) orelse continue;
        narrow = got;
        cal.compose16 = got;
        break;
    } else try missing.append(gpa, "compose16 (no probe lowered to 16 lanes)");

    for ([_][]const u8{ "[a-z]{20}[0-9]", "[a-z]{24}[0-9]{2}", "[a-z]{28}[0-9]" }) |pat| {
        cal.compose32 = (try composeAt(gpa, io, clock, rounds, hay, pat, .lanes32, false)) orelse continue;
        break;
    } else try missing.append(gpa, "compose32 (no probe lowered to 32 lanes)");

    if (narrow > 0) {
        for ([_][]const u8{ "[a-z][0-9]wxy$", "[a-z]{2}[0-9]{2}w$", "^[a-z]{4}[0-9]$" }) |pat| {
            const eol = (try composeAt(gpa, io, clock, rounds, hay, pat, .lanes16, true)) orelse continue;
            cal.compose_eol = @max(eol - narrow, 0);
            break;
        } else try missing.append(gpa, "compose_eol (no 16-lane probe carried the index)");
    }

    // Parabix: one coefficient for the whole bit-parallel price, because the
    // program publishes its own op count. Dividing the measured per-byte cost
    // by ops-per-stripe-of-bytes is the only arithmetic here, and it is the
    // inverse of what the model does — so a mis-stated `stripeOps` shows up as
    // a drifting coefficient rather than as a silently wrong bid.
    for ([_][]const u8{ "[a-z]+[0-9]+wxy", "[a-z]+[0-9]+", "[a-y]+[0-9]+w" }) |pat| {
        const armed = switch (Parabix.compileOffer(gpa, pat, .{})) {
            .armed => |p| p,
            .declined => continue,
        };
        if (armed.economics.stripe_ops == 0) continue;
        const cyc = clock.cycPerByte(probe.fastest(io, rounds, Pbx{ .p = &armed, .hay = hay }), hay.len);
        cal.parabix_op = cyc * @as(f64, @floatFromInt(stripe_width)) /
            @as(f64, @floatFromInt(armed.economics.stripe_ops));
        break;
    } else try missing.append(gpa, "parabix_op (no probe armed the rung)");
}

fn composeAt(
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: probe.Clock,
    rounds: usize,
    hay: []const u8,
    pattern: []const u8,
    width: Width,
    eol: bool,
) !?f64 {
    var re = Regex.compileOpts(gpa, pattern, .{ .force_dfa = true }) catch return null;
    defer re.deinit();
    const d = re.dfa orelse return null;
    const cx = (try Compose.lower(gpa, d)) orelse return null;
    defer cx.deinit();
    if (cx.width != width or (cx.index == .byte_eol) != eol) return null;
    return clock.cycPerByte(probe.fastest(io, rounds, Cx{ .cx = cx, .hay = hay }), hay.len);
}

const Cx = struct {
    cx: *const Compose,
    hay: []const u8,
    pub fn run(self: Cx) bool {
        return self.cx.docMatch(self.hay);
    }
};

const Pbx = struct {
    p: *const Parabix,
    hay: []const u8,
    pub fn run(self: Pbx) bool {
        return self.p.match(self.hay);
    }
};

// ── the sieve ────────────────────────────────────────────────────────────────

/// Four kernels, four numbers: one and two conjuncts, per line and per
/// document. The ratio this replaced was one number for all four.
fn sieves(
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: probe.Clock,
    rounds: usize,
    hay: []const u8,
    rows: []const []const u8,
    cal: *price.Calibration,
    missing: *std.ArrayList([]const u8),
) !void {
    // Neither conjunct count is selectable: how many windows a pattern's lattice
    // harvests is a property of the pattern, so the slate has to be wide enough
    // that both kernels turn up. The second half of it is deliberately
    // multi-window in shape — two separated fixed-offset class runs, which is what
    // a two-quotient conjunction is made of.
    const probes = [_][]const u8{
        "[0-9]{4}-[0-9]{2}-[0-9]{2}",
        "[0-9]{3}\\.[0-9]{3}",
        "[a-f0-9]{8}-[a-f0-9]{4}",
        "[A-Z]{3}[0-9]{4}",
        "[0-9]{2}:[0-9]{2}:[0-9]{2}",
        "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}",
        "[A-Z]{2}[0-9]{4}-[a-f]{3}[0-9]{3}",
        "[0-9]{3}-[0-9]{2}-[0-9]{4}",
        "[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}",
        "[0-9]{2}/[0-9]{2}/[0-9]{4} [0-9]{2}:[0-9]{2}",
    };
    var seen: [2]bool = .{ false, false };
    for (probes) |pat| {
        var re = Regex.compileOpts(gpa, pat, .{ .force_dfa = true }) catch continue;
        defer re.deinit();
        const d = re.dfa orelse continue;
        const s = (try Sieve.build(gpa, d, .{}, .ungated)) orelse continue;
        defer s.deinit();
        if (s.n == 0 or s.n > 2 or seen[s.n - 1]) continue;
        seen[s.n - 1] = true;
        cal.sieve_line[s.n - 1] = clock.cycPerByte(
            probe.fastest(io, rounds, SvLine{ .s = s, .rows = rows }),
            hay.len - rows.len, // the line view drops one terminator per row
        );
        if (s.doc_ok) cal.sieve_doc[s.n - 1] = clock.cycPerByte(
            probe.fastest(io, rounds, SvDoc{ .s = s, .hay = hay }),
            hay.len,
        );
        if (seen[0] and seen[1]) break;
    }
    inline for (.{ 0, 1 }) |i| {
        if (cal.sieve_line[i] == 0) try missing.append(gpa, std.fmt.comptimePrint("sieve_line[{d}]", .{i}));
        if (cal.sieve_doc[i] == 0) try missing.append(gpa, std.fmt.comptimePrint("sieve_doc[{d}]", .{i}));
    }
}

const SvLine = struct {
    s: *const Sieve,
    rows: []const []const u8,
    pub fn run(self: SvLine) usize {
        var alive: usize = 0;
        for (self.rows) |ln| alive += @intFromBool(self.s.scan(ln) != .miss);
        return alive;
    }
};

const SvDoc = struct {
    s: *const Sieve,
    hay: []const u8,
    pub fn run(self: SvDoc) bool {
        return self.s.scanDoc(self.hay) != .miss;
    }
};

// ── the one-off build, which is the auction's tiebreak ───────────────────────

fn builds(
    gpa: std.mem.Allocator,
    io: std.Io,
    clock: probe.Clock,
    rounds: usize,
    cal: *price.Calibration,
    missing: *std.ArrayList([]const u8),
) !void {
    var re = Regex.compileOpts(gpa, "[a-z]{12}[0-9]{4}", .{ .force_dfa = true }) catch {
        try missing.append(gpa, "build_per_table_byte (probe failed to compile)");
        return;
    };
    defer re.deinit();
    if (re.dfa) |d| lower: {
        const sizing = (try Compose.lower(gpa, d)) orelse break :lower;
        const bytes = sizing.table.len;
        sizing.deinit();
        if (bytes == 0) break :lower;
        const ns = probe.fastest(io, rounds, Lower{ .gpa = gpa, .d = d });
        cal.build_per_table_byte = clock.cycles(ns) / @as(f64, @floatFromInt(bytes));
    } else try missing.append(gpa, "build_per_table_byte (no DFA)");

    for ([_][]const u8{ "[a-z]+[0-9]+wxy", "[a-z]+[0-9]+" }) |pat| {
        const armed = switch (Parabix.compileOffer(gpa, pat, .{})) {
            .armed => |p| p,
            .declined => continue,
        };
        if (armed.prog.ninstrs == 0) continue;
        const ns = probe.fastest(io, rounds, Offer{ .gpa = gpa, .pattern = pat });
        cal.build_per_instr = clock.cycles(ns) / @as(f64, @floatFromInt(armed.prog.ninstrs));
        break;
    } else try missing.append(gpa, "build_per_instr (no probe armed the rung)");
}

const Lower = struct {
    gpa: std.mem.Allocator,
    d: *const Dfa,
    pub fn run(self: Lower) usize {
        const cx = (Compose.lower(self.gpa, self.d) catch null) orelse return 0;
        defer cx.deinit();
        return cx.table.len;
    }
};

const Offer = struct {
    gpa: std.mem.Allocator,
    pattern: []const u8,
    pub fn run(self: Offer) usize {
        return switch (Parabix.compileOffer(self.gpa, self.pattern, .{})) {
            .armed => |p| p.prog.ninstrs,
            .declined => 0,
        };
    }
};

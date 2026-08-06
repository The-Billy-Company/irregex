//! The ladder's PRICE lane — the harness that makes `ladder/price.zig` a
//! measurement instead of a transcription.
//!
//! The auction in `ladder/rungs.zig` was always structurally real: each machine
//! that can represent a pattern publishes a cost, the cheapest wins, and the
//! fallback bids like everyone else. What was not real was the numbers. They were
//! literals lifted out of bench prose — `30_000` for any DFA, `4_400`/`8_000` for
//! composition, `9_000 + stripe_ops/8` for Parabix, `0.40 × a DFA` for the sieve
//! — and a literal cannot be re-measured, cannot be wrong in a way anything
//! notices, and cannot tell a nine-state automaton from a nine-thousand-state
//! one.
//!
//! So this lane does the two things prose cannot:
//!
//!   `mint`    — time every coefficient in isolation and print the calibration
//!               literal to paste into `price.zig`. Each row is one kernel run
//!               alone against a non-matching haystack, min-of-N, with the core
//!               clock measured in this same process.
//!   `verify`  — re-time them and fail when one has drifted outside its band.
//!               The ratchet that stops a number rotting in place.
//!   `regret`  — ignore the model. Run every machine each pattern admits, find
//!               the measured-fastest, and fail when the auction's pick is more
//!               than the allowed factor slower. Coefficients can each verify
//!               clean and still compose into a bad decision; this is the only
//!               check that would notice.
//!
//! Default (no argument) runs `verify` and `regret`, which together are the gate.
//! `mint` is deliberately not the default: minting is how a number gets INTO the
//! plane, and a step that silently re-mints what it is asked to judge is
//! laundering rather than gating.
//!
//! Everything is fail-closed and everything is cheap: one 8 MiB synthetic
//! haystack per probe, a handful of small patterns, no corpus load, no
//! multi-gigabyte table. The heaviest thing in here is the footprint sweep's
//! 1.4 MB determinization of `\p{L}{6}[0-9]{6}`, and the whole default gate is
//! under two seconds of wall clock.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");
const probe = @import("probe.zig");
const mint = @import("mint.zig");
const regret_mod = @import("regret.zig");
const pmu = @import("pmu");
const lanes = gist.regex.compose.lanes;

const price = gist.regex.price;
const rungs = gist.regex.rungs;

/// How far a re-timed coefficient may sit from the committed one before the
/// verify step calls it drift. Generous on purpose: this laptop routinely
/// carries ten coworker agents, and a band tight enough to catch a 5% modeling
/// error would fail on contention alone — which is the failure mode that gets a
/// gate switched off. Regret is what catches the errors that matter; this band
/// catches a number that has changed KIND.
const band: f64 = 0.45;

/// The regret ceiling. 1.00 is a perfect pick; anything under this is "the
/// auction chose a machine that is at worst this much slower than the best one
/// available", which is the property the price plane exists to provide.
const regret_ceiling: f64 = 1.25;

/// How much the footprint sweep may move the walk's step before the collapsed
/// single-`dfa_step` model stops being the honest one. Loose, because the point
/// is to catch a real cache cliff (2×, 3×) rather than the ±20% of automaton
/// shape and contention this host actually shows across a 19,000× range.
const knee: f64 = 1.60;

fn envSpan(key: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(key)) |v| std.mem.span(v) else null;
}

const Verb = enum { verify, mint, regret, all };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const verb: Verb = if (args.next()) |a|
        std.meta.stringToEnum(Verb, a) orelse {
            std.debug.print("usage: ladder-price [verify|mint|regret|all]\n", .{});
            return error.UnknownVerb;
        }
    else
        .all;

    // Nine, not five. Three coefficients are SEPARATIONS — a slope across two
    // measured points (`skip_verify`, `anchor_line`) — and a difference carries
    // both points' error, so the estimator each point is a minimum over has to be
    // tighter than it would for a row that is read directly. Nine rounds cost
    // about a second of wall clock in total; the whole slate still mints in
    // roughly 1.2 s, and the default gate adds regret for about 1.8 s.
    const rounds: usize = if (envSpan("PRICE_ROUNDS")) |r| std.fmt.parseInt(usize, r, 10) catch 9 else 9;

    // Before anything is timed. On a hybrid part the clock and the coefficients
    // must come off the same core class or the plane is scaled by whichever one
    // each happened to land on — 1.37× apart on the x86 box these are minted on.
    const pinned = pmu.requestPerformanceQos();

    const clock = probe.Clock.measure(io, 1_500_000) orelse {
        std.debug.print(
            \\ladder-price: no in-process cycle clock on this target ({s}).
            \\Every coefficient in the plane is cycles per byte, so nothing is
            \\minted or verified here — and that is why `price.unmeasured` withholds
            \\`measured`, which is what the vector rungs consult before bidding.
            \\
        , .{@tagName(builtin.cpu.arch)});
        return error.NoClock;
    };
    // The clock converges on its own sampling (see `assay.Cadence.measure`);
    // `rounds` is the coefficient probes' count and was printed here as if it
    // described the clock, which read as provenance the clock did not have.
    std.debug.print("core clock measured in-process: {d:.3} GHz · fastest core class {s}\n", .{
        clock.ghz(),
        if (pinned) "pinned" else "not pinned (uniform cores, or the host declined)",
    });
    std.debug.print("coefficient probes: min-of-{d}\n", .{rounds});
    std.debug.print("committed calibration: {s} (minted {s})\n\n", .{ price.active.machine, price.active.minted });

    // One instrument for the whole run: both verbs measure through the same
    // clock and the same round count, which is the property that lets a regret
    // row be compared with the coefficient it was minted from.
    const rig = probe.Rig{ .gpa = gpa, .io = io, .clock = clock, .rounds = rounds };

    var failures: usize = 0;
    if (verb != .regret) failures += try coefficients(rig, verb);
    if (verb != .mint) failures += try auction(rig);

    if (failures != 0) {
        std.debug.print("\nFAILED: {d} check(s).\n", .{failures});
        return error.PriceProofFailed;
    }
    std.debug.print("\nOK.\n", .{});
}

// ── coefficients: mint / verify ──────────────────────────────────────────────

fn coefficients(rig: probe.Rig, verb: Verb) !usize {
    var report = try mint.measure(rig);
    defer report.deinit(rig.gpa);

    // This sweep was built to fit a residency curve and refuted one instead. It
    // stays because that refutation is a standing claim about this host, and the
    // spread below is exactly what a host with real cache sensitivity would move.
    std.debug.print("── table footprint sweep (does a bigger table walk slower? measure, don't assume) ──\n", .{});
    std.debug.print("{s:<34} {s:>7} {s:>10} {s:>9}\n", .{ "pattern", "states", "table B", "cyc/B" });
    for (report.sweep) |p| std.debug.print("{s:<34} {d:>7} {d:>10} {d:>9.2}\n", .{
        p.pattern, p.states, p.table_bytes, p.cyc_per_byte,
    });
    const sp = mint.spread(report.sweep);
    std.debug.print(
        "  {d:.0}x footprint range moves the step {d:.2}x — {s}\n",
        .{ sp.footprint, sp.cost, if (sp.cost <= knee)
            "no knee, so one dfa_step is the honest model"
        else
            "!! a knee appeared: this host may need the residency axis back" },
    );

    std.debug.print("\n── coefficients ──\n", .{});
    std.debug.print("{s:<24} {s:>10} {s:>10} {s:>9}  {s}\n", .{ "coefficient", "measured", "committed", "drift", "unit" });

    var drifted: usize = 0;
    inline for (comptime std.meta.fieldNames(price.Calibration)) |name| {
        const T = @FieldType(price.Calibration, name);
        const got = @field(report.cal, name);
        const want = @field(price.active, name);
        switch (T) {
            f64 => drifted += row(name, got, want, unitOf(name)),
            usize => drifted += row(name, @floatFromInt(got), @floatFromInt(want), "bytes"),
            [2]f64 => inline for (0..2) |i| {
                drifted += row(name ++ "[" ++ .{'0' + @as(u8, i)} ++ "]", got[i], want[i], "cyc/B");
            },
            else => {}, // provenance strings and the measured flag are not quantities
        }
    }
    for (report.missing) |m| std.debug.print("  ~ unreachable on this host: {s}\n", .{m});

    if (verb == .mint) {
        try emit(rig.io, report.cal);
        return 0;
    }
    if (drifted != 0) std.debug.print(
        "\n{d} coefficient(s) outside ±{d:.0}%. Re-run `ladder-price mint` and commit the plane, or find what changed.\n",
        .{ drifted, band * 100 },
    );
    return drifted;
}

/// One coefficient row. Returns 1 when it is outside the band, so the caller's
/// tally is the sum of the rows rather than a separate pass over them.
fn row(name: []const u8, got: f64, want: f64, unit: []const u8) usize {
    // A measurement of zero is a probe that did not run, not a free kernel; it
    // is reported in `missing` and cannot fail the band (there is nothing to
    // compare). A committed zero is an unported target, same reasoning.
    const comparable = got > 0 and want > 0;
    const drift = if (comparable) (got - want) / want else 0;
    const bad = comparable and @abs(drift) > band;
    var pct: [12]u8 = undefined;
    const shown = if (comparable)
        std.fmt.bufPrint(&pct, "{d:.0}%", .{drift * 100}) catch "?"
    else
        "-";
    std.debug.print("{s:<24} {d:>10.3} {d:>10.3} {s:>9}  {s}\n", .{ name, got, want, shown, unit });
    if (bad) std.debug.print("  !! {s} drifted {d:.0}% — the plane's number is not this machine's\n", .{ name, drift * 100 });
    return @intFromBool(bad);
}

/// What a coefficient is a quantity of. Derived from the name so a new field
/// cannot arrive without one, and so the table reads as measurements rather than
/// as a column of bare floats.
fn unitOf(comptime name: []const u8) []const u8 {
    if (comptime std.mem.eql(u8, name, "skip_verify")) return "cyc/candidate";
    if (comptime std.mem.eql(u8, name, "anchor_line")) return "cyc/line";
    if (comptime std.mem.startsWith(u8, name, "build_")) return "cyc/unit built";
    return "cyc/B";
}

/// The calibration literal, ready to paste. Generated from the same struct the
/// plane declares, so a field added there appears here without an edit.
fn emit(io: std.Io, cal: price.Calibration) !void {
    var brand: [128]u8 = undefined;
    const machine = hostName(&brand);
    std.debug.print("\n── paste into ladder/price.zig ──\n\n", .{});
    std.debug.print("pub const {s}: Calibration = .{{\n", .{planeName()});
    std.debug.print("    .machine = \"{s}\",\n", .{machine});
    std.debug.print("    .minted = \"{s}\",\n", .{today(io)});
    // WHICH build these numbers speak for, in the spelling `Calibration.fitsBuild`
    // matches on. Emitted rather than left to the paster because it is not a
    // judgment: the class is a fact about the binary that just did the timing,
    // and reading it off `lanes.isa` is the only way it cannot be mistyped into
    // a row that then prices a permute nobody measured.
    std.debug.print("    .isa = .{s},\n", .{@tagName(lanes.isa)});
    inline for (comptime std.meta.fieldNames(price.Calibration)) |name| {
        const v = @field(cal, name);
        switch (@FieldType(price.Calibration, name)) {
            f64 => std.debug.print("    .{s} = {d:.3},\n", .{ name, v }),
            usize => std.debug.print("    .{s} = {d},\n", .{ name, v }),
            [2]f64 => std.debug.print("    .{s} = .{{ {d:.3}, {d:.3} }},\n", .{ name, v[0], v[1] }),
            else => {},
        }
    }
    std.debug.print("}};\n", .{});
}

/// What to call the row this run produces: its permute class, which is the same
/// name `fitsBuild` selects on — so re-minting at a given ISA floor replaces the
/// row it replaced last time, and minting at a NEW floor adds one rather than
/// overwriting a neighbor.
///
/// It read the core's model name, and before that
/// `switch (builtin.cpu.arch) { .aarch64 => "apple_arm64", … }`, so a mint run
/// on Graviton emitted a row named for Apple silicon carrying Graviton's
/// numbers, and pasting it would have overwritten the Apple measurement rather
/// than added a second one.
fn planeName() []const u8 {
    return @tagName(lanes.isa);
}

fn hostName(buf: []u8) []const u8 {
    const target = .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) };
    // The silicon's own name, when the OS will say it. Arch-and-OS alone would
    // let two very different cores commit under one label, and the whole point of
    // the field is that a reader can tell whether these numbers are theirs.
    var brand: [96]u8 = undefined;
    if (comptime builtin.os.tag.isDarwin()) {
        var len: usize = brand.len;
        if (std.c.sysctlbyname("machdep.cpu.brand_string", &brand, &len, null, 0) == 0 and len > 1) {
            const name = std.mem.sliceTo(brand[0 .. len - 1], 0);
            return std.fmt.bufPrint(buf, "{s} ({s}-{s})", .{name} ++ target) catch "unknown";
        }
    }
    return std.fmt.bufPrint(buf, "{s}-{s}", target) catch "unknown";
}

/// The mint date, so a committed number carries when it was true. Static
/// storage, because the caller prints it and a stack buffer would be gone.
var stamp: [11]u8 = undefined;
fn today(io: std.Io) []const u8 {
    const ns: i128 = @intCast(std.Io.Clock.now(.real, io).nanoseconds);
    const day = std.time.epoch.EpochDay{ .day = @intCast(@divFloor(ns, std.time.ns_per_day)) };
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(&stamp, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
    }) catch "-";
}

// ── the auction: regret ──────────────────────────────────────────────────────

fn auction(rig: probe.Rig) !usize {
    var hay = try rig.hay(8 << 20, 96, 0x517cc1b7);
    defer hay.deinit();

    std.debug.print("\n── regret: did the auction pick the measured-fastest machine? ──\n", .{});
    std.debug.print("{s:<24}", .{"pattern"});
    inline for (arm_columns) |k| std.debug.print(" {s:>9}", .{@tagName(k)});
    std.debug.print("  {s:<9} {s:<9} {s:>7}\n", .{ "chose", "fastest", "regret" });

    var bad: usize = 0;
    var worst: f64 = 1;
    for (regret_mod.slate) |pattern| {
        const v = (try regret_mod.judge(rig, hay.bytes, pattern)) orelse {
            std.debug.print("{s:<24} {s:>9}  no timeable arm\n", .{ pattern, "-" });
            continue;
        };
        std.debug.print("{s:<24}", .{pattern});
        inline for (arm_columns) |k| std.debug.print(" {s:>9}", .{cell(v.arm(k))});
        std.debug.print("  {s:<9} {s:<9} {d:>6.2}x\n", .{
            @tagName(v.chose),
            @tagName(v.best),
            v.regret,
        });
        worst = @max(worst, v.regret);
        if (v.regret > regret_ceiling) {
            std.debug.print("  !! took {s} where {s} measured {d:.2}× faster\n", .{
                @tagName(v.chose), @tagName(v.best), v.regret,
            });
            bad += 1;
        }
    }
    std.debug.print("\nworst regret: {d:.2}x (ceiling {d:.2}x)\n", .{ worst, regret_ceiling });
    return bad;
}

/// One column per machine the ladder can name, taken from the enum rather than
/// listed — so a machine added to `Selection` appears in this table instead of
/// being judged in silence off the side of it. That is not hypothetical: the
/// `settled` outcome arrived exactly this way.
const arm_columns = std.enums.values(rungs.Selection);

/// A per-arm cell, `measured/bid` — the two numbers side by side, because a row
/// where they disagree wildly but the ORDER survives is the interesting case:
/// the model is mis-scaled and the auction is still right.
var cell_buf: [40]u8 = undefined;
fn cell(a: ?regret_mod.Arm) []const u8 {
    const x = a orelse return "-";
    return std.fmt.bufPrint(&cell_buf, "{d:.2}/{d:.2}", .{ x.measured, x.bid }) catch "?";
}

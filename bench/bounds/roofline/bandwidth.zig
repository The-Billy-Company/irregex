//! gist bench — `roofline`: Layer C of the performance certificate. A STREAM-style
//! (McCalpin 1995) single-thread **read-bandwidth** microbenchmark that measures
//! the achievable memory bandwidth of THIS machine at three working-set tiers —
//! L1-, L2-, and DRAM-resident — exposing the cache hierarchy. gist's verify path
//! is then measured through a matched ladder: the same dual-window load/compare
//! shape on one contiguous DRAM buffer, production `simd.contains` on that buffer,
//! and production over the fragmented corpus. The roofline model (Williams,
//! Waterman & Patterson, CACM 2009) supplies an upper bound; the ladder explains
//! the distance to it instead of pretending that a sub-ceiling point saturates it.
//!
//! Zero-dep, mirroring gist's discipline: a plain vectorized sum-reduction over
//! an aligned buffer, kept live through a global `sink` to defeat DCE (as
//! certify.zig does), timed with `std.Io.Clock`. Single-threaded on purpose —
//! certify's verify kernel is single-threaded, so the honest ceiling is the
//! per-core achievable bandwidth, not the chip's aggregate.
//!
//! ## Recorded defects — assertions this file made that were false (2026-07-29)
//!
//! For a year the ladder was INVERTED: the "matched dual-window control" that
//! is supposed to upper-bound production measured 47.5 GB/s where production
//! contiguous measured 53.0 (aarch64), and 16.8 vs 16.9 on x86_64. A control
//! cannot be below the thing it bounds, so the ladder explained nothing, and
//! the headroom it published was a comparison between two unrelated kernels.
//! Four false assertions, all of them this file describing production from
//! memory instead of reading it:
//!
//!   1. "The control's stride is production's stride." It was not.
//!      `suggestVectorLength(u8) orelse 16` is 16 bytes on NEON; production
//!      runs `@max(vlen, 64)`. The control paid 4× the loop overhead per byte.
//!      Fixed: stride is `simd.block_bytes`.
//!   2. "First+last bytes are the anchors." They are not, and have not been
//!      since the rarity table landed. Production picks the two rarest bytes
//!      by corpus density, so on the absent needle the control filtered on a
//!      byte production never touches. Fixed: `simd.anchorsOf`.
//!   3. "A movemask per block is what the gate costs." It is not. Production
//!      gates on `anyLane`, whose whole reason to exist is that the movemask
//!      emulation is multi-µop on NEON. Fixed: `simd.anyLane`.
//!   4. "Production always runs two loads per block." It does not. A
//!      rare-anchored needle — including this file's own absent needle — takes
//!      the single-probe loop, which is 1.42× the dual shape (measured under
//!      layout randomization). An unconditionally-dual control therefore
//!      bounds a path production never runs. Fixed: `simd.singleProbeEligible`.
//!
//! The denominator was wrong too: every rung was divided by a 512 MiB
//! uniform-random buffer, folding kernel, working-set size, and byte content
//! into one "headroom" figure. The ladder now runs on a corpus-sized buffer of
//! corpus bytes with its own STREAM roof at that size, so consecutive rungs
//! differ by exactly one thing. The 512 MiB tier stays, as what it always
//! actually was: a cache-hierarchy datum, not a scan denominator.
//!
//! ## Recorded defect — the absent needle was not absent (2026-08-01)
//!
//! The "absent" needle was the source literal `Zq9_gist_roofline_absent_needle_`,
//! and the corpus root defaults to the package itself — so THIS FILE was one of
//! the corpus documents, its literal was tiled into the contiguous buffer, and
//! `simd.contains` early-exited on the benchmark's own source instead of
//! streaming. "production contiguous" published ~3,029 GB/s: roughly 30× the
//! same run's measured 102 GB/s STREAM roof, i.e. an early return timed as a
//! memory sweep. `measureGistScan`'s "0 matches, pure streaming" row carried
//! the milder form of the same lie — one of 861 documents matched, so the
//! number was near-right but the label was false.
//!
//! Choosing a different literal only postpones the collision to the next edit
//! of this file, so the needle is no longer written down at all: `absentNeedle`
//! derives it from the bytes about to be scanned, as a run of one byte value
//! longer than that value's longest run anywhere in them. A run of length N
//! cannot contain a run of length N+1, so absence is a property of the corpus
//! rather than of this file's spelling, and no future edit to any source file
//! can make the needle present. The run additionally fails closed against
//! `simd.contains` before it is used, because an instrument that cannot tell
//! an early return from a memory sweep must refuse to publish.
//! Frequency is needed only for the *derived* cycles/byte ceiling; the GB/s
//! ceiling is bytes/ns and needs no clock at all. It is measured through
//! `pmu.Meter`, which tries kperf (root) and then the unprivileged per-thread
//! counters. Never fails the run (pmu.zig's discipline): no counter tier ⇒ the
//! GB/s ceilings publish and the cycles/byte ceilings do not exist.
//!
//! RECORDED DEFECT (2026-08-01): `dram_cyc_per_byte_ceiling` and
//! `l2_cyc_per_byte_ceiling` used to be emitted unconditionally, computed from a
//! hardcoded 4.4 GHz whenever no counter tier opened — an assumption published
//! under a field name that reads as a measurement, beside a `ghz_source` sibling
//! saying "assumed" that consumers were free to ignore. Divided by an assumed
//! clock those two fields are the GB/s ceiling in different units times a guess,
//! and their only honest reader is a comparison against Layer A's *measured*
//! cycles/byte — which only exists when a counter tier opened, in which case the
//! clock is measured too. So they are now behind `Clock.cycPerByte`, which
//! returns null on an assumed clock, and the artifact carries no top-level `ghz`
//! for another consumer to divide by. An assumption can no longer mint a
//! cycles/byte figure anywhere in Layer C.
//!
//! The artifact also records `meter` — the tiers `pmu.zig` actually tried — so a
//! run that reports no clock says which backend refused. Without it, a *stale
//! binary* built before a counter tier existed publishes "no PMU" on a host
//! whose counters work, and the receipt cannot tell that apart from a host that
//! genuinely has none.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");
const pmu = @import("pmu"); // bench/apparatus/harness/pmu.zig, wired as a module in build.zig

const corpus_mod = gist.corpus;
const simd = gist.scan.simd;
// `ArtifactPath`, not the comptime `default_out_dir`: `report.py --out-dir`
// reads this JSON out of the bundle the mint is assembling (GIST_DIR), so a
// baked-in `./.gist` would splice Layer C from an older roofline than the one
// this run just measured.
const json_path = gist.index.home.ArtifactPath("roofline.json");
const Span = gist.assay.Span; // package instrumentation floor: monotonic Span

// 8×u64 = 64-byte logical vector (lowered to NEON 128-bit loads on aarch64);
// NACC independent accumulators hide load-use latency so the loop is bound by
// load-port / cache bandwidth, not by the dependency chain.
const V = 8;
const NACC = 8;
const STEP = NACC * V; // u64 words consumed per inner iteration (512 B)
const Vu = @Vector(V, u64);

// Geometry is READ FROM PRODUCTION, never re-derived here. See the RECORDED
// DEFECTS in the header: every one of them was this file declaring its own.
const scan_vlen: usize = simd.block_bytes;
const ScanVec = @Vector(scan_vlen, u8);

// Best-of-N: interference from ~10 coworking agents on this shared box only ever
// *slows* a trial, so the max GB/s across trials is the cleanest estimate of the
// true achievable ceiling (min-of-N time). Median is kept for context.
const trials = 9;
const traffic_budget = 2 << 30; // ~2 GiB of reads per trial, per tier

/// Stand-in core clock when no counter tier opens (Apple M4 Max P-core sustained
/// boost, ~4.4 GHz). It is printed to the terminal so an operator can see what a
/// missing clock would have cost, and it reaches nothing else: `Clock.measured`
/// is false, so no derived figure and no artifact field is computed from it.
const assumed_ghz = 4.4;

/// Whether this build can measure memory bandwidth at all.
///
/// RECORDED DEFECT (2026-08-01): this rung's build posture is `.asked`, so it
/// compiles at the caller's `-Doptimize`, which Zig defaults to Debug — and
/// every documented invocation was a bare `zig build roofline`. In Debug the
/// reduction is neither unrolled nor vectorized, so all three tiers report the
/// same scalar issue rate instead of their cache level. The artifact on disk
/// read L1 8.0 · L2 8.4 · DRAM 8.3 GB/s: a flat "hierarchy", L1 *slower* than
/// L2, and every figure ~12x under the ReleaseFast roof this same host records
/// in the README. It was well-formed JSON with a measured clock, so the derived
/// cycles/byte inherited the defect honestly and looked like a result.
///
/// Nothing in the numbers says which build produced them, so the build mode is
/// the guard. `bench/README.md` has always said to build ReleaseFast; a
/// standing instruction that only the docs enforce is exactly the shape this
/// audit is closing, so the rung now refuses instead of publishing. Debug and
/// ReleaseSmall both suppress the vectorization the kernel is built around;
/// ReleaseSafe keeps bounds checks but still vectorizes, so it measures memory.
const measurable = measurableIn(builtin.mode);

fn measurableIn(mode: std.builtin.OptimizeMode) bool {
    return switch (mode) {
        .Debug, .ReleaseSmall => false,
        .ReleaseSafe, .ReleaseFast => true,
    };
}

var sink: u64 = 0; // defeat DCE of the measured reduction

/// The measured kernel: a pure streaming read reduction over `buf`. Returns the
/// checksum (kept live via `sink`) so the optimizer can't elide the loads.
fn streamSum(buf: []const u64) u64 {
    var acc: [NACC]Vu = undefined;
    inline for (&acc) |*a| a.* = @splat(0);

    var i: usize = 0;
    while (i + STEP <= buf.len) : (i += STEP) {
        inline for (0..NACC) |k| {
            const v: Vu = buf[i + k * V ..][0..V].*;
            acc[k] +%= v;
        }
    }
    var total: Vu = @splat(0);
    inline for (0..NACC) |k| total +%= acc[k];
    var s: u64 = @reduce(.Add, total);
    while (i < buf.len) : (i += 1) s +%= buf[i]; // tail
    return s;
}

const Tier = struct {
    name: []const u8,
    bytes: usize,
    gbps_max: f64,
    gbps_median: f64,
};

const Stage = struct {
    name: []const u8,
    gbps_max: f64,
    gbps_median: f64,
};

/// Read-bandwidth of one working-set size: sweep `buf` enough times to move
/// ~`traffic_budget` bytes per trial, take the fastest of `trials` (best = least
/// contended). GB/s = bytes moved ÷ ns (1 GB/s ≡ 1 byte/ns).
fn measureTier(io: std.Io, name: []const u8, buf: []u64) Tier {
    const buf_bytes = buf.len * @sizeOf(u64);
    const sweeps: usize = @max(traffic_budget / buf_bytes, 1);
    const moved: f64 = @floatFromInt(buf_bytes * sweeps);

    var samples: [trials]f64 = undefined; // GB/s per trial
    for (0..trials) |t| {
        // Warm the buffer into its target cache level before timing.
        sink +%= streamSum(buf);
        const sp = Span.open(io);
        var acc: u64 = 0;
        for (0..sweeps) |_| acc +%= streamSum(buf);
        const ns: f64 = @floatFromInt(@max(sp.read(io).ns(), 1));
        sink +%= acc;
        samples[t] = moved / ns; // bytes/ns == GB/s
    }
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    return .{
        .name = name,
        .bytes = buf_bytes,
        .gbps_max = samples[trials - 1],
        .gbps_median = samples[trials / 2],
    };
}

/// The matched control: production's streaming gate with candidate
/// verification and per-document dispatch removed, and NOTHING else changed.
/// Stride, anchors, block gate, and single-probe promotion all come from
/// `simd`'s published surface, so this cannot silently become a different
/// kernel again. Its gap from STREAM is the gate's own instruction and
/// load-port cost; the next rung adds verify, the last adds corpus shape.
///
/// The one thing it does NOT replicate is the mid-buffer demotion guard: the
/// guard exists to protect `verifyBlock` from a mispredicting probe, and there
/// is no verify here to protect. On a needle production demotes, this control
/// therefore reads as an optimistic bound rather than a matched one — which is
/// the honest direction for a control to err.
fn gateOnly(buf: []const u8, needle: []const u8) usize {
    const a = simd.anchorsOf(needle);
    const p1: ScanVec = @splat(needle[a.probe]);
    const p2: ScanVec = @splat(needle[a.confirm]);
    const last_off = needle.len - 1;
    const single = simd.singleProbeEligible(needle);
    var survivors: usize = 0;
    var i: usize = 0;
    while (i + last_off + scan_vlen <= buf.len) : (i += scan_vlen) {
        simd.streamAhead(buf, i);
        const eq1 = @as(ScanVec, buf[i + a.probe ..][0..scan_vlen].*) == p1;
        if (single and !simd.anyLane(eq1)) continue;
        const eq = eq1 & (@as(ScanVec, buf[i + a.confirm ..][0..scan_vlen].*) == p2);
        if (!simd.anyLane(eq)) continue;
        survivors +%= 1;
    }
    return survivors;
}

fn measureContiguous(io: std.Io, name: []const u8, buf: []const u8, needle: []const u8, comptime matched: bool) Stage {
    const sweeps: usize = @max(traffic_budget / buf.len, 1);
    const moved: f64 = @floatFromInt(buf.len * sweeps);
    var samples: [trials]f64 = undefined;
    for (0..trials) |t| {
        var result: usize = 0;
        const sp = Span.open(io);
        for (0..sweeps) |_| {
            if (matched) {
                result +%= gateOnly(buf, needle);
            } else {
                result +%= @intFromBool(simd.contains(buf, needle));
            }
        }
        const ns: f64 = @floatFromInt(@max(sp.read(io).ns(), 1));
        sink +%= result;
        samples[t] = moved / ns;
    }
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    return .{ .name = name, .gbps_max = samples[trials - 1], .gbps_median = samples[trials / 2] };
}

/// The clock the *derived* cycles/byte ceilings are divided by, and whether this
/// host produced it. Nothing reads `ghz` directly: the one conversion out of GB/s
/// goes through `cycPerByte`, which declines on an assumed clock, so a cycles/byte
/// figure cannot be built from a guess by any caller — present or future.
const Clock = struct {
    ghz: f64,
    source: []const u8,
    /// The tiers `pmu.Meter` tried, verbatim. Travels into the artifact so a
    /// missing clock names the backend that refused it.
    meter: []const u8,
    measured: bool,

    /// cycles/byte ceiling = cycles/ns ÷ bytes/ns = GHz ÷ GB/s — the floor no
    /// single-thread kernel can beat, since it would have to read faster than
    /// memory. `null` unless the clock was measured here: over an assumed clock
    /// this is the GB/s ceiling in different units multiplied by a guess, and its
    /// only honest reader is a comparison against Layer A's *measured* per-class
    /// cycles/byte, which exists only when a counter tier opened.
    fn cycPerByte(self: Clock, gbps: f64) ?f64 {
        return if (self.measured and gbps > 0) self.ghz / gbps else null;
    }
};

/// Effective core clock (GHz) via the PMU: stream the DRAM buffer once with the
/// cycle counter live, GHz = Δcycles ÷ Δns — the honest frequency *under memory
/// load*, which is exactly the regime the memory ceiling describes. Falls back to
/// the assumed clock when no PMU tier opened (not macOS, or both refused).
///
/// `source` names the tier that produced the number rather than a fixed backend:
/// the unprivileged `thread_selfcounts` reading is a real measured clock, and it
/// is not kperf's.
fn measureGhz(io: std.Io, meter: *pmu.Meter, buf: []u64) Clock {
    if (!meter.has_pmu) return .{ .ghz = assumed_ghz, .source = "assumed (no PMU — no cycle counter opened)", .meter = meter.note, .measured = false };
    const c0 = meter.counters();
    const sp = Span.open(io);
    var acc: u64 = 0;
    for (0..64) |_| acc +%= streamSum(buf);
    const ns: f64 = @floatFromInt(@max(sp.read(io).ns(), 1));
    const c1 = meter.counters();
    sink +%= acc;
    const cycles: f64 = @floatFromInt(c1.cycles -% c0.cycles);
    if (cycles <= 0) return .{ .ghz = assumed_ghz, .source = "assumed (PMU returned no cycles)", .meter = meter.note, .measured = false };
    // One arm per tier `pmu.Kind` can report, exhaustive on purpose: a new
    // backend must decide how it wants to be named in a certificate rather than
    // inherit a neighbour's name. (`.none` is unreachable behind the `has_pmu`
    // guard above, but it is a real enum value and naming it is free.)
    return .{ .ghz = cycles / ns, .meter = meter.note, .measured = true, .source = switch (meter.kind()) {
        .kperf => "measured (kperf, cycles ÷ ns under memory load)",
        .thsc => "measured (thread_selfcounts, cycles ÷ ns under memory load)",
        .perf => "measured (perf_event_open, cycles ÷ ns under memory load)",
        .qtct => "measured (QueryThreadCycleTime, cycles ÷ ns under memory load)",
        .none => "measured (PMU, cycles ÷ ns under memory load)",
    } };
}

const ScanResult = struct {
    needle: []const u8,
    /// Printable spelling of `needle` for the terminal and the artifact. The
    /// absent arm's needle is a run of one byte value picked out of the corpus
    /// at run time and is not printable; nothing downstream ever needs the
    /// bytes, only which needle a row was measured with.
    label: []const u8,
    kind: []const u8,
    gbps: f64,
};

// Row 0's needle forces a full scan of every byte (no early exit, no verify) —
// the clean streaming point — and is filled in by `absentNeedle` once the
// corpus is loaded. It is deliberately EMPTY here: a literal in this file is a
// literal in the corpus, which is exactly the 2026-08-01 recorded defect. The
// realistic ones show early-exit + verification.
const scan_needles = [_]ScanResult{
    .{ .needle = "", .label = "", .kind = "full-scan (0 matches, pure streaming)", .gbps = 0 },
    .{ .needle = "func", .label = "func", .kind = "with matches (early-exit + verify)", .gbps = 0 },
    .{ .needle = "})", .label = "})", .kind = "with matches (early-exit + verify)", .gbps = 0 },
};

/// Length of the absent arm's needle, held at the historical 32 bytes so the
/// arm stays comparable across mints.
const absent_len = 32;

/// Longest run of each byte value in `p`, folded into `run`.
fn tallyRuns(longest: *[256]usize, p: []const u8) void {
    var i: usize = 0;
    while (i < p.len) {
        const b = p[i];
        var j = i + 1;
        while (j < p.len and p[j] == b) j += 1;
        longest[b] = @max(longest[b], j - i);
        i = j;
    }
}

/// A needle that CANNOT occur in `first` or in any of `rest`, derived from
/// their bytes rather than written down — see the 2026-08-01 recorded defect.
///
/// Returns `absent_len` copies of the byte value with the shortest longest-run
/// across those bytes. A run of length N contains no run of length N+1, so the
/// needle's absence is a property of what is being scanned; it holds for the
/// contiguous buffer and for every individual document, and no edit to any
/// source file can make it present. Errors rather than degrading if all 256
/// values already carry an `absent_len`-long run, which no text corpus does.
fn absentNeedle(out: *[absent_len]u8, first: []const u8, rest: []const []const u8) ![]const u8 {
    var longest = [_]usize{0} ** 256;
    tallyRuns(&longest, first);
    for (rest) |p| tallyRuns(&longest, p);

    var pick: usize = 0;
    for (1..256) |b| {
        if (longest[b] < longest[pick]) pick = b;
    }
    if (longest[pick] >= absent_len) return error.NoAbsentNeedle;
    @memset(out, @intCast(pick));
    return out;
}

/// gist's real SIMD substring scan (`scan/simd.zig` `contains`) streamed over the
/// RAM-resident corpus — the **clean** roofline operating point. With an absent
/// needle it reads every byte (no early exit, no verification), so corpus_bytes ÷
/// ns is gist's true streaming bandwidth, directly comparable to the STREAM
/// ceiling. (certify.csv's per-class bytes÷ns conflates early-exit + false-positive
/// verification, so it is *not* a clean bandwidth — the report flags that.)
fn measureGistScan(io: std.Io, corpus: *const corpus_mod.Corpus, needle: []const u8) f64 {
    const bytes: f64 = @floatFromInt(corpus.bytes);
    var best: f64 = 0;
    for (0..trials) |_| {
        var hits: usize = 0;
        const sp = Span.open(io);
        for (corpus.docs) |d| if (simd.contains(d, needle)) {
            hits += 1;
        };
        const ns: f64 = @floatFromInt(@max(sp.read(io).ns(), 1));
        sink +%= hits;
        best = @max(best, bytes / ns);
    }
    return best;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}

pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    // Refuse before spending a single trial: an unoptimized build measures its
    // own codegen, not the memory system, and there is no way to tell the two
    // apart once the numbers are JSON. See `measurable`.
    if (!measurable) {
        std.debug.print(
            \\gist roofline: refusing to run in a {s} build.
            \\
            \\  The kernel's unrolled vector reduction is what makes this a bandwidth
            \\  probe; unoptimized it degrades to a scalar loop, every tier reports the
            \\  same issue rate, and the artifact looks like a measured hierarchy.
            \\
            \\  Run: zig build -Doptimize=ReleaseFast roofline
            \\
        , .{@tagName(builtin.mode)});
        return error.UnoptimizedBuild;
    }

    // Three tiers sized to land in distinct levels of the M-series hierarchy:
    // L1 (128 KiB P-core L1D) · L2 (16 MiB shared per P-cluster) · DRAM (beyond
    // the system-level cache). Sizes are rounded to whole STEP strides.
    const sizes = [_]struct { name: []const u8, bytes: usize }{
        .{ .name = "L1", .bytes = 16 << 10 }, // 16 KiB — deep inside L1D
        .{ .name = "L2", .bytes = 3 << 20 }, // 3 MiB — past L1, inside L2
        .{ .name = "DRAM", .bytes = 512 << 20 }, // 512 MiB — well past any cache
    };

    var meter = pmu.Meter.init();
    defer meter.deinit();

    std.debug.print("gist roofline · Layer C (measured headroom) · abi v{d}\n", .{gist.abi()});
    std.debug.print("machine: {s} · zig {s}\n", .{ @tagName(builtin.target.cpu.arch), builtin.zig_version_string });
    std.debug.print("meter:   {s}\n", .{meter.note});
    std.debug.print("method:  single-thread STREAM read reduction · best-of-{d} · ~{d} MiB/trial\n\n", .{ trials, traffic_budget >> 20 });

    std.debug.print("{s:<6} {s:>12} {s:>14} {s:>14}\n", .{ "tier", "working set", "read GB/s", "median GB/s" });
    std.debug.print("{s:-<6} {s:->12} {s:->14} {s:->14}\n", .{ "", "", "", "" });

    var tiers: [sizes.len]Tier = undefined;
    var dram_buf: []u64 = &.{};
    for (sizes, 0..) |s, i| {
        const words = (s.bytes / @sizeOf(u64) / STEP) * STEP;
        const buf = try gpa.alignedAlloc(u64, comptime .fromByteUnits(64), words);
        for (buf, 0..) |*x, k| x.* = k *% 0x9E3779B97F4A7C15; // non-zero, non-trivial
        tiers[i] = measureTier(io, s.name, buf);
        std.debug.print("{s:<6} {d:>9} KiB {d:>12.1}   {d:>12.1}\n", .{
            tiers[i].name, tiers[i].bytes >> 10, tiers[i].gbps_max, tiers[i].gbps_median,
        });
        if (i == sizes.len - 1) dram_buf = buf else gpa.free(buf);
    }

    const clk = measureGhz(io, &meter, dram_buf);
    const dram = tiers[sizes.len - 1];
    const l2 = tiers[1];

    // Fail-closed instrument check, in the same spirit as the absent needle
    // below: a 16 KiB working set that streams no faster than a 512 MiB one has
    // not resolved a cache hierarchy, so whatever this run measured, it was not
    // memory. No threshold to argue about — L1 read bandwidth exceeds DRAM read
    // bandwidth on every machine that has both, and best-of-9 leaves no room
    // for an inversion. The Debug artifact this guard was written against
    // reported L1 8.0 against DRAM 8.3.
    if (tiers[0].gbps_max <= dram.gbps_max) {
        std.debug.print(
            \\
            \\gist roofline: refusing to publish — the tier ladder did not resolve.
            \\  L1 ({d:.1} GB/s) is not faster than DRAM ({d:.1} GB/s), so these
            \\  figures describe something other than the memory hierarchy.
            \\
        , .{ tiers[0].gbps_max, dram.gbps_max });
        return error.HierarchyUnresolved;
    }

    std.debug.print("\nclock:   {d:.3} GHz · {s}\n", .{ clk.ghz, clk.source });
    std.debug.print("ceiling: DRAM {d:.1} GB/s · L2 {d:.1} GB/s\n", .{ dram.gbps_max, l2.gbps_max });
    // The cycles/byte restatement of those two ceilings exists only when this
    // host measured its own clock. Under the stand-in it is withheld from the
    // terminal for the same reason it is withheld from the artifact.
    if (clk.cycPerByte(dram.gbps_max)) |d| {
        std.debug.print("         = {d:.4} cyc/byte DRAM · {d:.4} cyc/byte L2 (derived, GHz ÷ GB/s)\n", .{ d, clk.cycPerByte(l2.gbps_max).? });
    } else {
        std.debug.print("         cyc/byte withheld — clock not measured here ({s})\n", .{clk.meter});
    }

    gpa.free(dram_buf); // the hierarchy table and the clock are done with it

    // The ladder's own denominator. RECORDED DEFECT (2026-07-29): every rung
    // used to be divided by the 512 MiB uniform-random DRAM tier above, so the
    // reported headroom folded THREE differences into one number — kernel,
    // buffer size, and buffer content. A corpus-sized buffer of corpus bytes,
    // with its own STREAM roof measured at that exact size, leaves only the
    // kernel varying between the roof and the contiguous rungs, and only
    // fragmentation between the contiguous rungs and the corpus rung.
    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try corpus_mod.load(gpa, io, roots, .contiguous);
    defer corpus.deinit();
    const corpus_mib = @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20);

    const flat_words = (corpus.bytes / @sizeOf(u64) / STEP) * STEP;
    const flat_buf = try gpa.alignedAlloc(u64, comptime .fromByteUnits(64), flat_words);
    defer gpa.free(flat_buf);
    const flat = std.mem.sliceAsBytes(flat_buf);
    // Tile the corpus's own bytes across the buffer. Docs cycle rather than
    // being truncated, so the byte statistics the scan sees here are the
    // corpus's, not a uniform-random buffer's — the anchor bytes' real density
    // is the whole reason production and the control diverge from STREAM.
    if (corpus.bytes == 0) return error.EmptyCorpus; // else the tiling can't advance
    {
        var w: usize = 0;
        while (w < flat.len) for (corpus.docs) |d| {
            const take = @min(d.len, flat.len - w);
            @memcpy(flat[w..][0..take], d[0..take]);
            w += take;
            if (w == flat.len) break;
        };
    }
    const roof = measureTier(io, "corpus-sized STREAM", flat_buf);

    // Derived, not written down, and then checked against the very kernel whose
    // early exit produced the 2026-08-01 defect: the construction makes a match
    // impossible, so a hit here means the derivation is broken and the ladder
    // must refuse to publish rather than time a return.
    var absent_buf: [absent_len]u8 = undefined;
    const absent = try absentNeedle(&absent_buf, flat, corpus.docs);
    if (simd.contains(flat, absent)) return error.NoAbsentNeedle;
    for (corpus.docs) |d| if (simd.contains(d, absent)) return error.NoAbsentNeedle;
    var absent_label: [32]u8 = undefined;
    const absent_shown = try std.fmt.bufPrint(&absent_label, "0x{X:0>2}x{d}", .{ absent[0], absent.len });

    const stages = [_]Stage{
        .{ .name = "corpus-sized STREAM roof", .gbps_max = roof.gbps_max, .gbps_median = roof.gbps_median },
        measureContiguous(io, "matched gate control", flat, absent, true),
        measureContiguous(io, "production contiguous", flat, absent, false),
    };
    std.debug.print("\nmatched scan ladder · {d:.1} MiB of corpus bytes, contiguous (logical input GB/s):\n", .{corpus_mib});
    for (stages) |stage| {
        std.debug.print("  {d:>6.1} GB/s · median {d:>6.1} · {d:>4.0}% of roof · {s}\n", .{
            stage.gbps_max, stage.gbps_median, stage.gbps_max / roof.gbps_max * 100.0, stage.name,
        });
    }

    // Production over the real corpus completes the ladder: same bytes, same
    // size, only the fragmentation into `corpus.docs.len` separate streams is
    // new. None of these sub-roof points is called a saturated hardware bound.
    var scans = scan_needles;
    scans[0].needle = absent;
    scans[0].label = absent_shown;
    std.debug.print("\ngist SIMD scan over {d} files · {d:.1} MiB (single-thread `contains`):\n", .{ corpus.docs.len, corpus_mib });
    for (&scans) |*s| {
        s.gbps = measureGistScan(io, &corpus, s.needle);
        std.debug.print("  {d:>6.1} GB/s = {d:>4.0}% of roof ({d:>3.0}% of the 512 MiB DRAM tier) · {s}\n", .{
            s.gbps, s.gbps / roof.gbps_max * 100.0, s.gbps / dram.gbps_max * 100.0, s.kind,
        });
    }

    try writeJson(gpa, io, tiers[0..], clk, dram, l2, roof.gbps_max, stages[0..], scans[0..], corpus_mib);
    std.debug.print("\nwrote {s} — run bench/bounds/roofline/report.py to splice Layer C\n", .{json_path.get()});
    if (!clk.measured) std.debug.print("note: no clock measured here, so the artifact publishes no cycles/byte. The GB/s ceilings are frequency-free and unaffected. Meter: {s}\n", .{clk.meter});
}

fn writeJson(
    gpa: std.mem.Allocator,
    io: std.Io,
    tiers: []const Tier,
    clk: Clock,
    dram: Tier,
    l2: Tier,
    roof_gbps: f64,
    stages: []const Stage,
    scans: []const ScanResult,
    corpus_mib: f64,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, gist.index.home.outDir());
    var j: std.ArrayList(u8) = .empty;
    defer j.deinit(gpa);
    var line: [512]u8 = undefined;

    try j.appendSlice(gpa, "{\n");
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"machine\": \"{s}\",\n", .{@tagName(builtin.target.cpu.arch)}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"zig\": \"{s}\",\n", .{builtin.zig_version_string}));
    // The clock is nested, and there is deliberately no top-level `ghz`: a flat
    // divisor is exactly what let a consumer multiply an assumption without ever
    // reading the sibling that called it one. `measured` is the field a reader
    // has to pass through to reach the number.
    try j.appendSlice(gpa, "  \"clock\": {\n");
    // An unmeasured clock publishes JSON `null`, not the stand-in the terminal
    // printed: a number here is divisible by a consumer who never reads
    // `measured`, and `null` is not. That is the whole fix, in one field.
    if (clk.measured) {
        try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    \"ghz\": {d:.4},\n", .{clk.ghz}));
    } else {
        try j.appendSlice(gpa, "    \"ghz\": null,\n");
    }
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    \"measured\": {},\n", .{clk.measured}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    \"source\": \"{s}\",\n", .{clk.source}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    \"meter\": \"{s}\"\n", .{clk.meter}));
    try j.appendSlice(gpa, "  },\n");
    // Present only when this host measured its own clock — see `Clock.cycPerByte`.
    // The object carries the clock it was divided by, so the derivation travels
    // with the figures instead of living in a sibling a reader may skip.
    if (clk.cycPerByte(dram.gbps_max)) |dram_cpb| {
        try j.appendSlice(gpa, "  \"derived_cyc_per_byte\": {\n");
        try j.appendSlice(gpa, "    \"basis\": \"measured clock GHz ÷ measured tier GB/s\",\n");
        try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    \"ghz\": {d:.4},\n", .{clk.ghz}));
        try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    \"dram_ceiling\": {d:.6},\n", .{dram_cpb}));
        try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    \"l2_ceiling\": {d:.6}\n", .{clk.cycPerByte(l2.gbps_max).?}));
        try j.appendSlice(gpa, "  },\n");
    }
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"corpus_mib\": {d:.1},\n", .{corpus_mib}));
    // The ladder's denominator: STREAM at the corpus's own size over the
    // corpus's own bytes. `tiers[DRAM]` is the cache-hierarchy datum only —
    // dividing a scan rung by it mixes size and content into the headroom.
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"roof_gbps\": {d:.3},\n", .{roof_gbps}));
    try j.appendSlice(gpa, "  \"tiers\": [\n");
    for (tiers, 0..) |t, i| {
        try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    {{ \"name\": \"{s}\", \"bytes\": {d}, \"gbps\": {d:.3}, \"gbps_median\": {d:.3} }}{s}\n", .{
            t.name, t.bytes, t.gbps_max, t.gbps_median, if (i + 1 < tiers.len) "," else "",
        }));
    }
    try j.appendSlice(gpa, "  ],\n");
    try j.appendSlice(gpa, "  \"matched_ladder\": [\n");
    for (stages, 0..) |stage, i| {
        try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    {{ \"name\": \"{s}\", \"gbps\": {d:.3}, \"gbps_median\": {d:.3} }}{s}\n", .{
            stage.name, stage.gbps_max, stage.gbps_median, if (i + 1 < stages.len) "," else "",
        }));
    }
    try j.appendSlice(gpa, "  ],\n");
    try j.appendSlice(gpa, "  \"gist_scan\": [\n");
    for (scans, 0..) |s, i| {
        try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    {{ \"needle\": \"{s}\", \"kind\": \"{s}\", \"gbps\": {d:.3} }}{s}\n", .{
            s.label, s.kind, s.gbps, if (i + 1 < scans.len) "," else "",
        }));
    }
    try j.appendSlice(gpa, "  ]\n}\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path.get(), .data = j.items });
}

test "streamSum reduces every word (checksum matches scalar)" {
    var buf: [STEP * 4 + 3]u64 = undefined;
    var expect: u64 = 0;
    for (&buf, 0..) |*x, i| {
        x.* = @as(u64, i) *% 0x9E3779B97F4A7C15 +% 1;
        expect +%= x.*;
    }
    try std.testing.expectEqual(expect, streamSum(&buf));
}

test "an unmeasured clock cannot mint a cycles/byte figure" {
    // The invariant the 2026-08-01 defect violated: `assumed_ghz` is a real
    // number and `102 GB/s` is a real number, so the division always succeeds.
    // What must not exist is the *result*, on a host that measured no clock.
    const assumed: Clock = .{ .ghz = assumed_ghz, .source = "assumed", .meter = "none", .measured = false };
    try std.testing.expectEqual(@as(?f64, null), assumed.cycPerByte(102.0));

    const measured: Clock = .{ .ghz = 4.0, .source = "measured", .meter = "kperf", .measured = true };
    try std.testing.expectEqual(@as(?f64, 0.04), measured.cycPerByte(100.0));
    // A tier that measured no bandwidth is not a cycles/byte figure either.
    try std.testing.expectEqual(@as(?f64, null), measured.cycPerByte(0.0));
}

test "an unoptimized build is not a bandwidth measurement" {
    // The Debug artifact this guard was written against is the negative case:
    // the mode is a comptime fact, so the only thing to pin is that the two
    // modes which suppress the kernel's vectorization are the two the rung
    // refuses to run under.
    try std.testing.expect(!measurableIn(.Debug));
    try std.testing.expect(!measurableIn(.ReleaseSmall));
    try std.testing.expect(measurableIn(.ReleaseFast));
    try std.testing.expect(measurableIn(.ReleaseSafe));
    // …and that the live build agrees with the predicate for its own mode.
    try std.testing.expectEqual(measurableIn(builtin.mode), measurable);
}

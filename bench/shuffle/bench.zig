//! Compose — production proof harness (does it work, and is it actually faster).
//!
//! Links gist's REAL engine (`@import("irregex")`) and the REAL rung
//! (`@import("compose")`), so the baseline is the shipped `Dfa.docMatch` and
//! not a reimplementation of it. Both arms run over the SAME buffer, in the
//! SAME process, interleaved round by round and reported min-of-N — a baseline
//! measured somewhere else is not a baseline, and on a box carrying ten
//! coworker agents an un-interleaved A/B measures the load, not the kernel.
//!
//! Four things it establishes, each fail-closed:
//!
//!   1. **Agreement on the whole buffer.** Every row prints whether the two
//!      arms returned the same verdict; a single disagreement exits non-zero.
//!      (The exhaustive proof is the 350k-case differential against the Pike VM
//!      in `compose_test.zig`; this is the same claim at 64 MiB scale.)
//!   2. **Throughput, both arms, same run.** `B/cyc` is normalized to 4.512 GHz
//!      so it is comparable with the pre-registered 0.277 figure, and the
//!      IN-RUN calibrated clock is printed beside it so the normalization is
//!      visible rather than assumed. The real clock on a loaded machine is
//!      always lower, which makes every speedup here conservative.
//!   3. **Full-buffer scans, proven per row.** The kernel returns the moment a
//!      chunk lands on MATCH, so one hit turns a throughput number into a
//!      measurement of the prefix before it. The `hit` column reports the
//!      verdict and a row that hit says so in the clear.
//!   4. **The honest boundary.** The `dot-star-chain` row lowers the rung past
//!      its own dispatch gate (`Compose.lower`, not `Compose.build`) purely to
//!      publish how badly it loses to an armed literal skip — and prints, on
//!      the row below, that `build` refuses that exact pattern. A rung with no
//!      ≈1× row is hiding something; this one has a 0.16× row.
//!
//! Haystack: `$COMPOSE_HAY` when set (the research lane's 64 MiB file, for
//! reproducing its exact numbers), else the real Billy corpus concatenated
//! into one contiguous buffer via the same `corpus.load` the certificate
//! layers use. Both are line-structured source bytes, which is what `docMatch`
//! is shaped for.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");
const compose = gist.regex_compose;

const Compose = compose.Compose;
const Regex = gist.regex.Regex;
const corpus_mod = gist.corpus;
const Span = gist.assay.Span;

/// The engine's own env spelling (`assay/channel.zig`), which this harness is
/// too small to reach through the seal for.
fn envSpan(key: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(key)) |v| std.mem.span(v) else null;
}

/// The clock every `B/cyc` column is normalized to — the advertised P-core
/// boost, and the divisor the pre-registered 0.277 baseline was derived with.
/// Never observed in practice; see `calibrate`.
const norm_ghz: f64 = 4.512;

const Spec = struct {
    id: []const u8,
    pattern: []const u8,
    /// Rows kept to show where the rung LOSES. Lowered past the dispatch gate
    /// on purpose, and never counted as a win.
    boundary: bool = false,
};

/// The research lane's slate, plus its two control rows. The first entry is the
/// pattern the whole effort was pointed at: nine states, no literal to skip on,
/// so the shipped DFA must retire every byte.
///
/// Sentinel tails carry a `~` where the research lane wrote a third letter. Its
/// all-letter tails DID match this haystack — a base64 integrity hash in
/// `pnpm-lock.yaml` satisfies `letters digits letters digits letters zqx` — and
/// the kernel returns the moment a chunk lands on MATCH, so one hit anywhere
/// turns every GB/s below into a measurement of the prefix before it. `~` is
/// absent from the corpus and keeps the literal LENGTH, hence the state count,
/// identical to the researched pattern. The `hit` column re-proves the property
/// per row rather than trusting this paragraph.
const specs = [_]Spec{
    .{ .id = "class-alt", .pattern = "[A-Za-z]+[0-9]+[A-Za-z]+[0-9]+[A-Za-z]+z~x" },
    .{ .id = "class-alt6", .pattern = "[A-Za-z]+[0-9]+[A-Za-z]+[0-9]+[A-Za-z]+[0-9]+[A-Za-z]+z~xj" },
    .{ .id = "date-suffix", .pattern = "[0-9]{4}-[0-9]{2}-[0-9]{2}z~x" },
    .{ .id = "alnum-run", .pattern = "[a-z]+[0-9]{3,6}[a-z]+z~xjvw" },
    .{ .id = "hex-pair", .pattern = "[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}z~x" },
    .{ .id = "digits-long", .pattern = "[0-9]{12,18}[a-z]z~x" },
    .{ .id = "hex-triple", .pattern = "[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}z~x" },
    // Past the 31-state ceiling: must refuse, and the row says so.
    .{ .id = "class-alt8", .pattern = "[A-Za-z]+[0-9]+[A-Za-z]+[0-9]+[A-Za-z]+[0-9]+[A-Za-z]+[0-9]+z~xjv" },
    .{ .id = "uni-prop", .pattern = "\\p{Greek}\\p{Greek}\\p{Greek}z~xjvw" },
    // The negative result, published rather than buried.
    .{ .id = "dot-star-chain", .pattern = "q~x.*j~w.*m~p", .boundary = true },
};

/// Core clock, measured in this process by a dependent `ADD` chain that is one
/// cycle per link by construction. The advertised boost is a marketing number
/// and a shared box never reaches it; this is what the machine was actually
/// doing while the rows above it were timed.
fn calibrate(io: std.Io, links: u64) f64 {
    if (comptime builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .aarch64_be) return 0;
    var x: u64 = 1;
    const sp = Span.open(io);
    var i: u64 = 0;
    while (i < links) : (i += 1) {
        inline for (0..16) |_| {
            x = asm ("add %[o], %[i], #1"
                : [o] "=r" (-> u64),
                : [i] "r" (x),
            );
        }
    }
    const ns = sp.read(io).ns();
    std.mem.doNotOptimizeAway(x);
    if (ns <= 0) return 0;
    return @as(f64, @floatFromInt(links * 16)) / @as(f64, @floatFromInt(ns));
}

/// One contiguous buffer, because sequential throughput is what is under test.
fn haystack(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    if (envSpan("COMPOSE_HAY")) |path|
        return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 31));
    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try corpus_mod.load(gpa, io, roots);
    defer corpus.deinit();
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.ensureTotalCapacity(gpa, corpus.bytes + corpus.docs.len);
    for (corpus.docs) |d| {
        buf.appendSliceAssumeCapacity(d);
        if (d.len == 0 or d[d.len - 1] != '\n') buf.appendAssumeCapacity('\n');
    }
    return buf.toOwnedSlice(gpa);
}

const Timing = struct { base_ns: i128, comp_ns: i128, agree: bool, hit: bool };

/// Interleaved A/B, min-of-N. Interleaving is the point: a load spike that
/// lands between two separate loops would be charged entirely to one arm.
fn race(io: std.Io, dfa: anytype, cx: *const Compose, hay: []const u8, rounds: usize) Timing {
    var base: i128 = std.math.maxInt(i64);
    var comp: i128 = std.math.maxInt(i64);
    var bhit = false;
    var chit = false;
    for (0..rounds) |_| {
        var sp = Span.open(io);
        bhit = dfa.docMatch(hay);
        const b = sp.read(io).ns();
        sp = Span.open(io);
        chit = cx.docMatch(hay);
        const c = sp.read(io).ns();
        if (b < base) base = b;
        if (c < comp) comp = c;
    }
    return .{ .base_ns = base, .comp_ns = comp, .agree = bhit == chit, .hit = bhit };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const hay = try haystack(gpa, io);
    defer gpa.free(hay);
    const rounds: usize = if (envSpan("COMPOSE_ROUNDS")) |r|
        std.fmt.parseInt(usize, r, 10) catch 7
    else
        7;

    std.debug.print("Compose — transformation-composition rung · abi v{d}\n", .{gist.abi()});
    std.debug.print("machine: {s} · zig {s} · rung armable: {}\n", .{ @tagName(builtin.target.cpu.arch), builtin.zig_version_string, compose.lanes.native });
    std.debug.print("haystack: {d} B ({d:.1} MiB) · rounds: {d} (min-of-N, interleaved)\n", .{ hay.len, @as(f64, @floatFromInt(hay.len)) / (1 << 20), rounds });
    std.debug.print("clock: {d:.3} GHz at start-up; each row carries the clock measured beside it,\n", .{calibrate(io, 3_000_000)});
    std.debug.print("       and its own B/cyc columns are derived with THAT clock, not with {d:.3}.\n\n", .{norm_ghz});

    std.debug.print("{s:<16} {s:>4} {s:>6} {s:>3} {s:>6} {s:>5} {s:>9} {s:>9} {s:>10} {s:>10} {s:>8} {s:>6} {s:>5}\n", .{
        "pattern", "|Q|", "lanes", "la", "accel", "GHz", "base GB/s", "comp GB/s", "base B/cyc", "comp B/cyc", "speedup", "agree", "hit",
    });
    std.debug.print("{s:-<16} {s:->4} {s:->6} {s:->3} {s:->6} {s:->5} {s:->9} {s:->9} {s:->10} {s:->10} {s:->8} {s:->6} {s:->5}\n", .{ "", "", "", "", "", "", "", "", "", "", "", "", "" });

    var disagreements: usize = 0;
    var best_norm: f64 = 0;

    for (specs) |sp| {
        var re = Regex.compileOpts(gpa, sp.pattern, .{ .unicode = true, .force_dfa = true }) catch |e| {
            std.debug.print("{s:<16} compile failed: {s}\n", .{ sp.id, @errorName(e) });
            continue;
        };
        defer re.deinit();
        const dfa = re.dfa orelse {
            std.debug.print("{s:<16} {s:>4} no DFA — the powerset cap refused; Pike serves\n", .{ sp.id, "-" });
            continue;
        };
        // A boundary row is lowered past the dispatch gate on purpose; every
        // other row goes through the gate the ladder would use.
        const cx = (if (sp.boundary) try Compose.lower(gpa, dfa) else try Compose.build(gpa, dfa)) orelse {
            std.debug.print("{s:<16} {d:>4} {s:>6} {s:>3} {any:>6}   declined — {s}\n", .{
                sp.id, dfa.nstates, "-", "-", dfa.accel != null, reason(dfa),
            });
            continue;
        };
        defer cx.deinit();

        const t = race(io, dfa, cx, hay, rounds);
        // Measured beside the row it annotates, so a thermal or contention
        // excursion during this pattern shows up in this pattern's own divisor.
        const ghz = calibrate(io, 1_500_000);

        const n: f64 = @floatFromInt(hay.len);
        const bgb = (n / (@as(f64, @floatFromInt(t.base_ns)) / 1e9)) / 1e9;
        const cgb = (n / (@as(f64, @floatFromInt(t.comp_ns)) / 1e9)) / 1e9;
        std.debug.print("{s:<16} {d:>4} {d:>6} {s:>3} {any:>6} {d:>5.2} {d:>9.2} {d:>9.2} {d:>10.3} {d:>10.3} {d:>7.2}x {any:>6} {any:>5}{s}\n", .{
            sp.id,                  dfa.nstates,
            @intFromEnum(cx.width), if (cx.index == .byte_eol) "yes" else "no",
            dfa.accel != null,      ghz,
            bgb,                    cgb,
            bgb / ghz,              cgb / ghz,
            cgb / bgb,              t.agree,
            t.hit,
            if (sp.boundary) "  ← boundary" else "",
        });
        if (!t.agree) disagreements += 1;
        if (!sp.boundary and !t.hit and cgb / norm_ghz > best_norm) best_norm = cgb / norm_ghz;
        // A hit ends the scan at the chunk that found it, so the row above
        // measured a prefix of unknown length rather than the buffer.
        if (t.hit) std.debug.print("  !! matched — throughput above is over a prefix, not {d} B\n", .{hay.len});

        // The boundary row's whole point: the ladder must NOT take this.
        if (sp.boundary) {
            const gated = try Compose.build(gpa, dfa);
            if (gated) |g| {
                g.deinit();
                std.debug.print("  !! the dispatch gate ARMED on an accelerated pattern — that is the 6× regression\n", .{});
                disagreements += 1;
            } else std.debug.print("{s:<16} gate holds: `build` refuses it, the ladder keeps the accelerated DFA\n", .{""});
        }
    }

    // The one figure comparable with the pre-registered 0.277: same divisor.
    std.debug.print("\nbest full-buffer row renormalised to {d:.3} GHz: {d:.3} B/cyc\n", .{ norm_ghz, best_norm });
    if (disagreements != 0) {
        std.debug.print("\nFAILED: {d} row(s) disagreed with the shipped DFA or armed against the gate.\n", .{disagreements});
        return error.ComposeProofFailed;
    }
    std.debug.print("\nOK: every armed row agrees with the shipped DFA on the whole buffer.\n", .{});
}

/// Why `build`/`lower` said no, read back off the DFA so the declined rows are
/// informative rather than blank.
fn reason(dfa: anytype) []const u8 {
    if (!compose.lanes.native) return "not AArch64";
    if (dfa.accel != null) return "literal skip armed — skipping beats retiring";
    if (dfa.word_ctx) return "word context (\\b) needs a second table axis";
    if (dfa.is_match[dfa.start]) return "start closure already accepts";
    return "more than 31 non-accepting states";
}

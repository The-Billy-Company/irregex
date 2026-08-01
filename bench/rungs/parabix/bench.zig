//! Parabix — production proof harness: does the bit-parallel rung agree with
//! the shipped engine, and is it actually faster.
//!
//! Links gist's REAL engine (`@import("irregex")`) and arms the REAL rung
//! through the engine's own seal (`gist.regex_parabix`), so both arms of every
//! race are production code. Four things it establishes, each fail-closed:
//!
//!   1. **Agreement, over the real host corpus.** Every pattern is run over
//!      every corpus document by both the shipped ladder and this rung; a single
//!      disagreement exits non-zero. (The exhaustive proof is the randomized
//!      differential against the Pike VM in `parabix_test.zig`; this is the same
//!      claim at corpus scale against the engine a user actually gets.)
//!   2. **Throughput, on a haystack that provably cannot match.** A boolean
//!      scan returns at the first hit, so timing a matching buffer measures
//!      where the match happens to sit, not the engine. The number both arms
//!      are actually judged on is the negative case — the grep-common case, and
//!      the only one that retires the whole buffer. Each row therefore carries
//!      its own adversarial filler: bytes DENSE in the pattern's leading class
//!      (so the marker chain does maximum work and the DFA leaves its start
//!      state constantly) that never complete the chain. The `hit` column
//!      re-proves the miss per row rather than trusting the construction.
//!   3. **The phase ladder.** Each row prints transposition alone, transposition
//!      plus class streams, then the whole scan, so the claim that transposition
//!      is the cheap half is measured here rather than quoted from PACT 2014.
//!   4. **The refusals, from the bench as well as from the tests.** Rows marked
//!      refused must produce a named Decline; a row that arms where the gate
//!      must refuse fails the run. Boundary rows are lowered past the gate
//!      purely to publish where the rung loses.
//!
//! Two baselines, both measured here in this process, because they answer
//! different questions. `ladder` is `Regex.docMatch` — the whole shipped
//! verdict ladder including the class-run kernel and every accelerator, i.e.
//! what a user gets today. `dfa` is `Dfa.docMatch` — the table-walk engine
//! whose ~4-cycle load-latency floor is the pre-registered 0.277 B/cycle this
//! rung was designed against. A rung that only beat the narrower baseline would
//! be hiding behind it.
//!
//! Prior art: Cameron et al., "Bitwise Data Parallelism in Regular Expression
//! Matching" (PACT 2014) / icGrep. No novelty is claimed for the technique.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");
const parabix = gist.regex_parabix;

const Parabix = parabix.Parabix;
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
/// Never observed in practice on a box carrying ten agents; see `calibrate`,
/// whose lower in-run number makes every speedup here conservative.
const norm_ghz: f64 = 4.512;

const lower = "abcdefghijklmnopqrstuvwxyz";
const mixed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

const Spec = struct {
    id: []const u8,
    pattern: []const u8,
    /// Alphabet the adversarial filler draws from. Chosen per row to be dense
    /// in the pattern's LEADING class and to omit at least one class the chain
    /// needs, which is what makes the miss structural rather than lucky.
    filler: []const u8 = lower,
    /// Longest run of filler bytes between separators. Caps class-run length
    /// for the rows whose pattern is a counted run.
    run: u8 = 12,
    /// Lowered past the dispatch gate on purpose, to publish the loss.
    boundary: bool = false,
    /// Expected to be refused; the row prints the reason instead of a time.
    refused: bool = false,
    /// Compile with `--no-unicode`. `.` and `\w` are codepoint classes under
    /// rg's default `-u`, and a codepoint class is not a function of one byte's
    /// eight bits, so the rung can only serve their ASCII spellings.
    ascii: bool = false,
    note: []const u8 = "",
};

/// The flat class-chain family the lane measured, plus the boundary and refusal
/// rows the acceptance bar requires.
const specs = [_]Spec{
    .{ .id = "chain3", .pattern = "[a-z]+[0-9]+[a-z]+", .note = "the lane's headline shape" },
    .{ .id = "chain5", .pattern = "[a-z]+[0-9]+[a-z]+[0-9]+[a-z]+" },
    .{ .id = "counted", .pattern = "[a-z]{4}[0-9]{2}[a-z]{4}", .note = "counted: fusion path" },
    .{ .id = "ident-pair", .pattern = "[a-z]+_[0-9]+_[a-z]+" },
    .{ .id = "emailish", .pattern = "[a-z]+@[a-z]+\\.[0-9]+" },
    .{ .id = "dot-lead", .pattern = ".{4}[a-z]+[0-9][a-z]", .ascii = true, .note = "`.` only under --no-unicode" },
    .{ .id = "bounded", .pattern = "[a-z][a-z0-9]{7,15}[0-9]" },
    // Cross-lane overlap: this is COMPOSE's headline shape without its literal
    // sentinel. Both rungs can arm on it; the parent owns the ordering.
    .{ .id = "alnum-alt", .pattern = "[A-Za-z]+[0-9]+[A-Za-z]+", .filler = mixed, .note = "compose also arms — parent decides" },
    .{ .id = "digit-run", .pattern = "[0-9]{4}-[0-9]{2}", .note = "10 escape bytes: past dwell.max_exit_bytes, the DFA walks it" },
    .{ .id = "word-gap", .pattern = "\\b[a-z]+_[0-9]+\\b", .ascii = true, .note = "assertion population COMPOSE cannot serve" },
    .{ .id = "line-gap", .pattern = "^[a-z]+[0-9]+$", .note = "line-marker catalogue" },
    // ── Honest boundary: the shipped engine already has a better machine ─────
    .{ .id = "classrun", .pattern = "[a-z]{6,}", .run = 5, .boundary = true, .note = "classrun kernel answers at load bandwidth" },
    .{ .id = "memchr-skip", .pattern = "z[a-z]+[0-9]+", .filler = "abcdefghijklmnoprstuvw", .boundary = true, .note = "singleton first byte: memchr skips the buffer" },
    // ── Refusals: the gate, proven from the bench as well as from the tests ──
    .{ .id = "nested-star", .pattern = "([a-z]+)+[0-9]", .refused = true, .note = "star-height 2 — the 0.061 B/cyc collapse" },
    .{ .id = "uni-class", .pattern = "[a-z]+\\p{Greek}+", .refused = true, .note = "codepoint class: not one byte's 8 bits" },
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

/// A line-structured buffer over `alphabet`, tokens of 1..=`run` bytes, ~8
/// tokens per line. Deterministic from a fixed seed so a re-run measures the
/// same bytes.
fn filler(gpa: std.mem.Allocator, alphabet: []const u8, run: u8, len: usize) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    var rng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15);
    const rand = rng.random();
    var i: usize = 0;
    var tokens: usize = 0;
    while (i < len) {
        const take = @min(len - i, 1 + rand.uintLessThan(usize, run));
        for (buf[i..][0..take]) |*c| c.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        i += take;
        if (i == len) break;
        tokens += 1;
        buf[i] = if (tokens % 8 == 0) '\n' else ' ';
        i += 1;
    }
    return buf;
}

const plane = parabix.plane_floor;
const stencil = parabix.class_circuits;

var sink: u128 = 0;

/// Phase A — transposition alone, over the whole buffer. The floor every other
/// phase is built on, and the number the report attributes ~40% of the work to.
fn timeTranspose(io: std.Io, hay: []const u8) i128 {
    var acc: plane.Wide = @splat(0);
    const sp = Span.open(io);
    var pos: usize = 0;
    while (pos + plane.stripe_width <= hay.len) : (pos += plane.stripe_width) {
        const basis = plane.transposeStripe(hay[pos..][0..plane.stripe_width]);
        inline for (0..8) |k| acc ^= basis[k];
    }
    const ns = sp.read(io).ns();
    sink ^= @as(u128, @bitCast(@as([plane.stripe]plane.Lane, @bitCast(acc))[0]));
    return ns;
}

/// Phase B — transposition plus every class circuit. The marker chain is the
/// only thing phase C adds on top.
fn timeClasses(io: std.Io, px: *const Parabix, hay: []const u8) i128 {
    var vals: stencil.Scratch(plane.Wide) = undefined;
    var acc: plane.Wide = @splat(0);
    const sp = Span.open(io);
    var pos: usize = 0;
    while (pos + plane.stripe_width <= hay.len) : (pos += plane.stripe_width) {
        const basis = plane.transposeStripe(hay[pos..][0..plane.stripe_width]);
        for (px.prog.circuits[0..px.prog.nclasses]) |*c| acc ^= c.eval(plane.Wide, &basis, &vals);
    }
    const ns = sp.read(io).ns();
    sink ^= @as(u128, @bitCast(@as([plane.stripe]plane.Lane, @bitCast(acc))[0]));
    return ns;
}

const Timing = struct {
    ladder_ns: i128 = std.math.maxInt(i64),
    dfa_ns: i128 = std.math.maxInt(i64),
    pbx_ns: i128 = std.math.maxInt(i64),
    agree: bool = true,
    hit: bool = false,
};

/// Interleaved A/B/C, min-of-N. Interleaving is the point: a load spike landing
/// between two separate loops would be charged entirely to one arm.
fn race(gpa: std.mem.Allocator, io: std.Io, re: *Regex, px: *const Parabix, hay: []const u8, rounds: usize) !Timing {
    var t: Timing = .{};
    var sim = try Regex.Sim.init(gpa, re);
    defer sim.deinit();
    for (0..rounds) |_| {
        var sp = Span.open(io);
        const lhit = re.docMatch(&sim, hay);
        const l = sp.read(io).ns();

        sp = Span.open(io);
        const dhit = if (re.dfa) |d| d.docMatch(hay) else lhit;
        const d = sp.read(io).ns();

        sp = Span.open(io);
        const phit = px.match(hay);
        const p = sp.read(io).ns();

        if (l < t.ladder_ns) t.ladder_ns = l;
        if (d < t.dfa_ns) t.dfa_ns = d;
        if (p < t.pbx_ns) t.pbx_ns = p;
        t.hit = lhit;
        t.agree = lhit == phit and lhit == dhit;
    }
    return t;
}

/// Every corpus document, both engines, verbatim bytes. Agreement at corpus
/// scale against the ladder a user actually gets — the complement to the
/// randomized Pike differential in `parabix_test.zig`.
fn agree(gpa: std.mem.Allocator, re: *Regex, px: *const Parabix, docs: []const []const u8, hits: *usize) !usize {
    var sim = try Regex.Sim.init(gpa, re);
    defer sim.deinit();
    var bad: usize = 0;
    for (docs) |doc| {
        const want = re.docMatch(&sim, doc);
        if (want) hits.* += 1;
        if (px.match(doc) != want) bad += 1;
    }
    return bad;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const megs: usize = if (envSpan("PARABIX_MIB")) |m| std.fmt.parseInt(usize, m, 10) catch 64 else 64;
    const rounds: usize = if (envSpan("PARABIX_ROUNDS")) |r| std.fmt.parseInt(usize, r, 10) catch 9 else 9;
    const hay_len = megs << 20;

    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try corpus_mod.load(gpa, io, roots, .contiguous);
    defer corpus.deinit();

    const ghz = calibrate(io, 3_000_000);
    std.debug.print("Parabix — bit-parallel within-document scan rung · abi v{d}\n", .{gist.abi()});
    // Armable is BOTH conjuncts — the kernel compiles here and the ladder has a
    // minted price for it. `parabix.native` alone would report a freshly-ported
    // target as armable while the auction still refuses to let it bid.
    std.debug.print("machine: {s} · zig {s} · kernel here: {} · rung armable (kernel + calibration): {}\n", .{
        @tagName(builtin.target.cpu.arch),
        builtin.zig_version_string,
        parabix.native,
        gist.regex_rungs.parabix_armable,
    });
    std.debug.print("throughput haystack: {d} MiB adversarial near-miss per row · rounds {d} (min-of-N, interleaved)\n", .{ megs, rounds });
    std.debug.print("agreement corpus: {d} docs · {d:.1} MiB\n", .{ corpus.docs.len, @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20) });
    std.debug.print("clock: {d:.3} GHz measured in-run · B/cyc normalized to {d:.3} GHz\n\n", .{ ghz, norm_ghz });

    std.debug.print("{s:<12} {s:>3} {s:>3} {s:>5} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>7} {s:>7}\n", .{
        "row", "cls", "ins", "carry", "ladder", "dfa", "parabix", "pbx GB/s", "pbx B/cyc", "vs ldr", "vs dfa",
    });
    std.debug.print("{s:-<12} {s:->3} {s:->3} {s:->5} {s:->8} {s:->8} {s:->8} {s:->8} {s:->8} {s:->7} {s:->7}\n", .{ "", "", "", "", "", "", "", "", "", "", "" });

    var failures: usize = 0;
    var verdicts: usize = 0;

    for (specs) |sp| {
        var re = Regex.compileOpts(gpa, sp.pattern, .{ .unicode = !sp.ascii, .force_dfa = true }) catch |e| {
            std.debug.print("{s:<12} compile failed: {s}\n", .{ sp.id, @errorName(e) });
            failures += 1;
            continue;
        };
        defer re.deinit();
        // Representability and intrinsic price only. The parent compares these
        // economics with its public prefilter economics; this lane has no rival
        // booleans and therefore no construction-order coupling.
        const verdict = Parabix.decide(gpa, sp.pattern, .{ .unicode = !sp.ascii });
        const gated: ?Parabix = switch (verdict) {
            .admitted => |candidate| .{
                .prog = candidate.program,
                .economics = candidate.economics,
            },
            .declined => null,
        };
        if (sp.refused or (gated == null and !sp.boundary)) {
            if (gated != null) {
                std.debug.print("{s:<12} !! ARMED on a pattern the gate must refuse\n", .{sp.id});
                failures += 1;
            } else std.debug.print("{s:<12} refused ({s}) — {s}\n", .{ sp.id, @tagName(verdict.declined), sp.note });
            continue;
        }

        const px = gated orelse {
            std.debug.print("{s:<12} row will not lower ({s})\n", .{ sp.id, @tagName(verdict.declined) });
            failures += 1;
            continue;
        };

        const hay = try filler(gpa, sp.filler, sp.run, hay_len);
        defer gpa.free(hay);

        const t = try race(gpa, io, &re, &px, hay, rounds);
        const n: f64 = @floatFromInt(hay.len);
        const ls = @as(f64, @floatFromInt(t.ladder_ns)) / 1e9;
        const ds = @as(f64, @floatFromInt(t.dfa_ns)) / 1e9;
        const ps = @as(f64, @floatFromInt(t.pbx_ns)) / 1e9;
        const pgb = (n / ps) / 1e9;

        std.debug.print("{s:<12} {d:>3} {d:>3} {d:>5} {d:>7.1}m {d:>7.1}m {d:>7.1}m {d:>8.2} {d:>8.3} {d:>6.2}x {d:>6.2}x{s}\n", .{
            sp.id,           px.prog.nclasses,
            px.prog.ninstrs, px.prog.ncarries,
            ls * 1000,       ds * 1000,
            ps * 1000,       pgb,
            pgb / norm_ghz,  ls / ps,
            ds / ps,
            if (sp.boundary) "  ← boundary" else "",
        });

        if (t.hit) {
            std.debug.print("{s:<12} !! the near-miss filler MATCHED — every time above is a prefix scan\n", .{""});
            failures += 1;
        }
        if (!t.agree) {
            std.debug.print("{s:<12} !! disagreed with the shipped ladder\n", .{""});
            failures += 1;
        }
        // The phase ladder: where the cycles actually go, measured rather than
        // apportioned. `s2p` is the transposition alone; `+cls` adds every class
        // circuit; the remainder up to the row above is the marker chain.
        var s2p: i128 = std.math.maxInt(i64);
        var cls: i128 = std.math.maxInt(i64);
        for (0..rounds) |_| {
            const a = timeTranspose(io, hay);
            const b = timeClasses(io, &px, hay);
            if (a < s2p) s2p = a;
            if (b < cls) cls = b;
        }
        std.debug.print("{s:<12} phases: s2p {d:.2} GB/s ({d:.2} B/cyc) · +cls {d:.2} GB/s ({d:.2} B/cyc) · full {d:.2} GB/s\n", .{
            "",
            (n / (@as(f64, @floatFromInt(s2p)) / 1e9)) / 1e9,
            (n / (@as(f64, @floatFromInt(s2p)) / 1e9)) / 1e9 / norm_ghz,
            (n / (@as(f64, @floatFromInt(cls)) / 1e9)) / 1e9,
            (n / (@as(f64, @floatFromInt(cls)) / 1e9)) / 1e9 / norm_ghz,
            pgb,
        });

        if (sp.note.len > 0 and !sp.boundary) std.debug.print("{s:<12} {s}\n", .{ "", sp.note });
        if (sp.boundary) std.debug.print(
            "{s:<12} overlap published: parent compares economics ({d} stripe ops) — {s}\n",
            .{ "", px.economics.stripe_ops, sp.note },
        );

        // Corpus-scale agreement, on the gated rows only: a boundary row is not
        // a rung the ladder would ever use.
        if (!sp.boundary) {
            var hits: usize = 0;
            const bad = try agree(gpa, &re, &px, corpus.docs, &hits);
            verdicts += corpus.docs.len;
            if (bad != 0) {
                std.debug.print("{s:<12} !! {d}/{d} corpus documents disagreed\n", .{ "", bad, corpus.docs.len });
                failures += bad;
            } else {
                std.debug.print("{s:<12} corpus: {d} docs agree ({d} matching)\n", .{ "", corpus.docs.len, hits });
            }
        }
    }

    std.debug.print("\ncorpus agreement: {d} document verdicts, byte-identical to the shipped ladder\n", .{verdicts});
    // `B/cyc` is renormalised to 4.512 GHz because that is the clock the
    // pre-registered 0.277 baseline was taken at, and a per-cycle figure is
    // only comparable at one clock. On a box carrying ten coworker agents the
    // real clock drops by half, which UNDERSTATES the absolute column while
    // leaving the ratio columns — both arms, same buffer, interleaved — intact.
    // Say so rather than let a loaded run be read as a regression.
    const closing = calibrate(io, 1_500_000);
    std.debug.print("mean in-run clock: {d:.3} GHz\n", .{closing});
    if (closing < norm_ghz * 0.85) std.debug.print(
        "  ! ran at {d:.0}% of the {d:.3} GHz normalization clock — trust the ratio columns, not the absolute B/cyc\n",
        .{ closing / norm_ghz * 100, norm_ghz },
    );
    if (failures != 0) {
        std.debug.print("\nFAILED: {d} problem(s) above.\n", .{failures});
        return error.ParabixProofFailed;
    }
    std.debug.print("\nOK: every representable row agrees; overlap rows publish cost for parent selection.\n", .{});
}

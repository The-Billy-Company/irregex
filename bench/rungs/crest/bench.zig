//! Crest — production proof harness (Layer: does it actually work + how fast).
//!
//! Links gist's REAL engine (`@import("irregex")` — the crest kernel ships
//! inside it at `src/kernel/math/crest.zig`) and walks the REAL host corpus via the
//! same `corpus.load` the certificate layers use, so this is not a toy: the
//! baseline is gist's production `Regex.docMatch`, and every claim is a
//! measured number over live source bytes.
//!
//! For each class-repetition query it establishes three things, fail-closed:
//!   1. SOUNDNESS (the load-bearing claim). For EVERY file, if the real matcher
//!      matches then the Crest sieve must NOT prune it. A single violation over
//!      the whole corpus exits non-zero — no bandaid. This is the
//!      Sieve Theorem checked against the production matcher on 100+ MiB.
//!   2. PRUNING. What fraction of files the k-int crest compare removes before
//!      the matcher runs — on exactly the class where the trigram index prunes
//!      0% (gist Certificate `regex-classcount` cand%=100%).
//!   3. SPEED. Wall time of (full scan with the real matcher) vs (crest compare
//!      + real matcher on survivors), same matcher both sides, so the speedup is
//!      purely avoided work. In the shipped integration the win is larger
//!      still: a pruned doc's read is elided entirely (serial `IndexSkip` /
//!      parallel `Elide`), not just its match call.
//!
//! It also runs the count-cousin ABLATION (total class population at the same
//! threshold) to show the *run* is the right necessary condition, and a
//! randomized adversarial soundness sweep — in both engine modes (byte/ASCII
//! and rg-default Unicode) and both case sensitivities, each paired with its
//! own ĝ per the Alphabet Contract and caseless fold guard (PROOF.md §3.6–§3.7).

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");
const crest = gist.crest;

const corpus_mod = gist.corpus;
const Regex = gist.regex.Regex;
const load = corpus_mod.load;
const K = crest.K;
const Span = gist.assay.Span; // package instrumentation floor: monotonic Span
const evidence = @import("evidence/harness.zig");
const out_dir = evidence.out_dir;
const ascii_seed = evidence.ascii_seed;
const unicode_seed = evidence.unicode_seed;
const caseless_seed_mask = evidence.caseless_seed_mask;
const RandomResult = evidence.RandomResult;
const Row = evidence.Row;

const Query = struct {
    label: []const u8,
    pattern: []const u8,
    caseless: bool = false,
    unicode: bool = false,
};

/// The slate: literal-free class repetitions — the trigram index's blind spot.
/// The caseless rows exercise the case-closed extension. The last two are wide
/// classes, kept HONEST: they should prune ~nothing.
const queries = [_]Query{
    .{ .label = "hex-8  (uuid/sha)", .pattern = "[0-9a-f]{8}" },
    .{ .label = "hex-12 (mac/hash)", .pattern = "[0-9a-f]{12}" },
    .{ .label = "digit-4 (year)", .pattern = "[0-9]{4}" },
    .{ .label = "digit-6", .pattern = "[0-9]{6}" },
    .{ .label = "upper-4 (CONST)", .pattern = "[A-Z]{4}" },
    .{ .label = "upper-6", .pattern = "[A-Z]{6}" },
    .{ .label = "ci-hex-8  (?i)uuid", .pattern = "[0-9a-f]{8}", .caseless = true, .unicode = true },
    .{ .label = "ci-hex-12 (?i)mac", .pattern = "[0-9a-f]{12}", .caseless = true, .unicode = true },
    .{ .label = "ci-upper-6 -iu A-Z", .pattern = "[A-Z]{6}", .caseless = true },
    .{ .label = "word-3 (wide)", .pattern = "\\w{3,8}" },
    .{ .label = "alpha-5 (wide)", .pattern = "[A-Za-z]{5}" },
    // The disjunctive rows: two alternatives forcing classes with no common
    // superclass. A collapsed single-vector ĝ is 0⃗ for both, so the whole sieve
    // used to stand down — which is what `gist -e A -e B` compiles to.
    .{ .label = "alt hex-12|rule-60", .pattern = "[0-9a-f]{12}|~{60}" },
    .{ .label = "alt digit-6|CONST-6", .pattern = "[0-9]{6}|[A-Z]{6}" },
    // THE DEFAULT-FLAG SPELLINGS, which is how these queries are actually
    // typed. `unicode` is the engine's own default and it lowers a Perl escape
    // to a CODEPOINT class, so these rows measure a different sieve from their
    // character-for-character ASCII twins above: `\d{6}` used to certify
    // nothing at all and prune 0% where `[0-9]{6}` pruned 92.7%.
    .{ .label = "\\d{6}  -u default", .pattern = "\\d{6}", .unicode = true },
    .{ .label = "\\d{4}  -u default", .pattern = "\\d{4}", .unicode = true },
    .{ .label = "\\w{8}  -u (wide)", .pattern = "\\w{8}", .unicode = true },
    .{ .label = "\\s{4}  -u", .pattern = "\\s{4}", .unicode = true },
    .{ .label = "[0-9]{6} -u (twin)", .pattern = "[0-9]{6}", .unicode = true },
};

/// One alternative, as `member:run` pairs; alternatives joined by `|`.
///
/// A class and its scalar twin agree on most queries — an ASCII byte class
/// certifies both halves identically — so naming both would double the column
/// to say one thing. Equal pairs collapse to the bare class name; the twin is
/// named only where it carries a demand the ASCII half does not, which is
/// exactly the codepoint-class case worth seeing.
fn forcedStr(buf: []u8, branches: []const crest.Vector) []const u8 {
    var end: usize = 0;
    for (branches) |gv| {
        if (end > 0) end += (std.fmt.bufPrint(buf[end..], "|", .{}) catch break).len;
        for (std.enums.values(crest.Class)) |c| {
            const a = gv[crest.lane(c, .ascii)];
            const s = gv[crest.lane(c, .scalar)];
            if (a == 0 and s == 0) continue;
            const sep: []const u8 = if (end > 0 and buf[end - 1] != '|') " " else "";
            const part = (if (a == s)
                std.fmt.bufPrint(buf[end..], "{s}{s}:{d}", .{ sep, @tagName(c), a })
            else if (a == 0)
                std.fmt.bufPrint(buf[end..], "{s}{s}+u:{d}", .{ sep, @tagName(c), s })
            else
                std.fmt.bufPrint(buf[end..], "{s}{s}:{d}+u:{d}", .{ sep, @tagName(c), a, s })) catch break;
            end += part.len;
        }
    }
    return if (end == 0) "—" else buf[0..end];
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const config = evidence.parseArgs(init);
    var violations: usize = 0;
    const fixed = try evidence.fixedRegression(gpa, &violations);
    if (violations != 0) {
        std.debug.print("FAILED: fixed production matcher regression did not hold; refusing corpus timing.\n", .{});
        std.process.exit(1);
    }

    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try load(gpa, io, roots, .contiguous);
    defer corpus.deinit();

    const n = corpus.docs.len;
    const mib = @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20);

    // Build the crest table via the PRODUCTION builder (the same parallel pass
    // `gist index` persists as crest.bin) + the count index (ablation).
    const build_sp = Span.open(io);
    const crests = try gist.crest_sidecar.build(gpa, corpus.docs);
    defer gpa.free(crests);
    const build = build_sp.read(io);

    const counts = try gpa.alloc([K]u32, n);
    defer gpa.free(counts);
    for (corpus.docs, 0..) |d, i| counts[i] = classCounts(d);

    const idx_bytes = n * K * @sizeOf(u16);
    std.debug.print("Crest — production proof · abi v{d} · {d} measured runs after {d} warmup\n", .{ gist.abi(), config.runs, config.warmup });
    std.debug.print("machine: {s} · zig {s}\n", .{ @tagName(builtin.target.cpu.arch), builtin.zig_version_string });
    std.debug.print("corpus:  {d} files · {d:.1} MiB\n", .{ n, mib });
    std.debug.print("index:   crest built in {d:.2} ms · {d} classes · ~{d:.1} KiB ({d:.4}% of corpus)\n\n", .{
        build.ms(),                                  K,
        @as(f64, @floatFromInt(idx_bytes)) / 1024.0, @as(f64, @floatFromInt(idx_bytes)) / @as(f64, @floatFromInt(@max(corpus.bytes, 1))) * 100.0,
    });
    try scanProof(io, corpus.docs, corpus.bytes, config.runs, &violations);
    if (violations != 0) {
        std.debug.print("FAILED: the block scan disagrees with the per-byte definition the proof is stated over.\n", .{});
        std.process.exit(1);
    }

    std.debug.print("{s:<20} {s:>30} {s:>10} {s:>11} {s:>10} {s:>10} {s:>10} {s:>9}\n", .{ "query", "forced ĝ (per alternative)", "RUN prune%", "FOLD prune%", "CNT prune%", "full ms", "sieve ms", "speedup" });
    std.debug.print("{s:-<20} {s:->30} {s:->10} {s:->11} {s:->10} {s:->10} {s:->10} {s:->9}\n", .{ "", "", "", "", "", "", "", "" });

    var rows: std.ArrayList(Row) = .empty;
    defer {
        for (rows.items) |row| {
            gpa.free(row.ghat);
            gpa.free(row.full_samples_ns);
            gpa.free(row.sieve_samples_ns);
        }
        rows.deinit(gpa);
    }

    for (queries) |q| {
        // Matcher and ĝ share the SAME parse, options, and fold — one AST, so
        // the Alphabet Contract holds by construction rather than by pairing.
        const opts: Regex.Options = .{ .caseless = q.caseless, .unicode = q.unicode };
        const swell = Regex.forcedSwell(gpa, q.pattern, opts);

        var re = try Regex.compileOpts(gpa, q.pattern, opts);
        defer re.deinit();
        var sim = try Regex.Sim.init(gpa, &re);
        defer sim.deinit();

        // (1) Untimed, per-document differential: the real matcher is the
        // authority, and every matched document is checked directly against
        // the production Crest decision. Aggregate equality alone is not the
        // proof: matched_and_pruned must itself remain zero.
        const diff = evidence.differential(&re, &sim, corpus.docs, crests, swell);
        if (diff.matched_and_pruned != 0 or diff.sieve_hits != diff.matched) {
            violations += 1;
            std.debug.print(
                "  !! SOUNDNESS VIOLATION on {s}: matched_and_pruned={d}, sieve {d} hits, full {d} — matched⇒¬pruned failed!\n",
                .{ q.pattern, diff.matched_and_pruned, diff.sieve_hits, diff.matched },
            );
        }

        // (2) Warm the exact paths that will be timed, validating every pass.
        for (0..config.warmup) |_| {
            const full = evidence.timeFull(io, &re, &sim, corpus.docs);
            const sieve = evidence.timeSieve(io, &re, &sim, corpus.docs, crests, swell);
            if (full.hits != diff.matched or sieve.hits != diff.matched or sieve.survivors != diff.survivors) {
                violations += 1;
                std.debug.print("  !! WARMUP DIFFERENTIAL DRIFT on {s}: full={d} sieve={d} survivors={d}\n", .{
                    q.pattern, full.hits, sieve.hits, sieve.survivors,
                });
            }
        }

        // (3) Raw timing evidence. Samples are retained in run JSON in
        // execution order; crest.csv remains the aggregate summary.
        const full_samples = try gpa.alloc(u64, config.runs);
        errdefer gpa.free(full_samples);
        const sieve_samples = try gpa.alloc(u64, config.runs);
        errdefer gpa.free(sieve_samples);
        for (0..config.runs) |run| {
            const full = evidence.timeFull(io, &re, &sim, corpus.docs);
            const sieve = evidence.timeSieve(io, &re, &sim, corpus.docs, crests, swell);
            full_samples[run] = full.ns;
            sieve_samples[run] = sieve.ns;
            if (full.hits != diff.matched or sieve.hits != diff.matched or sieve.survivors != diff.survivors) {
                violations += 1;
                std.debug.print("  !! TIMED DIFFERENTIAL DRIFT on {s} run {d}: full={d} sieve={d} survivors={d}\n", .{
                    q.pattern, run, full.hits, sieve.hits, sieve.survivors,
                });
            }
        }
        const full_ns = try evidence.upperMedian(gpa, full_samples);
        const sieve_ns = try evidence.upperMedian(gpa, sieve_samples);

        // (4) two ablations at the same ĝ, both sound, both dominated:
        //     CNT — the count cousin (total class population ≥ longest run);
        //     FOLD — the retired single-vector sieve (componentwise min over
        //     the alternatives), which is what this change replaced.
        var cnt_survivors: usize = 0;
        for (counts) |c| {
            if (!countPruned(c, swell)) cnt_survivors += 1;
        }
        const folded = foldSwell(swell);
        var fold_survivors: usize = 0;
        for (crests) |rho| {
            if (!crest.pruned(rho, folded)) fold_survivors += 1;
        }
        // Dominance, checked rather than argued: min ĝᵢ ≤ ĝⱼ for every branch,
        // so anything the fold pruned the disjunction prunes too. A row where
        // the disjunction survived MORE files would mean the new sieve lost
        // selectivity somewhere, and that is a defect, not a tradeoff.
        if (diff.survivors > fold_survivors) {
            violations += 1;
            std.debug.print("  !! DOMINANCE VIOLATION on {s}: disjunction left {d} survivors, the retired fold left {d}\n", .{
                q.pattern, diff.survivors, fold_survivors,
            });
        }

        const branches = try gpa.dupe(crest.Vector, swell.crests[0..swell.len]);
        errdefer gpa.free(branches);
        try rows.append(gpa, .{
            .label = q.label,
            .pattern = q.pattern,
            .caseless = q.caseless,
            .unicode = q.unicode,
            .ghat = branches,
            .files = n,
            .run_survivors = diff.survivors,
            .fold_survivors = fold_survivors,
            .cnt_survivors = cnt_survivors,
            .hits = diff.matched,
            .full_ns = full_ns,
            .sieve_ns = sieve_ns,
            .differential = diff,
            .full_samples_ns = full_samples,
            .sieve_samples_ns = sieve_samples,
        });

        var fbuf: [256]u8 = undefined;
        const run_pct = (1.0 - @as(f64, @floatFromInt(diff.survivors)) / @as(f64, @floatFromInt(@max(n, 1)))) * 100.0;
        const fold_pct = (1.0 - @as(f64, @floatFromInt(fold_survivors)) / @as(f64, @floatFromInt(@max(n, 1)))) * 100.0;
        const cnt_pct = (1.0 - @as(f64, @floatFromInt(cnt_survivors)) / @as(f64, @floatFromInt(@max(n, 1)))) * 100.0;
        const full_ms = @as(f64, @floatFromInt(full_ns)) / 1e6;
        const sieve_ms = @as(f64, @floatFromInt(sieve_ns)) / 1e6;
        const speed = if (sieve_ns > 0) @as(f64, @floatFromInt(full_ns)) / @as(f64, @floatFromInt(sieve_ns)) else 0;
        std.debug.print("{s:<20} {s:>30} {d:>9.1}% {d:>10.1}% {d:>9.1}% {d:>9.2} {d:>9.2} {d:>8.2}x\n", .{
            q.label, forcedStr(&fbuf, branches), run_pct, fold_pct, cnt_pct, full_ms, sieve_ms, speed,
        });
    }

    std.debug.print("\nRUN = Crest sieve (disjunction of per-alternative forced runs) · FOLD = retired single-vector sieve (componentwise min over the alternatives) · CNT = weaker cousin (total class population, same ĝ)\n", .{});

    // (5) randomized adversarial soundness sweep — both engine modes × both
    //     case sensitivities, each paired with its own ĝ.
    const ascii_checks = try randomSoundness(gpa, &corpus, false, false, &violations);
    const uni_checks = try randomSoundness(gpa, &corpus, true, false, &violations);
    const ci_ascii_checks = try randomSoundness(gpa, &corpus, false, true, &violations);
    const ci_uni_checks = try randomSoundness(gpa, &corpus, true, true, &violations);
    std.debug.print(
        "randomized soundness: {d} ASCII + {d} Unicode + {d} (?i)ASCII + {d} (?i)Unicode (pattern,file) pairs · matched⇒¬pruned held on all\n",
        .{ ascii_checks.checks, uni_checks.checks, ci_ascii_checks.checks, ci_uni_checks.checks },
    );

    const manifest_sha = try evidence.writeCorpusManifest(gpa, io, &corpus);
    try writeCsv(gpa, io, n, mib, rows.items);
    try evidence.writeRunJson(gpa, io, .{
        .config = .{ .runs = config.runs, .warmup = config.warmup },
        .engine = .{
            .abi_version = gist.abi(),
            .architecture = @tagName(builtin.target.cpu.arch),
            .zig_version = builtin.zig_version_string,
        },
        .corpus = .{
            .roots = roots,
            .file_count = n,
            .total_bytes = corpus.bytes,
            .manifest_sha256 = &manifest_sha,
        },
        .seeds = .{ .ascii = ascii_seed, .unicode = unicode_seed, .caseless_mask = caseless_seed_mask },
        .fixed_regression = &fixed,
        .queries = rows.items,
        .randomized_soundness = .{
            .ascii = ascii_checks,
            .unicode = uni_checks,
            .caseless_ascii = ci_ascii_checks,
            .caseless_unicode = ci_uni_checks,
        },
        .violations = violations,
        .passed = violations == 0,
    });
    std.debug.print("wrote {s}/crest.csv, crest-run.json, corpus-manifest.tsv\n", .{out_dir});

    if (violations > 0) {
        std.debug.print("\nFAILED: {d} soundness violation(s) — the sieve pruned a real match. Do NOT weaken; fix the calculus.\n", .{violations});
        std.process.exit(1);
    }
    std.debug.print("\nPROVEN: 0 false negatives across the corpus and random sweeps; Crest prunes the configured literal-free slate where Gist's required-literal trigram extractor yields no requirement, and the count cousin is weaker.\n", .{});
}

/// The retired document half: one table load and k data-dependent lane updates
/// PER BYTE. Kept as the reference for both things a rewrite has to prove —
/// that the block scan answers identically, and that it is faster.
fn referenceCrest(doc: []const u8) crest.Vector {
    var best: crest.Vector = @splat(0);
    var cur: [K]u32 = @splat(0);
    for (doc) |b| {
        const m = crest.membership[b];
        inline for (0..K) |i| {
            if ((m & (@as(crest.Mask, 1) << i)) != 0) {
                cur[i] +|= 1;
                best[i] = @max(best[i], @as(u16, @intCast(@min(cur[i], std.math.maxInt(u16)))));
            } else cur[i] = 0;
        }
    }
    return best;
}

/// The document half, measured against the algorithm it replaced on the very
/// bytes the sieve runs over.
///
/// BYTE PARITY FIRST: every document is scanned both ways and the two vectors
/// compared element for element. A faster scan that answers differently is not
/// a faster scan, and the sieve's soundness proof is stated over the per-byte
/// definition — so this is the link between the proof and the shipped code.
/// Only then are the two timed, same corpus, same order, checksummed so
/// neither side can be optimized away.
fn scanProof(io: std.Io, docs: []const []const u8, bytes: usize, runs: usize, violations: *usize) !void {
    for (docs) |d| {
        const fast = crest.crest(d);
        const slow = referenceCrest(d);
        if (!std.mem.eql(u16, &fast, &slow)) {
            violations.* += 1;
            std.debug.print("  !! SCAN PARITY VIOLATION on a {d}-byte document: block scan {any} ≠ per-byte {any}\n", .{ d.len, fast, slow });
            return;
        }
    }

    // Interleaved, and scored on the MINIMUM. Ten agents share this machine, so
    // a median samples the neighbors' compile jobs as much as the code under
    // test; the fastest observed run is the one least contaminated by them, and
    // alternating the two scans run-by-run keeps that contamination shared.
    var sink: u64 = 0;
    var fastest: [2]u64 = @splat(std.math.maxInt(u64));
    for (0..runs + 1) |r| {
        inline for (.{ crest.crest, referenceCrest }, 0..) |scan, which| {
            const sp = Span.open(io);
            for (docs) |d| sink +%= scan(d)[0];
            const ns: u64 = @intCast(sp.read(io).ns());
            if (r > 0) fastest[which] = @min(fastest[which], ns); // r == 0 warms
        }
    }
    for (fastest, [2][]const u8{ "scan:    shipped ", " · per-byte reference " }) |ns, label| {
        std.debug.print("{s}{d:.2} GiB/s ({d:.1} ms)", .{
            label,
            @as(f64, @floatFromInt(bytes)) / (@as(f64, @floatFromInt(ns)) / 1e9) / (1 << 30),
            @as(f64, @floatFromInt(ns)) / 1e6,
        });
    }
    std.debug.print(" · {d:.2}x · byte-identical on all {d} documents [checksum {x}]\n\n", .{
        @as(f64, @floatFromInt(fastest[1])) / @as(f64, @floatFromInt(fastest[0])),
        docs.len,
        sink,
    });
}

/// The weaker cousin: total per-class population (branch B). Sound but dominated.
fn classCounts(doc: []const u8) [K]u32 {
    var cnt: [K]u32 = @splat(0);
    for (doc) |b| {
        const bits = crest.membership[b];
        inline for (0..K) |i| {
            if ((bits & (@as(crest.Mask, 1) << i)) != 0) cnt[i] += 1;
        }
    }
    return cnt;
}

/// The retired single-vector ĝ: componentwise min over the alternatives. Sound,
/// and exactly as strong as the disjunction when there is only one branch —
/// which is why the regression it caused stayed invisible until multi-`-e`.
fn foldSwell(swell: crest.Swell) crest.Vector {
    if (swell.len == 0) return crest.zero_vector;
    var folded = swell.crests[0];
    for (swell.crests[1..swell.len]) |gv| {
        inline for (0..K) |i| folded[i] = @min(folded[i], gv[i]);
    }
    return folded;
}

/// The cousin's sieve decision at the same ĝ (population < forced run ⇒ prune),
/// read over the same disjunction so the ablation compares functionals rather
/// than query languages.
fn countPruned(cnt: [K]u32, swell: crest.Swell) bool {
    if (swell.len == 0) return false;
    for (swell.crests[0..swell.len]) |gv| {
        var short = false;
        inline for (0..K) |i| {
            if (cnt[i] < gv[i]) short = true;
        }
        if (!short) return false;
    }
    return true;
}

/// Randomized adversarial soundness: build class-repetition patterns with random
/// classes / counts / concatenation / alternation, compile with the REAL engine
/// in the requested mode, and assert matched ⇒ ¬pruned on a sample of real
/// files — ĝ computed with the SAME mode flag the engine got, exactly as the
/// production `gate.winnow` pairs them. Returns exact differential counts and
/// the seed, so the sweep is independently replayable from crest-run.json.
fn randomSoundness(gpa: std.mem.Allocator, corpus: *const corpus_mod.Corpus, unicode: bool, caseless: bool, violations: *usize) !RandomResult {
    const seed = (if (unicode) unicode_seed else ascii_seed) ^ (if (caseless) caseless_seed_mask else 0);
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const atoms = [_][]const u8{ "[0-9]", "[0-9a-f]", "[A-Z]", "[a-z]", "[A-Za-z]", "\\d", "\\w", "\\s", "[A-Za-z0-9]", "[0-7]" };
    var result: RandomResult = .{
        .unicode = unicode,
        .caseless = caseless,
        .seed = seed,
        .patterns = 0,
        .checks = 0,
        .matches = 0,
        .pruned = 0,
        .violations = 0,
    };
    var buf: [128]u8 = undefined;

    var iter: usize = 0;
    while (iter < 400) : (iter += 1) {
        var end: usize = 0;
        const terms = 1 + rnd.uintLessThan(usize, 3);
        for (0..terms) |t| {
            const alt: []const u8 = if (t > 0 and rnd.boolean()) "|" else "";
            const quant = rnd.uintLessThan(u8, 4);
            var qbuf: [16]u8 = undefined;
            const q: []const u8 = switch (quant) {
                0 => std.fmt.bufPrint(&qbuf, "{{{d}}}", .{1 + rnd.uintLessThan(u32, 10)}) catch "",
                1 => std.fmt.bufPrint(&qbuf, "{{{d},}}", .{1 + rnd.uintLessThan(u32, 6)}) catch "",
                2 => "+",
                else => "",
            };
            const part = std.fmt.bufPrint(buf[end..], "{s}{s}{s}", .{ alt, atoms[rnd.uintLessThan(usize, atoms.len)], q }) catch break;
            end += part.len;
        }
        const pat = buf[0..end];
        const opts: Regex.Options = .{ .caseless = caseless, .unicode = unicode };
        var re = Regex.compileOpts(gpa, pat, opts) catch continue;
        defer re.deinit();
        var sim = Regex.Sim.init(gpa, &re) catch continue;
        defer sim.deinit();
        const swell = Regex.forcedSwell(gpa, pat, opts);
        result.patterns += 1;

        // sample up to 60 files per pattern
        var s: usize = 0;
        while (s < 60) : (s += 1) {
            const d = corpus.docs[rnd.uintLessThan(usize, corpus.docs.len)];
            result.checks += 1;
            const matched = re.docMatch(&sim, d);
            const pruned = swell.prunes(crest.crest(d));
            if (matched) result.matches += 1;
            if (pruned) result.pruned += 1;
            if (matched and pruned) {
                violations.* += 1;
                result.violations += 1;
                std.debug.print("  !! RANDOM SOUNDNESS VIOLATION: pat={s} unicode={} caseless={} pruned a match\n", .{ pat, unicode, caseless });
            }
        }
    }
    return result;
}

fn writeCsv(gpa: std.mem.Allocator, io: std.Io, n: usize, mib: f64, rows: []const Row) !void {
    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(gpa);
    try csv.appendSlice(gpa, "# corpus_files\tcorpus_mib\n");
    var line: [256]u8 = undefined;
    try csv.appendSlice(gpa, try std.fmt.bufPrint(&line, "# {d}\t{d:.1}\n", .{ n, mib }));
    try csv.appendSlice(gpa, "query\tpattern\tcaseless\tunicode\talternatives\tfiles\trun_survivors\tfold_survivors\tcnt_survivors\trun_prune_pct\tfold_prune_pct\tcnt_prune_pct\thits\tfull_ms\tsieve_ms\tspeedup\n");
    for (rows) |r| {
        const pct = struct {
            fn of(survivors: usize, files: usize) f64 {
                return (1.0 - @as(f64, @floatFromInt(survivors)) / @as(f64, @floatFromInt(@max(files, 1)))) * 100.0;
            }
        }.of;
        const speed = if (r.sieve_ns > 0) @as(f64, @floatFromInt(r.full_ns)) / @as(f64, @floatFromInt(r.sieve_ns)) else 0;
        try csv.appendSlice(gpa, try std.fmt.bufPrint(&line, "{s}\t{s}\t{}\t{}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d:.2}\t{d:.2}\t{d:.2}\t{d}\t{d:.3}\t{d:.3}\t{d:.3}\n", .{
            r.label,                 r.pattern,                r.caseless,              r.unicode, r.ghat.len,                               r.files,                                   r.run_survivors, r.fold_survivors, r.cnt_survivors,
            pct(r.run_survivors, n), pct(r.fold_survivors, n), pct(r.cnt_survivors, n), r.hits,    @as(f64, @floatFromInt(r.full_ns)) / 1e6, @as(f64, @floatFromInt(r.sieve_ns)) / 1e6, speed,
        }));
    }
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    var d = try std.Io.Dir.cwd().openDir(io, out_dir, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = "crest.csv", .data = csv.items });
}

//! Crest — production proof harness (Layer: does it actually work + how fast).
//!
//! Links this package's REAL engine (`@import("irregex")` — the crest kernel
//! ships inside it at `src/kernel/math/crest.zig`) and walks the REAL host
//! corpus via the same `corpus.load` the certificate layers use, so this is not
//! a toy: the baseline is our production `Regex.docMatch`, and every claim is a
//! measured number over live source bytes.
//!
//! For each class-repetition query it establishes three things, fail-closed:
//!   1. SOUNDNESS (the load-bearing claim). For EVERY file, if the real matcher
//!      matches then the Crest sieve must NOT prune it. A single violation over
//!      the whole corpus exits non-zero — no bandaid. This is the
//!      Sieve Theorem checked against the production matcher on 100+ MiB.
//!   2. PRUNING. What fraction of files the k-int crest compare removes before
//!      the matcher runs — on exactly the class where the trigram index prunes
//!      0% (Certificate class `regex-classcount`, cand%=100%).
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
const crest = gist.math.crest;
const crest_sidecar = gist.index.crest;
const crest_runtime = gist.index.crest_runtime;
const signet = gist.index.signet;

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
    // used to stand down — which is what a `-e A -e B` invocation compiles to.
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

/// One alternative as `predicate:r1/r2/...`; alternatives joined by `|`.
/// Rank values stay in evidence order instead of collapsing q4 back to q1.
fn forcedStr(buf: []u8, branches: []const crest.Requirement, rank: u8) []const u8 {
    var end: usize = 0;
    for (branches) |requirement| {
        if (end > 0) end += (std.fmt.bufPrint(buf[end..], "|", .{}) catch break).len;
        for (0..K) |predicate| {
            var any = false;
            for (0..rank) |r| any = any or requirement[crest.spectrumLane(predicate, r)] != 0;
            if (!any) continue;
            const sep: []const u8 = if (end > 0 and buf[end - 1] != '|') " " else "";
            const part = std.fmt.bufPrint(buf[end..], "{s}{s}:", .{ sep, crest.className(predicate) }) catch break;
            end += part.len;
            for (0..rank) |r| {
                const delimiter: []const u8 = if (r == 0) "" else "/";
                end += (std.fmt.bufPrint(buf[end..], "{s}{d}", .{
                    delimiter,
                    requirement[crest.spectrumLane(predicate, r)],
                }) catch break).len;
            }
        }
    }
    return if (end == 0) "—" else buf[0..end];
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const config = evidence.parseArgs(init);
    if (config.help) {
        evidence.printUsage();
        return;
    }
    if (config.self_test) {
        try selfTest(gpa, config);
        return;
    }
    var violations: usize = 0;
    const fixed = try evidence.fixedRegression(gpa, config, &violations);
    if (violations != 0) {
        std.debug.print("FAILED: fixed production matcher regression did not hold; refusing corpus timing.\n", .{});
        std.process.exit(1);
    }

    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try load(gpa, io, roots, .contiguous);
    defer corpus.deinit();

    // A soundness proof over zero documents proves nothing, and this lane is
    // fail-closed, so it must refuse rather than report a clean sweep of an
    // empty set. It also cannot survive one: the adversarial sweep below draws
    // `rnd.uintLessThan(usize, corpus.docs.len)`, which on an empty corpus is
    // UB — the failure a mint run from the wrong directory actually hit was a
    // SEGV, which reads as a broken proof instead of a missing corpus.
    if (corpus.docs.len == 0) {
        std.debug.print(
            "crest: no documents under the corpus roots — nothing to prove.\n" ++
                "Run this from the tree being measured (the mint does: `cd $CORPUS`),\n" ++
                "or set GIST_ROOTS to roots that exist there.\n",
            .{},
        );
        return error.EmptyCorpus;
    }

    const n = corpus.docs.len;
    const mib = @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20);

    // Build, encode, seal, decode, and validate the production v6 sidecar.
    const build_sp = Span.open(io);
    var production = try ProductionIndex.init(gpa, corpus.docs);
    defer production.deinit(gpa);
    const build = build_sp.read(io);
    const spectra = production.spectra;
    const view = production.view;
    const calibration = crest_runtime.calibratedCosts();
    const calibrated = calibration != null;

    const counts = try gpa.alloc([K]u32, n);
    defer gpa.free(counts);
    for (corpus.docs, 0..) |d, i| counts[i] = classCounts(d);

    const idx_bytes = production.encoded.len;
    std.debug.print("Crest — production proof · query q={d}, B={d} · abi v{d} · {d} measured runs after {d} warmup\n", .{
        config.rank,
        config.budget,
        gist.abi(),
        config.runs,
        config.warmup,
    });
    std.debug.print("machine: {s} · zig {s}\n", .{ @tagName(builtin.target.cpu.arch), builtin.zig_version_string });
    std.debug.print("corpus:  {d} files · {d:.1} MiB\n", .{ n, mib });
    std.debug.print("index:   production v6 sidecar built+sealed+decoded in {d:.2} ms · {d} predicates × sidecar q{d} · {d:.1} KiB · {d} overflow entries ({d:.4}% of corpus)\n", .{
        build.ms(),                                  K,                           production.view.q,
        @as(f64, @floatFromInt(idx_bytes)) / 1024.0, production.overflow_entries, @as(f64, @floatFromInt(idx_bytes)) / @as(f64, @floatFromInt(@max(corpus.bytes, 1))) * 100.0,
    });
    std.debug.print("planner: calibration {s}; uncalibrated production policy is always-sieve\n\n", .{
        if (calibrated) "present (cost-gated)" else "absent",
    });
    try scanProof(io, corpus.docs, spectra, corpus.bytes, config.runs, &violations);
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
        const swell = Regex.forcedRankedSwell(gpa, q.pattern, opts, config.budget, config.rank);

        var re = try Regex.compileOpts(gpa, q.pattern, opts);
        defer re.deinit();
        var sim = try Regex.Sim.init(gpa, &re);
        defer sim.deinit();

        // (1) Untimed, per-document differential: the real matcher is the
        // authority, and every matched document is checked directly against
        // the production Crest decision. Aggregate equality alone is not the
        // proof: matched_and_pruned must itself remain zero.
        const applied = try evidence.differential(
            gpa,
            &re,
            &sim,
            corpus.docs,
            view,
            swell,
            calibrated,
        );
        const diff = applied.counts;
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
            const sieve = try evidence.timeSieve(
                gpa,
                io,
                &re,
                &sim,
                corpus.docs,
                view,
                swell,
                calibrated,
            );
            if (full.hits != diff.matched or
                sieve.hits != diff.matched or
                sieve.survivors != diff.survivors or
                !plannerEqual(sieve.planner.?, applied.planner))
            {
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
            const sieve = try evidence.timeSieve(
                gpa,
                io,
                &re,
                &sim,
                corpus.docs,
                view,
                swell,
                calibrated,
            );
            full_samples[run] = full.ns;
            sieve_samples[run] = sieve.ns;
            if (full.hits != diff.matched or
                sieve.hits != diff.matched or
                sieve.survivors != diff.survivors or
                !plannerEqual(sieve.planner.?, applied.planner))
            {
                violations += 1;
                std.debug.print("  !! TIMED DIFFERENTIAL DRIFT on {s} run {d}: full={d} sieve={d} survivors={d}\n", .{
                    q.pattern, run, full.hits, sieve.hits, sieve.survivors,
                });
            }
        }
        const full_ns = try evidence.upperMedian(gpa, full_samples);
        const sieve_ns = try evidence.upperMedian(gpa, sieve_samples);

        // (4) two untimed kernel micro-oracles at the same ĝ, neither a release
        //     speed/index claim:
        //     CNT — the count cousin (total class population ≥ longest run);
        //     FOLD — the retired collapsed sieve (componentwise min over the
        //     alternatives at every selected rank).
        var cnt_survivors: usize = 0;
        for (counts) |c| {
            if (!countPruned(c, swell)) cnt_survivors += 1;
        }
        const folded = foldSwell(swell);
        var fold_survivors: usize = 0;
        for (spectra) |spectrum| {
            if (!folded.prunesSpectrum(spectrum)) fold_survivors += 1;
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

        const branches = try gpa.dupe(crest.Requirement, swell.requirements[0..swell.len]);
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
            .planner = applied.planner,
            .full_samples_ns = full_samples,
            .sieve_samples_ns = sieve_samples,
        });

        var fbuf: [1024]u8 = undefined;
        const run_pct = (1.0 - @as(f64, @floatFromInt(diff.survivors)) / @as(f64, @floatFromInt(@max(n, 1)))) * 100.0;
        const fold_pct = (1.0 - @as(f64, @floatFromInt(fold_survivors)) / @as(f64, @floatFromInt(@max(n, 1)))) * 100.0;
        const cnt_pct = (1.0 - @as(f64, @floatFromInt(cnt_survivors)) / @as(f64, @floatFromInt(@max(n, 1)))) * 100.0;
        const full_ms = @as(f64, @floatFromInt(full_ns)) / 1e6;
        const sieve_ms = @as(f64, @floatFromInt(sieve_ns)) / 1e6;
        const speed = if (sieve_ns > 0) @as(f64, @floatFromInt(full_ns)) / @as(f64, @floatFromInt(sieve_ns)) else 0;
        std.debug.print("{s:<20} {s:>30} {d:>9.1}% {d:>10.1}% {d:>9.1}% {d:>9.2} {d:>9.2} {d:>8.2}x\n", .{
            q.label, forcedStr(&fbuf, branches, config.rank), run_pct, fold_pct, cnt_pct, full_ms, sieve_ms, speed,
        });
    }

    std.debug.print("\nRUN = production v6 View + crest_runtime.apply · FOLD/CNT = untimed kernel micro-oracles only\n", .{});

    // (5) randomized adversarial soundness sweep — both engine modes × both
    //     case sensitivities, each paired with its own ĝ.
    const ascii_checks = try randomSoundness(gpa, &corpus, view, config, calibrated, false, false, &violations);
    const uni_checks = try randomSoundness(gpa, &corpus, view, config, calibrated, true, false, &violations);
    const ci_ascii_checks = try randomSoundness(gpa, &corpus, view, config, calibrated, false, true, &violations);
    const ci_uni_checks = try randomSoundness(gpa, &corpus, view, config, calibrated, true, true, &violations);
    std.debug.print(
        "randomized soundness: {d} ASCII + {d} Unicode + {d} (?i)ASCII + {d} (?i)Unicode (pattern,file) pairs · matched⇒¬pruned held on all\n",
        .{ ascii_checks.checks, uni_checks.checks, ci_ascii_checks.checks, ci_uni_checks.checks },
    );

    const manifest_sha = try evidence.writeCorpusManifest(gpa, io, &corpus);
    var profile_buf: [16]u8 = undefined;
    const profile = try evidence.profileName(&profile_buf, config);
    var csv_buf: [32]u8 = undefined;
    const csv_name = try evidence.csvName(&csv_buf, config);
    var run_json_buf: [40]u8 = undefined;
    const run_json_name = try evidence.runJsonName(&run_json_buf, config);
    try writeCsv(gpa, io, csv_name, config, n, mib, rows.items);
    try evidence.writeRunJson(gpa, io, run_json_name, .{
        .config = .{
            .runs = config.runs,
            .warmup = config.warmup,
            .rank = config.rank,
            .budget = config.budget,
            .profile = profile,
        },
        .engine = .{
            .abi_version = gist.abi(),
            .architecture = @tagName(builtin.target.cpu.arch),
            .zig_version = builtin.zig_version_string,
        },
        .production = .{
            .sidecar_format_version = crest.SidecarSchema.format_version,
            .encoded_bytes = production.encoded.len,
            .overflow_entries = production.overflow_entries,
            .sidecar_q = production.view.q,
            .query_rank = config.rank,
            .validated = true,
            .planner_calibration = if (calibrated) "environment" else "absent",
            .planner_coefficients = if (calibration) |coefficients| .{
                .fixed = coefficients.fixed,
                .column_document = coefficients.column_document,
                .verify_document = coefficients.verify_document,
            } else null,
        },
        .corpus = .{
            .roots = roots,
            .file_count = n,
            .total_bytes = corpus.bytes,
            .manifest_sha256 = &manifest_sha,
        },
        .artifacts = .{
            .aggregate_csv = csv_name,
            .run_json = run_json_name,
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
    std.debug.print("wrote {s}/{s}, {s}, corpus-manifest.tsv\n", .{ out_dir, csv_name, run_json_name });

    if (violations > 0) {
        std.debug.print("\nFAILED: {d} soundness violation(s) — the sieve pruned a real match. Do NOT weaken; fix the calculus.\n", .{violations});
        std.process.exit(1);
    }
    std.debug.print("\nPROVEN: 0 false negatives across the corpus and random sweeps; Crest prunes the configured literal-free slate where Gist's required-literal trigram extractor yields no requirement, and the count cousin is weaker.\n", .{});
}

const ProductionIndex = struct {
    spectra: []crest.Spectrum,
    encoded: []u8,
    view: crest_sidecar.View,
    overflow_entries: usize,

    fn init(gpa: std.mem.Allocator, docs: []const []const u8) !ProductionIndex {
        const sidecar_q: u8 = crest.max_rank;
        const spectra = try crest_sidecar.buildSpectra(gpa, docs);
        errdefer gpa.free(spectra);
        var identity = signet.Scribe.init(.rollup);
        for (docs) |doc| identity.push(signet.of(.content, doc));
        const binding = crest_sidecar.Binding.forBuild(identity.finish());
        const encoded = try gpa.alloc(u8, try crest_sidecar.encodedSize(spectra, sidecar_q));
        errdefer gpa.free(encoded);
        if (try crest_sidecar.writeInto(
            spectra,
            .{ .q = sidecar_q, .binding = binding },
            encoded,
        ) != encoded.len)
            return error.SidecarLengthMismatch;
        try crest_sidecar.verify(encoded);
        const view = crest_sidecar.decode(encoded, .{
            .document_count = @intCast(docs.len),
            .q = sidecar_q,
            .binding = binding,
        }) orelse return error.SidecarValidationFailed;
        for (spectra, 0..) |spectrum, document| for (0..sidecar_q) |rank| for (0..K) |predicate| {
            if (view.value(predicate, rank, document) != spectrum[crest.spectrumLane(predicate, rank)])
                return error.SidecarRoundTripMismatch;
        };
        return .{
            .spectra = spectra,
            .encoded = encoded,
            .view = view,
            .overflow_entries = view.overflow.len / crest_sidecar.overflow_entry_len,
        };
    }

    fn deinit(self: *ProductionIndex, gpa: std.mem.Allocator) void {
        gpa.free(self.encoded);
        gpa.free(self.spectra);
        self.* = undefined;
    }
};

fn exactReferenceMember(property: crest.ExactProperty, cp: u21) bool {
    const ranges = gist.regex.unicode.property(switch (property) {
        .nd => "Nd",
        .letter => "L",
        .white_space => "White_Space",
    }) orelse return false;
    return gist.regex.unicode.inRanges(ranges, cp);
}

fn insertReferenceRun(
    spectrum: *crest.Spectrum,
    predicate: usize,
    value: u16,
) void {
    if (value == 0) return;
    var candidate = value;
    for (0..crest.max_rank) |rank| {
        const lane = crest.spectrumLane(predicate, rank);
        if (candidate > spectrum[lane]) {
            const displaced = spectrum[lane];
            spectrum[lane] = candidate;
            candidate = displaced;
        }
    }
}

/// Independent scalar/property oracle. It shares only the public byte masks,
/// UTF-8 decoder, and pinned UCD tables—not the production spectrum scanner.
fn referenceSpectrum(doc: []const u8) crest.Spectrum {
    var spectrum = crest.zero_spectrum;
    var approximate: [crest.approximate_k]u16 = @splat(0);
    for (doc) |b| {
        const m = crest.membership[b];
        for (0..crest.approximate_k) |predicate| {
            if (predicate >= 2 * crest.base_k and crest.isContinuation(b)) continue;
            if ((m & (@as(crest.Mask, 1) << @intCast(predicate))) != 0) {
                approximate[predicate] +|= 1;
            } else {
                insertReferenceRun(&spectrum, predicate, approximate[predicate]);
                approximate[predicate] = 0;
            }
        }
    }
    for (0..crest.approximate_k) |predicate|
        insertReferenceRun(&spectrum, predicate, approximate[predicate]);

    var exact: [crest.exact_k]u16 = @splat(0);
    var offset: usize = 0;
    while (offset < doc.len) {
        const decoded = gist.regex.decode.decode(doc[offset..]);
        offset += if (decoded) |scalar| scalar.len else 1;
        inline for (std.enums.values(crest.ExactProperty), 0..) |property, index| {
            if (decoded != null and exactReferenceMember(property, decoded.?.cp)) {
                exact[index] +|= 1;
            } else {
                insertReferenceRun(&spectrum, crest.exactLane(property), exact[index]);
                exact[index] = 0;
            }
        }
    }
    inline for (std.enums.values(crest.ExactProperty), 0..) |property, index|
        insertReferenceRun(&spectrum, crest.exactLane(property), exact[index]);
    return spectrum;
}

fn referenceCrest(doc: []const u8) crest.Vector {
    const spectrum = referenceSpectrum(doc);
    var vector = crest.zero_vector;
    for (0..K) |predicate|
        vector[predicate] = spectrum[crest.spectrumLane(predicate, 0)];
    return vector;
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
fn scanProof(
    io: std.Io,
    docs: []const []const u8,
    spectra: []const crest.Spectrum,
    bytes: usize,
    runs: usize,
    violations: *usize,
) !void {
    for (docs, spectra) |d, fast| {
        const slow = referenceSpectrum(d);
        if (!std.mem.eql(u16, &fast, &slow)) {
            violations.* += 1;
            std.debug.print("  !! SCAN PARITY VIOLATION on a {d}-byte document: production spectrum ≠ independent scalar/UCD oracle\n", .{d.len});
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
    std.debug.print(" · {d:.2}x · untimed release claim: kernel scan micro-oracle only; q4-identical on all {d} documents [checksum {x}]\n\n", .{
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
        inline for (0..crest.approximate_k) |predicate| {
            if ((bits & (@as(crest.Mask, 1) << predicate)) != 0)
                cnt[predicate] +|= 1;
        }
    }
    var offset: usize = 0;
    while (offset < doc.len) {
        const decoded = gist.regex.decode.decode(doc[offset..]);
        offset += if (decoded) |scalar| scalar.len else 1;
        if (decoded) |scalar| inline for (std.enums.values(crest.ExactProperty)) |property| {
            if (exactReferenceMember(property, scalar.cp))
                cnt[crest.exactLane(property)] +|= 1;
        };
    }
    return cnt;
}

fn plannerEqual(a: evidence.PlannerState, b: evidence.PlannerState) bool {
    return a.calibrated == b.calibrated and
        a.decision_available == b.decision_available and
        a.ran == b.ran and
        std.mem.eql(u8, a.reason, b.reason) and
        a.touched_columns == b.touched_columns and
        a.candidate_docs == b.candidate_docs and
        a.scanned_docs == b.scanned_docs and
        a.expected_candidates == b.expected_candidates and
        a.expected_rejected == b.expected_rejected and
        a.direct_cost == b.direct_cost and
        a.crest_cost == b.crest_cost and
        a.estimated_savings == b.estimated_savings and
        a.required_savings == b.required_savings;
}

fn selfTest(gpa: std.mem.Allocator, config: evidence.Config) !void {
    const docs = [_][]const u8{
        "123ABC \t",
        "\u{0660}\u{0661}\u{0662}",
        "A\u{0627}b",
        " \u{2003}\t",
        "12\xff34A\xc3(\u{0627}",
        "1" ** 300,
    };
    const expected = [_]struct {
        nd_run: u16,
        nd_count: u32,
        letter_run: u16,
        letter_count: u32,
        whitespace_run: u16,
        whitespace_count: u32,
    }{
        .{ .nd_run = 3, .nd_count = 3, .letter_run = 3, .letter_count = 3, .whitespace_run = 2, .whitespace_count = 2 },
        .{ .nd_run = 3, .nd_count = 3, .letter_run = 0, .letter_count = 0, .whitespace_run = 0, .whitespace_count = 0 },
        .{ .nd_run = 0, .nd_count = 0, .letter_run = 3, .letter_count = 3, .whitespace_run = 0, .whitespace_count = 0 },
        .{ .nd_run = 0, .nd_count = 0, .letter_run = 0, .letter_count = 0, .whitespace_run = 3, .whitespace_count = 3 },
        .{ .nd_run = 2, .nd_count = 4, .letter_run = 1, .letter_count = 2, .whitespace_run = 0, .whitespace_count = 0 },
        .{ .nd_run = 300, .nd_count = 300, .letter_run = 0, .letter_count = 0, .whitespace_run = 0, .whitespace_count = 0 },
    };
    var production = try ProductionIndex.init(gpa, &docs);
    defer production.deinit(gpa);
    if (production.view.q != crest.max_rank or config.rank > production.view.q)
        return error.SidecarQueryRankMismatch;
    if (production.overflow_entries == 0) return error.SelfTestMissedOverflow;
    for (docs, expected, production.spectra) |doc, want, got| {
        const reference = referenceSpectrum(doc);
        if (!std.mem.eql(u16, &reference, &got)) return error.ReferenceSpectrumMismatch;
        const counts = classCounts(doc);
        inline for (.{
            .{ crest.ExactProperty.nd, want.nd_run, want.nd_count },
            .{ crest.ExactProperty.letter, want.letter_run, want.letter_count },
            .{ crest.ExactProperty.white_space, want.whitespace_run, want.whitespace_count },
        }) |case| {
            const lane = crest.exactLane(case[0]);
            if (reference[crest.spectrumLane(lane, 0)] != case[1] or counts[lane] != case[2])
                return error.ExactUcdReferenceMismatch;
        }
    }
    const invalid = referenceSpectrum(docs[4]);
    const nd = crest.exactLane(.nd);
    if (invalid[crest.spectrumLane(nd, 0)] != 2 or
        invalid[crest.spectrumLane(nd, 1)] != 2 or
        invalid[crest.spectrumLane(nd, 2)] != 0)
        return error.InvalidUtf8DidNotResetExactRun;

    const opts: Regex.Options = .{ .unicode = true };
    const swell = Regex.forcedRankedSwell(gpa, "\\d{3}", opts, config.budget, config.rank);
    var re = try Regex.compileOpts(gpa, "\\d{3}", opts);
    defer re.deinit();
    var sim = try Regex.Sim.init(gpa, &re);
    defer sim.deinit();
    const calibrated = crest_runtime.calibratedCosts() != null;
    const applied = try evidence.differential(
        gpa,
        &re,
        &sim,
        &docs,
        production.view,
        swell,
        calibrated,
    );
    if (applied.counts.matched != 3 or
        applied.counts.matched_and_pruned != 0 or
        applied.counts.sieve_hits != applied.counts.matched)
        return error.ProductionRuntimeSoundnessMismatch;
    if (calibrated) {
        var sparse = try std.DynamicBitSet.initEmpty(gpa, docs.len);
        defer sparse.deinit();
        sparse.set(0);
        const sparse_decision = try crest_runtime.apply(gpa, production.view, &sparse, swell);
        const sparse_state = try evidence.plannerState(swell, true, sparse_decision);
        if (sparse_state.candidate_docs != 1 or sparse_state.scanned_docs != 1)
            return error.SparsePlannerScanMismatch;

        var dense = try std.DynamicBitSet.initEmpty(gpa, docs.len);
        defer dense.deinit();
        dense.setRangeValue(.{ .start = 0, .end = 2 }, true);
        const dense_decision = try crest_runtime.apply(gpa, production.view, &dense, swell);
        const dense_state = try evidence.plannerState(swell, true, dense_decision);
        if (dense_state.candidate_docs != 2 or dense_state.scanned_docs != docs.len)
            return error.DensePlannerScanMismatch;
    }
    std.debug.print(
        "crest self-test: query q{d} on sidecar q{d}; scalar/UCD oracle, malformed UTF-8 reset, v6 encode/decode, overflow, and production runtime{s} passed\n",
        .{ config.rank, production.view.q, if (calibrated) " + sparse/dense planner scan" else "" },
    );
}

/// The retired collapsed ĝ: componentwise min over alternatives at every
/// selected rank. Sound, and exactly as strong when there is only one branch —
/// which is why the regression it caused stayed invisible until multi-`-e`.
fn foldSwell(swell: crest.RankedSwell) crest.RankedSwell {
    var folded: crest.RankedSwell = .{ .rank = swell.rank, .budget = swell.budget };
    if (swell.len == 0) return folded;
    folded.len = 1;
    folded.requirements[0] = swell.requirements[0];
    for (swell.requirements[1..swell.len]) |requirement| {
        for (0..@as(usize, swell.rank) * K) |i|
            folded.requirements[0][i] = @min(folded.requirements[0][i], requirement[i]);
    }
    return folded;
}

/// The cousin's sieve decision at the same ĝ (population < forced run ⇒ prune),
/// read over the same disjunction so the ablation compares functionals rather
/// than query languages.
fn countPruned(cnt: [K]u32, swell: crest.RankedSwell) bool {
    if (swell.len == 0) return false;
    for (swell.requirements[0..swell.len]) |requirement| {
        var short = false;
        for (0..swell.rank) |rank| {
            for (0..K) |predicate| {
                if (cnt[predicate] < requirement[crest.spectrumLane(predicate, rank)])
                    short = true;
            }
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
fn randomSoundness(
    gpa: std.mem.Allocator,
    corpus: *const corpus_mod.Corpus,
    view: crest_sidecar.View,
    config: evidence.Config,
    calibrated: bool,
    unicode: bool,
    caseless: bool,
    violations: *usize,
) !RandomResult {
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
        const swell = Regex.forcedRankedSwell(gpa, pat, opts, config.budget, config.rank);
        result.patterns += 1;

        // Apply the production runtime to exactly the sampled candidates.
        var candidates = try std.DynamicBitSet.initEmpty(gpa, corpus.docs.len);
        defer candidates.deinit();
        var sampled: [60]usize = undefined;
        for (&sampled) |*index| {
            index.* = rnd.uintLessThan(usize, corpus.docs.len);
            candidates.set(index.*);
        }
        const decision = try crest_runtime.apply(gpa, view, &candidates, swell);
        _ = try evidence.plannerState(swell, calibrated, decision);
        for (sampled) |index| {
            const d = corpus.docs[index];
            result.checks += 1;
            const matched = re.docMatch(&sim, d);
            const pruned = !candidates.isSet(index);
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

fn writeCsv(gpa: std.mem.Allocator, io: std.Io, filename: []const u8, config: evidence.Config, n: usize, mib: f64, rows: []const Row) !void {
    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(gpa);
    var profile_buf: [16]u8 = undefined;
    const profile = try evidence.profileName(&profile_buf, config);
    try csv.appendSlice(gpa, "# profile\trank\tbudget\n");
    var line: [512]u8 = undefined;
    try csv.appendSlice(gpa, try std.fmt.bufPrint(&line, "# {s}\t{d}\t{d}\n", .{
        profile,
        config.rank,
        config.budget,
    }));
    try csv.appendSlice(gpa, "# corpus_files\tcorpus_mib\n");
    try csv.appendSlice(gpa, try std.fmt.bufPrint(&line, "# {d}\t{d:.1}\n", .{ n, mib }));
    try csv.appendSlice(gpa, "rank\tbudget\tquery\tpattern\tcaseless\tunicode\talternatives\tfiles\trun_survivors\tfold_survivors\tcnt_survivors\trun_prune_pct\tfold_prune_pct\tcnt_prune_pct\thits\tfull_ms\tsieve_ms\tspeedup\n");
    for (rows) |r| {
        const pct = struct {
            fn of(survivors: usize, files: usize) f64 {
                return (1.0 - @as(f64, @floatFromInt(survivors)) / @as(f64, @floatFromInt(@max(files, 1)))) * 100.0;
            }
        }.of;
        const speed = if (r.sieve_ns > 0) @as(f64, @floatFromInt(r.full_ns)) / @as(f64, @floatFromInt(r.sieve_ns)) else 0;
        try csv.appendSlice(gpa, try std.fmt.bufPrint(&line, "{d}\t{d}\t{s}\t{s}\t{}\t{}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d:.2}\t{d:.2}\t{d:.2}\t{d}\t{d:.3}\t{d:.3}\t{d:.3}\n", .{
            config.rank,             config.budget,            r.label,                 r.pattern, r.caseless,                               r.unicode,                                 r.ghat.len, r.files, r.run_survivors, r.fold_survivors, r.cnt_survivors,
            pct(r.run_survivors, n), pct(r.fold_survivors, n), pct(r.cnt_survivors, n), r.hits,    @as(f64, @floatFromInt(r.full_ns)) / 1e6, @as(f64, @floatFromInt(r.sieve_ns)) / 1e6, speed,
        }));
    }
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    var d = try std.Io.Dir.cwd().openDir(io, out_dir, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = filename, .data = csv.items });
}

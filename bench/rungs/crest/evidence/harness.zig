//! Evidence mechanics for the CREST production proof harness.

const std = @import("std");
const gist = @import("irregex");
const crest = gist.math.crest;
const corpus_mod = gist.corpus;
const Regex = gist.regex.Regex;
const Span = gist.assay.Span; // package instrumentation floor: monotonic Span
const sidecar = gist.index.crest;
const runtime = gist.index.crest_runtime;

pub const out_dir = ".local/crest-evidence";
pub const ascii_seed: u64 = 0xC0FFEE;
pub const unicode_seed: u64 = 0xBEEFCAFE;
pub const caseless_seed_mask: u64 = 0x5A11CA5E;

pub const Config = struct {
    runs: usize = 20,
    warmup: usize = 3,
    rank: u8 = crest.default_rank,
    budget: u8 = crest.default_budget,
    help: bool = false,
    self_test: bool = false,
};

pub const FixedResult = struct {
    pattern: []const u8,
    document: []const u8,
    expected_match: bool,
    matched: bool,
    expected_pruned: bool,
    pruned: bool,
    expected_branches: u8,
    branches: u8,
    expected_digit_threshold: u16,
    digit_threshold: u16,
    passed: bool,
};

pub const Differential = struct {
    matched: usize,
    sieve_hits: usize,
    survivors: usize,
    pruned_files: usize,
    matched_and_pruned: usize,
};

pub const RandomResult = struct {
    unicode: bool,
    caseless: bool,
    seed: u64,
    patterns: usize,
    checks: usize,
    matches: usize,
    pruned: usize,
    violations: usize,
};

pub const PlannerState = struct {
    calibrated: bool,
    decision_available: bool,
    ran: bool,
    reason: []const u8,
    touched_columns: u16 = 0,
    candidate_docs: u64 = 0,
    scanned_docs: u64 = 0,
    expected_candidates: u64 = 0,
    expected_rejected: u64 = 0,
    direct_cost: u128 = 0,
    crest_cost: u128 = 0,
    estimated_savings: u128 = 0,
    required_savings: u128 = 0,
};

pub const Row = struct {
    label: []const u8,
    pattern: []const u8,
    caseless: bool,
    unicode: bool,
    /// One ĝ per top-level alternative — the disjunction the sieve tests, not a
    /// collapsed min. Owned by the caller, alongside the sample slices.
    ghat: []const crest.Requirement,
    files: usize,
    run_survivors: usize,
    /// Survivors under the retired collapsed sieve (componentwise min over the
    /// alternatives at every selected rank).
    fold_survivors: usize,
    cnt_survivors: usize,
    hits: usize,
    full_ns: u64,
    sieve_ns: u64,
    differential: Differential,
    planner: PlannerState,
    full_samples_ns: []u64,
    sieve_samples_ns: []u64,
};

pub const RunReport = struct {
    /// v5 is the current package contract; ranked, profile-qualified artifacts
    /// and per-alternative `queries[].ghat` remain revision-bound.
    schema_version: u8 = 5,
    artifact_kind: []const u8 = "crest-production-proof",
    config: struct {
        runs: usize,
        warmup: usize,
        rank: u8,
        budget: u8,
        profile: []const u8,
        timing_clock: []const u8 = "awake-monotonic-nanoseconds",
        aggregation: []const u8 = "upper-median",
    },
    engine: struct {
        abi_version: u32,
        architecture: []const u8,
        zig_version: []const u8,
    },
    production: struct {
        sidecar_format_version: u16,
        builder: []const u8 = "gist.index.crest.buildSpectra",
        runtime: []const u8 = "gist.index.crest_runtime.apply",
        encoded_bytes: usize,
        overflow_entries: usize,
        sidecar_q: u8,
        query_rank: u8,
        validated: bool,
        planner_calibration: []const u8,
        planner_coefficients: ?struct {
            fixed: u64,
            column_document: u64,
            verify_document: u64,
        },
        uncalibrated_policy: []const u8 = "always-sieve",
    },
    corpus: struct {
        roots: []const []const u8,
        file_count: usize,
        total_bytes: u64,
        manifest_file: []const u8 = "corpus-manifest.tsv",
        manifest_sha256: []const u8,
    },
    artifacts: struct {
        aggregate_csv: []const u8,
        run_json: []const u8,
        corpus_manifest: []const u8 = "corpus-manifest.tsv",
    },
    seeds: struct { ascii: u64, unicode: u64, caseless_mask: u64 },
    fixed_regression: []const FixedResult,
    queries: []const Row,
    randomized_soundness: struct {
        ascii: RandomResult,
        unicode: RandomResult,
        caseless_ascii: RandomResult,
        caseless_unicode: RandomResult,
    },
    violations: usize,
    passed: bool,
};

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("crest: " ++ fmt, args);
    std.process.exit(2);
}

pub fn parseArgs(init: std.process.Init) Config {
    var config: Config = .{};
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            config.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--self-test")) {
            config.self_test = true;
            continue;
        }
        if (!std.mem.eql(u8, arg, "--runs") and
            !std.mem.eql(u8, arg, "--warmup") and
            !std.mem.eql(u8, arg, "--rank") and
            !std.mem.eql(u8, arg, "--budget"))
            die("unexpected argument '{s}' (usage: crest [--self-test] [--rank Q] [--budget B] [--runs N] [--warmup N])\n", .{arg});
        const raw = it.next() orelse die("{s} requires a non-negative integer\n", .{arg});
        if (std.mem.eql(u8, arg, "--runs")) {
            config.runs = std.fmt.parseInt(usize, raw, 10) catch
                die("{s} requires a non-negative integer, got '{s}'\n", .{ arg, raw });
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            config.warmup = std.fmt.parseInt(usize, raw, 10) catch
                die("{s} requires a non-negative integer, got '{s}'\n", .{ arg, raw });
        } else if (std.mem.eql(u8, arg, "--rank")) {
            config.rank = std.fmt.parseInt(u8, raw, 10) catch
                die("{s} requires a non-negative integer, got '{s}'\n", .{ arg, raw });
        } else if (std.mem.eql(u8, arg, "--budget")) {
            config.budget = std.fmt.parseInt(u8, raw, 10) catch
                die("{s} requires a non-negative integer, got '{s}'\n", .{ arg, raw });
        }
    }
    if (config.runs == 0) die("--runs must be at least 1\n", .{});
    if (!crest.supportsRank(config.rank))
        die("--rank must be one of 1, 2, or 4; got {d}\n", .{config.rank});
    if (!crest.supportsBudget(config.budget))
        die("--budget must be one of 1, 2, 4, or 8; got {d}\n", .{config.budget});
    return config;
}

pub fn printUsage() void {
    std.debug.print(
        \\usage: crest [--self-test] [--rank Q] [--budget B] [--runs N] [--warmup N]
        \\  Q: 1, 2, or 4 (default 1)
        \\  B: 1, 2, 4, or 8 (default 8)
        \\
    , .{});
}

pub fn profileName(buffer: []u8, config: Config) ![]const u8 {
    return std.fmt.bufPrint(buffer, "q{d}-b{d}", .{ config.rank, config.budget });
}

pub fn csvName(buffer: []u8, config: Config) ![]const u8 {
    return std.fmt.bufPrint(buffer, "crest-q{d}-b{d}.csv", .{ config.rank, config.budget });
}

pub fn runJsonName(buffer: []u8, config: Config) ![]const u8 {
    return std.fmt.bufPrint(buffer, "crest-run-q{d}-b{d}.json", .{ config.rank, config.budget });
}

pub fn fixedRegression(gpa: std.mem.Allocator, config: Config, violations: *usize) ![3]FixedResult {
    // Untimed kernel micro-oracle only; release timing uses the decoded View
    // through crest_runtime.apply.
    const cases = [_]struct {
        pattern: []const u8,
        expected_match: bool,
        expected_pruned: bool,
        expected_branches: u8,
        expected_digit_threshold: u16,
    }{
        .{ .pattern = "[0-9][a-z]?[0-9]", .expected_match = true, .expected_pruned = false, .expected_branches = 1, .expected_digit_threshold = 1 },
        .{ .pattern = "[0-9][0-9]?[0-9]", .expected_match = false, .expected_pruned = true, .expected_branches = 1, .expected_digit_threshold = 2 },
        // The disjunctive case, pinned in the same fail-closed regression: two
        // alternatives forcing disjoint classes. A collapsed ĝ is 0⃗ here and
        // prunes nothing; the swell still prunes a document short of both.
        .{ .pattern = "[0-9]{3}|~{3}", .expected_match = false, .expected_pruned = true, .expected_branches = 2, .expected_digit_threshold = 3 },
    };
    const document = "1a2";
    const document_crest = crest.spectrum(document, config.rank);
    const digit = @intFromEnum(crest.Class.digit);
    var results: [cases.len]FixedResult = undefined;
    for (cases, 0..) |case, i| {
        const opts: Regex.Options = .{ .caseless = false, .unicode = true };
        const swell = Regex.forcedRankedSwell(gpa, case.pattern, opts, config.budget, config.rank);
        var re = try Regex.compileOpts(gpa, case.pattern, opts);
        defer re.deinit();
        var sim = try Regex.Sim.init(gpa, &re);
        defer sim.deinit();
        const matched = re.docMatch(&sim, document);
        // Untimed kernel micro-oracle; never reported as release runtime speed.
        const pruned = swell.prunesSpectrum(document_crest);
        const threshold = if (swell.len == 0) 0 else swell.requirements[0][crest.spectrumLane(digit, 0)];
        const passed = matched == case.expected_match and
            pruned == case.expected_pruned and
            swell.len == case.expected_branches and
            threshold == case.expected_digit_threshold and
            (!matched or !pruned);
        results[i] = .{
            .pattern = case.pattern,
            .document = document,
            .expected_match = case.expected_match,
            .matched = matched,
            .expected_pruned = case.expected_pruned,
            .pruned = pruned,
            .expected_branches = case.expected_branches,
            .branches = swell.len,
            .expected_digit_threshold = case.expected_digit_threshold,
            .digit_threshold = threshold,
            .passed = passed,
        };
        if (!passed) {
            violations.* += 1;
            std.debug.print(
                "  !! FIXED PRODUCTION REGRESSION FAILED: pattern={s} doc={s} match={} expected={} prune={} expected={} branches={d} expected={d} digit-threshold={d} expected={d}\n",
                .{ case.pattern, document, matched, case.expected_match, pruned, case.expected_pruned, swell.len, case.expected_branches, threshold, case.expected_digit_threshold },
            );
        }
    }
    return results;
}

pub const AppliedDifferential = struct {
    counts: Differential,
    planner: PlannerState,
};

pub fn plannerState(
    swell: crest.RankedSwell,
    calibrated: bool,
    decision: anytype,
) !PlannerState {
    if (decision) |value| return .{
        .calibrated = calibrated,
        .decision_available = true,
        .ran = value.run,
        .reason = @tagName(value.reason),
        .touched_columns = value.touched_columns,
        .candidate_docs = value.candidate_docs,
        .scanned_docs = value.scanned_docs,
        .expected_candidates = value.expected_candidates,
        .expected_rejected = value.expected_rejected,
        .direct_cost = value.direct_cost,
        .crest_cost = value.crest_cost,
        .estimated_savings = value.estimated_savings,
        .required_savings = value.required_savings,
    };
    if (!swell.active()) return .{
        .calibrated = calibrated,
        .decision_available = false,
        .ran = false,
        .reason = "inactive",
    };
    if (calibrated) return error.MissingPlannerDecision;
    return .{
        .calibrated = false,
        .decision_available = false,
        .ran = true,
        .reason = "uncalibrated-always-sieve",
    };
}

pub fn differential(
    gpa: std.mem.Allocator,
    re: *const Regex,
    sim: *Regex.Sim,
    docs: []const []const u8,
    view: sidecar.View,
    swell: crest.RankedSwell,
    calibrated: bool,
) !AppliedDifferential {
    var candidates = try std.DynamicBitSet.initFull(gpa, docs.len);
    defer candidates.deinit();
    const decision = try runtime.apply(gpa, view, &candidates, swell);
    var result: Differential = .{ .matched = 0, .sieve_hits = 0, .survivors = 0, .pruned_files = 0, .matched_and_pruned = 0 };
    for (docs, 0..) |doc, document| {
        const pruned = !candidates.isSet(document);
        const matched = re.docMatch(sim, doc);
        if (matched) result.matched += 1;
        if (pruned) {
            result.pruned_files += 1;
            if (matched) result.matched_and_pruned += 1;
        } else {
            result.survivors += 1;
            if (matched) result.sieve_hits += 1;
        }
    }
    return .{
        .counts = result,
        .planner = try plannerState(swell, calibrated, decision),
    };
}

pub const Timed = struct {
    ns: u64,
    hits: usize,
    survivors: usize = 0,
    planner: ?PlannerState = null,
};

pub fn timeFull(io: std.Io, re: *const Regex, sim: *Regex.Sim, docs: []const []const u8) Timed {
    const sp = Span.open(io);
    var hits: usize = 0;
    for (docs) |doc| if (re.docMatch(sim, doc)) {
        hits += 1;
    };
    return .{ .ns = @intCast(sp.read(io).ns()), .hits = hits };
}

pub fn timeSieve(
    gpa: std.mem.Allocator,
    io: std.Io,
    re: *const Regex,
    sim: *Regex.Sim,
    docs: []const []const u8,
    view: sidecar.View,
    swell: crest.RankedSwell,
    calibrated: bool,
) !Timed {
    var candidates = try std.DynamicBitSet.initFull(gpa, docs.len);
    defer candidates.deinit();
    const sp = Span.open(io);
    const decision = try runtime.apply(gpa, view, &candidates, swell);
    var hits: usize = 0;
    var iterator = candidates.iterator(.{});
    while (iterator.next()) |document| {
        if (re.docMatch(sim, docs[document])) hits += 1;
    }
    return .{
        .ns = @intCast(sp.read(io).ns()),
        .hits = hits,
        .survivors = candidates.count(),
        .planner = try plannerState(swell, calibrated, decision),
    };
}

pub fn upperMedian(gpa: std.mem.Allocator, samples: []const u64) !u64 {
    const scratch = try gpa.dupe(u64, samples);
    defer gpa.free(scratch);
    std.mem.sort(u64, scratch, {}, comptime std.sort.asc(u64));
    return scratch[scratch.len / 2];
}

const ManifestEntry = struct {
    path: []const u8,
    doc: []const u8,

    fn lessThan(_: void, a: ManifestEntry, b: ManifestEntry) bool {
        return std.mem.order(u8, a.path, b.path) == .lt;
    }
};

fn hexLower(bytes: anytype) [bytes.len * 2]u8 {
    const alphabet = "0123456789abcdef";
    var out: [bytes.len * 2]u8 = undefined;
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

pub fn writeCorpusManifest(gpa: std.mem.Allocator, io: std.Io, corpus: *const corpus_mod.Corpus) ![64]u8 {
    const entries = try gpa.alloc(ManifestEntry, corpus.docs.len);
    defer gpa.free(entries);
    for (entries, corpus.paths, corpus.docs) |*entry, path, doc| entry.* = .{ .path = path, .doc = doc };
    std.mem.sort(ManifestEntry, entries, {}, ManifestEntry.lessThan);

    var tsv: std.ArrayList(u8) = .empty;
    defer tsv.deinit(gpa);
    try tsv.appendSlice(gpa, "path\tsize_bytes\tsha256\n");
    var suffix: [96]u8 = undefined;
    var previous: ?[]const u8 = null;
    for (entries) |entry| {
        if (std.mem.indexOfAny(u8, entry.path, "\t\r\n") != null)
            return error.CorpusPathCannotBeRepresented;
        if (previous) |path| if (std.mem.eql(u8, path, entry.path))
            return error.DuplicateCorpusPath;
        previous = entry.path;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(entry.doc, &digest, .{});
        const hex = hexLower(digest);
        try tsv.appendSlice(gpa, entry.path);
        try tsv.appendSlice(gpa, try std.fmt.bufPrint(&suffix, "\t{d}\t{s}\n", .{ entry.doc.len, &hex }));
    }
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/corpus-manifest.tsv", .data = tsv.items });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tsv.items, &digest, .{});
    return hexLower(digest);
}

pub fn writeRunJson(gpa: std.mem.Allocator, io: std.Io, filename: []const u8, report: RunReport) !void {
    var body = try std.json.Stringify.valueAlloc(gpa, report, .{});
    defer gpa.free(body);
    body = try gpa.realloc(body, body.len + 1);
    body[body.len - 1] = '\n';
    var path: [128]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&path, "{s}/{s}", .{ out_dir, filename });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sub_path, .data = body });
}

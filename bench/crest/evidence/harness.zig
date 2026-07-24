//! Evidence mechanics for the CREST production proof harness.

const std = @import("std");
const gist = @import("irregex");
const crest = gist.crest;
const corpus_mod = gist.corpus;
const Regex = gist.regex.Regex;

pub const out_dir = ".local/crest-evidence";
pub const ascii_seed: u64 = 0xC0FFEE;
pub const unicode_seed: u64 = 0xBEEFCAFE;
pub const caseless_seed_mask: u64 = 0x5A11CA5E;

pub const Config = struct { runs: usize = 20, warmup: usize = 3 };

pub const FixedResult = struct {
    pattern: []const u8,
    document: []const u8,
    expected_match: bool,
    matched: bool,
    expected_pruned: bool,
    pruned: bool,
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

pub const Row = struct {
    label: []const u8,
    pattern: []const u8,
    caseless: bool,
    unicode: bool,
    ghat: crest.Vector,
    files: usize,
    run_survivors: usize,
    cnt_survivors: usize,
    hits: usize,
    full_ns: u64,
    sieve_ns: u64,
    differential: Differential,
    full_samples_ns: []u64,
    sieve_samples_ns: []u64,
};

pub const RunReport = struct {
    schema_version: u8 = 2,
    artifact_kind: []const u8 = "crest-production-proof",
    config: struct {
        runs: usize,
        warmup: usize,
        timing_clock: []const u8 = "awake-monotonic-nanoseconds",
        aggregation: []const u8 = "upper-median",
    },
    engine: struct {
        abi_version: u32,
        architecture: []const u8,
        zig_version: []const u8,
    },
    corpus: struct {
        roots: []const []const u8,
        file_count: usize,
        total_bytes: u64,
        manifest_file: []const u8 = "corpus-manifest.tsv",
        manifest_sha256: []const u8,
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

pub fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.now(.awake, io).nanoseconds);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("crest: " ++ fmt, args);
    std.process.exit(2);
}

pub fn parseArgs(init: std.process.Init) Config {
    var config: Config = .{};
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |arg| {
        const dst: *usize = if (std.mem.eql(u8, arg, "--runs"))
            &config.runs
        else if (std.mem.eql(u8, arg, "--warmup"))
            &config.warmup
        else
            die("unexpected argument '{s}' (usage: crest [--runs N] [--warmup N])\n", .{arg});
        const raw = it.next() orelse die("{s} requires a non-negative integer\n", .{arg});
        dst.* = std.fmt.parseInt(usize, raw, 10) catch
            die("{s} requires a non-negative integer, got '{s}'\n", .{ arg, raw });
    }
    if (config.runs == 0) die("--runs must be at least 1\n", .{});
    return config;
}

pub fn fixedRegression(gpa: std.mem.Allocator, violations: *usize) ![2]FixedResult {
    const cases = [_]struct {
        pattern: []const u8,
        expected_match: bool,
        expected_pruned: bool,
        expected_digit_threshold: u16,
    }{
        .{ .pattern = "[0-9][a-z]?[0-9]", .expected_match = true, .expected_pruned = false, .expected_digit_threshold = 1 },
        .{ .pattern = "[0-9][0-9]?[0-9]", .expected_match = false, .expected_pruned = true, .expected_digit_threshold = 2 },
    };
    const document = "1a2";
    const document_crest = crest.crest(document);
    const digit = @intFromEnum(crest.Class.digit);
    var results: [cases.len]FixedResult = undefined;
    for (cases, 0..) |case, i| {
        const gv = crest.ghat(case.pattern, .{ .unicode = true });
        var re = try Regex.compileOpts(gpa, case.pattern, .{ .caseless = false, .unicode = true });
        defer re.deinit();
        var sim = try Regex.Sim.init(gpa, &re);
        defer sim.deinit();
        const matched = re.docMatch(&sim, document);
        const pruned = crest.pruned(document_crest, gv);
        const passed = matched == case.expected_match and
            pruned == case.expected_pruned and
            gv[digit] == case.expected_digit_threshold and
            (!matched or !pruned);
        results[i] = .{
            .pattern = case.pattern,
            .document = document,
            .expected_match = case.expected_match,
            .matched = matched,
            .expected_pruned = case.expected_pruned,
            .pruned = pruned,
            .expected_digit_threshold = case.expected_digit_threshold,
            .digit_threshold = gv[digit],
            .passed = passed,
        };
        if (!passed) {
            violations.* += 1;
            std.debug.print(
                "  !! FIXED PRODUCTION REGRESSION FAILED: pattern={s} doc={s} match={} expected={} prune={} expected={} digit-threshold={d} expected={d}\n",
                .{ case.pattern, document, matched, case.expected_match, pruned, case.expected_pruned, gv[digit], case.expected_digit_threshold },
            );
        }
    }
    return results;
}

pub fn differential(re: *const Regex, sim: *Regex.Sim, docs: []const []const u8, crests: []const crest.Vector, gv: crest.Vector) Differential {
    var result: Differential = .{ .matched = 0, .sieve_hits = 0, .survivors = 0, .pruned_files = 0, .matched_and_pruned = 0 };
    for (docs, crests) |doc, document_crest| {
        const pruned = crest.pruned(document_crest, gv);
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
    return result;
}

pub const Timed = struct { ns: u64, hits: usize, survivors: usize = 0 };

pub fn timeFull(io: std.Io, re: *const Regex, sim: *Regex.Sim, docs: []const []const u8) Timed {
    const started = nowNs(io);
    var hits: usize = 0;
    for (docs) |doc| if (re.docMatch(sim, doc)) {
        hits += 1;
    };
    return .{ .ns = nowNs(io) - started, .hits = hits };
}

pub fn timeSieve(io: std.Io, re: *const Regex, sim: *Regex.Sim, docs: []const []const u8, crests: []const crest.Vector, gv: crest.Vector) Timed {
    const started = nowNs(io);
    var hits: usize = 0;
    var survivors: usize = 0;
    for (docs, crests) |doc, document_crest| {
        if (crest.pruned(document_crest, gv)) continue;
        survivors += 1;
        if (re.docMatch(sim, doc)) hits += 1;
    }
    return .{ .ns = nowNs(io) - started, .hits = hits, .survivors = survivors };
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

pub fn writeRunJson(gpa: std.mem.Allocator, io: std.Io, report: RunReport) !void {
    var body = try std.json.Stringify.valueAlloc(gpa, report, .{});
    defer gpa.free(body);
    body = try gpa.realloc(body, body.len + 1);
    body[body.len - 1] = '\n';
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/crest-run.json", .data = body });
}

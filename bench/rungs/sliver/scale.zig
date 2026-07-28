//! gist/bench/sliver — Layer J: what the sub-trigram tier is worth, in the one
//! unit Layer D measures in.
//!
//! Layer D records that four of the twelve certificate classes reach it with
//! **cand% = 100** — the trigram directory admits the entire corpus, because the
//! needle is too thin to produce a trigram (`literal-punct2` = `})`) or carries
//! a branch that is (`regex-litalt` = `panic|0x`). At 100% "the floor" is just
//! the corpus, and a floor you meet by reading everything is not a filter.
//!
//! This audit measures, over the SAME corpus and the SAME imported probe set,
//! the candidate bytes each class delivers to verify under two rules:
//!
//!   • `directory` — the historical gate: a needle < 3 bytes cannot be queried,
//!     so every document is a candidate. This reproduces Layer D's numbers and
//!     is the honest "before".
//!   • `tiered`    — the sliver tier (`corpus/index/trigrams/sliver.zig`) answers
//!     sub-trigram needles from the same directory, and a mixed alternation is
//!     unioned per branch.
//!
//! Method, and why it can be trusted:
//!
//!   • No production code is instrumented and no candidate rule is re-implemented
//!     here. `tiered` calls the SAME `sliver.candidates` production uses, so a
//!     number in this table cannot drift from shipped behavior.
//!   • **Soundness is asserted, not assumed.** For every class, gist's real
//!     verify (`simd.contains` / `Regex.docMatch`) establishes ground truth over
//!     EVERY document, and every truly-matching document must appear in the
//!     tiered candidate set. A single missing match exits non-zero: that is a
//!     correctness defect, and no measured speed-up would excuse it.
//!   • Fail-closed on the payoff too — a class whose tiered candidate bytes
//!     EXCEED the directory rule's is a regression and fails the audit.
//!
//! Output: a table on stdout, and a machine-readable TSV at
//! `.local/gist-verify/scale_tiers.tsv` for `certify_scale_report.py`.

const std = @import("std");
const gist = @import("irregex");

const corpus_mod = gist.corpus;
const crest = gist.crest;
const simd = gist.simd;
const sliver = gist.sliver;
const Index = gist.trigram.Index;
const Regex = gist.regex.Regex;
const Dir = std.Io.Dir;

const probes_mod = @import("probes");
const Kind = probes_mod.Kind;
const probes = probes_mod.probes;

const Row = struct {
    class: []const u8,
    kind: Kind,
    pattern: []const u8,
    /// Candidate docs/bytes under the historical ≥3-byte directory gate.
    base_docs: usize,
    base_bytes: u64,
    /// Candidate docs/bytes with the sliver tier engaged.
    tier_docs: usize,
    tier_bytes: u64,
    hits: usize,
    /// True when the tier changed this class at all (a sub-trigram needle).
    engaged: bool,
    sound: bool,
};

/// Documents no crest vector proves are ≥3 bytes — the production rule from
/// `persist.zig::shortDocs`, over vectors recomputed from the live corpus.
fn shortDocs(gpa: std.mem.Allocator, docs: []const []const u8) ![]u32 {
    var n: usize = 0;
    for (docs) |d| {
        if (@reduce(.Max, @as(@Vector(crest.K, u16), crest.crest(d))) < 3) n += 1;
    }
    const out = try gpa.alloc(u32, n);
    var w: usize = 0;
    for (docs, 0..) |d, i| {
        if (@reduce(.Max, @as(@Vector(crest.K, u16), crest.crest(d))) < 3) {
            out[w] = @intCast(i);
            w += 1;
        }
    }
    return out;
}

fn allDocs(gpa: std.mem.Allocator, n: usize) ![]u32 {
    const all = try gpa.alloc(u32, n);
    for (all, 0..) |*x, i| x.* = @intCast(i);
    return all;
}

/// The historical rule, verbatim from `bench/lowerbound/lowerbound.zig`: a
/// needle under 3 bytes is unqueryable, so every document is a candidate.
fn baseCandidates(idx: *const Index, gpa: std.mem.Allocator, n_docs: usize, filters: []const []const u8) ![]u32 {
    var usable = filters.len > 0;
    for (filters) |f| if (f.len < 3) {
        usable = false;
    };
    if (usable) {
        if (idx.queryAny(gpa, filters)) |c| return c else |_| {}
    }
    return allDocs(gpa, n_docs);
}

/// The tiered rule: sub-trigram branches go to `sliver`, the rest to the
/// directory, and the union of sound per-branch supersets is sound. Mirrors
/// `Persisted.queryMixed` while calling the same production kernel it does.
fn tierCandidates(idx: *const Index, gpa: std.mem.Allocator, n_docs: usize, filters: []const []const u8, short: []const u32) ![]u32 {
    if (filters.len == 0) return allDocs(gpa, n_docs);
    const lists = try gpa.alloc([]u32, filters.len);
    defer gpa.free(lists);
    var got: usize = 0;
    defer for (lists[0..got]) |l| gpa.free(l);

    var total: usize = 0;
    for (filters, lists) |f, *slot| {
        slot.* = if (f.len <= sliver.max_len)
            sliver.candidates(idx, gpa, f, short) catch return allDocs(gpa, n_docs)
        else
            idx.queryLiteral(gpa, f) catch return allDocs(gpa, n_docs);
        got += 1;
        total += slot.len;
    }
    if (got == 1) {
        const only = lists[0];
        got = 0; // ownership moves out
        return only;
    }
    const buf = try gpa.alloc(u32, total);
    var w: usize = 0;
    for (lists[0..got]) |l| {
        @memcpy(buf[w..][0..l.len], l);
        w += l.len;
    }
    std.mem.sort(u32, buf[0..w], {}, comptime std.sort.asc(u32));
    const k = gist.ngram.dedupSorted(u32, buf, w);
    return gpa.realloc(buf, k) catch buf[0..k];
}

fn bytesOf(docs: []const []const u8, cand: []const u32) u64 {
    var n: u64 = 0;
    for (cand) |d| n += docs[d].len;
    return n;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}

pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);

    var corpus = try corpus_mod.load(gpa, io, roots);
    defer corpus.deinit();
    std.debug.print("gist scale · Layer J (sub-trigram tier, candidate bytes)\n", .{});
    std.debug.print("corpus: {d} docs / {d:.1} MiB\n", .{
        corpus.docs.len, @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20),
    });

    var idx = try Index.build(gpa, corpus.docs);
    defer idx.deinit();
    const short = try shortDocs(gpa, corpus.docs);
    defer gpa.free(short);
    std.debug.print("scale: index {d} groups / {d} postings · {d} doc(s) unprovable-length\n", .{
        idx.dir_tri.len, idx.posting_count, short.len,
    });

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    var faults: usize = 0;

    for (probes) |p| {
        // The filters this class offers the index, by the same rule the CLI uses
        // (`kernel/query/prefilter.zig`): a literal is its own filter; a
        // regex offers its required literal, else its alternation cover.
        var one: [1][]const u8 = undefined;
        var re: ?Regex = null;
        var sim: ?Regex.Sim = null;
        defer if (sim) |*s| s.deinit();
        defer if (re) |*r| r.deinit();
        const filters: []const []const u8 = switch (p.kind) {
            .literal => blk: {
                one[0] = p.pattern;
                break :blk one[0..1];
            },
            .regex => blk: {
                re = try Regex.compile(gpa, p.pattern);
                sim = try Regex.Sim.init(gpa, &re.?);
                break :blk gist.engine.query.regexPrefilter(&re.?, &one);
            },
        };

        if (gist.assay.envSpan("GIST_SCALE_TRACE") != null) {
            std.debug.print("  {s}: {d} filter(s)", .{ p.class, filters.len });
            for (filters) |f| std.debug.print(" '{s}'", .{f});
            std.debug.print("\n", .{});
        }

        const base = try baseCandidates(&idx, gpa, corpus.docs.len, filters);
        defer gpa.free(base);
        const tier = try tierCandidates(&idx, gpa, corpus.docs.len, filters, short);
        defer gpa.free(tier);

        // Ground truth over EVERY document, from gist's real verify — then the
        // tiered candidate set must contain every match. This is the assertion
        // that makes the pruning numbers below meaningful rather than merely small.
        var admitted = try std.DynamicBitSet.initEmpty(gpa, corpus.docs.len);
        defer admitted.deinit();
        for (tier) |d| admitted.set(d);

        var hits: usize = 0;
        var missed: usize = 0;
        for (corpus.docs, 0..) |doc, d| {
            const matched = switch (p.kind) {
                .literal => simd.contains(doc, p.pattern),
                .regex => re.?.docMatch(&sim.?, doc),
            };
            if (!matched) continue;
            hits += 1;
            if (!admitted.isSet(d)) {
                missed += 1;
                if (missed <= 3) std.debug.print("  !! {s}: match in doc {d} ({s}) NOT admitted\n", .{ p.class, d, corpus.paths[d] });
            }
        }
        if (missed != 0) faults += 1;

        const tb = bytesOf(corpus.docs, tier);
        const bb = bytesOf(corpus.docs, base);
        if (tb > bb) {
            faults += 1;
            std.debug.print("  !! {s}: tiered candidate bytes {d} EXCEED directory {d}\n", .{ p.class, tb, bb });
        }
        try rows.append(gpa, .{
            .class = p.class,
            .kind = p.kind,
            .pattern = p.pattern,
            .base_docs = base.len,
            .base_bytes = bb,
            .tier_docs = tier.len,
            .tier_bytes = tb,
            .hits = hits,
            .engaged = tb != bb,
            .sound = missed == 0,
        });
    }

    try report(gpa, io, rows.items, corpus.bytes, corpus.docs.len, idx, faults);
    if (faults != 0) {
        std.debug.print("\nscale: FAIL — {d} invariant violation(s)\n", .{faults});
        std.process.exit(1);
    }
}

fn pct(n: u64, of: u64) f64 {
    return 100.0 * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(@max(of, 1)));
}

fn report(gpa: std.mem.Allocator, io: std.Io, rows: []const Row, corpus_bytes: u64, corpus_docs: usize, idx: Index, faults: usize) !void {
    std.debug.print("\n{s:<20} {s:>9} {s:>9} {s:>11} {s:>8} {s:>7}\n", .{ "class", "cand%·dir", "cand%·tier", "reduction", "hits", "sound" });
    for (rows) |r| {
        const bp = pct(r.base_bytes, corpus_bytes);
        const tp = pct(r.tier_bytes, corpus_bytes);
        const red: f64 = if (r.tier_bytes == 0) std.math.inf(f64) else @as(f64, @floatFromInt(r.base_bytes)) / @as(f64, @floatFromInt(r.tier_bytes));
        std.debug.print("{s:<20} {d:>8.2}% {d:>9.2}% {d:>10.2}x {d:>8} {s:>7}\n", .{
            r.class, bp, tp, red, r.hits, if (r.sound) "ok" else "FAIL",
        });
    }

    var tsv: std.ArrayList(u8) = .empty;
    defer tsv.deinit(gpa);
    var line: [512]u8 = undefined;
    try tsv.appendSlice(gpa, try std.fmt.bufPrint(&line, "# corpus_docs={d} corpus_bytes={d} index_groups={d} index_postings={d} faults={d}\n", .{
        corpus_docs, corpus_bytes, idx.dir_tri.len, idx.posting_count, faults,
    }));
    try tsv.appendSlice(gpa, "class\tkind\tpattern\tbase_docs\tbase_bytes\ttier_docs\ttier_bytes\tbase_cand_frac\ttier_cand_frac\thits\tengaged\tsound\n");
    for (rows) |r| {
        try tsv.appendSlice(gpa, try std.fmt.bufPrint(&line, "{s}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d:.6}\t{d:.6}\t{d}\t{s}\t{s}\n", .{
            r.class,      @tagName(r.kind),                     r.pattern,
            r.base_docs,  r.base_bytes,                         r.tier_docs,
            r.tier_bytes, pct(r.base_bytes, corpus_bytes) / 100, pct(r.tier_bytes, corpus_bytes) / 100,
            r.hits,       if (r.engaged) "yes" else "no",        if (r.sound) "yes" else "no",
        }));
    }
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/scale_tiers.tsv", .{gist.home.outDir()});
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = tsv.items });
    std.debug.print("\nscale: wrote {s}\n", .{path});
}

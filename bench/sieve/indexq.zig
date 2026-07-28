//! gist bench — `indexq`: Layer L of the certificate, **index quality head to
//! head against csearch** (Google Code Search, Russ Cox 2012 — gist's direct
//! trigram ancestor).
//!
//! The axis is deliberately NOT wall time. Wall time confounds the index with
//! the walk, the IO and the matcher, and none of those is what "your trigram
//! index is csearch-class" is a claim about. The claim is about the **filter**,
//! and a filter has exactly three honest measures:
//!
//!   • **selectivity** — candidate documents, and above all candidate BYTES,
//!     admitted as a fraction of the corpus (lower is strictly better);
//!   • **precision** — of the candidates admitted, how many actually match;
//!   • **the formula** — the boolean query over trigrams that produced them.
//!
//! So this harness holds everything else fixed: ONE corpus, ONE built index,
//! ONE evaluator (`Index.queryPlan`), ONE verifier (the production matcher).
//! The only thing that varies between arms is the formula:
//!
//!   `gist-base`  the shipped-before-Layer-L prefilter — a single required
//!                literal, else the per-branch alternation cover (one clause).
//!   `gist`       the production planner as it stands now (`analysis.coverPlan`
//!                once landed; identical to `gist-base` before that), read off
//!                the REAL compiled `Regex` so the harness cannot flatter it.
//!   `csearch`    csearch's own formula, lifted verbatim from `csearch
//!                -verbose` by `csearch_plan.py` and replayed here.
//!
//! Fail-closed on soundness, twice: every arm must report the SAME verified hit
//! count (each is a sound superset of the true matches, so any arm that finds
//! fewer has silently elided a real match), and gist's arm must never admit a
//! document that gist's own full-corpus verify says matches but the filter
//! dropped. A violation exits non-zero; it is a real finding, never something
//! to paper over.
//!
//! Probe rows are `@import`ed from `bench/harness/probes.zig`, the same registry
//! Layers A and D use, so Layer L lines up class-for-class by construction.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");

const corpus_mod = gist.corpus;
const simd = gist.simd;
const query = gist.engine.query;
const Span = gist.assay.Span; // the package monotonic stopwatch (never the wall clock)
const Index = gist.trigram.Index;
const Regex = gist.regex.Regex;
const Dir = std.Io.Dir;
const out_dir = gist.home.default_out_dir;

const probes_mod = @import("probes");
const Kind = probes_mod.Kind;
const Probe = probes_mod.Probe;
/// The certificate's own twelve classes first (nobody can call them
/// cherry-picked), then the planner-stress extension (`stress.zig` explains why
/// eight of the twelve cannot separate two planners at all). Reported and
/// spliced as two tables, never merged.
const probes = probes_mod.probes ++ @import("stress.zig").probes;
const shared_classes = probes_mod.probes.len;

const plan_path = out_dir ++ "/indexq_csearch.plan";
const csv_path = out_dir ++ "/indexq.tsv";

/// The three formulas under comparison. Only the formula differs — corpus,
/// index, evaluator and verifier are shared.
const Arm = enum {
    gist_base,
    gist,
    csearch,

    fn label(self: Arm) []const u8 {
        return switch (self) {
            .gist_base => "gist-base",
            .gist => "gist",
            .csearch => "csearch",
        };
    }
};

const Row = struct {
    class: []const u8,
    /// "shared" (the certificate's twelve) or "stress" (Layer L's planner slate).
    slate: []const u8,
    kind: Kind,
    arm: Arm,
    clauses: usize,
    atoms: usize,
    filtered: bool, // false ⇒ no sound formula, the whole corpus is a candidate
    cand_docs: usize,
    cand_bytes: u64,
    cand_byte_frac: f64,
    hits: usize,
    precision: f64, // hits ÷ candidate docs
    query_us: u64,
    csearch_own_docs: i64, // csearch's own `post query identified N`, else -1
};

// ── the csearch plan file ────────────────────────────────────────────────────

const Plan = struct {
    clauses: []const Index.Clause,
    own_docs: i64,
    /// Present in the file but with no clause ⇒ csearch proved no filter at all.
    filtered: bool,
};

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn unhex(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len % 2 != 0) return error.BadPlan;
    const out = try arena.alloc(u8, s.len / 2);
    for (out, 0..) |*b, i| {
        const hi = hexNibble(s[i * 2]) orelse return error.BadPlan;
        const lo = hexNibble(s[i * 2 + 1]) orelse return error.BadPlan;
        b.* = hi << 4 | lo;
    }
    return out;
}

/// Parse `class \t own_docs \t atom|atom|…` rows (atom = `hex,hex,…`) into one
/// plan per class. Order is preserved; a row with an empty clause body records
/// "csearch has no filter for this class".
fn readPlans(arena: std.mem.Allocator, io: std.Io) !std.StringHashMap(Plan) {
    var out = std.StringHashMap(Plan).init(arena);
    const text = Dir.cwd().readFileAlloc(io, plan_path, arena, .limited(1 << 26)) catch |e| {
        std.debug.print("indexq: cannot read {s}: {s}\n  run: python3 pkg/kernels/irregex/bench/sieve/csearch_plan.py --probes pkg/kernels/irregex/bench/harness/probes.zig --index .local/gist-compete/csearch.idx --out {s}\n", .{ plan_path, @errorName(e), plan_path });
        return e;
    };
    var acc = std.StringHashMap(std.ArrayList(Index.Clause)).init(arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const class = f.next() orelse continue;
        const own = std.fmt.parseInt(i64, f.next() orelse "-1", 10) catch -1;
        const body = f.next() orelse "";
        const gop = try acc.getOrPut(class);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            try out.put(class, .{ .clauses = &.{}, .own_docs = own, .filtered = false });
        }
        if (body.len == 0) continue;
        var atoms: std.ArrayList(Index.Atom) = .empty;
        var it = std.mem.splitScalar(u8, body, '|');
        while (it.next()) |atom_src| {
            var lits: std.ArrayList([]const u8) = .empty;
            var lit_it = std.mem.splitScalar(u8, atom_src, ',');
            while (lit_it.next()) |h| try lits.append(arena, try unhex(arena, h));
            try atoms.append(arena, try lits.toOwnedSlice(arena));
        }
        try gop.value_ptr.append(arena, try atoms.toOwnedSlice(arena));
    }
    var it = acc.iterator();
    while (it.next()) |e| {
        const p = out.getPtr(e.key_ptr.*).?;
        p.clauses = try e.value_ptr.toOwnedSlice(arena);
        p.filtered = p.clauses.len > 0;
    }
    return out;
}

// ── the gist arms ────────────────────────────────────────────────────────────

/// gist's shipped-before-Layer-L formula: the single required literal (≥3 B),
/// else the per-branch alternation cover — one clause either way. Mirrors
/// `query.regexPrefilter` exactly (the same two fields, the same 3-byte floor),
/// which is the point: this arm is the baseline the improvement is measured on.
fn baseClauses(arena: std.mem.Allocator, re: *const Regex) ![]const Index.Clause {
    const lits: []const []const u8 = if (re.required.len >= 3) blk: {
        const one = try arena.alloc([]const u8, 1);
        one[0] = re.required;
        break :blk one;
    } else re.alts;
    if (lits.len == 0) return &.{};
    const atoms = try arena.alloc(Index.Atom, lits.len);
    for (atoms, lits) |*a, l| {
        if (l.len < 3) return &.{}; // a sub-trigram branch makes the OR unfilterable
        const one = try arena.alloc([]const u8, 1);
        one[0] = l;
        a.* = one;
    }
    const clause = try arena.alloc(Index.Clause, 1);
    clause[0] = atoms;
    return clause;
}

/// A fixed-string probe: one clause, one atom, one literal.
fn literalClauses(arena: std.mem.Allocator, needle: []const u8) ![]const Index.Clause {
    if (needle.len < 3) return &.{};
    const lits = try arena.alloc([]const u8, 1);
    lits[0] = needle;
    const atoms = try arena.alloc(Index.Atom, 1);
    atoms[0] = lits;
    const clause = try arena.alloc(Index.Clause, 1);
    clause[0] = atoms;
    return clause;
}

// ── measurement ──────────────────────────────────────────────────────────────

fn allDocs(gpa: std.mem.Allocator, n: usize) ![]u32 {
    const all = try gpa.alloc(u32, n);
    for (all, 0..) |*x, i| x.* = @intCast(i);
    return all;
}

fn countAtoms(clauses: []const Index.Clause) usize {
    var n: usize = 0;
    for (clauses) |c| n += c.len;
    return n;
}

fn measureArm(
    gpa: std.mem.Allocator,
    io: std.Io,
    corpus: *const corpus_mod.Corpus,
    idx: *const Index,
    probe: Probe,
    slate: []const u8,
    arm: Arm,
    clauses: []const Index.Clause,
    re: ?*Regex,
    sim: ?*Regex.Sim,
    own_docs: i64,
) !Row {
    const span = Span.open(io);
    const cand: []u32 = if (clauses.len == 0)
        try allDocs(gpa, corpus.docs.len)
    else
        idx.queryPlan(gpa, clauses) catch try allDocs(gpa, corpus.docs.len);
    const query_us: u64 = @intCast(@divTrunc(span.read(io).ns(), 1000));
    defer gpa.free(cand);

    var cand_bytes: u64 = 0;
    var hits: usize = 0;
    for (cand) |d| {
        const doc = corpus.docs[d];
        cand_bytes += doc.len;
        const hit = switch (probe.kind) {
            .literal => simd.contains(doc, probe.pattern),
            .regex => re.?.docMatch(sim.?, doc),
        };
        if (hit) hits += 1;
    }
    return .{
        .class = probe.class,
        .slate = slate,
        .kind = probe.kind,
        .arm = arm,
        .clauses = clauses.len,
        .atoms = countAtoms(clauses),
        .filtered = clauses.len > 0,
        .cand_docs = cand.len,
        .cand_bytes = cand_bytes,
        .cand_byte_frac = @as(f64, @floatFromInt(cand_bytes)) / @as(f64, @floatFromInt(@max(corpus.bytes, 1))),
        .hits = hits,
        .precision = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(@max(cand.len, 1))),
        .query_us = query_us,
        .csearch_own_docs = own_docs,
    };
}

pub fn main(init: std.process.Init) !void {
    // The three cost ceilings, overridable so the published defaults are a
    // measured frontier (`--cover-atoms=N` …) rather than a number somebody liked.
    var limits: query.CoverLimits = .{};
    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.skip(); // argv[0]
    while (args.next()) |a| {
        const eq = std.mem.indexOfScalar(u8, a, '=') orelse {
            std.debug.print("usage: gist-indexq [--cover-atoms=N] [--cover-class=N] [--cover-clauses=N]\n", .{});
            return error.BadArgument;
        };
        const v = try std.fmt.parseInt(usize, a[eq + 1 ..], 10);
        const k = a[0..eq];
        if (std.mem.eql(u8, k, "--cover-atoms")) limits.atoms = v else if (std.mem.eql(u8, k, "--cover-class")) limits.class = v else if (std.mem.eql(u8, k, "--cover-clauses")) limits.clauses = v else return error.BadArgument;
    }
    try run(init.gpa, init.io, limits);
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, limits: query.CoverLimits) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try corpus_mod.load(gpa, io, roots);
    defer corpus.deinit();

    const build_span = Span.open(io);
    var idx = try Index.build(gpa, corpus.docs);
    const build_ms = build_span.read(io).ms();
    defer idx.deinit();

    const plans = try readPlans(arena, io);

    const mib = @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20);
    std.debug.print("gist indexq · Layer L (index quality vs csearch) · abi v{d}\n", .{gist.abi()});
    std.debug.print("machine: {s} · zig {s}\n", .{ @tagName(builtin.target.cpu.arch), builtin.zig_version_string });
    std.debug.print("corpus:  {d} files · {d:.1} MiB · one index, one evaluator — only the FORMULA differs\n", .{ corpus.docs.len, mib });
    std.debug.print("gist index: {d:.0} ms build · {d:.1} MiB serialized · {d} distinct trigrams · {d} postings\n", .{
        build_ms, @as(f64, @floatFromInt(idx.serializedSize())) / (1 << 20), idx.dir_tri.len, idx.posting_count,
    });
    std.debug.print("cover limits: class={d} atoms={d} clauses={d}\n\n", .{ limits.class, limits.atoms, limits.clauses });

    std.debug.print("{s:<18} {s:<10} {s:>6} {s:>6} {s:>8} {s:>8} {s:>13} {s:>9} {s:>8}\n", .{ "class", "arm", "clause", "atoms", "docs", "cand%", "cand bytes", "precision", "query" });
    std.debug.print("{s:-<18} {s:-<10} {s:->6} {s:->6} {s:->8} {s:->8} {s:->13} {s:->9} {s:->8}\n", .{ "", "", "", "", "", "", "", "", "" });

    var violations: usize = 0;
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);

    for (probes, 0..) |p, pi| {
        const slate = if (pi < shared_classes) "shared" else "stress";
        if (pi == shared_classes) std.debug.print("{s:-<18} {s:-<10} {s:->6} {s:->6} {s:->8} {s:->8} {s:->13} {s:->9} {s:->8}  planner-stress slate\n", .{ "", "", "", "", "", "", "", "", "" });
        var re: ?Regex = null;
        var sim: ?Regex.Sim = null;
        defer if (sim) |*s| s.deinit();
        defer if (re) |*r| r.deinit();
        if (p.kind == .regex) {
            re = try Regex.compile(gpa, p.pattern);
            sim = try Regex.Sim.init(gpa, &re.?);
        }
        const plan = plans.get(p.class);
        const cs: []const Index.Clause = if (plan) |pl| pl.clauses else &.{};
        const own: i64 = if (plan) |pl| pl.own_docs else -1;

        const base = switch (p.kind) {
            .literal => try literalClauses(arena, p.pattern),
            .regex => try baseClauses(arena, &re.?),
        };
        // The Layer-L planner: the conjunctive cover
        // (`src/kernel/query/cover.zig`), read off the pattern SOURCE with
        // the matcher's own parse options, so the harness measures the formula
        // production would use and cannot flatter it.
        const prod: []const Index.Clause = switch (p.kind) {
            .literal => base,
            .regex => query.coverPlanSource(arena, p.pattern, .{}, limits) orelse base,
        };

        var hits_ref: ?usize = null;
        inline for (.{ Arm.gist_base, Arm.gist, Arm.csearch }) |arm| {
            const clauses = switch (arm) {
                .gist_base => base,
                .gist => if (p.kind == .literal) base else prod,
                .csearch => cs,
            };
            const row = try measureArm(gpa, io, &corpus, &idx, p, slate, arm, clauses, if (re) |*r| r else null, if (sim) |*s| s else null, if (arm == .csearch) own else -1);
            try rows.append(gpa, row);
            if (hits_ref) |h| {
                if (h != row.hits) {
                    violations += 1;
                    std.debug.print("  !! {s}/{s}: {d} verified hits, but another arm found {d} — a filter elided a real match\n", .{ p.class, arm.label(), row.hits, h });
                }
            } else hits_ref = row.hits;
            std.debug.print("{s:<18} {s:<10} {d:>6} {d:>6} {d:>8} {d:>7.2}% {d:>13} {d:>8.2}% {d:>6} us\n", .{
                row.class, arm.label(), row.clauses, row.atoms, row.cand_docs, row.cand_byte_frac * 100.0, row.cand_bytes, row.precision * 100.0, row.query_us,
            });
        }
    }

    try writeTsv(gpa, io, &corpus, &idx, build_ms, rows.items);
    std.debug.print("\nwrote {s}\n", .{csv_path});
    std.debug.print("run: python3 pkg/kernels/irregex/bench/certify/certify_indexq_report.py --certificate {s}/CERTIFICATE.md --tsv {s}\n", .{ out_dir, csv_path });

    if (violations > 0) {
        std.debug.print("\nFAILED: {d} cross-arm hit disagreement(s) — one of the three formulas is UNSOUND (it pruned a document the matcher says matches). Investigate; do NOT weaken the assertion.\n", .{violations});
        std.process.exit(1);
    }
    std.debug.print("\nSOUND: all three formulas admit supersets that verify to the identical hit set on every class.\n", .{});
}

fn writeTsv(gpa: std.mem.Allocator, io: std.Io, corpus: *const corpus_mod.Corpus, idx: *const Index, build_ms: f64, rows: []const Row) !void {
    try Dir.cwd().createDirPath(io, out_dir);
    var tsv: std.ArrayList(u8) = .empty;
    defer tsv.deinit(gpa);
    var line: [320]u8 = undefined;
    try tsv.appendSlice(gpa, try std.fmt.bufPrint(&line, "# corpus_docs\tcorpus_bytes\tgist_index_bytes\tgist_build_ms\n# {d}\t{d}\t{d}\t{d:.1}\n", .{
        corpus.docs.len, corpus.bytes, idx.serializedSize(), build_ms,
    }));
    try tsv.appendSlice(gpa, "class\tslate\tkind\tarm\tclauses\tatoms\tfiltered\tcand_docs\tcand_bytes\tcand_byte_frac\thits\tprecision\tquery_us\tcsearch_own_docs\n");
    for (rows) |r| {
        try tsv.appendSlice(gpa, try std.fmt.bufPrint(&line, "{s}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d:.6}\t{d}\t{d:.6}\t{d}\t{d}\n", .{
            r.class,
            r.slate,
            @tagName(r.kind),
            r.arm.label(),
            r.clauses,
            r.atoms,
            @intFromBool(r.filtered),
            r.cand_docs,
            r.cand_bytes,
            r.cand_byte_frac,
            r.hits,
            r.precision,
            r.query_us,
            r.csearch_own_docs,
        }));
    }
    try Dir.cwd().writeFile(io, .{ .sub_path = csv_path, .data = tsv.items });
}

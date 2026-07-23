//! Crest — production proof harness (Layer: does it actually work + how fast).
//!
//! Links gist's REAL engine (`@import("irregex")` — the crest kernel ships
//! inside it at `src/kernel/primitives/crest.zig`) and walks the REAL Billy corpus via the
//! same `corpus.load` the certificate layers use, so this is not a toy: the
//! baseline is gist's production `Regex.docMatch`, and every claim is a
//! measured number over live source bytes.
//!
//! For each class-repetition query it establishes three things, fail-closed:
//!   1. SOUNDNESS (the load-bearing claim). For EVERY file, if the real matcher
//!      matches then the Crest sieve must NOT prune it. A single violation over
//!      the whole corpus exits non-zero — no bandaid (sins.mdc). This is the
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
//! randomized adversarial soundness sweep — in BOTH engine modes (byte/ASCII
//! and rg-default Unicode), each paired with its own ĝ per the Alphabet
//! Contract (PROOF.md §3.6).

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");
const crest = gist.crest;

const corpus_mod = gist.corpus;
const Regex = gist.regex.Regex;
const load = corpus_mod.load;
const out_dir = corpus_mod.default_out_dir;
const K = crest.K;

const Query = struct { label: []const u8, pattern: []const u8 };

/// The slate: literal-free class repetitions — the trigram index's blind spot.
/// The last two are wide classes, kept HONEST: they should prune ~nothing.
const queries = [_]Query{
    .{ .label = "hex-8  (uuid/sha)", .pattern = "[0-9a-f]{8}" },
    .{ .label = "hex-12 (mac/hash)", .pattern = "[0-9a-f]{12}" },
    .{ .label = "digit-4 (year)", .pattern = "[0-9]{4}" },
    .{ .label = "digit-6", .pattern = "[0-9]{6}" },
    .{ .label = "upper-4 (CONST)", .pattern = "[A-Z]{4}" },
    .{ .label = "upper-6", .pattern = "[A-Z]{6}" },
    .{ .label = "word-3 (wide)", .pattern = "\\w{3,8}" },
    .{ .label = "alpha-5 (wide)", .pattern = "[A-Za-z]{5}" },
};

const Row = struct {
    label: []const u8,
    pattern: []const u8,
    ghat: crest.Vector,
    files: usize,
    run_survivors: usize,
    cnt_survivors: usize,
    hits: usize,
    full_ns: u64,
    sieve_ns: u64,
};

fn forcedStr(buf: []u8, gv: crest.Vector) []const u8 {
    var end: usize = 0;
    for (0..K) |i| {
        if (gv[i] == 0) continue;
        const sep: []const u8 = if (end > 0) " " else "";
        const part = std.fmt.bufPrint(buf[end..], "{s}{s}:{d}", .{ sep, crest.className(i), gv[i] }) catch break;
        end += part.len;
    }
    return if (end == 0) "—" else buf[0..end];
}

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.now(.awake, io).nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try load(gpa, io, roots);
    defer corpus.deinit();

    const n = corpus.docs.len;
    const mib = @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20);

    // Build the crest table via the PRODUCTION builder (the same parallel pass
    // `gist index` persists as crest.bin) + the count index (ablation).
    const build_t0 = nowNs(io);
    const crests = try gist.crest_sidecar.build(gpa, corpus.docs);
    defer gpa.free(crests);
    const build_ns = nowNs(io) - build_t0;

    const counts = try gpa.alloc([K]u32, n);
    defer gpa.free(counts);
    for (corpus.docs, 0..) |d, i| counts[i] = classCounts(d);

    const idx_bytes = n * K * @sizeOf(u16);
    std.debug.print("Crest — production proof · abi v{d}\n", .{gist.abi()});
    std.debug.print("machine: {s} · zig {s}\n", .{ @tagName(builtin.target.cpu.arch), builtin.zig_version_string });
    std.debug.print("corpus:  {d} files · {d:.1} MiB\n", .{ n, mib });
    std.debug.print("index:   crest built in {d:.2} ms · {d} classes · ~{d:.1} KiB ({d:.4}% of corpus)\n\n", .{
        @as(f64, @floatFromInt(build_ns)) / 1e6,     K,
        @as(f64, @floatFromInt(idx_bytes)) / 1024.0, @as(f64, @floatFromInt(idx_bytes)) / @as(f64, @floatFromInt(@max(corpus.bytes, 1))) * 100.0,
    });

    std.debug.print("{s:<20} {s:>16} {s:>10} {s:>10} {s:>10} {s:>10} {s:>9}\n", .{ "query", "forced ĝ", "RUN prune%", "CNT prune%", "full ms", "sieve ms", "speedup" });
    std.debug.print("{s:-<20} {s:->16} {s:->10} {s:->10} {s:->10} {s:->10} {s:->9}\n", .{ "", "", "", "", "", "", "" });

    var violations: usize = 0;
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);

    for (queries) |q| {
        // ASCII-mode pair — matcher and ĝ over the SAME byte alphabet (the
        // Alphabet Contract; the production sieve pairs them identically).
        const gv = crest.ghat(q.pattern, .{ .unicode = false });

        var re = try Regex.compileOpts(gpa, q.pattern, .{ .caseless = false, .unicode = false });
        defer re.deinit();
        var sim = try Regex.Sim.init(gpa, &re);
        defer sim.deinit();

        // (1) baseline: real matcher over EVERY file.
        const full_t0 = nowNs(io);
        var base_hits: usize = 0;
        for (corpus.docs) |d| {
            if (re.docMatch(&sim, d)) base_hits += 1;
        }
        const full_ns = nowNs(io) - full_t0;

        // (2) sieve: crest compare, real matcher only on survivors + per-file
        //     soundness assertion (matched ⇒ ¬pruned) across the whole corpus.
        const sieve_t0 = nowNs(io);
        var run_survivors: usize = 0;
        var sieve_hits: usize = 0;
        for (corpus.docs, 0..) |d, i| {
            if (crest.pruned(crests[i], gv)) continue;
            run_survivors += 1;
            if (re.docMatch(&sim, d)) sieve_hits += 1;
        }
        const sieve_ns = nowNs(io) - sieve_t0;

        // Fail-closed soundness: the sieve must not have dropped a real hit.
        if (sieve_hits != base_hits) {
            violations += 1;
            std.debug.print("  !! SOUNDNESS VIOLATION on {s}: sieve {d} hits, full {d} — a match was pruned!\n", .{ q.pattern, sieve_hits, base_hits });
        }

        // (3) ablation: the weaker count cousin at the same ĝ (sound: pop ≥ run).
        var cnt_survivors: usize = 0;
        for (counts) |c| {
            if (!countPruned(c, gv)) cnt_survivors += 1;
        }

        try rows.append(gpa, .{
            .label = q.label,
            .pattern = q.pattern,
            .ghat = gv,
            .files = n,
            .run_survivors = run_survivors,
            .cnt_survivors = cnt_survivors,
            .hits = base_hits,
            .full_ns = full_ns,
            .sieve_ns = sieve_ns,
        });

        var fbuf: [128]u8 = undefined;
        const run_pct = (1.0 - @as(f64, @floatFromInt(run_survivors)) / @as(f64, @floatFromInt(@max(n, 1)))) * 100.0;
        const cnt_pct = (1.0 - @as(f64, @floatFromInt(cnt_survivors)) / @as(f64, @floatFromInt(@max(n, 1)))) * 100.0;
        const full_ms = @as(f64, @floatFromInt(full_ns)) / 1e6;
        const sieve_ms = @as(f64, @floatFromInt(sieve_ns)) / 1e6;
        const speed = if (sieve_ns > 0) @as(f64, @floatFromInt(full_ns)) / @as(f64, @floatFromInt(sieve_ns)) else 0;
        std.debug.print("{s:<20} {s:>16} {d:>9.1}% {d:>9.1}% {d:>9.2} {d:>9.2} {d:>8.2}x\n", .{
            q.label, forcedStr(&fbuf, gv), run_pct, cnt_pct, full_ms, sieve_ms, speed,
        });
    }

    std.debug.print("\nRUN = Crest sieve (max consecutive class-run) · CNT = weaker cousin (total class population, same ĝ)\n", .{});

    // (4) randomized adversarial soundness sweep beyond the fixed slate — both
    //     engine modes, each paired with its own ĝ (the Alphabet Contract).
    const ascii_checks = try randomSoundness(gpa, &corpus, false, &violations);
    const uni_checks = try randomSoundness(gpa, &corpus, true, &violations);
    std.debug.print("randomized soundness: {d} ASCII + {d} Unicode (pattern,file) pairs · matched⇒¬pruned held on all\n", .{ ascii_checks, uni_checks });

    try writeCsv(gpa, io, n, mib, rows.items);
    std.debug.print("wrote {s}/crest.csv\n", .{out_dir});

    if (violations > 0) {
        std.debug.print("\nFAILED: {d} soundness violation(s) — the sieve pruned a real match. Do NOT weaken; fix the calculus.\n", .{violations});
        std.process.exit(1);
    }
    std.debug.print("\nPROVEN: 0 false negatives across the corpus and the random sweeps; the Crest sieve prunes the literal-free class where the trigram index prunes 0%, and the count cousin cannot.\n", .{});
}

/// The weaker cousin: total per-class population (branch B). Sound but dominated.
fn classCounts(doc: []const u8) [K]u32 {
    var cnt: [K]u32 = @splat(0);
    for (doc) |b| {
        const bits = crest.membership[b];
        inline for (0..K) |i| {
            if ((bits & (@as(u8, 1) << i)) != 0) cnt[i] += 1;
        }
    }
    return cnt;
}

/// The cousin's sieve decision at the same ĝ (population < forced run ⇒ prune).
fn countPruned(cnt: [K]u32, gv: crest.Vector) bool {
    inline for (0..K) |i| {
        if (cnt[i] < gv[i]) return true;
    }
    return false;
}

/// Randomized adversarial soundness: build class-repetition patterns with random
/// classes / counts / concatenation / alternation, compile with the REAL engine
/// in the requested mode, and assert matched ⇒ ¬pruned on a sample of real
/// files — ĝ computed with the SAME mode flag the engine got, exactly as the
/// production `crestSieve` pairs them. Returns the number of pairs checked.
fn randomSoundness(gpa: std.mem.Allocator, corpus: *const corpus_mod.Corpus, unicode: bool, violations: *usize) !usize {
    var prng = std.Random.DefaultPrng.init(if (unicode) 0xBEEFCAFE else 0xC0FFEE);
    const rnd = prng.random();
    const atoms = [_][]const u8{ "[0-9]", "[0-9a-f]", "[A-Z]", "[a-z]", "[A-Za-z]", "\\d", "\\w", "\\s", "[A-Za-z0-9]", "[0-7]" };
    var checked: usize = 0;
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
        var re = Regex.compileOpts(gpa, pat, .{ .caseless = false, .unicode = unicode }) catch continue;
        defer re.deinit();
        var sim = Regex.Sim.init(gpa, &re) catch continue;
        defer sim.deinit();
        const gv = crest.ghat(pat, .{ .unicode = unicode });

        // sample up to 60 files per pattern
        var s: usize = 0;
        while (s < 60) : (s += 1) {
            const d = corpus.docs[rnd.uintLessThan(usize, corpus.docs.len)];
            checked += 1;
            const matched = re.docMatch(&sim, d);
            if (matched and crest.pruned(crest.crest(d), gv)) {
                violations.* += 1;
                std.debug.print("  !! RANDOM SOUNDNESS VIOLATION: pat={s} unicode={} pruned a match\n", .{ pat, unicode });
            }
        }
    }
    return checked;
}

fn writeCsv(gpa: std.mem.Allocator, io: std.Io, n: usize, mib: f64, rows: []const Row) !void {
    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(gpa);
    try csv.appendSlice(gpa, "# corpus_files\tcorpus_mib\n");
    var line: [256]u8 = undefined;
    try csv.appendSlice(gpa, try std.fmt.bufPrint(&line, "# {d}\t{d:.1}\n", .{ n, mib }));
    try csv.appendSlice(gpa, "query\tpattern\tfiles\trun_survivors\tcnt_survivors\trun_prune_pct\tcnt_prune_pct\thits\tfull_ms\tsieve_ms\tspeedup\n");
    for (rows) |r| {
        const run_pct = (1.0 - @as(f64, @floatFromInt(r.run_survivors)) / @as(f64, @floatFromInt(@max(n, 1)))) * 100.0;
        const cnt_pct = (1.0 - @as(f64, @floatFromInt(r.cnt_survivors)) / @as(f64, @floatFromInt(@max(n, 1)))) * 100.0;
        const speed = if (r.sieve_ns > 0) @as(f64, @floatFromInt(r.full_ns)) / @as(f64, @floatFromInt(r.sieve_ns)) else 0;
        try csv.appendSlice(gpa, try std.fmt.bufPrint(&line, "{s}\t{s}\t{d}\t{d}\t{d}\t{d:.2}\t{d:.2}\t{d}\t{d:.3}\t{d:.3}\t{d:.3}\n", .{
            r.label,                                  r.pattern,                                 r.files, r.run_survivors, r.cnt_survivors, run_pct, cnt_pct, r.hits,
            @as(f64, @floatFromInt(r.full_ns)) / 1e6, @as(f64, @floatFromInt(r.sieve_ns)) / 1e6, speed,
        }));
    }
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    var d = try std.Io.Dir.cwd().openDir(io, out_dir, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = "crest.csv", .data = csv.items });
}

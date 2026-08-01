//! Quotient sieve — production proof harness (soundness, selectivity, speed).
//!
//! Links gist's REAL engine (`@import("irregex")`) and walks the REAL host
//! corpus, so nothing here is a toy: the baseline is the shipped byte-class
//! DFA's own `docMatch`, and the sieve under test is the one `Sieve.build`
//! hands the ladder.
//!
//! Three claims, each fail-closed:
//!
//!   1. **Soundness, per byte position.** For every position of every document,
//!      if the search DFA is in a matching state then every conjunct must be in
//!      an accepting block. One violation across the whole corpus exits
//!      non-zero — the sieve would have retired a haystack that matches, which
//!      is a missed match and the worst failure this engine has. Checked twice:
//!      per position against the DFA's own interior run, and per document
//!      end-to-end against the production matcher.
//!   2. **Selectivity, measured.** The share of positions that fall through,
//!      printed beside the compile-time structural estimate that decides whether
//!      the sieve arms at all. Bad rows are printed, not hidden: the
//!      distribution is bimodal and that is the honest result.
//!   3. **Speed.** Wall time of the shipped `docMatch` over the corpus vs the
//!      Sheng-resident kernel over the same bytes in the same run, so the ratio
//!      is robust to a loaded machine.
//!
//! Novelty, stated once so the numbers are not read as a claim: the filter
//! contract — a compact over-approximating automaton as a sound reject stage in
//! front of an exact verifier — is Luchaup et al., INFOCOM 2014; Češka et al.,
//! arXiv:1904.10786; and Hyperscan's `HS_FLAG_PREFILTER`. See `README.md`.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");
const corpus_mod = gist.corpus;
const Regex = gist.regex.Regex;
const sieve_mod = gist.regex_sieve;
/// The measured price plane, so every cost this bench quotes or hands the gate is
/// the same number the gate itself reads.
const price = sieve_mod.price;
const Sieve = sieve_mod.Sieve;
const Class = sieve_mod.Class;
const Quotient = gist.regex_sieve.quotient.Quotient;
const Span = gist.assay.Span;

const Query = struct { label: []const u8, pattern: []const u8 };

/// The research lane's slate, plus the two rows that keep it honest. The last
/// two should sieve badly — a table with no ≈0% row is hiding something.
const queries = [_]Query{
    .{ .label = "digit-40 (saturating)", .pattern = "[0-9]{40,}" },
    .{ .label = "alnum-alt (exact)", .pattern = "[A-Za-z]+[0-9]+[A-Za-z]+" },
    .{ .label = "iso-date", .pattern = "[0-9]{4}-[0-9]{2}-[0-9]{2}" },
    .{ .label = "uuid", .pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}" },
    .{ .label = "two-Capitals", .pattern = "[A-Z][a-z]+ [A-Z][a-z]+" },
    .{ .label = "word-space-word", .pattern = "\\w+\\s+\\w+" },
    .{ .label = "base64-40", .pattern = "[A-Za-z0-9+/]{40,}={0,2}" },
    .{ .label = "alnum (weak)", .pattern = "[A-Za-z]+[0-9]+" },
    .{ .label = "hex-literal (worthless)", .pattern = "0x[0-9a-fA-F]{8,16}" },
};

/// One document's lockstep walk: the DFA's interior run and the sieve's
/// quotients advanced over the same bytes, position by position.
const Walk = struct {
    positions: u64 = 0,
    truth: u64 = 0, // positions where the DFA is in a matching state
    fallthrough: u64 = 0, // positions where every conjunct accepts
    violations: u64 = 0, // truth ∧ ¬fallthrough — the only fatal outcome
};

fn walk(d: *const gist.regex_dfa.Dfa, qs: []const Quotient, doc: []const u8, w: *Walk) void {
    var s: u32 = d.start;
    var st: [4]u8 = undefined;
    for (qs, 0..) |*q, i| st[i] = q.start;
    for (doc) |b| {
        s = d.trans_in[s + d.class[b]];
        var all = true;
        for (qs, 0..) |*q, i| {
            st[i] = q.rows[b][st[i]];
            all = all and st[i] >= q.th;
        }
        const hit = d.isMatch(s);
        w.positions += 1;
        w.truth += @intFromBool(hit);
        w.fallthrough += @intFromBool(all);
        w.violations += @intFromBool(hit and !all);
    }
}

/// Wall time of the shipped engine's whole-corpus scan, plus its hit count so
/// the timed loop is provably doing the work.
fn timeFull(io: std.Io, re: *Regex, sim: *Regex.Sim, docs: []const []const u8) struct { ns: i128, hits: usize } {
    const sp = Span.open(io);
    var hits: usize = 0;
    for (docs) |doc| hits += @intFromBool(re.docMatch(sim, doc));
    return .{ .ns = sp.read(io).ns(), .hits = hits };
}

/// Wall time of the sieve kernel over the same bytes, plus how many documents
/// it retired.
fn timeSieve(io: std.Io, s: *const Sieve, docs: []const []const u8) struct { ns: i128, retired: usize } {
    const sp = Span.open(io);
    var retired: usize = 0;
    for (docs) |doc| retired += @intFromBool(verdict(s, doc) == .miss);
    return .{ .ns = sp.read(io).ns(), .retired = retired };
}

/// The shipped dispatch: four-lane whole-buffer scan where the `nl_reset`
/// licence holds, one chain otherwise.
fn verdict(s: *const Sieve, doc: []const u8) sieve_mod.Verdict {
    return if (s.doc_ok) s.scanDoc(doc) else s.scan(doc);
}

/// The same automaton, same bytes, one chain, walked one dependent L1 load at a
/// time — the Sheng residency claim's proper control. Everything but where the
/// state lives is held constant: same quotients, same corpus, same single
/// stream, no early exit on either side. (`Sieve.scanScalar` is the differential
/// *oracle* and short-circuits the moment a position survives, which makes it a
/// verdict reference but not a timing control.)
fn timeScalar(io: std.Io, s: *const Sieve, docs: []const []const u8) i128 {
    const sp = Span.open(io);
    var acc: usize = 0;
    for (docs) |doc| {
        var st: [4]u8 = undefined;
        for (s.q[0..s.n], 0..) |*q, i| st[i] = q.start;
        for (doc) |b| {
            for (s.q[0..s.n], 0..) |*q, i| st[i] = q.rows[b][st[i]];
            acc += st[0];
        }
    }
    std.mem.doNotOptimizeAway(acc);
    return sp.read(io).ns();
}

/// The single-chain vector kernel over the same documents — the middle rung, so
/// the register-residency win and the lane-parallelism win are reported
/// separately instead of as one conflated number.
fn timeSheng1(io: std.Io, s: *const Sieve, docs: []const []const u8) i128 {
    const sp = Span.open(io);
    var retired: usize = 0;
    for (docs) |doc| retired += @intFromBool(s.scan(doc) == .miss);
    std.mem.doNotOptimizeAway(retired);
    return sp.read(io).ns();
}

/// What the sieve actually SAVED: the exact matcher over only the documents it
/// retired, plus how many of the corpus's bytes those documents held.
///
/// This is the row that explains a sieve which retires most DOCUMENTS and still
/// measures a loss. Profit is decided in bytes, and survival grows with buffer
/// length (`1-(1-f)^L`), so the documents that survive are systematically the
/// long ones — a corpus can hand 98% of its documents to the sieve and keep 60%
/// of its bytes on the other side of the gate. The compile-time arithmetic
/// judges one nominal 4 KiB buffer and cannot see that.
fn timeSaved(io: std.Io, s: *const Sieve, re: *Regex, sim: *Regex.Sim, docs: []const []const u8) struct { ns: i128, bytes: usize } {
    var retired: std.ArrayList([]const u8) = .empty;
    defer retired.deinit(std.heap.page_allocator);
    var bytes: usize = 0;
    for (docs) |doc| if (verdict(s, doc) == .miss) {
        retired.append(std.heap.page_allocator, doc) catch continue;
        bytes += doc.len;
    };
    const sp = Span.open(io);
    var hits: usize = 0;
    for (retired.items) |doc| hits += @intFromBool(re.docMatch(sim, doc));
    std.mem.doNotOptimizeAway(hits);
    return .{ .ns = sp.read(io).ns(), .bytes = bytes };
}

/// What the ladder actually pays: the sieve over every document, then the
/// shipped matcher over only the survivors.
fn timeLadder(io: std.Io, s: *const Sieve, re: *Regex, sim: *Regex.Sim, docs: []const []const u8) struct { ns: i128, hits: usize } {
    const sp = Span.open(io);
    var hits: usize = 0;
    for (docs) |doc| {
        if (verdict(s, doc) == .miss) continue;
        hits += @intFromBool(re.docMatch(sim, doc));
    }
    return .{ .ns = sp.read(io).ns(), .hits = hits };
}

fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn ratio(a: i128, b: i128) f64 {
    return @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(@max(b, 1)));
}

fn docPct(part: usize, whole: usize) f64 {
    return @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(@max(whole, 1))) * 100.0;
}

fn median(xs: []i128) i128 {
    std.mem.sort(i128, xs, {}, std.sort.asc(i128));
    return xs[xs.len / 2];
}

fn byteClass(chars: []const u8) Class {
    var set: Class = .{};
    for (chars) |b| set.set(b);
    return set;
}

fn hasWindow(classes: []const Class, hay: []const u8) bool {
    if (hay.len < classes.len) return false;
    for (0..hay.len - classes.len + 1) |at| {
        var all = true;
        for (classes, hay[at..][0..classes.len]) |*set, b| all = all and set.has(b);
        if (all) return true;
    }
    return false;
}

/// Prove and price the no-eager-DFA seam on the same corpus. The q-gram is a
/// UUID-like heterogeneous class sequence; truth is evaluated directly from
/// its classes, independently of the subset machine built by the sieve.
fn windowEvidence(gpa: std.mem.Allocator, io: std.Io, docs: []const []const u8) !u64 {
    var hex = byteClass("0123456789");
    hex.setRange('a', 'f');
    hex.setRange('A', 'F');
    const dash = byteClass("-");
    const classes = [_]Class{ hex, hex, hex, hex, dash, hex, hex, hex, hex };
    const built = try Sieve.buildWindows(gpa, &.{.{ .classes = &classes }}, .{}, .ungated);
    const s = built.sieve orelse return error.WindowBuilderDeclined;
    defer s.deinit();

    var violations: u64 = 0;
    for (docs) |doc| if (hasWindow(&classes, doc) and s.scan(doc) == .miss) {
        violations += 1;
    };
    const timed = timeSieve(io, s, docs);
    std.debug.print("\nno-DFA window: q=9 · states={d} · retired={d:.1}% · {d:.1} ms · violations={d}\n", .{
        s.q[0].nb,
        100.0 - docPct(docs.len - timed.retired, docs.len),
        ms(timed.ns),
        violations,
    });
    // Sensitivity to the machine it fronts, swept over the three REAL deciders
    // rather than three round numbers. The point of the sweep is that a sieve
    // profitable in front of the Pike VM can be a loss in front of composition,
    // and the prices have to be the ones those machines actually measured for
    // that to mean anything.
    const rivals = [_]struct { name: []const u8, m: price.Machine }{
        .{ .name = "compose16", .m = .{ .compose = .{ .width = .lanes16, .eol = false, .table_bytes = 0 } } },
        .{ .name = "eager-dfa", .m = .{ .walk = .{ .kind = .eager } } },
        .{ .name = "pike-vm", .m = .{ .walk = .{ .kind = .pike } } },
    };
    for (rivals) |rival| {
        const cost = price.price(rival.m).scan;
        const admission = try Sieve.buildWindows(gpa, &.{.{ .classes = &classes }}, .{ .decider_cost = cost }, .worth);
        defer if (admission.sieve) |armed| armed.deinit();
        std.debug.print("  census: fronting {s:<9} ({d:.2} cyc/B) · {s} · line-total={d:.0} · doc-total={d:.0}\n", .{
            rival.name,
            price.price(rival.m).cycPerByte(),
            if (admission.sieve != null) "armed" else @tagName(admission.decline.?),
            if (admission.cost) |c| c.total(.line) else 0,
            if (admission.cost) |c| c.total(.doc) else 0,
        });
    }
    return violations;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try corpus_mod.load(gpa, io, roots, .contiguous);
    defer corpus.deinit();

    // The same instrument `ladder-price` mints with, so a corpus cyc/B printed
    // below and the coefficient it disagrees with were divided by one clock.
    const clock = gist.assay.Cadence.measure(io, 1 << 16);
    const mib = @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20);
    std.debug.print("Quotient sieve — production proof · abi v{d}\n", .{gist.abi()});
    std.debug.print("machine: {s} · zig {s} · shuffle-resident: {}\n", .{ @tagName(builtin.target.cpu.arch), builtin.zig_version_string, sieve_mod.sheng.resident });
    std.debug.print("corpus:  {d} files · {d:.1} MiB\n", .{ corpus.docs.len, mib });
    // The gate, stated as the arithmetic it now is: two measured prices and a
    // survival term, not one offline constant standing in for both sides. The
    // ratio is printed because the README argues in ratios — but it is derived
    // from the same two numbers rather than declared beside them.
    std.debug.print("gate:    arm when sieve + (1-(1-f)^len)·exact < exact at EITHER grain (line {d:.0} B, buffer {d:.0} B);\n", .{ sieve_mod.nominal_line, sieve_mod.nominal_doc });
    std.debug.print("         each path then enforces its own half — lineSafe / docSafe\n", .{});
    std.debug.print("price:   sieve {d:.3} cyc/B (1 conjunct, buffer kernel) vs dense walk {d:.3} cyc/B = {d:.2}x advantage\n", .{
        price.sievePerByte(1, .doc),
        price.active.dfa_step,
        1.0 / sieve_mod.speedRatio(1, .doc),
    });
    std.debug.print("         calibration: {s} · minted {s}\n\n", .{ price.active.machine, price.active.minted });

    std.debug.print("{s:<24} {s:>4} {s:>8} {s:>12} {s:>12} {s:>11} {s:>10} {s:>9}\n", .{
        "pattern", "|Q|", "blocks", "truth rate", "fallthrough", "reject%", "docs kept", "armed",
    });
    std.debug.print("{s:-<24} {s:->4} {s:->8} {s:->12} {s:->12} {s:->11} {s:->10} {s:->9}\n", .{ "", "", "", "", "", "", "", "" });

    var violations: u64 = 0;
    var total_positions: u64 = 0;
    var declined: usize = 0;
    // Rows the gate admitted that the corpus then measured as slower than no
    // sieve at all. Not a soundness failure — every answer is still correct —
    // but it is the decision quality this whole cost policy exists to deliver,
    // so it is counted and named rather than left for a reader to spot.
    var armed_losses: usize = 0;

    for (queries) |q| {
        var re = try Regex.compileOpts(gpa, q.pattern, .{ .force_dfa = true });
        defer re.deinit();
        const d = re.dfa orelse {
            std.debug.print("{s:<24}  (no DFA — powerset cap; Pike serves)\n", .{q.label});
            continue;
        };
        var sim = try Regex.Sim.init(gpa, &re);
        defer sim.deinit();

        // Built twice on purpose: `.ungated` gives the row its measured
        // selectivity even when the cost gate declines, which is the only way
        // to publish the bad rows at all; `.worth` is the shipped decision.
        const s = (try Sieve.build(gpa, d, .{}, .ungated)) orelse {
            std.debug.print("{s:<24} {d:>4}  (no register-resident quotient harvested)\n", .{ q.label, d.nstates });
            continue;
        };
        defer s.deinit();
        // The machine this sieve would really front is whatever the ladder just
        // selected for this pattern — its accelerated DFA, its composition, its
        // skip. A flat `30_000` here told every sieve it fronted a 3.0 cyc/B
        // dense walk, and the `ladder:` rows below are what that bought: three
        // patterns arming into a measured LOSS because they were quoted an
        // incumbent 3x dearer than the one the bench then timed them against.
        const admitted = try Sieve.buildDfa(gpa, d, .{
            .decider_cost = re.rungs.admission.selected_cost.scan,
            .prefilter = re.rungs.admission.prefilter,
        }, .worth);
        const shipped = admitted.sieve;
        defer if (shipped) |sh| sh.deinit();
        if (shipped == null) declined += 1;

        // (1) Soundness, every position of every document.
        var w: Walk = .{};
        for (corpus.docs) |doc| walk(d, s.q[0..s.n], doc, &w);
        total_positions += w.positions;
        if (w.violations != 0) {
            violations += w.violations;
            std.debug.print("  !! SOUNDNESS VIOLATION on /{s}/: {d} positions where the DFA matched and the sieve did not\n", .{ q.pattern, w.violations });
        }

        // (2) Soundness end-to-end: a retired document must not match. This is
        // the claim the ladder actually rests on, checked against the shipped
        // matcher rather than against the DFA the sieve was derived from.
        if (s.doc_ok) {
            for (corpus.docs) |doc| {
                if (s.scanDoc(doc) == .miss and re.docMatch(&sim, doc)) {
                    violations += 1;
                    std.debug.print("  !! DOCUMENT VIOLATION on /{s}/: retired a matching document\n", .{q.pattern});
                    break;
                }
            }
        }

        // (3) Speed: three paired runs, median, same machine, same run, so a
        // loaded box moves every arm together and the ratios survive it.
        var full_ns: [3]i128 = undefined;
        var kern_ns: [3]i128 = undefined;
        var scal_ns: [3]i128 = undefined;
        var one_ns: [3]i128 = undefined;
        var ladder_ns: [3]i128 = undefined;
        var retired: usize = 0;
        var hits: usize = 0;
        for (0..3) |i| {
            const f = timeFull(io, &re, &sim, corpus.docs);
            const k = timeSieve(io, s, corpus.docs);
            const l = timeLadder(io, s, &re, &sim, corpus.docs);
            full_ns[i] = f.ns;
            kern_ns[i] = k.ns;
            scal_ns[i] = timeScalar(io, s, corpus.docs);
            one_ns[i] = timeSheng1(io, s, corpus.docs);
            ladder_ns[i] = l.ns;
            retired = k.retired;
            // The ladder must find exactly what the full scan finds. This is
            // the same soundness claim as (2), re-checked inside the timing
            // loop so a fast wrong answer cannot be reported as a fast one.
            if (l.hits != f.hits) {
                violations += 1;
                std.debug.print("  !! LADDER DIVERGENCE on /{s}/: sieve+survivors found {d}, full scan found {d}\n", .{ q.pattern, l.hits, f.hits });
            }
            hits = f.hits;
        }
        const full = median(&full_ns);
        const kern = median(&kern_ns);
        const scal = median(&scal_ns);
        const one = median(&one_ns);
        const ladder = median(&ladder_ns);

        const pos: f64 = @floatFromInt(@max(w.positions, 1));
        const measured = @as(f64, @floatFromInt(w.fallthrough)) / pos;
        var blocks: [8]u8 = undefined;
        const blocks_str = if (s.n == 1)
            std.fmt.bufPrint(&blocks, "{d}", .{s.q[0].nb}) catch "?"
        else
            std.fmt.bufPrint(&blocks, "{d},{d}", .{ s.q[0].nb, s.q[1].nb }) catch "?";

        std.debug.print("{s:<24} {d:>4} {s:>8} {e:>12.2} {e:>12.2} {d:>10.4}% {d:>9.1}% {s:>9}\n", .{
            q.label,                                            d.nstates,
            blocks_str,                                         @as(f64, @floatFromInt(w.truth)) / pos,
            measured,                                           (1.0 - measured) * 100.0,
            docPct(corpus.docs.len - retired, corpus.docs.len), if (shipped != null) "yes" else "DECLINED",
        });
        std.debug.print("  model: est f={e:.2} (uniform {e:.2} · text {e:.2}) · measured f={e:.2}{s}\n", .{
            s.fallthrough,
            gist.regex_sieve.quotient.fallthroughRate(&s.q[0], .uniform),
            gist.regex_sieve.quotient.fallthroughRate(&s.q[0], .text),
            measured,
            if (shipped == null and measured > 0.4) "  ← correctly declined" else "",
        });
        // Every row's arithmetic, armed or declined. A bench that explains only
        // its refusals hides half its reasoning — and the half it hid was where
        // three patterns armed into a measured loss.
        if (admitted.cost) |c| std.debug.print(
            "  census: {s:<13} · fronting {s} at {d:.2} cyc/B · line {d:.2} vs {d:.2} · doc {d:.2} vs {d:.2}\n",
            .{
                if (admitted.decline) |why| @tagName(why) else "armed",
                @tagName(re.rungs.admission.selected),
                (price.Cost{ .scan = c.decider_cost }).cycPerByte(),
                c.total(.line) / price.unit,
                c.exact(.line) / price.unit,
                c.total(.doc) / price.unit,
                c.exact(.doc) / price.unit,
            },
        );
        std.debug.print("  kernel: scalar-1 {d:.1} ms → sheng-1 {d:.1} ms ({d:.2}x residency) → sheng-{d} {d:.1} ms ({d:.2}x lanes, {d:.2}x total)\n", .{
            ms(scal),          ms(one),
            ratio(scal, one),  if (s.n == 1) @as(usize, 4) else 2,
            ms(kern),          ratio(one, kern),
            ratio(scal, kern),
        });
        std.debug.print("  ladder: shipped {d:.1} ms · sieve+survivors {d:.1} ms ({d:.2}x)\n", .{ ms(full), ms(ladder), ratio(full, ladder) });
        // Where the profit had to come from, in bytes rather than documents.
        const saved = timeSaved(io, s, &re, &sim, corpus.docs);
        std.debug.print("  bytes:  retired {d:.1}% of bytes · saved {d:.1} ms vs {d:.1} ms of pre-pass ({d:.2}x)\n", .{
            docPct(saved.bytes, corpus.bytes),
            ms(saved.ns),
            ms(kern),
            ratio(saved.ns, kern),
        });
        // What the incumbent's price was derived from, beside what it measured
        // here. A rung mispriced against the corpus is the auction's defect, not
        // this rung's, and the two have to be told apart before either is fixed.
        std.debug.print("  walk:   {d} classes · dwell {s} · bid {d:.2} cyc/B · corpus {d:.2} cyc/B\n", .{
            d.ncls,
            if (d.start_dwell) |dw| brk: {
                var buf: [48]u8 = undefined;
                break :brk std.fmt.bufPrint(&buf, "armed (stride {d})", .{dw.economics.stride}) catch "armed";
            } else "none",
            re.rungs.admission.selected_cost.cycPerByte(),
            if (clock) |c| c.cycPerByte(@enumFromInt(saved.ns), @max(saved.bytes, 1)) else 0,
        });
        if (shipped != null and ratio(full, ladder) < 1.0) {
            armed_losses += 1;
            std.debug.print("  ↑ ARMED INTO A LOSS: the compile-time arithmetic said this pays and the corpus says it does not.\n", .{});
        }
    }
    violations += try windowEvidence(gpa, io, corpus.docs);

    std.debug.print("\nsoundness: {d} violations over {d} byte-positions\n", .{ violations, total_positions });
    std.debug.print("gate:      {d} of {d} patterns declined at compile time\n", .{ declined, queries.len });
    std.debug.print("decision:  {d} armed row(s) measured slower than no sieve\n", .{armed_losses});
    if (armed_losses != 0) std.debug.print(
        \\           The residual is ONE input, not the cost arithmetic: `fallthroughRate`
        \\           prices each position under a MEMORYLESS byte prior, and pattern-shaped
        \\           bytes cluster. Its error is exponential in the run the pattern needs —
        \\           ~6x at 10 required bytes, ~4e4 at 32, ~2e17 at 40 — so no single
        \\           correction covers the slate and only a persistence-aware prior closes
        \\           it. See `sieve/README.md`.
        \\
    , .{});
    if (violations != 0) {
        std.debug.print("FAILED: the sieve rejected somewhere the matcher accepted.\n", .{});
        std.process.exit(1);
    }
    if (total_positions == 0) {
        std.debug.print("FAILED: no positions checked — the corpus did not load.\n", .{});
        std.process.exit(1);
    }
}

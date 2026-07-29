//! Automata — the machine-algebra proof harness: does a change to the
//! determinizer or to the automaton's layout actually pay, and is the automaton
//! we build smaller and cheaper than the one the field builds?
//!
//! Every other rung under `bench/rungs/` races a whole accelerator against the
//! shipped DFA. This one races *inside* the DFA. The claims in
//! `research/automata/CLAIM.md` are each about one function — a closure, a match
//! test, a table — so a binary race cannot attribute them and a whole-suite
//! rerun cannot either.
//!
//! Three sections, three kinds of evidence, and they are deliberately not mixed:
//!
//!   1. **`shape`** — NFA states, byte classes, DFA states, how many accept,
//!      table bytes, and determinization time. No search timing. This is the
//!      section that crosses the engine boundary: `bar.py` joins it against
//!      `regex-cli debug dense dfa` from the rust-`regex` clone, so the
//!      coarser-alphabet claim is measured against theirs rather than asserted.
//!      Emitted as TSV so that join needs no column-width guessing.
//!   2. **`build`** — determinization alone, re-run over the SAME lowered NFA the
//!      shipped compile produced, min-of-N. Isolating it from parse + analysis is
//!      what makes a closure-level claim attributable.
//!   3. **`search`** — the match test, both forms: the shipped `s < match_hi`
//!      compare against the `is_match[s]` load it replaced. The load arm
//!      reconstructs the exact array the old code allocated, *from the shipped
//!      bound*, so the two arms are provably the same machine; the two walks are
//!      byte-identical but for that one line. Interleaved round by round.
//!
//! **Every search document is match-free by construction, and the harness proves
//! it.** A boolean scan returns at the first hit, so timing a matching haystack
//! measures the match position rather than the recurrence. Each row carries the
//! alphabet its document is filled from, chosen so the pattern cannot match, and
//! a row whose document *does* match fails the run instead of publishing a
//! number. (`bench/bounds/port/measure.zig` makes the same argument for the same
//! loop; this is that discipline over a slate.)
//!
//! Read the `seen` column before the `speedup` column. It reports how many
//! distinct states the walk actually entered, and it is what separates a row that
//! exercises the automaton from a row that sits in a self-loop. A pattern can
//! determinize to 512 states and visit two of them; a state that never changes
//! makes the load it replaced a perfectly-predicted L1 hit, so those rows price
//! the *instruction* and nothing more. The rows that wander are where the
//! recurrence is doing real work, and they are the rows to judge this by.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");

const Regex = gist.regex.Regex;
const syntax = gist.regex_syntax;
const analysis = gist.regex_analysis;
const ast_mod = gist.regex_ast;
/// The first-byte prefilter as the handle carries it, reached through the handle's
/// own field rather than through a new export: pricing a candidate byte set is the
/// engine's opinion, and a rung that asked a second implementation would be
/// measuring its own arithmetic.
const Prefilter = @FieldType(Regex, "first");
const determinize = gist.regex_determinize;
const dwell_mod = gist.regex_dwell;
const reduce = gist.regex_reduce;
const Span = gist.assay.Span;

/// Interference from the ~10 coworker agents on this box only ever *slows* a
/// trial, so min-of-N across interleaved rounds is the cleanest estimate of the
/// true per-core cost (the rationale every other rung here uses).
const trials = 9;

/// Rounds for the build section. Determinization is milliseconds where a scan is
/// seconds, so it needs more rounds to escape timer noise, and it is cheap enough
/// to afford them.
const build_trials = 15;
const scan_trials = 5; // a 2 MiB walk, so fewer trials than a microsecond build needs

/// Document size and sweeps per trial. The document streams from memory while
/// the tables stay resident, which is the regime `docMatch` runs in; sweeping a
/// mid-sized buffer rather than reading one huge one keeps the number about the
/// loop instead of about the file system.
const doc_bytes = 8 << 20;
const sweeps = 4;
const line_len = 80; // real source shape: `$`/`trans_fin` resolves this often

/// One row: a pattern, and — when the row is eligible for the search A/B — the
/// alphabet its document is filled from. The alphabet is chosen so the pattern
/// provably cannot match, which is what makes the walk traverse every byte
/// instead of returning at the first hit, and the harness verifies the claim
/// rather than trusting it. `fill == null` means shape-and-build only: the
/// pattern is here to be measured against the field, and no match-free alphabet
/// for it was worth constructing.
const Row = struct {
    pat: []const u8,
    /// Bytes the filler draws from. `\n` is inserted separately, every
    /// `line_len` bytes, so it never needs to appear here.
    fill: ?[]const u8 = null,
    why: []const u8 = "", // why this alphabet cannot match this pattern
};

/// The slate. The first block is the **cross-engine** set: it is the pattern
/// list `bench/dominance/races/regex.sh` races binaries on, so the shape numbers
/// here describe the same automata that race decides — a shape win on patterns
/// nobody searches for would be a curiosity. The second block is the **width**
/// set: "the n-th byte from the end" needs ~2^n states, which is where a
/// `ncls`-sparse flag array stops fitting one cache line and where a table-area
/// claim has room to be wrong.
const slate = [_]Row{
    // ── the cross-engine set (mirrors the dominance regex slate) ─────────────
    .{ .pat = "func\\s+\\w+\\(" },
    .{ .pat = "return\\s+nil" },
    .{ .pat = "pgxpool\\.\\w+" },
    .{ .pat = "if\\s+err\\s*!=\\s*nil" },
    .{ .pat = "const\\s+\\w+\\s*=" },
    .{ .pat = "^package\\s+\\w+" },
    .{ .pat = "^func\\s" },
    .{ .pat = ";$", .fill = "abcdefghijklmnop", .why = "no ';'" },
    .{ .pat = "[0-9]{4}", .fill = "abcdefghijklmnop", .why = "no digits" },
    .{ .pat = "\\w{3,8}" },
    .{ .pat = "[a-f0-9]{2,}", .fill = "ghijklmnopqrstuv", .why = "no hex digit" },
    .{ .pat = "[0-9a-f]{8}-[0-9a-f]{4}", .fill = "0123456789abcdef", .why = "no '-'" },
    .{ .pat = "[a-z]+_[a-z]+_[a-z]+", .fill = "abcdefghijklmnop", .why = "no '_'" },
    .{ .pat = "[a-z]+[A-Z]\\w+", .fill = "abcdefghijklmnop", .why = "no uppercase" },
    .{ .pat = "\\w+\\.\\w+\\(" },
    .{ .pat = "return|continue|break" },
    .{ .pat = "func|struct|enum" },
    .{ .pat = "error|panic|fatal" },
    .{ .pat = "panic|0x", .fill = "abcdefghijklmno123456789", .why = "no 'p', no '0'" },
    // ── the width set: where table area and the flag array actually bite ─────
    .{ .pat = "[A-Z][a-z]+ [A-Z][a-z]+", .fill = "abcdefghijklmnop ", .why = "no uppercase" },
    .{ .pat = "\\d+\\.\\d+\\.\\d+\\.\\d+", .fill = "abcdefghij.", .why = "no digits" },
    .{ .pat = "a.*b.*c", .fill = "defghijklmnop", .why = "no 'a', 'b' or 'c'" },
    .{ .pat = "\\w+X", .fill = "abcdefghijklmnop", .why = "no 'X'" },
    .{ .pat = "(a|b)*a(a|b)(a|b)(a|b)(a|b)(a|b)", .fill = "cdefghijklmnop", .why = "no 'a' or 'b'" },
    .{ .pat = "(a|b)*a(a|b)(a|b)(a|b)(a|b)(a|b)(a|b)(a|b)(a|b)", .fill = "cdefghijklmnop", .why = "no 'a' or 'b'" },
    .{ .pat = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", .fill = "0123456789abcdef", .why = "no '-'" },
    // Wide AND live: a hex fill keeps all 32 counted states on the path, which is
    // the only combination that prices the recurrence at the automaton's width.
    .{ .pat = "[0-9a-f]{32}-", .fill = "0123456789abcdef", .why = "no '-'" },
};

/// A byte-faithful copy of `Dfa.docMatchScalar` — the shipped per-line doc walk
/// — with ONE line different: the match test is a load from the `ncls`-sparse
/// `is_match` array rather than a compare against the partition bound. That is
/// the whole A/B. It lives here rather than in the engine because it is the
/// *superseded* form, and nothing in production may link it by accident.
///
/// Scalar, and so is its counterpart: the shipped multi-lane `docMatchDense`
/// overlaps four independent dependent-load chains, which is precisely the
/// mechanism that would HIDE the second load this arm exists to price. One lane
/// measures the recurrence; four lanes measure the out-of-order window.
fn walkLoaded(d: anytype, doc: []const u8, im: []const bool) bool {
    const n = doc.len;
    var i: usize = 0;
    while (i < n) {
        if (doc[i] == '\n') {
            if (d.empty_match) return true;
            i += 1;
            continue;
        }
        var s = d.start;
        if (im[s]) return true;
        var prev = s;
        var hit_dead = false;
        while (i < n and doc[i] != '\n') {
            prev = s;
            s = d.trans_in[s + d.class[doc[i]]];
            i += 1;
            if (im[s]) return true;
            if (d.anchored and s == d.dead) {
                if (i < n and doc[i] != '\n') hit_dead = true;
                break;
            }
        }
        if (!hit_dead) {
            s = d.trans_fin[prev + d.class[doc[i - 1]]];
            if (im[s]) return true;
            if (i < n) i += 1;
        } else {
            i = std.mem.indexOfScalarPos(u8, doc, i, '\n') orelse n;
            if (i < n) i += 1;
        }
    }
    return false;
}

/// The same walk with the shipped match test: one unsigned compare, no load.
fn walkCompared(d: anytype, doc: []const u8) bool {
    const n = doc.len;
    const mhi = d.match_hi;
    var i: usize = 0;
    while (i < n) {
        if (doc[i] == '\n') {
            if (d.empty_match) return true;
            i += 1;
            continue;
        }
        var s = d.start;
        if (s < mhi) return true;
        var prev = s;
        var hit_dead = false;
        while (i < n and doc[i] != '\n') {
            prev = s;
            s = d.trans_in[s + d.class[doc[i]]];
            i += 1;
            if (s < mhi) return true;
            if (d.anchored and s == d.dead) {
                if (i < n and doc[i] != '\n') hit_dead = true;
                break;
            }
        }
        if (!hit_dead) {
            s = d.trans_fin[prev + d.class[doc[i - 1]]];
            if (s < mhi) return true;
            if (i < n) i += 1;
        } else {
            i = std.mem.indexOfScalarPos(u8, doc, i, '\n') orelse n;
            if (i < n) i += 1;
        }
    }
    return false;
}

/// How many DISTINCT states the walk actually enters on this document — the
/// column that makes the rest of the table readable. A pattern can determinize
/// to 512 states and still spend every byte in one of them, and a state that
/// never changes turns `im[s]` into a perfectly-predicted L1 hit that costs
/// almost nothing. Without this number a wide `dfa` column reads like evidence
/// of a wide traversal, which it is not. Not timed.
fn statesVisited(gpa: std.mem.Allocator, d: anytype, doc: []const u8) !u32 {
    const seen = try gpa.alloc(bool, d.nstates);
    defer gpa.free(seen);
    return visitedInto(d, doc, seen);
}

/// `statesVisited` writing which states into a caller-owned array, so a caller
/// that needs the SET rather than the count doesn't walk the document twice.
fn visitedInto(d: anytype, doc: []const u8, seen: []bool) u32 {
    @memset(seen, false);
    var count: u32 = 0;
    const note = struct {
        fn f(sn: []bool, c: *u32, ncls: u16, s: u32) void {
            const id = s / ncls;
            if (id >= sn.len or sn[id]) return;
            sn[id] = true;
            c.* += 1;
        }
    }.f;

    var i: usize = 0;
    while (i < doc.len) {
        if (doc[i] == '\n') {
            i += 1;
            continue;
        }
        var s = d.start;
        note(seen, &count, d.ncls, s);
        var prev = s;
        while (i < doc.len and doc[i] != '\n') {
            prev = s;
            s = d.trans_in[s + d.class[doc[i]]];
            i += 1;
            note(seen, &count, d.ncls, s);
        }
        note(seen, &count, d.ncls, d.trans_fin[prev + d.class[doc[i - 1]]]);
        if (i < doc.len) i += 1;
    }
    return count;
}

/// Rebuild the array the shipped automaton no longer carries: one bool per row
/// offset, live only in the `ncls`-aligned slots. Derived from the bound rather
/// than from a second determinization, which is what makes the two arms the same
/// machine rather than two machines that ought to agree.
fn sparseFlags(gpa: std.mem.Allocator, d: anytype) ![]bool {
    const im = try gpa.alloc(bool, @as(usize, d.nstates) * d.ncls);
    @memset(im, false);
    var id: u32 = 0;
    while (id < d.nstates) : (id += 1) im[@as(usize, id) * d.ncls] = id * d.ncls < d.match_hi;
    return im;
}

/// Fill a document from `row.fill`, newline-terminated every `line_len` bytes.
/// Deterministic per row, so a rerun on this machine reproduces the number.
fn document(gpa: std.mem.Allocator, fill: []const u8) ![]u8 {
    return documentOf(gpa, fill, doc_bytes);
}

/// `document` at a caller-chosen size. The timing arms want the full buffer; a
/// correctness sweep that mutates and re-scans thousands of times wants a small
/// one, and it must be the same *shape* (same alphabet, same line length) or it is
/// proving something about a different document.
fn documentOf(gpa: std.mem.Allocator, fill: []const u8, bytes: usize) ![]u8 {
    const doc = try gpa.alloc(u8, bytes);
    fillLines(doc, fill, line_len);
    return doc;
}

/// `documentOf`'s body, with the line length free. An interior skip's stride is
/// capped by the distance to the next `\n`, so line length is the one knob that
/// moves that stride without changing the automaton, the alphabet, or the
/// instruction mix — which is what makes a break-even measurement possible.
fn fillLines(doc: []u8, fill: []const u8, line: usize) void {
    var prng = std.Random.DefaultPrng.init(0xA07_0_9A7A);
    const rng = prng.random();
    for (doc, 0..) |*b, i| {
        b.* = if (i % line == line - 1) '\n' else fill[rng.uintLessThan(usize, fill.len)];
    }
}

/// Bytes of transition table the automaton actually holds: every row of every
/// live table, at the exact class stride. The number `regex-cli`'s
/// `memory_usage()` is comparable to, and the one a padded power-of-two stride
/// inflates.
fn tableBytes(d: anytype) usize {
    return (d.trans_in.len + d.trans_fin.len + d.trans_in_w.len) * @sizeOf(u32);
}

/// How many of the automaton's states accept. Derived from the partition bound,
/// which is the only place the automaton still records it.
fn accepting(d: anytype) u32 {
    var n: u32 = 0;
    var id: u32 = 0;
    while (id < d.nstates) : (id += 1) n += @intFromBool(id * d.ncls < d.match_hi);
    return n;
}

/// Determinize `re`'s lowered NFA again, min-of-N, and report the fastest run in
/// nanoseconds. `.unbudgeted` on purpose: a *shipped* compile may have declined
/// this pattern on cost and answered from the on-demand tier, and the cost of the
/// build it declined is exactly the number a cost claim is about. Every arm of
/// every trial is freed, so this measures discovery and not the allocator's
/// high-water mark.
fn buildNs(gpa: std.mem.Allocator, io: anytype, re: *const Regex) !?i128 {
    var best: i128 = std.math.maxInt(i128);
    for (0..build_trials) |_| {
        const sp = Span.open(io);
        const out = try determinize.build(gpa, re.states, re.start, re.anchored, re.unicode, .unbudgeted);
        const ns = sp.read(io).ns();
        switch (out) {
            .built => |d| d.deinit(),
            .declined => return null, // no automaton of this kind exists to time
        }
        best = @min(best, ns);
    }
    return best;
}

const Section = enum { shape, build, search, area, width, dwell, reduce, inner, sift, all };

/// One row of the literal-dispatch audit. `unit` is tiled deterministically into
/// the document, and it must not contain any of the pattern's literals — the
/// leading bytes appear as often as the unit puts them there, which is the whole
/// independent variable, while a completed literal never does. Match-freedom is
/// asserted against the engine rather than trusted, exactly as the other arms do.
const SiftRow = struct {
    pat: []const u8,
    unit: []const u8,
    note: []const u8,
};

/// A tile of real-shaped source text, so one document per pattern has the byte
/// statistics the corpus prior was built from. This is the row the verdict rests on:
/// the adversarial and absent documents bracket the extremes, but the product's job
/// is code, and a prior is entitled to be judged on the population it describes.
/// Contains none of the slate's literals, which is what keeps every row match-free.
const code_unit =
    \\const std = @import("std");
    \\pub fn resolve(self: *Item, n: usize) !void {
    \\    if (self.len <= n) return error.OutOfRange;
    \\    self.items[n] = try self.build(n + 1);
    \\}
    \\
;

/// The two axes the literal dispatcher could key on, crossed. Down the rows, the
/// NEEDLE COUNT walks the cascade's own boundaries (1 ⇒ memmem, ≤64 ⇒ Teddy,
/// beyond ⇒ sparse Aho). Across each count sit three documents: one where the
/// prefilter's anchor bytes are everywhere and it must reject constantly, one where
/// they are absent and it skips wholesale, and one of real code.
///
/// The pairing is the point. Rows sharing a pattern share every pattern-derived
/// number the engine could gate on — same needles, same anchors, same corpus-priced
/// stride, same `beatsDense` answer — so if their measured verdicts disagree, no
/// gate computed from the pattern can be right on both.
const sift_slate = [_]SiftRow{
    .{ .pat = "xylophone", .unit = "xy ", .note = "1 needle · anchors everywhere" },
    .{ .pat = "xylophone", .unit = "qw ", .note = "1 needle · anchors absent" },
    .{ .pat = "xylophone", .unit = code_unit, .note = "1 needle · real code" },
    .{ .pat = "foo|bar|baz|qux", .unit = "fbq ", .note = "4 needles · leads everywhere" },
    .{ .pat = "foo|bar|baz|qux", .unit = "mnp ", .note = "4 needles · leads absent" },
    .{ .pat = "foo|bar|baz|qux", .unit = code_unit, .note = "4 needles · real code" },
    .{ .pat = "alpha|bravo|charlie|delta|echo|foxtrot|golf|hotel", .unit = "abcdefgh ", .note = "8 needles · leads everywhere" },
    .{ .pat = "alpha|bravo|charlie|delta|echo|foxtrot|golf|hotel", .unit = "rstuvw ", .note = "8 needles · leads absent" },
    .{ .pat = "alpha|bravo|charlie|delta|echo|foxtrot|golf|hotel", .unit = code_unit, .note = "8 needles · real code" },
};

/// How much of a real automaton is skippable, and — the part that decides it —
/// how much of a real document is spent in the skippable part. This is C4's
/// premise, priced before C4 is built, in the order C2 and C3 taught: a table
/// property is not a cost, and the walk's occupancy is.
///
/// The engine already skips out of ONE dwell, the start state. C4's proposal is to
/// carry an exit set for every state that has a narrow one, so an interior `.*`
/// run skips too. Three columns say whether that is worth building:
///
///   * `skip` — states whose exit set is narrow enough to skip out of. A TABLE
///     property, and on its own the same mistake C2 made: 85× more area cost
///     nothing when the walk didn't touch it.
///   * `hot` — how many of those the document actually enters. A skippable state
///     nothing sits in is worth exactly zero.
///   * `elide%` — of every byte the walk reads, the share it reads while parked in
///     a skippable state on a byte that state does not exit on. Those are the
///     bytes a skip would delete. This is the ceiling on C4's whole payoff, and
///     the only column that can justify it.
///
/// `start?` is the control: where the start dwell is already armed, its share of
/// `elide%` is a win the engine has *already banked*, so C4's marginal value is
/// whatever is left over. A row that elides 90% through a start dwell it already
/// exploits is not evidence for C4.
/// The slate C4 has to be judged on, and it is NOT the search slate. Every `fill`
/// there is chosen to make its pattern unmatchable by excluding a byte the pattern
/// needs *first* — which parks the walk in the start state for the whole document
/// (`seen = 1`). That is the right control for C1, whose claim is about the match
/// test on every step, and exactly the wrong document for C4: a skip out of an
/// interior state cannot pay in a document that never enters one.
///
/// So these rows are built the other way round. Each fill contains the pattern's
/// opening byte and omits a LATER one, so the walk leaves start almost immediately,
/// lands in a `.*`-shaped state that self-loops on nearly everything, and sits
/// there to end of line without ever matching. If an interior dwell can pay
/// anywhere, it pays here — this is C4's best case, constructed on purpose.
const dwell_slate = [_]Row{
    .{ .pat = "a.*b", .fill = "acdefghij", .why = "has 'a', no 'b'" },
    .{ .pat = "a.*b.*c", .fill = "abdefghij", .why = "has 'a' and 'b', no 'c'" },
    .{ .pat = "foo.*bar", .fill = "fo defghij", .why = "can spell 'foo', never 'bar'" },
    .{ .pat = "\\{.*\\}", .fill = "{abcdefghij", .why = "opens a brace, never closes one" },
    .{ .pat = "\"[^\"]*;", .fill = "\"abcdefghij", .why = "opens a quote, no ';'" },
    .{ .pat = "<[^>]*>", .fill = "<abcdefghij", .why = "opens a tag, never closes it" },
    // No `/\*.*\*/` row: an alphabet that can spell the opening `/*` necessarily
    // holds both `*` and `/`, so a random fill eventually spells the closing `*/`
    // too and the document matches. Every row here needs its unmatchable byte to be
    // one the OPENING doesn't also need — the asymmetry is why `{`/`}`, `<`/`>`, and
    // `"`/`;` work and a symmetric delimiter cannot.
};

/// Rounds of mutation each timed row's verdict is proven under. 4000 over a 64 KiB
/// document lands inside every line many times over, which is what makes the
/// last-byte-of-line case reachable rather than hypothetical.
const mutation_rounds = 4000;
const mutation_doc_bytes = 64 << 10;
/// Longest run one mutation overwrites. A needle longer than the run can never be
/// spelled, and a row whose oracle therefore proves nothing fails rather than
/// reporting a time — which is the check that caught `foo.*bar`.
const max_mutation_run = 8;

/// The timing that settles C4. The census says an interior dwell holds ~97% of the
/// document's bytes and that the only thing refusing to skip it is one threshold;
/// this asks the question the census structurally cannot — **is skipping actually
/// faster than stepping at the stride an interior dwell can reach?**
///
/// **Three arms, because two of them answer different questions.** `step` is the
/// same scalar walk the `search` arm baselines on, and it differs from the skip arm
/// in exactly one respect, so `vs step` is *attributable* to the skip and to nothing
/// else. But the scalar walk is not what the engine runs: an unanchored document
/// scan goes through the multi-lane `docMatch`, whose overlapping load chains are
/// already far faster than one dependent chain. `vs ship` is therefore the number
/// that decides whether C4 ships, and it is the smaller of the two by construction.
/// Publishing only `vs step` would be quoting a speedup against a baseline the
/// product does not use.
///
/// All three run over the same buffer in the same process, interleaved round by
/// round and min-of-N.
///
/// Rows whose START dwell is already armed are timed and printed but kept out of the
/// geomean: `docMatch` already banks that skip for them, so their `vs step` is
/// measuring the start skip C4 never proposed.
fn runDwellCost(gpa: std.mem.Allocator, io: anytype, failed: *bool) !void {
    std.debug.print(
        \\
        \\── dwell cost: is skipping an interior dwell FASTER than stepping it? (C4's verdict) ──
        \\   {d} MiB match-free document × {d} sweeps, min of {d}, all three arms interleaved.
        \\   The bar is WAIVED, so every narrow-exit state is armed — C4 at its most generous.
        \\   step = the scalar walk, identical to the skip arm but for the skip ⇒ vs step is ATTRIBUTABLE
        \\   ship = what the engine actually runs (`docMatch`, multi-lane)      ⇒ vs ship is what DECIDES
        \\   hit = mutations that produced a MATCH while both arms agreed (0 ⇒ the oracle proved nothing)
        \\   stride = bytes one armed skip ACTUALLY elides here, against the bar's {d}-byte prediction
        \\{s: <30}{s: >7}{s: >5}{s: >5}{s: >6}{s: >8}{s: >8}{s: >8}{s: >8}{s: >9}{s: >9}
        \\
    , .{
        doc_bytes >> 20,                 sweeps,    trials,
        dwell_mod.min_profitable_stride, "pattern", "start?",
        "skip",                          "seen",    "hit",
        "stride",                        "step",    "ship",
        "skip",                          "vs step", "vs ship",
    });

    var ratio_log: f64 = 0;
    var oracle_log: f64 = 0;
    var priced: usize = 0;
    for (dwell_slate) |row| {
        const fill = row.fill.?;
        var re = Regex.compileOpts(gpa, row.pat, .{ .force_dfa = true }) catch |e| {
            std.debug.print("{s: <44}  compile failed: {s}\n", .{ row.pat, @errorName(e) });
            failed.* = true;
            continue;
        };
        defer re.deinit();
        const d = re.dfa orelse {
            std.debug.print("{s: <44}  no eager dfa\n", .{row.pat});
            continue;
        };

        const found = try gpa.alloc(dwell_mod.Skippable, d.nstates);
        defer gpa.free(found);
        const exits_of = try gpa.alloc(u32, d.nstates);
        defer gpa.free(exits_of);
        // Bar waived: C4 at its most generous, so a loss here is a loss at the
        // ceiling rather than a threshold that could be retuned into a win.
        const census = dwell_mod.survey(d, found, 0);
        const armed = found[0..@min(census.skippable, d.nstates)];
        indexExits(d, armed, exits_of);
        if (armed.len == 0) {
            std.debug.print("{s: <44}  no state has a narrow exit set — nothing to time\n", .{row.pat});
            continue;
        }

        // Correctness before cost, and on documents that MATCH — a skip validated
        // only against match-free input is validated against its easy case.
        const small = try documentOf(gpa, fill, mutation_doc_bytes);
        defer gpa.free(small);
        const agree = agreeUnderMutation(d, small, row.pat, armed, exits_of, mutation_rounds);
        if (agree.diverged != 0) {
            std.debug.print("{s: <44}  DIVERGED on {d}/{d} mutations — the skip is wrong, not slow\n", .{ row.pat, agree.diverged, mutation_rounds });
            failed.* = true;
            continue;
        }
        if (agree.matched == 0) {
            std.debug.print("{s: <44}  {d} mutations produced no match — the oracle proved nothing\n", .{ row.pat, mutation_rounds });
            failed.* = true;
            continue;
        }

        const doc = try document(gpa, fill);
        defer gpa.free(doc);
        const plain = walkCompared(d, doc);
        const skipped = walkDwelling(d, doc, armed, exits_of);
        // The shipped arm is a third verdict, not a second: if `docMatch` disagrees
        // with the scalar walk the row is unusable for any of the three ratios.
        if (plain != skipped or plain != d.docMatch(doc)) {
            std.debug.print("{s: <30}  DISAGREE: step={} skip={} ship={}\n", .{ row.pat, plain, skipped, d.docMatch(doc) });
            failed.* = true;
            continue;
        }
        if (plain) {
            std.debug.print("{s: <30}  document MATCHES ({s}) — timing would measure the hit position\n", .{ row.pat, row.why });
            failed.* = true;
            continue;
        }

        var best_step: i128 = std.math.maxInt(i128);
        var best_ship: i128 = std.math.maxInt(i128);
        var best_skip: i128 = std.math.maxInt(i128);
        for (0..trials) |_| {
            var sp = Span.open(io);
            for (0..sweeps) |_| std.mem.doNotOptimizeAway(walkCompared(d, doc));
            const t_step = sp.read(io).ns();
            sp = Span.open(io);
            for (0..sweeps) |_| std.mem.doNotOptimizeAway(d.docMatch(doc));
            const t_ship = sp.read(io).ns();
            sp = Span.open(io);
            for (0..sweeps) |_| std.mem.doNotOptimizeAway(walkDwelling(d, doc, armed, exits_of));
            const t_skip = sp.read(io).ns();
            best_step = @min(best_step, t_step);
            best_ship = @min(best_ship, t_ship);
            best_skip = @min(best_skip, t_skip);
        }
        if (best_step <= 0 or best_ship <= 0 or best_skip <= 0) {
            std.debug.print("{s: <30}  timer resolution too coarse — raise `sweeps`\n", .{row.pat});
            failed.* = true;
            continue;
        }

        const scanned: f64 = @floatFromInt(doc.len * sweeps);
        const nsb_step = @as(f64, @floatFromInt(best_step)) / scanned;
        const nsb_ship = @as(f64, @floatFromInt(best_ship)) / scanned;
        const nsb_skip = @as(f64, @floatFromInt(best_skip)) / scanned;
        const banked = d.start_dwell != null;
        if (!banked) {
            ratio_log += @log(nsb_ship / nsb_skip); // the deciding ratio, not the flattering one
            // A free, perfect per-row oracle takes whichever arm is faster, so its
            // ratio is `max(1, ship/skip)`. Every adaptive scheme is bounded by this
            // and pays bookkeeping to approach it — so the geomean below is R2's ceiling.
            oracle_log += @log(@max(1.0, nsb_ship / nsb_skip));
            priced += 1;
        }
        std.debug.print("{s: <30}{s: >7}{d: >5}{d: >5}{d: >6}{d: >8.1}{d: >8.4}{d: >8.4}{d: >8.4}{d: >8.3}x{d: >8.3}x{s}\n", .{
            row.pat,                        if (banked) "armed" else "-", armed.len,
            try statesVisited(gpa, d, doc), agree.matched,                observedStride(d, doc, armed, exits_of),
            nsb_step,                       nsb_ship,                     nsb_skip,
            nsb_step / nsb_skip,            nsb_ship / nsb_skip,
            if (banked) "  (banked — out of geomean)" else "",
        });
    }
    if (priced > 0) std.debug.print(
        "\ngeomean `vs ship` over the {d} rows with NO banked start skip: {d:.3}x  (ns/byte)\n" ++
            "that is C4's marginal value over what the engine already does, at the waived bar.\n" ++
            "geomean of a FREE PERFECT per-row oracle (arm only where it pays): {d:.3}x\n" ++
            "that is the ceiling on R2 — no adaptive scheme can exceed a free correct choice.\n",
        .{ priced, @exp(ratio_log / @as(f64, @floatFromInt(priced))), @exp(oracle_log / @as(f64, @floatFromInt(priced))) },
    );
    try runStrideSweep(gpa, io);
    try runStrideProfile(gpa, io);
}

/// Line lengths the break-even sweep runs at. An interior skip must stop at `\n`, so
/// on `a.*b`-shaped rows — whose exit byte is absent from the fill — the realized
/// stride is exactly the mean distance to end of line, i.e. half of this. Sweeping it
/// walks the stride across the bar from well below to well above.
const stride_lines = [_]usize{ 8, 16, 24, 32, 48, 64, 96, 160, 320 };
const stride_doc_bytes = 2 << 20;
const stride_trials = 5;

/// **Where is break-even?** The rows above bracket it — a 39-byte stride wins and a
/// 25.7-byte stride loses — but bracketing is not a number, and the shipped bar is a
/// number. So this holds the automaton, the alphabet, and the instruction mix fixed
/// and moves only the line length, which is the sole thing that changes how far an
/// interior skip can run before `\n` stops it.
///
/// The pattern is `a.*b` over an alphabet with no `b`: its interior dwell exits on
/// `{b, \n}`, `b` never occurs, so the realized stride *is* the distance to end of
/// line and nothing else. That makes the x-axis exactly the quantity
/// `dwell.min_profitable_stride` predicts, and the crossing point directly comparable
/// to it.
fn runStrideSweep(gpa: std.mem.Allocator, io: anytype) !void {
    std.debug.print(
        \\
        \\── break-even: how far must an interior skip run to beat the shipped walk? ──
        \\   `a.*b` over an alphabet with no `b`, so the skip's stride IS the distance to `\n`.
        \\   Only the line length moves; automaton, alphabet, and instruction mix are fixed.
        \\   The crossing of `vs ship` through 1.000x is the real bar, to compare against {d}.
        \\{s: >6}{s: >8}{s: >9}{s: >9}{s: >9}
        \\
    , .{ dwell_mod.min_profitable_stride, "line", "stride", "ship", "skip", "vs ship" });

    var re = try Regex.compileOpts(gpa, "a.*b", .{ .force_dfa = true });
    defer re.deinit();
    const d = re.dfa.?;
    const found = try gpa.alloc(dwell_mod.Skippable, d.nstates);
    defer gpa.free(found);
    const exits_of = try gpa.alloc(u32, d.nstates);
    defer gpa.free(exits_of);
    const census = dwell_mod.survey(d, found, 0);
    const armed = found[0..@min(census.skippable, d.nstates)];
    indexExits(d, armed, exits_of);

    const doc = try gpa.alloc(u8, stride_doc_bytes);
    defer gpa.free(doc);
    for (stride_lines) |line| {
        fillLines(doc, "acdefghij", line);
        if (d.docMatch(doc) or walkDwelling(d, doc, armed, exits_of)) {
            std.debug.print("{d: >6}  document MATCHES — the fill leaked a 'b'\n", .{line});
            continue;
        }
        var best_ship: i128 = std.math.maxInt(i128);
        var best_skip: i128 = std.math.maxInt(i128);
        for (0..stride_trials) |_| {
            var sp = Span.open(io);
            std.mem.doNotOptimizeAway(d.docMatch(doc));
            const t_ship = sp.read(io).ns();
            sp = Span.open(io);
            std.mem.doNotOptimizeAway(walkDwelling(d, doc, armed, exits_of));
            const t_skip = sp.read(io).ns();
            best_ship = @min(best_ship, t_ship);
            best_skip = @min(best_skip, t_skip);
        }
        const scanned: f64 = @floatFromInt(doc.len);
        const nsb_ship = @as(f64, @floatFromInt(best_ship)) / scanned;
        const nsb_skip = @as(f64, @floatFromInt(best_skip)) / scanned;
        std.debug.print("{d: >6}{d: >8.1}{d: >9.4}{d: >9.4}{d: >8.3}x\n", .{
            line, observedStride(d, doc, armed, exits_of), nsb_ship, nsb_skip, nsb_ship / nsb_skip,
        });
    }
}

/// **Is there anything for a per-skip decision to decide?** (R2's premise)
///
/// C4 retired because a build-time prior cannot see a property of the document: two
/// states with the same exit set get the same prediction, and `a.*b` won while
/// `foo.*bar` lost. R2 asks whether a skip could measure its own realized stride and
/// disarm itself — trading a prior for a measurement.
///
/// The cheapest way to price that is to grant the measurement for free and perfectly.
/// A per-*row* free oracle is already priced beside the timings above. This asks the
/// strictly stronger question, because an adaptive skip decides per site, not per
/// pattern: of the bytes an armed skip elides, how many belong to skips that
/// individually cleared the bar? That share is the most a flawless per-site oracle
/// could remove from the walk, before any bookkeeping is charged against it.
///
/// A near-zero `payB%` on the losing rows would collapse the per-site oracle onto the
/// per-row one and make the free per-row geomean the whole ceiling. Where it is *not*
/// near zero, the per-site bound is still not reachable — a skip's stride is only known
/// after it runs — so this also times the strongest *implementable* form: a per-state
/// counter, granted its measurement for free and perfectly, that keeps only the dwell
/// states whose own realized stride clears the bar.
fn runStrideProfile(gpa: std.mem.Allocator, io: anytype) !void {
    std.debug.print(
        \\
        \\── adaptive ceiling: could a self-measuring skip beat a build-time prior? (R2's premise) ──
        \\   Each armed skip's realized stride, split by whether that skip alone cleared {d}B.
        \\   pay%  = share of armed skips that individually cleared the bar
        \\   payB% = share of the DOCUMENT those paying skips cover — an unreachable per-SITE bound
        \\   per-state strides expose whether the variance is BETWEEN states (learnable) or within one
        \\   kept  = states a free, perfect per-STATE counter would leave armed — R2's real mechanism
        \\   adapt = the walk with only those states armed. NOTE it is still the SCALAR walk, so it
        \\           carries the same ~2.2x handicap to `ship` that C4 did; `vs step` isolates the skip.
        \\{s: <22}{s: >8}{s: >8}{s: >8}{s: >18}{s: >6}{s: >8}{s: >8}{s: >9}{s: >9}
        \\
    , .{
        dwell_mod.min_profitable_stride, "pattern", "skips", "stride", "payB%",
        "per-state stride",              "kept",    "step",  "adapt",  "vs step",
        "vs ship",
    });

    var ratio_log: f64 = 0;
    var priced: usize = 0;
    for (dwell_slate) |row| {
        const fill = row.fill.?;
        var re = Regex.compileOpts(gpa, row.pat, .{ .force_dfa = true }) catch continue;
        defer re.deinit();
        const d = re.dfa orelse continue;

        const found = try gpa.alloc(dwell_mod.Skippable, d.nstates);
        defer gpa.free(found);
        const exits_of = try gpa.alloc(u32, d.nstates);
        defer gpa.free(exits_of);
        const census = dwell_mod.survey(d, found, 0);
        const armed = found[0..@min(census.skippable, d.nstates)];
        indexExits(d, armed, exits_of);
        if (armed.len == 0) continue;

        const doc = try document(gpa, fill);
        defer gpa.free(doc);
        const per_state = try gpa.alloc(Profile, armed.len);
        defer gpa.free(per_state);
        @memset(per_state, .{});
        const bar = dwell_mod.min_profitable_stride;
        const p = strideProfile(d, doc, armed, exits_of, bar, per_state);

        // Keep exactly the states whose OWN realized stride pays. This is the decision
        // a per-state counter converges on, handed over for free and without error.
        const kept = try gpa.alloc(dwell_mod.Skippable, armed.len);
        defer gpa.free(kept);
        var nkept: usize = 0;
        var strides: [64]u8 = undefined;
        var w: usize = 0;
        for (armed, per_state) |sk, ps| {
            // Truncation is marked rather than silent: a reader must be able to tell
            // "these are all the dwell states" from "these are the first few".
            if (std.fmt.bufPrint(strides[w..], "{d:.0} ", .{ps.mean()})) |s| w += s.len else |_| {
                if (w + 1 < strides.len) strides[w] = '+';
                w = @min(w + 1, strides.len);
            }
            if (ps.mean() >= @as(f64, @floatFromInt(bar))) {
                kept[nkept] = sk;
                nkept += 1;
            }
        }
        const adapt = kept[0..nkept];
        indexExits(d, adapt, exits_of);
        if (walkDwelling(d, doc, adapt, exits_of) != walkCompared(d, doc)) {
            std.debug.print("{s: <22}  DISAGREE under the kept subset\n", .{row.pat});
            continue;
        }

        var best_step: i128 = std.math.maxInt(i128);
        var best_ship: i128 = std.math.maxInt(i128);
        var best_adapt: i128 = std.math.maxInt(i128);
        for (0..trials) |_| {
            var sp = Span.open(io);
            for (0..sweeps) |_| std.mem.doNotOptimizeAway(walkCompared(d, doc));
            const t_step = sp.read(io).ns();
            sp = Span.open(io);
            for (0..sweeps) |_| std.mem.doNotOptimizeAway(d.docMatch(doc));
            const t_ship = sp.read(io).ns();
            sp = Span.open(io);
            for (0..sweeps) |_| std.mem.doNotOptimizeAway(walkDwelling(d, doc, adapt, exits_of));
            const t_adapt = sp.read(io).ns();
            best_step = @min(best_step, t_step);
            best_ship = @min(best_ship, t_ship);
            best_adapt = @min(best_adapt, t_adapt);
        }
        const scanned: f64 = @floatFromInt(doc.len * sweeps);
        const nsb_step = @as(f64, @floatFromInt(best_step)) / scanned;
        const nsb_ship = @as(f64, @floatFromInt(best_ship)) / scanned;
        const nsb_adapt = @as(f64, @floatFromInt(best_adapt)) / scanned;
        const banked = d.start_dwell != null;
        if (!banked) {
            ratio_log += @log(nsb_ship / nsb_adapt);
            priced += 1;
        }
        std.debug.print("{s: <22}{d: >8}{d: >8.1}{d: >7.1}%{s: >18}{d: >6}{d: >8.4}{d: >8.4}{d: >8.3}x{d: >8.3}x{s}\n", .{
            row.pat,              p.skips,                          p.mean(),
            p.coverage(doc.len),  strides[0..w],                    nkept,
            nsb_step,             nsb_adapt,                        nsb_step / nsb_adapt,
            nsb_ship / nsb_adapt, if (banked) "  (banked)" else "",
        });
    }
    if (priced > 0) std.debug.print(
        "\ngeomean `vs ship` for the FREE PERFECT per-state skip over {d} unbanked rows: {d:.3}x\n" ++
            "R2's mechanism at its ceiling, with zero bookkeeping charged and no learning error.\n",
        .{ priced, @exp(ratio_log / @as(f64, @floatFromInt(priced))) },
    );
}

fn runDwell(gpa: std.mem.Allocator, failed: *bool) !void {
    std.debug.print(
        \\
        \\── dwell: how much of the automaton is skippable, and is it where the walk is? (C4's premise) ──
        \\   skip = states skippable at the shipped bar · elide% = bytes such a skip would delete
        \\   start? = the start dwell the engine ALREADY skips, so that share is banked, not new
        \\   refusals: seal = nothing exits it · pors = exit set too wide · unpr = narrow but common
        \\   with the bar WAIVED: hot* = narrow-exit states the document enters · ceil% = its elide%
        \\   so ceil% is what the SHAPE allows and elide% is what the THRESHOLD allows.
        \\{s: <44}{s: >6}{s: >7}{s: >6}{s: >6}{s: >6}{s: >6}{s: >6}{s: >6}{s: >8}{s: >8}
        \\
    , .{ "pattern", "dfa", "start?", "skip", "seal", "pors", "unpr", "seen", "hot*", "elide%", "ceil%" });

    var eligible: usize = 0;
    var with_interior: usize = 0;
    for (slate ++ dwell_slate, 0..) |row, ri| {
        if (ri == slate.len) std.debug.print(
            "{s:-<44}{s:->6}{s:->7}{s:->6}{s:->6}{s:->6}{s:->6}{s:->6}{s:->6}{s:->8}{s:->8}\n" ++
                "  ↓ C4's best case: documents that ENTER an interior `.*` dwell and sit in it\n",
            .{ "", "", "", "", "", "", "", "", "", "", "" },
        );
        const fill = row.fill orelse continue; // needs a match-free document
        var re = Regex.compileOpts(gpa, row.pat, .{ .force_dfa = true }) catch continue;
        defer re.deinit();
        const d = re.dfa orelse continue;
        eligible += 1;

        const doc = try document(gpa, fill);
        defer gpa.free(doc);
        // The occupancy number is only about the recurrence if the scan never
        // returns early, so the unmatchability claim in `why` gets checked rather
        // than trusted — a fill that can spell the pattern would report a dwell
        // census over a fraction of the document and look like a small `elide%`.
        if (d.docMatch(doc)) {
            std.debug.print("{s: <44}  !! matched its own document ({s}) — the fill is wrong\n", .{ row.pat, row.why });
            failed.* = true;
            continue;
        }

        const found = try gpa.alloc(dwell_mod.Skippable, d.nstates);
        defer gpa.free(found);
        const seen = try gpa.alloc(bool, d.nstates);
        defer gpa.free(seen);
        const nseen = visitedInto(d, doc, seen);

        // At the shipped bar, and then with it waived. The pair is the whole point:
        // the first says what C4 would buy today, the second says whether what
        // stands between C4 and a win is the automaton's shape or one threshold.
        const census = dwell_mod.survey(d, found, dwell_mod.min_profitable_stride);
        const at_bar = try occupancy(gpa, d, doc, found[0..@min(census.skippable, d.nstates)], seen);
        const ceiling = dwell_mod.survey(d, found, 0);
        const waived = try occupancy(gpa, d, doc, found[0..@min(ceiling.skippable, d.nstates)], seen);

        if (d.start_dwell == null and at_bar.pct > 1.0) with_interior += 1;

        std.debug.print("{s: <44}{d: >6}{s: >7}{d: >6}{d: >6}{d: >6}{d: >6}{d: >6}{d: >6}{d: >7.1}%{d: >7.1}%\n", .{
            row.pat,             d.nstates,     if (d.start_dwell != null) "armed" else "-",
            census.skippable,    census.sealed, census.porous,
            census.unprofitable, nseen,         waived.hot,
            at_bar.pct,          waived.pct,
        });
    }
    std.debug.print(
        "\n{d} of {d} eligible rows elide >1% of their bytes through a dwell the engine does NOT already skip.\n",
        .{ with_interior, eligible },
    );
}

/// `exits_of[id]` when `id` is not a skippable dwell. A dense array of these beats
/// a map here: the lookup sits in the transition loop, where a hash would cost more
/// than the skip saves and a mispredicted branch would cost more still.
const no_dwell = std.math.maxInt(u32);

/// `walkCompared` with the skip C4 proposes: whenever the scan is parked in a state
/// with a narrow exit set, jump to the next byte that state exits on instead of
/// stepping the table. Same per-line `^`/`$`/`\n` handling, same `trans_fin`
/// last-byte resolution, same verdict — the only difference is the skip.
///
/// The soundness argument is the exit set's definition, and one consequence of it
/// is easy to get wrong. Every byte in `[i, j)` both kept `s` in itself *and*
/// cannot match under `trans_fin`, so eliding them cannot change the verdict. But
/// after a skip, `prev` — the state the last-byte resolution needs — is no longer
/// the state before the last *stepped* byte; it is `s`, which held unchanged across
/// the whole skipped run and therefore also held just before the run's final byte.
/// Missing that leaves `trans_fin` reading a stale row, which is precisely the bug
/// the mutation sweep below exists to catch.
fn walkDwelling(d: anytype, doc: []const u8, found: []const dwell_mod.Skippable, exits_of: []const u32) bool {
    const n = doc.len;
    const mhi = d.match_hi;
    var i: usize = 0;
    while (i < n) {
        if (doc[i] == '\n') {
            if (d.empty_match) return true;
            i += 1;
            continue;
        }
        var s = d.start;
        if (s < mhi) return true;
        var prev = s;
        var hit_dead = false;
        while (i < n and doc[i] != '\n') {
            const k = exits_of[s / d.ncls];
            if (k != no_dwell) {
                const j = found[k].exits.nextStart(doc, i) orelse n;
                if (j > i) {
                    prev = s; // `s` held across every skipped byte, the last one included
                    i = j;
                    if (i >= n or doc[i] == '\n') break; // the line ended inside the skip
                }
            }
            prev = s;
            s = d.trans_in[s + d.class[doc[i]]];
            i += 1;
            if (s < mhi) return true;
            if (d.anchored and s == d.dead) {
                if (i < n and doc[i] != '\n') hit_dead = true;
                break;
            }
        }
        if (!hit_dead) {
            s = d.trans_fin[prev + d.class[doc[i - 1]]];
            if (s < mhi) return true;
            if (i < n) i += 1;
        } else {
            i = std.mem.indexOfScalarPos(u8, doc, i, '\n') orelse n;
            if (i < n) i += 1;
        }
    }
    return false;
}

/// Do the two walks agree when the document is *perturbed into matching*? A
/// match-free document is a weak oracle for a skip: "returns false" agrees with
/// "returns false" for the wrong reasons, and the last-byte case above is only
/// reachable on a document where the skip runs to end of line.
///
/// So this overwrites a short run of bytes, re-scans with both arms, and restores —
/// thousands of times. `matched` is reported rather than assumed: a sweep that never
/// produced a match proved nothing, and the row fails rather than publishing a
/// timing, which is how `foo.*bar` was caught below.
///
/// **Why half the mutations splice in the pattern's own text.** A uniform random
/// byte breaks a one-byte tail easily — `a.*b` matches the moment any position
/// becomes `b`. Against a multi-byte tail it is hopeless: spelling `bar` by chance
/// is 1 in 2²⁴ per position, so 4000 uniform rounds over `foo.*bar` produce zero
/// matches and the oracle silently degrades to "false agrees with false". Copying a
/// random *substring of the pattern* over the document plants `bar` directly, and
/// stays generic — the pattern text is an input the harness already holds, not
/// per-row knowledge someone hand-tuned. The other half stays uniform, because
/// bytes the pattern never mentions are how the *non*-matching paths get exercised.
fn agreeUnderMutation(
    d: anytype,
    doc: []u8,
    pat: []const u8,
    found: []const dwell_mod.Skippable,
    exits_of: []const u32,
    rounds: usize,
) struct { matched: usize, diverged: usize } {
    var prng = std.Random.DefaultPrng.init(0x0DD_1_7E57);
    const rng = prng.random();
    var saved: [max_mutation_run]u8 = undefined;
    var matched: usize = 0;
    var diverged: usize = 0;
    for (0..rounds) |_| {
        const run = 1 + rng.uintLessThan(usize, @min(max_mutation_run, pat.len));
        const p = rng.uintLessThan(usize, doc.len - run);
        @memcpy(saved[0..run], doc[p..][0..run]);
        if (rng.boolean()) {
            const q = rng.uintLessThan(usize, pat.len - run + 1);
            @memcpy(doc[p..][0..run], pat[q..][0..run]);
        } else {
            for (doc[p..][0..run]) |*b| b.* = rng.int(u8);
        }
        const plain = walkCompared(d, doc);
        const skipped = walkDwelling(d, doc, found, exits_of);
        if (plain != skipped) diverged += 1;
        if (plain) matched += 1;
        @memcpy(doc[p..][0..run], saved[0..run]);
    }
    return .{ .matched = matched, .diverged = diverged };
}

/// The mean number of bytes one armed skip actually elides on THIS document — the
/// observed stride, against which `dwell.min_profitable_stride` is a prediction.
///
/// This is the column that turns C4's verdict from an inference into a measurement.
/// The corpus prior estimates a stride from the exit set's byte frequencies alone, so
/// two states with the *same* exit set get the same estimate no matter what document
/// they are run over. Measuring the realized stride beside the timing shows whether
/// a row won because its skip genuinely ran far, or lost because it paid vector-kernel
/// entry for a handful of bytes.
fn observedStride(d: anytype, doc: []const u8, found: []const dwell_mod.Skippable, exits_of: []const u32) f64 {
    return strideProfile(d, doc, found, exits_of, 0, null).mean();
}

/// The realized stride of every armed skip, split by whether that skip — on its own —
/// cleared `bar`. The mean alone cannot answer R2: one distribution with mean 4 is
/// "every skip is worthless", and another with the same mean is "97% elide nothing and
/// 3% elide 130 bytes", where a per-skip decision has something to decide.
///
/// `paying_elided` is the load-bearing field. A perfect per-skip oracle arms exactly
/// the skips that clear the bar and declines the rest for free, so the share of the
/// document those skips cover is the most time it could possibly remove — before any
/// bookkeeping is charged for it.
const Profile = struct {
    skips: usize = 0,
    elided: usize = 0,
    paying: usize = 0,
    paying_elided: usize = 0,

    fn bump(p: *Profile, stride: usize, bar: usize) void {
        p.skips += 1; // a skip is armed here even when it advances nothing
        p.elided += stride;
        if (stride >= bar) {
            p.paying += 1;
            p.paying_elided += stride;
        }
    }
    fn mean(p: Profile) f64 {
        return if (p.skips == 0) 0 else @as(f64, @floatFromInt(p.elided)) / @as(f64, @floatFromInt(p.skips));
    }
    fn payingShare(p: Profile) f64 {
        return if (p.skips == 0) 0 else 100 * @as(f64, @floatFromInt(p.paying)) / @as(f64, @floatFromInt(p.skips));
    }
    /// The ceiling a free per-skip oracle could remove, as a share of the document.
    fn coverage(p: Profile, doc_len: usize) f64 {
        return 100 * @as(f64, @floatFromInt(p.paying_elided)) / @as(f64, @floatFromInt(doc_len));
    }
    /// The same for every armed skip, paying or not — what C4 armed unconditionally.
    fn allCoverage(p: Profile, doc_len: usize) f64 {
        return 100 * @as(f64, @floatFromInt(p.elided)) / @as(f64, @floatFromInt(doc_len));
    }
};

/// `per_state`, when given, is indexed by the armed slot `k` rather than the state id,
/// so a caller can ask the question an implementable adaptive skip has to answer:
/// does the stride vary *between* dwell states, which a per-state counter can learn,
/// or *within* one, which it cannot?
fn strideProfile(
    d: anytype,
    doc: []const u8,
    found: []const dwell_mod.Skippable,
    exits_of: []const u32,
    bar: usize,
    per_state: ?[]Profile,
) Profile {
    var p: Profile = .{};
    var i: usize = 0;
    while (i < doc.len) {
        if (doc[i] == '\n') {
            i += 1;
            continue;
        }
        var s = d.start;
        while (i < doc.len and doc[i] != '\n') {
            const k = exits_of[s / d.ncls];
            if (k != no_dwell) {
                const j = found[k].exits.nextStart(doc, i) orelse doc.len;
                p.bump(j - i, bar);
                if (per_state) |ps| ps[k].bump(j - i, bar);
                i = j;
                if (i >= doc.len or doc[i] == '\n') break;
            }
            s = d.trans_in[s + d.class[doc[i]]];
            i += 1;
            if (s < d.match_hi) break;
        }
        i = std.mem.indexOfScalarPos(u8, doc, i, '\n') orelse doc.len;
        i += 1;
    }
    return p;
}

/// How much of this document a skip out of `found` would delete, and how many of
/// those states the walk actually enters.
fn occupancy(
    gpa: std.mem.Allocator,
    d: anytype,
    doc: []const u8,
    found: []const dwell_mod.Skippable,
    seen: []const bool,
) !struct { pct: f64, hot: u32 } {
    const exits_of = try gpa.alloc(u32, d.nstates);
    defer gpa.free(exits_of);
    indexExits(d, found, exits_of);
    var hot: u32 = 0;
    for (found) |sk| if (seen[sk.state / d.ncls]) {
        hot += 1;
    };
    const elided = elidableBytes(d, doc, found, exits_of);
    return .{
        .pct = 100.0 * @as(f64, @floatFromInt(elided)) / @as(f64, @floatFromInt(doc.len)),
        .hot = hot,
    };
}

/// State id → its index in `found`, or `no_dwell`. The lookup table both the
/// occupancy census and the skipping walk index by.
fn indexExits(d: anytype, found: []const dwell_mod.Skippable, exits_of: []u32) void {
    @memset(exits_of, no_dwell);
    for (found, 0..) |sk, k| exits_of[sk.state / d.ncls] = @intCast(k);
}

/// Bytes this document reads while parked in a skippable state, on a byte that
/// state does not exit on — i.e. the bytes an interior skip would delete. Walks
/// the same per-line shape as `walkCompared` so the denominator is the same
/// document the search arm times. Not timed; this is a census.
fn elidableBytes(d: anytype, doc: []const u8, found: []const dwell_mod.Skippable, exits_of: []const u32) usize {
    var elided: usize = 0;
    var i: usize = 0;
    while (i < doc.len) {
        if (doc[i] == '\n') {
            i += 1;
            continue;
        }
        var s = d.start;
        while (i < doc.len and doc[i] != '\n') {
            const k = exits_of[s / d.ncls];
            if (k != no_dwell and !found[k].exits.has(doc[i])) elided += 1;
            s = d.trans_in[s + d.class[doc[i]]];
            i += 1;
        }
        if (i < doc.len) i += 1;
    }
    return elided;
}

/// Patterns chosen to try to make the *NFA* wide, which is the only condition
/// under which C3 can pay. `subset.zig` keeps its closure scratch as
/// `ceil(nfa_states / 64)` u64 words and clears them with `@memset` per closure
/// step, so the waste it targets is `words` — not DFA states, not table area. At
/// `words = 1` the `@memset` C3 deletes is a single store and there is nothing to
/// win no matter how the closure behaves.
///
/// So this section asks the prior question: does anything reach this determinizer
/// with `words > 1`? Unicode classes, big bounded repeats, and wide alternations
/// are the three shapes that could, and a Unicode class looks like the interesting
/// one — its UTF-8 range trie is the ~10³-state NFA the `visits` comment cites.
///
/// It is not, and finding that out is half the value of the section: a `\p{…}`
/// class lowers to a **codepoint** automaton and is determinized by
/// `symbolic/determinize.zig`, then transcribed to bytes. It never reaches
/// `subset.zig`, so the widest NFA in the crate is not in C3's blast radius at
/// all. Those rows are marked `symbolic` rather than counted.
const width_slate = [_][]const u8{
    "\\w+",
    "\\p{L}+",
    "\\p{Greek}+",
    "\\p{Han}{3}",
    "(?i)\\p{L}\\p{N}",
    "[\\x{1000}-\\x{2000}]+",
    "\\d{50}",
    "\\w{100}",
    "[0-9a-f]{512}-",
    "(a|b|c|d|e|f|g|h){10}",
    "(?:foo|bar|baz|qux|quux|corge){8}",
};

/// How wide is the NFA that actually reaches `subset.zig`, and therefore how many
/// scratch words its per-step `@memset` clears? This is C3's premise, priced
/// before C3 is built — the same order C2 should have been asked in.
fn runWidth(gpa: std.mem.Allocator) !void {
    std.debug.print(
        \\
        \\── width: how wide is the NFA reaching the byte determinizer? (C3's premise) ──
        \\   `words` = ceil(nfa/64) = the u64s `subset.zig` @memsets per closure step.
        \\   At words=1 there is no waste to reclaim, whatever the closure does.
        \\{s: <36}{s: >7}{s: >7}{s: >7}{s: >9}
        \\
    , .{ "pattern", "nfa", "words", "cls", "dfa" });

    var widest: usize = 0;
    for (width_slate) |pat| {
        // `force_dfa` demands the BYTE determinizer. A pattern it refuses on those
        // terms but the plain compile accepts is a pattern that goes down the
        // symbolic (codepoint) path instead — which is the answer for that row,
        // not an error, so it must be distinguished from a real parse failure.
        var re = Regex.compileOpts(gpa, pat, .{ .force_dfa = true }) catch {
            // A `\p{…}` class needs `.unicode`, and under it the pattern lowers to a
            // CODEPOINT automaton that `symbolic/determinize.zig` owns — so the row
            // still reports its NFA width, marked `symbolic`, because that width is
            // outside C3's blast radius however large it turns out to be.
            var plain = Regex.compileOpts(gpa, pat, .{ .unicode = true, .force_dfa = true }) catch |e2| {
                std.debug.print("{s: <36}  will not compile at all: {s}\n", .{ pat, @errorName(e2) });
                continue;
            };
            defer plain.deinit();
            std.debug.print("{s: <36}{d: >7}{s: >7}{s: >7}{s: >9}\n", .{
                pat, plain.states.len, "-", "-", "symbolic",
            });
            continue;
        };
        defer re.deinit();
        const words = (re.states.len + 63) / 64;
        widest = @max(widest, words);
        if (re.dfa) |d| {
            std.debug.print("{s: <36}{d: >7}{d: >7}{d: >7}{d: >9}\n", .{ pat, re.states.len, words, d.ncls, d.nstates });
        } else {
            std.debug.print("{s: <36}{d: >7}{d: >7}{s: >7}{s: >9}\n", .{ pat, re.states.len, words, "-", "on-demand" });
        }
    }
    std.debug.print("\nwidest scratch: {d} u64 word(s)\n", .{widest});
}

/// The area sweep, in run lengths of `[0-9a-f]{k}-`. Two properties make this the
/// right family and `(a|b)*a(a|b){n}` the wrong one, even though the latter grows
/// area exponentially:
///
///   * **Every state is live.** The run counter advances on each hex byte, so a
///     hex document walks all ~k+2 states. The exponential family's match-free
///     document must exclude `a` and `b` entirely, which parks the walk in the
///     start state — `seen = 1` at every depth, measuring one row and calling it
///     an area sweep.
///   * **It still cannot match**, because the document holds no `-`. So the scan
///     never returns early and the number is about the recurrence.
///
/// Area therefore grows linearly in `k` and the document, alphabet, and per-byte
/// instruction count all hold still. This is the experiment that decides C2:
/// folding `trans_fin` into an EOI column halves total area, and is worth its
/// risk only if area is what binds.
/// Stops at 512 because the parser's `max_repeat` is 1000 — `{1024}` is
/// `BadPattern` by design, the guard against `a{999999}` lowering an NFA nobody
/// asked for. So 512 is not a chosen ceiling, it is the widest run length this
/// engine will parse, and the sweep covers everything below it.
const area_runs = [_]usize{ 4, 8, 16, 32, 64, 128, 256, 512 };

/// The sweep runs at two line lengths, and the pair is the actual experiment.
///
/// A hex run cannot outlast the line it sits in, so the line length is a ceiling
/// on how many states the walk can enter — `seen ≈ min(k, line)`. That gives a
/// controlled way to vary *touched breadth* while holding the table identical:
///
///   * `clipped` (48) — every row walks at most 47 states no matter how wide its
///     table is, so touched breadth is constant across the sweep while the table
///     grows 85×. Cost that tracks the table shows up here.
///   * `full` (640) — the walk uses `min(k, 639)` states, so breadth grows with
///     the table. Cost that tracks breadth shows up only here.
///
/// One number cannot separate those two; the pair can. This is why an 80-byte
/// line was the wrong single choice — it silently pinned the walk at 80 states
/// however wide the automaton got, which is the self-loop artifact in slow motion.
const area_lines = [_]usize{ 48, 640 };

/// Smaller document and fewer rounds than the search section. Eleven rows over an
/// 8 MiB document is a minute of wall clock for a question that is about the
/// SHAPE of the curve, not about its fourth decimal place.
const area_doc_bytes = 2 << 20;
const area_trials = 5;

/// Build `[0-9a-f]{k}-` into `buf`.
fn areaPattern(buf: []u8, k: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "[0-9a-f]{{{d}}}-", .{k});
}

/// Fill `doc` with hex bytes broken into lines of `line`. Hex only, so the pattern
/// can never match, and the line length caps how far the run counter can climb.
fn areaDoc(doc: []u8, line: usize) void {
    var prng = std.Random.DefaultPrng.init(0xA07_0_9A7A);
    const rng = prng.random();
    const hex = "0123456789abcdef";
    for (doc, 0..) |*b, i| {
        b.* = if (i % line == line - 1) '\n' else hex[rng.uintLessThan(usize, hex.len)];
    }
}

/// Does table area cost throughput? Same alphabet, same loop, same per-byte
/// instruction count; the table grows 85× across the sweep. Each row is priced
/// twice — once with the walk clipped to a constant breadth, once with it free to
/// use the whole table — because a single column cannot tell a table-size cost
/// from a touched-breadth cost, and C2 is only worth its risk if the cost is size.
fn runArea(gpa: std.mem.Allocator, io: anytype) !void {
    std.debug.print(
        \\
        \\── area: does table SIZE cost throughput, or only the part the walk touches? ──
        \\   `[0-9a-f]{{k}}-` over a hex document. `clipped` holds touched breadth
        \\   constant (48-byte lines) while the table grows; `full` lets breadth grow
        \\   with it. Size-driven cost appears in both columns, breadth-driven in one.
        \\{s: >5}{s: >7}{s: >5}{s: >9}{s: >9}{s: >18}{s: >18}
        \\{s: >5}{s: >7}{s: >5}{s: >9}{s: >9}{s: >18}{s: >18}
        \\
    , .{
        "k", "dfa", "cls", "hotB", "totalB", "clipped",        "full",
        "",  "",    "",    "",     "",       "seen   ns/byte", "seen   ns/byte",
    });

    const doc = try gpa.alloc(u8, area_doc_bytes);
    defer gpa.free(doc);

    for (area_runs) |k| {
        var buf: [32]u8 = undefined;
        const pat = try areaPattern(&buf, k);
        // `force_dfa` waives the VISIT budget, not the state ceiling. Past k≈256
        // the shipped compile declines this pattern on discovery cost and answers
        // from the on-demand tier — but the automaton it declined is exactly the
        // one whose area is under test, so the sweep must build it anyway.
        var re = Regex.compileOpts(gpa, pat, .{ .force_dfa = true }) catch |e| {
            std.debug.print("{d: >5}  compile failed: {s}\n", .{ k, @errorName(e) });
            continue;
        };
        defer re.deinit();
        const d = re.dfa orelse {
            std.debug.print("{d: >5}  no eager dfa (past max_states, which nothing waives)\n", .{k});
            continue;
        };

        var seen: [area_lines.len]u32 = undefined;
        var nsb: [area_lines.len]f64 = undefined;
        var bad = false;
        for (area_lines, 0..) |line, li| {
            areaDoc(doc, line);
            if (walkCompared(d, doc)) {
                std.debug.print("{d: >5}  document MATCHES — the filler leaked a '-'\n", .{k});
                bad = true;
                break;
            }
            seen[li] = try statesVisited(gpa, d, doc);

            var best: i128 = std.math.maxInt(i128);
            for (0..area_trials) |_| {
                const sp = Span.open(io);
                for (0..sweeps) |_| std.mem.doNotOptimizeAway(walkCompared(d, doc));
                best = @min(best, sp.read(io).ns());
            }
            nsb[li] = @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(doc.len * sweeps));
        }
        if (bad) continue;
        // `hotB` is the interior table alone — the only one an interior byte
        // reads. `totalB` adds `trans_fin`, which a per-line walk touches once
        // per line and which is exactly what C2 would delete.
        const hot = d.trans_in.len * @sizeOf(u32);
        std.debug.print("{d: >5}{d: >7}{d: >5}{d: >9}{d: >9}{d: >8}{d: >10.4}{d: >8}{d: >10.4}\n", .{
            k, d.nstates, d.ncls, hot, tableBytes(d), seen[0], nsb[0], seen[1], nsb[1],
        });
    }
}

/// Write one whole line to fd 1, retrying `EINTR`. Any other short or failed
/// write is fatal: a silently truncated row would let `bar.py` join a pattern
/// against the wrong engine's numbers, which is worse than no row at all.
fn emit(line: []const u8) void {
    var off: usize = 0;
    while (off < line.len) {
        const rc = std.posix.system.write(1, line.ptr + off, line.len - off);
        if (rc <= 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            std.debug.print("stdout write failed\n", .{});
            std.process.exit(1);
        }
        off += @intCast(rc);
    }
}

fn emitRow(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    emit(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

/// Shape as TSV on **stdout**, so `bar.py` can join it against the rust-`regex`
/// clone's own numbers without parsing a human table's column widths. Everything
/// explanatory stays on stderr, which is why this is the one section that writes
/// to stdout at all.
fn runShape(gpa: std.mem.Allocator, io: anytype) !void {
    emit("pattern\tnfa\tcls\tdfa\taccept\ttable_bytes\tbuild_ns\tengine\n");
    for (slate) |row| {
        var re = Regex.compile(gpa, row.pat) catch |e| {
            std.debug.print("{s: <52}  compile failed: {s}\n", .{ row.pat, @errorName(e) });
            continue;
        };
        defer re.deinit();
        const ns = try buildNs(gpa, io, &re);
        // The shipped handle may hold no eager automaton (the ladder answered
        // another way), yet an unbudgeted determinization still has a shape to
        // report — so re-derive it rather than skipping the row. `which` says
        // which of the two the numbers describe.
        const which: []const u8 = if (re.dfa != null) "eager" else "forced";
        var owned: ?*gist.regex_dfa.Dfa = null;
        defer if (owned) |d| d.deinit();
        const d = re.dfa orelse blk: {
            switch (try determinize.build(gpa, re.states, re.start, re.anchored, re.unicode, .unbudgeted)) {
                .built => |b| {
                    owned = b;
                    break :blk b;
                },
                .declined => {
                    std.debug.print("{s: <52}  no automaton of this kind (declined unbudgeted)\n", .{row.pat});
                    continue;
                },
            }
        };
        emitRow("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\n", .{
            row.pat, re.states.len, d.ncls, d.nstates, accepting(d), tableBytes(d), ns orelse 0, which,
        });
    }
}

/// The search A/B: the shipped compare against the load it replaced, over the
/// rows that have a provably match-free document. Returns the geometric mean, or
/// null when nothing was priced.
fn runSearch(gpa: std.mem.Allocator, io: anytype, failed: *bool) !?f64 {
    std.debug.print(
        \\
        \\── search: the match test, both forms ── {d} MiB match-free document × {d} sweeps, min of {d} ──
        \\{s: <52}{s: >5}{s: >6}{s: >5}{s: >6}{s: >8}{s: >9}{s: >9}{s: >8}  {s}
        \\
    , .{
        doc_bytes >> 20, sweeps, trials,
        "pattern",       "cls",  "dfa",
        "acc",           "seen", "flagB",
        "load",          "cmp",  "speedup",
        "match-free",
    });

    var ratio_log: f64 = 0;
    var priced: usize = 0;

    for (slate) |row| {
        const fill = row.fill orelse continue; // shape-only row
        var re = Regex.compile(gpa, row.pat) catch |e| {
            std.debug.print("{s: <52}  compile failed: {s}\n", .{ row.pat, @errorName(e) });
            failed.* = true;
            continue;
        };
        defer re.deinit();
        const d = re.dfa orelse {
            // Not every pattern reaches the eager automaton — the powerset cap
            // may have refused it and the ladder answered another way. Say so; a
            // silently skipped row would read like a measurement.
            std.debug.print("{s: <52}  no eager dfa (powerset declined; a lower rung serves)\n", .{row.pat});
            continue;
        };
        if (d.word_ctx) {
            std.debug.print("{s: <52}  word-context dfa (its doc scan goes per-line)\n", .{row.pat});
            continue;
        }

        const doc = try document(gpa, fill);
        defer gpa.free(doc);
        const im = try sparseFlags(gpa, d);
        defer gpa.free(im);

        // Fail closed on the premise before publishing anything derived from it.
        const hit_cmp = walkCompared(d, doc);
        const hit_load = walkLoaded(d, doc, im);
        if (hit_cmp != hit_load) {
            std.debug.print("{s: <52}  DISAGREE: cmp={} load={}\n", .{ row.pat, hit_cmp, hit_load });
            failed.* = true;
            continue;
        }
        if (hit_cmp) {
            std.debug.print("{s: <52}  document MATCHES ({s}) — timing would measure the hit position\n", .{ row.pat, row.why });
            failed.* = true;
            continue;
        }

        const seen = try statesVisited(gpa, d, doc);

        var best_load: i128 = std.math.maxInt(i128);
        var best_cmp: i128 = std.math.maxInt(i128);
        for (0..trials) |_| {
            // Interleaved: a baseline measured in a different round is a
            // measurement of that round's machine load, not of the baseline.
            var sp = Span.open(io);
            for (0..sweeps) |_| std.mem.doNotOptimizeAway(walkLoaded(d, doc, im));
            const t_load = sp.read(io).ns();
            sp = Span.open(io);
            for (0..sweeps) |_| std.mem.doNotOptimizeAway(walkCompared(d, doc));
            const t_cmp = sp.read(io).ns();
            best_load = @min(best_load, t_load);
            best_cmp = @min(best_cmp, t_cmp);
        }
        if (best_cmp <= 0 or best_load <= 0) {
            std.debug.print("{s: <52}  timer resolution too coarse — raise `sweeps`\n", .{row.pat});
            failed.* = true;
            continue;
        }

        const scanned: f64 = @floatFromInt(doc.len * sweeps);
        const nsb_load = @as(f64, @floatFromInt(best_load)) / scanned;
        const nsb_cmp = @as(f64, @floatFromInt(best_cmp)) / scanned;
        const speedup = nsb_load / nsb_cmp;
        ratio_log += @log(speedup);
        priced += 1;
        std.debug.print("{s: <52}{d: >5}{d: >6}{d: >5}{d: >6}{d: >8}{d: >9.4}{d: >9.4}{d: >7.3}x  {s}\n", .{
            row.pat, d.ncls,  d.nstates, accepting(d),
            seen,    im.len,  nsb_load,  nsb_cmp,
            speedup, row.why,
        });
    }
    if (priced == 0) return null;
    return @exp(ratio_log / @as(f64, @floatFromInt(priced)));
}

/// Determinization time on its own, as a human table. The same numbers `shape`
/// emits in its `build_ns` column — this section exists so the split is readable
/// without a spreadsheet, and so `visits` sits next to the milliseconds it buys.
fn runBuild(gpa: std.mem.Allocator, io: anytype) !void {
    std.debug.print(
        \\
        \\── build: determinization alone, over the shipped NFA, min of {d} ──
        \\   `wds` = ceil(nfa/64), the u64s `subset.zig` @memsets per closure step.
        \\   Read `ns/step`, not `ns/state`: one state costs `cls` closure steps, so
        \\   `ns/state` conflates alphabet width with closure cost. `ns/step` is the
        \\   unit `wds` actually scales, and therefore the unit C3 would move.
        \\   `vis/step` is mean closure WIDTH — how many NFA states a step really
        \\   touched. C3 only pays where `vis/step` is small AND `wds` is large; where
        \\   `vis/step` approaches `nfa`, clearing scratch in bulk is already correct.
        \\{s: <52}{s: >6}{s: >5}{s: >6}{s: >7}{s: >10}{s: >9}{s: >9}{s: >9}  {s}
        \\
    , .{
        build_trials, "pattern",  "nfa",
        "wds",        "cls",      "dfa",
        "build_us",   "ns/state", "ns/step",
        "vis/step",   "tier",
    });
    for (slate) |row| try buildRow(gpa, io, row.pat);
    // The width set carries the only rows where `wds` exceeds 1, which is the
    // only regime where C3's `@memset` is more than a single store. Priced in the
    // same table so the share it could reclaim is read against a real denominator
    // rather than estimated.
    std.debug.print("{s: <52}  ── wide-NFA rows (wds > 1: where C3 could pay) ──\n", .{""});
    for (width_slate) |pat| try buildRow(gpa, io, pat);
}

/// Time determinization for one pattern and print its row. Shared by the everyday
/// slate and the wide-NFA set so both are priced by identical machinery.
fn buildRow(gpa: std.mem.Allocator, io: anytype, pat: []const u8) !void {
    var re = Regex.compile(gpa, pat) catch return;
    defer re.deinit();
    const ns = (try buildNs(gpa, io, &re)) orelse {
        std.debug.print("{s: <52}  declined even unbudgeted\n", .{pat});
        return;
    };
    var owned: ?*gist.regex_dfa.Dfa = null;
    defer if (owned) |d| d.deinit();
    const d = re.dfa orelse blk: {
        switch (try determinize.build(gpa, re.states, re.start, re.anchored, re.unicode, .unbudgeted)) {
            .built => |b| {
                owned = b;
                break :blk b;
            },
            .declined => return,
        }
    };
    const us = @as(f64, @floatFromInt(ns)) / 1000.0;
    const per_state = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(d.nstates));
    const per_step = per_state / @as(f64, @floatFromInt(d.ncls));
    const steps = @as(f64, @floatFromInt(d.nstates)) * @as(f64, @floatFromInt(d.ncls));
    const vis_step = @as(f64, @floatFromInt(d.visits)) / steps;
    std.debug.print("{s: <52}{d: >6}{d: >5}{d: >6}{d: >7}{d: >10.1}{d: >9.0}{d: >9.0}{d: >9.1}  {s}\n", .{
        pat,       re.states.len,                             (re.states.len + 63) / 64, d.ncls,
        d.nstates, us,                                        per_state,                 per_step,
        vis_step,  if (re.dfa != null) "eager" else "forced",
    });
}

/// A frozen automaton un-premultiplied back into the id-indexed mutable form a
/// reduction operates on.
///
/// `reduce` runs BEFORE `freeze` in production, so pricing it against a shipped
/// `Dfa` means undoing the one step that came after: premultiplication is
/// `id * ncls`, monotone and exactly invertible, and the match partition is
/// recovered from the bound the way `sparseFlags` recovers it. Match-first
/// renumbering is an isomorphism, so reducing the renumbered automaton finds the
/// same quotient — a permutation of the states cannot change which of them a
/// suffix separates.
///
/// This is what makes the row a measurement of the shipped table rather than of a
/// second determinization built to be measured.
const Unfrozen = struct {
    gpa: std.mem.Allocator,
    cls: reduce.Classes,
    interior: std.ArrayList(u32),
    final: std.ArrayList(u32),
    is_match: []bool,
    map: []u32,
    nstates: u32,
    start: u32,
    dead: u32,
    empty_match: bool,
    anchored: bool,

    /// Null when the automaton is outside the reduction's envelope: a
    /// word-context table splits interiors on a second axis, and an unfilled slot
    /// means a lazily-built automaton whose missing rows this reasoning does not
    /// hold for. Both are declines rather than failures.
    fn of(gpa: std.mem.Allocator, d: anytype) !?Unfrozen {
        if (d.trans_in_w.len != 0) return null;
        const ncls: usize = d.ncls;
        const cells = @as(usize, d.nstates) * ncls;

        var u: Unfrozen = .{
            .gpa = gpa,
            .cls = .{ .class = d.class, .rep = undefined, .ncls = d.ncls },
            .interior = .empty,
            .final = .empty,
            .is_match = try gpa.alloc(bool, d.nstates),
            .map = try gpa.alloc(u32, d.nstates),
            .nstates = d.nstates,
            .start = d.start / d.ncls,
            .dead = if (d.dead == reduce.unexpanded) d.dead else d.dead / d.ncls,
            .empty_match = d.empty_match,
            .anchored = d.anchored,
        };
        errdefer u.deinit();
        for (0..256) |b| u.cls.rep[u.cls.class[b]] = @intCast(b);
        try u.interior.ensureTotalCapacityPrecise(gpa, cells);
        try u.final.ensureTotalCapacityPrecise(gpa, cells);
        for (d.trans_in[0..cells], d.trans_fin[0..cells]) |i, f| {
            if (i == reduce.unexpanded or f == reduce.unexpanded) return null;
            u.interior.appendAssumeCapacity(i / d.ncls);
            u.final.appendAssumeCapacity(f / d.ncls);
        }
        for (u.is_match, 0..) |*m, id| m.* = id * ncls < d.match_hi;
        return u;
    }

    fn deinit(u: *Unfrozen) void {
        u.interior.deinit(u.gpa);
        u.final.deinit(u.gpa);
        u.gpa.free(u.is_match);
        u.gpa.free(u.map);
    }

    fn tables(u: *Unfrozen) reduce.Tables {
        return .{ .interior = &u.interior, .final = &u.final, .is_match = u.is_match };
    }

    /// `walkCompared`'s decision, over id-indexed tables and an explicit match
    /// array instead of premultiplied offsets and a partition bound. Byte-for-byte
    /// the same control flow — that is the point: any verdict difference is the
    /// reduction's, not the walker's.
    fn decide(u: *const Unfrozen, doc: []const u8) bool {
        const ncls: usize = u.cls.ncls;
        const n = doc.len;
        var i: usize = 0;
        while (i < n) {
            if (doc[i] == '\n') {
                if (u.empty_match) return true;
                i += 1;
                continue;
            }
            var s = u.start;
            if (u.is_match[s]) return true;
            var prev = s;
            var hit_dead = false;
            while (i < n and doc[i] != '\n') {
                prev = s;
                s = u.interior.items[@as(usize, s) * ncls + u.cls.class[doc[i]]];
                i += 1;
                if (u.is_match[s]) return true;
                if (u.anchored and s == u.dead) {
                    if (i < n and doc[i] != '\n') hit_dead = true;
                    break;
                }
            }
            if (!hit_dead) {
                s = u.final.items[@as(usize, prev) * ncls + u.cls.class[doc[i - 1]]];
                if (u.is_match[s]) return true;
                if (i < n) i += 1;
            } else {
                i = std.mem.indexOfScalarPos(u8, doc, i, '\n') orelse n;
                if (i < n) i += 1;
            }
        }
        return false;
    }
};

/// A shortest string the shipped automaton accepts mid-line, or null when it has
/// none reachable through interior bytes. Breadth-first over the interior table
/// from the start state, one representative non-newline byte per class.
///
/// This is what lets the agreement check mean something on every row. Splicing
/// bytes of the pattern's *source text* only produces a match when the pattern is
/// mostly literal: `pgxpool\.\w+` spliced verbatim carries a backslash the pattern
/// does not accept, so such an oracle proves agreement about rejection and calls it
/// a day. The automaton, asked directly, always answers — and it answers about the
/// language rather than about the syntax that spelled it.
fn witness(gpa: std.mem.Allocator, d: anytype) !?[]u8 {
    const ncls: usize = d.ncls;
    // A newline would end the line the witness is spliced into, so a class whose
    // only member is `\n` is not a usable edge.
    const none: u16 = 0x100;
    var rep: [256]u16 = @splat(none);
    for (0..256) |b| {
        if (b == '\n') continue;
        const k = d.class[b];
        if (rep[k] == none) rep[k] = @intCast(b);
    }

    const prev = try gpa.alloc(u32, d.nstates);
    defer gpa.free(prev);
    const via = try gpa.alloc(u8, d.nstates);
    defer gpa.free(via);
    const seen = try gpa.alloc(bool, d.nstates);
    defer gpa.free(seen);
    @memset(seen, false);
    var q: std.ArrayList(u32) = .empty;
    defer q.deinit(gpa);

    const s0: u32 = d.start / d.ncls;
    if (d.start < d.match_hi) return try gpa.alloc(u8, 0); // accepts at every position
    seen[s0] = true;
    try q.append(gpa, s0);
    var head: usize = 0;
    while (head < q.items.len) : (head += 1) {
        const s = q.items[head];
        for (0..ncls) |k| {
            if (rep[k] == none) continue;
            const off = d.trans_in[@as(usize, s) * ncls + k];
            if (off == reduce.unexpanded) continue;
            const t = off / d.ncls;
            if (seen[t]) continue;
            seen[t] = true;
            prev[t] = s;
            via[t] = @intCast(rep[k]);
            if (off < d.match_hi) {
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(gpa);
                var cur = t;
                while (cur != s0) : (cur = prev[cur]) try out.append(gpa, via[cur]);
                std.mem.reverse(u8, out.items);
                return try out.toOwnedSlice(gpa);
            }
            try q.append(gpa, t);
        }
    }
    return null;
}

/// What an agreement check actually established. `reject_only` is not a pass and
/// not a failure: it means no witness could be spliced, so the two automata were
/// only ever asked about lines that do not match, and half the claim is unproven.
const Agreement = enum { proven, reject_only, diverged };

/// Does the reduced automaton decide every line the way the shipped one does?
///
/// A state-count drop is not evidence on its own — a reduction that merged two
/// states some suffix DOES separate would report a smaller number too, and report
/// it proudly. So both automata are run over the same documents and must agree on
/// every one: first the row's own match-free document (where both must reject),
/// then mutations that splice the automaton's own witness in, so agreement is
/// proven on lines that MATCH as well.
///
/// The witness is placed at three kinds of position in rotation — a random offset,
/// a line start, and flush against a line end — because a `^`-anchored pattern only
/// matches at the first and a `$`-anchored one only at the last. One placement
/// would silently test rejection for two thirds of the anchored slate.
fn reducedAgrees(gpa: std.mem.Allocator, d: anytype, u: *const Unfrozen, fill: []const u8) !Agreement {
    const doc = try documentOf(gpa, fill, mutation_doc_bytes);
    defer gpa.free(doc);
    if (walkCompared(d, doc) != u.decide(doc)) return .diverged;

    const wit = try witness(gpa, d);
    defer if (wit) |w| gpa.free(w);

    var prng = std.Random.DefaultPrng.init(0x5EED_C5);
    const rng = prng.random();
    var matched = false;
    for (0..mutation_rounds) |round| {
        var at = rng.uintLessThan(usize, doc.len);
        var run = 1 + rng.uintLessThan(usize, max_mutation_run);
        if (wit) |w| if (w.len != 0 and w.len < line_len) {
            run = w.len;
            const line = at - at % line_len;
            at = switch (round % 3) {
                0 => @min(at, doc.len - w.len),
                1 => line, // `^`
                else => line + line_len - 1 - w.len, // flush to the `\n`, for `$`
            };
        };
        const end = @min(doc.len, at + run);
        const saved = try gpa.dupe(u8, doc[at..end]);
        defer gpa.free(saved);
        if (wit) |w| if (w.len == run) {
            @memcpy(doc[at..end], w);
        };
        if (wit == null or wit.?.len != run) {
            for (doc[at..end]) |*b| b.* = rng.int(u8);
        }
        const want = walkCompared(d, doc);
        matched = matched or want;
        const got = u.decide(doc);
        @memcpy(doc[at..end], saved);
        if (want != got) return .diverged;
    }
    return if (matched) .proven else .reject_only;
}

/// C5's premise, priced: how much of the byte road's finished table is still
/// redundant, and what does removing it cost against the determinization that
/// produced it?
///
/// The symbolic road reduces in production because its product is *visibly*
/// redundant — it carries a decoder phase the pattern cannot observe. The byte
/// road's redundancy is not visible: subset construction interns on the NFA-state
/// SET, which quotients the UTF-8 trie for free and makes it easy to assume the
/// result is already minimal. It quotients by *reachability*, though, and two
/// distinct reachable state sets can still be separated by no suffix. Whether that
/// happens often enough to pay for a pass is not an argument, it is a number.
///
/// Read `states` and `cls` against `->`: those are the two dimensions' collapses,
/// separately attributable, and `bytes` is what the two together take off the
/// table the scan loop keeps resident. `%build` prices the pass against the
/// determinization that produced its input — the ratio rust-`regex-automata` puts
/// at "an order of magnitude" for Hopcroft, which is why theirs ships off.
///
/// Both numbers are needed and they answer different questions. `%build` says
/// whether we COULD leave it on; the `->` columns say whether it would buy
/// anything. A cheap pass that collapses nothing is still not worth running.
fn runReduce(gpa: std.mem.Allocator, io: anytype, failed: *bool) !void {
    std.debug.print(
        \\
        \\── reduce: what the BYTE road's finished table still contains, min of {d} ──
        \\   Every `->` is what declining `automata/reduce.zig` leaves on the table:
        \\   `states` is the row collapse Moore's refinement would find, `cls`/`bytes`
        \\   the column collapse the coincidence pass would, and `%both` / `%cols`
        \\   price each pass against the determinization that produced the table. The
        \\   ratio rust-`regex-automata` reports for Hopcroft is ~10x, which is why
        \\   theirs ships off too — so `%` says whether we COULD leave a pass on and
        \\   the `->` columns say whether it would buy anything.
        \\   Three slates, summarized apart, because they answer differently: the
        \\   everyday patterns, the widest ASCII determinizations, and the UTF-8 trie
        \\   automata the byte road builds whenever the symbolic path declines.
        \\   `scan` is the verdict the byte counts cannot give: the SAME walker over
        \\   {d} MiB, raw table versus fully reduced, since C2 already measured that
        \\   area alone is free. `matched` means there was no full-document walk to
        \\   time — the row's own document matches, so `decide` returns on a prefix.
        \\   `agree` is the gate: verdicts checked against the shipped automaton on
        \\   the row's document plus {d} mutations that splice the automaton's OWN
        \\   shortest accepted string in, at a random offset, a line start and a line
        \\   end in rotation — so `proven` means the two agreed about matching lines
        \\   and not just about rejection, and a merge some suffix actually separates
        \\   fails the row instead of quietly shrinking it.
        \\{s: <44}{s: >11}{s: >10}{s: >15}{s: >9}{s: >7}{s: >7}{s: >8}  {s}
        \\
    , .{
        build_trials, area_doc_bytes >> 20, mutation_rounds,
        "pattern",    "states",             "cls",
        "bytes",      "build_us",           "%both",
        "%cols",      "scan",               "agree",
    });

    var ascii: Tally = .{};
    for (slate) |row| try reduceRow(gpa, io, row.pat, row.fill, .ascii, &ascii, failed);
    // The wide-NFA set, where a determinization has the most room to keep states no
    // suffix separates — and, it turns out, where the class builder has the most
    // room to refine on sets that the finished table routes identically. If either
    // dimension carries slack anywhere in an ASCII program, it carries it here.
    std.debug.print("{s: <44}  ── wide-NFA rows (the widest determinizations we build) ──\n", .{""});
    for (width_slate) |pat| try reduceRow(gpa, io, pat, null, .ascii, &ascii, failed);

    // And the population the two above cannot speak for. A UTF-8 range trie is not a
    // wider version of an ASCII program; it is a decoder, and a decoder's states are
    // indistinguishable by construction wherever two scalar ranges resume the same
    // continuation. Whether that is worth a pass is a different question from
    // whether `func\s+\w+\(` is, and it has to be asked separately or the answer to
    // the common case buries it.
    std.debug.print("{s: <44}  ── UTF-8 trie rows (Unicode forced onto the byte road) ──\n", .{""});
    var trie: Tally = .{};
    for (trie_slate) |row| try reduceRow(gpa, io, row.pat, row.fill, .trie, &trie, failed);

    summarize("ascii", ascii);
    summarize("trie ", trie);
}

/// One slate's verdict. Both dimensions, both as a hit rate and as a price, because
/// either alone has been misleading here: a pass that fires on 1 row in 32 for 2% of
/// a build and a pass that fires on 3 in 5 for 8% are the same two numbers arranged
/// into opposite decisions.
fn summarize(name: []const u8, t: Tally) void {
    if (t.priced == 0) return;
    const n: f64 = @floatFromInt(t.priced);
    std.debug.print(
        \\
        \\  {s}: rows collapse on {d}/{d} · the full pass costs a geomean {d:.1}% of determinization
        \\  {s}: cols collapse on {d}/{d} · the columns-only pass costs a geomean {d:.1}% of determinization
        \\  {s}: columns-only takes this slate's table from {d} to {d} bytes ({d:.2}x)
        \\
    , .{
        name,         t.rows_shrank,
        t.priced,     @exp(t.pct_log / n),
        name,         t.cols_shrank,
        t.priced,     @exp(t.cols_pct_log / n),
        name,         t.was_bytes,
        t.cols_bytes, @as(f64, @floatFromInt(t.was_bytes)) / @as(f64, @floatFromInt(t.cols_bytes)),
    });
}

/// Which lowering a reduce row is measuring.
///
/// Not a variant of the same question — a different POPULATION, and keeping them
/// apart is most of this section's result. `ascii` is a pattern whose classes come
/// from its own byte sets. `trie` forces a Unicode pattern down the BYTE road
/// (`symbolic = .off`), which is what production does whenever the symbolic path
/// declines a construct it cannot express exactly, and it is the only shape in this
/// engine that hands the powerset a UTF-8 range trie — hundreds of states that
/// exist to decode a scalar, most of them accepting the same suffixes.
const Lowering = enum { ascii, trie };

/// Unicode patterns measured on the byte road. The first three are the symbolic
/// path's own headline cases (`../../../src/kernel/regex/linear/symbolic/README.md`),
/// so the trie they build is the exact structure that lane exists to avoid; `é+X` is
/// the control — a two-node decoder with nothing to collapse, here to pin that a
/// pass which finds a quarter of `\w{3,8}` does not invent a merge on a pattern
/// that has none.
///
/// `\w{3,8}` is the one row in the engine whose ROWS collapse materially, so it is
/// the one row whose scan timing would decide whether row collapse buys anything —
/// and it is unmeasurable, which the `fill` records rather than hides. The pattern
/// accepts ANY three word bytes, so no alphabet containing a word byte can spell a
/// document it does not match: `ab-` draws two word bytes in three and spells `aab`
/// within the first line. Narrowing to a single word byte does not help either,
/// since `aaa` matches too. The row reports `matched` on purpose — a 1.0 MB table
/// touched for tens of bytes was never going to repay a 190 ms determinization by
/// being 729 KB, and a fill that faked a crossing would be timing a prefix.
const trie_slate = [_]struct { pat: []const u8, fill: ?[]const u8 = null }{
    .{ .pat = "\\w+X" },
    .{ .pat = "\\w{3,8}", .fill = "ab-" },
    .{ .pat = "\\p{L}+;" },
    .{ .pat = "\\p{Greek}+" },
    .{ .pat = "é+X" },
};

/// What `runReduce` accumulates across a slate. The two dimensions are tallied
/// apart because the measurement's whole finding is that they behave differently —
/// and each slate gets its own `Tally` for the same reason one dimension does.
const Tally = struct {
    pct_log: f64 = 0,
    cols_pct_log: f64 = 0,
    priced: usize = 0,
    rows_shrank: usize = 0,
    cols_shrank: usize = 0,
    was_bytes: usize = 0,
    cols_bytes: usize = 0,
};

/// Price the reduction for one pattern and print its row. Shared by the everyday
/// slate and the wide-NFA set so both are judged by identical machinery.
fn reduceRow(gpa: std.mem.Allocator, io: anytype, pat: []const u8, fill: ?[]const u8, low: Lowering, tally: *Tally, failed: *bool) !void {
    // A pattern that will not compile under this lowering has no row to print, but a
    // silent `return` is how five `\p{…}` rows disappeared from this section for as
    // long as it existed: they were compiled without `unicode`, built nothing, and
    // left a slate that looked complete. Say so instead.
    var re = (switch (low) {
        .ascii => Regex.compileOpts(gpa, pat, .{ .force_dfa = true }),
        // `symbolic = .off` is the point: what the BYTE road does with a trie.
        .trie => Regex.compileOpts(gpa, pat, .{ .force_dfa = true, .unicode = true, .symbolic = .off }),
    }) catch {
        std.debug.print("{s: <40}  will not compile as {s}\n", .{ pat, @tagName(low) });
        return;
    };
    defer re.deinit();
    var owned: ?*gist.regex_dfa.Dfa = null;
    defer if (owned) |x| x.deinit();
    const d = re.dfa orelse blk: {
        switch (try determinize.build(gpa, re.states, re.start, re.anchored, re.unicode, .unbudgeted)) {
            .built => |b| {
                owned = b;
                break :blk b;
            },
            .declined => return,
        }
    };
    const build_ns = (try buildNs(gpa, io, &re)) orelse return;

    const both = (try priceReduce(gpa, io, d, .both)) orelse {
        std.debug.print("{s: <40}  outside the reduction's envelope (word context or an unfilled row)\n", .{pat});
        return;
    };
    const cols = (try priceReduce(gpa, io, d, .columns)).?;

    // One more un-premultiplication to hold a reduced automaton while its verdicts
    // are checked. `both` is the one worth checking: it is the strictly larger
    // change, so a merge that some suffix separates shows up here if it shows up at
    // all. The timing loops freed their own copies.
    var u = (try Unfrozen.of(gpa, d)).?;
    defer u.deinit();
    _ = try reduce.run(gpa, &u.cls, u.tables(), u.nstates, u.map, .both);
    u.start = u.map[u.start];
    if (u.dead != reduce.unexpanded) u.dead = u.map[u.dead];
    const agree = try reducedAgrees(gpa, d, &u, fill orelse "abcdefghijklmnopqrstuvwxyz");
    if (agree == .diverged) failed.* = true;
    const scan = try scanRatio(gpa, io, d, &u, fill orelse "abcdefghijklmnopqrstuvwxyz");

    const build_us = @as(f64, @floatFromInt(build_ns)) / 1000.0;
    const both_pct = 100.0 * both.us / build_us;
    const cols_pct = 100.0 * cols.us / build_us;
    tally.pct_log += @log(both_pct);
    tally.cols_pct_log += @log(cols_pct);
    tally.priced += 1;
    if (both.ext.nstates < d.nstates) tally.rows_shrank += 1;
    if (cols.ext.ncls < d.ncls) tally.cols_shrank += 1;
    tally.was_bytes += extentBytes(d.nstates, d.ncls);
    tally.cols_bytes += extentBytes(d.nstates, cols.ext.ncls);
    var scan_buf: [8]u8 = undefined;
    const scan_txt = if (scan) |r|
        std.fmt.bufPrint(&scan_buf, "{d:.2}x", .{r}) catch "?"
    else
        "matched"; // no full-document walk to time
    std.debug.print("{s: <44}{d: >4} ->{d: >4}{d: >5} ->{d: >3}{d: >7} ->{d: >6}{d: >9.1}{d: >7.1}{d: >7.1}{s: >8}  {s}\n", .{
        pat,                                   d.nstates,
        both.ext.nstates,                      d.ncls,
        cols.ext.ncls,                         extentBytes(d.nstates, d.ncls),
        extentBytes(d.nstates, cols.ext.ncls), build_us,
        both_pct,                              cols_pct,
        scan_txt,                              @tagName(agree),
    });
}

/// Transition-table bytes at a given extent: both live tables, at the exact class
/// stride. The number a column collapse actually removes.
fn extentBytes(nstates: u32, ncls: u16) usize {
    return @as(usize, nstates) * ncls * 2 * @sizeOf(u32);
}

/// How many times faster the reduced automaton scans — the number that decides
/// whether a collapse is worth a build's percent.
///
/// It cannot be inferred from `bytes`. C2 measured that table AREA is free at
/// constant touched breadth: 85x growth cost nothing, because the walk touches one
/// cell per byte either way. So a smaller table earns its pass only when the walk's
/// working set was the thing that shrank, and that is a property of the automaton's
/// shape rather than its size. Same walker over the same document, twice — once on
/// the raw automaton, once on the fully reduced one — so the table is all that
/// differs between the two timings.
///
/// Null when either walk MATCHES: `decide` returns on the first hit, so it would be
/// timing a prefix instead of a table.
fn scanRatio(gpa: std.mem.Allocator, io: anytype, d: anytype, red: *const Unfrozen, fill: []const u8) !?f64 {
    var raw = (try Unfrozen.of(gpa, d)) orelse return null;
    defer raw.deinit();
    const doc = try documentOf(gpa, fill, area_doc_bytes);
    defer gpa.free(doc);
    if (raw.decide(doc) or red.decide(doc)) return null;
    const before = scanNs(io, &raw, doc);
    const after = scanNs(io, red, doc);
    return @as(f64, @floatFromInt(before)) / @as(f64, @floatFromInt(after));
}

fn scanNs(io: anytype, u: *const Unfrozen, doc: []const u8) i128 {
    var best: i128 = std.math.maxInt(i128);
    for (0..scan_trials) |_| {
        const sp = Span.open(io);
        const hit = u.decide(doc);
        const ns = sp.read(io).ns();
        std.mem.doNotOptimizeAway(hit);
        best = @min(best, ns);
    }
    return best;
}

/// One plan's cost and outcome, min-of-N.
///
/// A fresh un-premultiplication per trial: `run` mutates in place, so a second
/// trial over the first's output would be timing a reduction of an already-reduced
/// automaton — which is the fixpoint, and cheap for the wrong reason.
fn priceReduce(gpa: std.mem.Allocator, io: anytype, d: anytype, plan: reduce.Plan) !?struct { us: f64, ext: reduce.Extent } {
    var best: i128 = std.math.maxInt(i128);
    var ext: ?reduce.Extent = null;
    for (0..build_trials) |_| {
        var u = (try Unfrozen.of(gpa, d)) orelse return null;
        defer u.deinit();
        const sp = Span.open(io);
        const e = try reduce.run(gpa, &u.cls, u.tables(), u.nstates, u.map, plan);
        const ns = sp.read(io).ns();
        if (e == null) return null;
        if (ns < best) {
            best = ns;
            ext = e;
        }
    }
    return .{ .us = @as(f64, @floatFromInt(best)) / 1000.0, .ext = ext.? };
}

/// C7's premise, priced before any of C7 is built — and the first question is not
/// "would it pay" but "what does the engine already do", because the answer turns out
/// to be most of it.
///
/// `ReverseInner` is one strategy doing two separable jobs. **Finding** a candidate
/// through a mandatory interior literal instead of a first-byte set is a prefilter,
/// and `ladder/verdict.zig` has shipped it: `lower.zig` compiles the required literal
/// into a `.candidate` `LiteralSet`, and that set is consulted BEFORE the class-run
/// kernel, the accelerator tier and the DFA — a whole-haystack miss rejects every
/// line at once. **Bounding** the confirmation to the literal's neighborhood is the
/// other job, and that one is not done: `presence` computes `findRaw(hay, 0) != null`
/// and drops the offset, so a candidate hit sends the automaton back to the start of
/// the haystack the literal scan just crossed.
///
/// So the columns are aimed at the residual rather than at the strategy:
///
///   * `literal` / `where` — the mandatory literal and whether it is INTERIOR, i.e.
///     extends past what the mandatory prefix proves. Interiority is what puts the
///     literal out of reach of a first-byte skip, which is C7's premise.
///   * `1st` / `f-str` — the first-byte set's size and its corpus-priced expected
///     stride: the skip the engine would use if no literal existed.
///   * `l-str` / `gain` — the literal's own stride from the SAME pricing function, so
///     `gain` is a ratio of two comparable numbers rather than of two conventions.
///   * `max` — the pattern's longest possible match, and the column that decides
///     whether the discarded offset is worth keeping. A match holding the literal at
///     `p` must start in `[p + lit.len - max, p]`, so a BOUNDED `max` licenses
///     confirming inside a window of about 2·max instead of walking the line; `inf`
///     means no window exists at any offset and the position buys nothing.
///   * `answers` — which ladder rung decides this pattern today. A row the literal
///     engine already answers `.exact` has no confirmation step to bound.
fn runInner(gpa: std.mem.Allocator, failed: *bool) !void {
    std.debug.print(
        \\
        \\── inner: the literal C7 would search for, and what the engine does with it ──
        \\   C7's FINDING half already ships: `lower.zig` compiles the mandatory
        \\   literal into a `.candidate` LiteralSet and `ladder/verdict.zig` consults
        \\   it ahead of every automaton, so a haystack without it is rejected whole.
        \\   Its BOUNDING half does not: `presence` throws the offset away. `where`
        \\   says whether a first-byte skip could have found the literal anyway, and
        \\   `max` says whether the thrown-away offset could bound anything — a
        \\   window needs a finite longest match, and `inf` is most of this engine.
        \\{s: <34}{s: >12}{s: >9}{s: >5}{s: >8}{s: >10}{s: >9}{s: >5}  {s}
        \\
    , .{
        "pattern", "literal", "where", "1st", "f-str", "l-str", "gain", "max", "answers",
    });

    var tally: Inner = .{};
    for (slate) |row| try innerRow(gpa, row.pat, &tally, failed);
    std.debug.print("{s: <34}  ── the dwell slate: the shapes with a real interior ──\n", .{""});
    for (dwell_slate) |row| try innerRow(gpa, row.pat, &tally, failed);

    if (tally.rows == 0) return;
    std.debug.print(
        \\
        \\  {d}/{d} rows prove a mandatory literal, and the engine already searches for
        \\  it. Of those, {d} are INTERIOR — out of reach of a first-byte skip, which is
        \\  C7's premise — and where both strides are comparable the literal skips
        \\  {d:.1}x further than the first-byte set (geomean over {d} unanchored rows).
        \\  {d}/{d} could bound a confirmation WINDOW: an interior literal AND a finite
        \\  longest match. A window is the cheap way to reuse the offset, and this is
        \\  why the field builds a reverse automaton instead — `inf` is the common case,
        \\  so there is no window to confirm inside.
        \\  {d}/{d} have NO start dwell, which is the same population read the other way:
        \\  a wide first-byte set is exactly what makes a literal interior, and it is
        \\  also what denies the existing skip. The two mechanisms cover disjoint rows.
        \\
    , .{
        tally.lit,      tally.rows,
        tally.interior, @exp(tally.gain_log / @as(f64, @floatFromInt(@max(tally.priced, 1)))),
        tally.priced,   tally.windowed,
        tally.rows,     tally.dwell_less,
        tally.rows,
    });
}

/// What the `inner` sweep is counting. `priced` is deliberately narrower than
/// `lit`: an anchored pattern seeds only at line start, so there is no first-byte
/// stride for a literal's stride to be a multiple OF, and folding those rows into
/// the geomean would be dividing by a baseline the engine never runs.
const Inner = struct {
    rows: usize = 0,
    lit: usize = 0,
    interior: usize = 0,
    windowed: usize = 0,
    priced: usize = 0,
    dwell_less: usize = 0,
    gain_log: f64 = 0,
};

/// One `inner` row. Everything here is static — a compile and two analyses, no
/// document and no timing — because a premise that fails statically should never
/// cost a benchmark.
fn innerRow(gpa: std.mem.Allocator, pat: []const u8, tally: *Inner, failed: *bool) !void {
    var re = Regex.compile(gpa, pat) catch {
        std.debug.print("{s: <34}  will not compile\n", .{pat});
        failed.* = true;
        return;
    };
    defer re.deinit();

    // The mandatory prefix, which is what decides interiority, is not retained on the
    // handle — only the strongest literal is. Re-derive it from the same analysis the
    // compile ran, over the same parse, so `where` cannot disagree with what the
    // engine believed.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parser = syntax.Parser{ .src = pat, .arena = arena };
    const tree = try parser.parseAlt();
    const lit = try analysis.literalInfo(arena, tree);
    var facts = try ast_mod.analyze(gpa, arena, tree, .{});
    defer facts.deinit();
    const max = facts.root().max_len;

    const best = re.required;
    const is_interior = best.len > lit.prefix.len;
    const where: []const u8 = if (best.len == 0) "none" else if (is_interior) "interior" else "prefix";

    // An anchored pattern never runs a first-byte skip — it seeds at line start — so
    // its `f-str` is a number the engine does not use, and a ratio against it would
    // be arithmetic rather than a comparison. Those rows print their strides and
    // abstain from `gain`.
    const priced = best.len > 0 and !re.anchored and re.first.count() > 0;
    const first_stride = re.first.economics.stride;
    const lit_stride = literalStride(best);
    const gain = @as(f64, @floatFromInt(lit_stride)) / @as(f64, @floatFromInt(@max(first_stride, 1)));

    // Whether the automaton already skips its own dead prefix. This is the control
    // the residual has to clear: an armed start dwell memchr's past the bytes before
    // a candidate at SIMD speed, so on those rows there is no byte-by-byte prefix
    // left for an offset to save.
    const dwelling = if (re.dfa) |d| d.start_dwell != null else if (re.lazy) |l| l.start_dwell != null else false;

    tally.rows += 1;
    if (best.len > 0) tally.lit += 1;
    if (is_interior) tally.interior += 1;
    if (is_interior and max != ast_mod.unbounded) tally.windowed += 1;
    if (!dwelling) tally.dwell_less += 1;
    if (priced) {
        tally.priced += 1;
        tally.gain_log += @log(@max(gain, 1e-9));
    }

    // A literal is QUOTED, because two of this slate's literals are a `-` and a
    // space: printed bare, the first is indistinguishable from the "no literal"
    // marker and the second from an empty column.
    var litbuf: [24]u8 = undefined;
    const littxt: []const u8 = if (best.len == 0) "none" else std.fmt.bufPrint(&litbuf, "'{s}'", .{best}) catch "'…'";
    var maxbuf: [12]u8 = undefined;
    const maxtxt: []const u8 = if (max == ast_mod.unbounded) "inf" else std.fmt.bufPrint(&maxbuf, "{d}", .{max}) catch "?";
    var gainbuf: [16]u8 = undefined;
    const gaintxt: []const u8 = if (!priced)
        "—"
    else
        std.fmt.bufPrint(&gainbuf, "{d:.1}x", .{gain}) catch "?";
    std.debug.print("{s: <34}{s: >12}{s: >9}{d: >5}{d: >8}{d: >10}{s: >9}{s: >5}  {s}\n", .{
        pat,              littxt,
        where,            re.first.count(),
        first_stride,     lit_stride,
        gaintxt,          maxtxt,
        answersWith(&re),
    });
}

/// The corpus-priced expected distance between occurrences of `lit`, through the
/// engine's OWN pricing rather than a second density table — the same `Prefilter`
/// the handle carries in `first`, so `f-str` and `l-str` are one function's output
/// twice.
///
/// **Two bytes, not all of them**, and the reason is the machine rather than the
/// mathematics. Multiplying every byte's probability is the textbook independence
/// model, and over a real corpus it is not merely imprecise but unusable: it prices
/// `return` at a 16 MB stride in a tree where `return` appears on most screens,
/// because code is the least independent text there is. The substring kernel does
/// not believe that model either — `scan/simd.zig` anchors its block filter on the
/// needle's TWO rarest bytes and verifies the rest — so pricing a literal by those
/// same two bytes is pricing it the way the machine that would execute the search
/// actually estimates it. Compounding further would be claiming selectivity no
/// kernel goes looking for.
fn literalStride(lit: []const u8) u32 {
    if (lit.len == 0) return 0;
    var rarest: u64 = 1; // largest stride ⇒ rarest byte
    var second: u64 = 1;
    for (lit) |b| {
        var one: syntax.ByteSet = .{};
        one.set(b);
        const s: u64 = @max(Prefilter.init(one).economics.stride, 1);
        if (s > rarest) {
            second = rarest;
            rarest = s;
        } else if (s > second) second = s;
    }
    const joint = rarest * if (lit.len >= 2) second else 1;
    return @intCast(@min(joint, std.math.maxInt(u32)));
}

/// Which rung of `ladder/verdict.zig` decides this pattern, named in that file's
/// own order, with `dwell` marking an automaton that already memchr's out of its own
/// start state. Not a timing — a row whose literal engine answers `.exact` has no
/// confirmation step for an offset to shorten, a row the class-run kernel owns never
/// reaches an automaton at all, and a row that dwells already skips its dead prefix.
fn answersWith(re: *const Regex) []const u8 {
    if (re.eol_empty) return "eol (no scan)";
    if (re.literal_scan) |*set| if (set.authority == .exact) return "literal .exact";
    if (re.classrun != null) return "class-run kernel";
    const nominated = re.literal_scan != null;
    if (re.dfa) |d| return if (d.start_dwell != null)
        (if (nominated) "candidate -> dfa (dwell)" else "dfa (dwell)")
    else if (nominated) "candidate -> dfa" else "dfa";
    if (re.lazy) |l| return if (l.start_dwell != null)
        (if (nominated) "candidate -> lazy (dwell)" else "lazy (dwell)")
    else if (nominated) "candidate -> lazy" else "lazy";
    return if (nominated) "candidate -> pike" else "pike";
}

/// Splice fractions the offset's worth is read at. A `docMatch` returns at its first
/// match, so where the match sits IS the independent variable: the prefix is the work
/// the discarded offset would have deleted, and one number at one position would be a
/// claim about that position rather than about the mechanism.
const leads = [_]u8{ 10, 50, 90 };
const lead_trials = 5;

/// What the discarded offset is worth, timed rather than argued.
///
/// The `inner` table says the offset exists and is thrown away. This says what
/// keeping it buys, on the one path where keeping it needs no new automaton:
/// `docMatch`. In the per-line model a line before the literal's first occurrence
/// cannot match — the literal is mandatory in every match and a match never crosses
/// `\n` — so `docMatch(doc)` and `docMatch(doc[k..])` agree for the line start `k`
/// holding that occurrence. The two arms are therefore the SAME automaton, one of
/// them handed a suffix, which is what makes this an A/B rather than two machines
/// that ought to agree:
///
///   * `ship` — `presence(doc)` then `Dfa.docMatch(doc)`, exactly `ladder/verdict.zig`.
///   * `seed` — `find(doc, 0)` (the same scan, its result kept) then
///     `Dfa.docMatch(doc[k..])`.
///
/// Every document is filled to be match-free and then has ONE witness spliced in, so
/// the answer is `true` in both arms and the timed work is the walk up to it. `lead`
/// is measured rather than assumed: a fill that can spell the literal itself puts the
/// first occurrence near byte zero whatever the splice says, and those rows are the
/// control — they should read 1.0x, and a mechanism that "wins" there is measuring
/// noise.
fn runLead(gpa: std.mem.Allocator, io: anytype, failed: *bool) !void {
    std.debug.print(
        \\
        \\── inner-lead: what keeping the offset is worth on the boolean doc scan ──
        \\   Same automaton twice, the second one handed the suffix beginning at the
        \\   line that holds the literal's first occurrence — sound because a line
        \\   without the mandatory literal cannot match. `lead%` is where that
        \\   occurrence actually is, measured, not where the witness was spliced: a
        \\   fill that can spell the literal has lead ~0 and is this arm's control.
        \\{s: <26}{s: >6}{s: >6}{s: >10}{s: >10}{s: >9}  {s}
        \\
    , .{ "pattern", "split", "lead%", "ship us", "seed us", "speedup", "agree" });

    var geo: f64 = 0;
    var counted: usize = 0;
    for (slate) |row| {
        const fill = row.fill orelse continue;
        var re = Regex.compile(gpa, row.pat) catch continue;
        defer re.deinit();
        const d = re.dfa orelse continue;
        const set = if (re.literal_scan) |s| s else continue;
        if (re.required.len == 0) continue;

        const wit = (try witness(gpa, d)) orelse continue;
        defer gpa.free(wit);
        if (wit.len == 0 or wit.len >= line_len) continue;

        for (leads) |pct| {
            const doc = try documentOf(gpa, fill, doc_bytes);
            defer gpa.free(doc);
            // Land the witness inside a line, never across its terminator, so the
            // spliced match is a real one-line match rather than two half-matches.
            const target = doc_bytes / 100 * @as(usize, pct);
            const at = target - (target % line_len) + 1;
            if (at + wit.len + 1 >= doc.len) continue;
            if (d.docMatch(doc)) {
                std.debug.print("{s: <26}  document matched BEFORE the splice — fill is not match-free\n", .{row.pat});
                failed.* = true;
                continue;
            }
            @memcpy(doc[at..][0..wit.len], wit);

            const found = switch (set.find(doc, 0)) {
                .exact => |p| p,
                .candidate => |p| p,
            } orelse {
                std.debug.print("{s: <26}  spliced witness holds no required literal\n", .{row.pat});
                failed.* = true;
                continue;
            };
            var ship_us: f64 = std.math.floatMax(f64);
            var seed_us: f64 = std.math.floatMax(f64);
            var ship_v = false;
            var seed_v = false;
            for (0..lead_trials) |_| {
                var sp = Span.open(io);
                const a = switch (set.presence(doc)) {
                    .exact => |m| m,
                    .candidate => |n| n and d.docMatch(doc),
                };
                ship_us = @min(ship_us, @as(f64, @floatFromInt(sp.read(io).ns())) / 1000.0);
                sp = Span.open(io);
                const b = switch (set.find(doc, 0)) {
                    .exact => |p| p != null,
                    .candidate => |p| p != null and d.docMatch(doc[lineHead(doc, p.?)..]),
                };
                seed_us = @min(seed_us, @as(f64, @floatFromInt(sp.read(io).ns())) / 1000.0);
                ship_v = a;
                seed_v = b;
            }
            const agree = ship_v == seed_v and ship_v;
            if (!agree) failed.* = true;
            const speedup = ship_us / @max(seed_us, 1e-9);
            geo += @log(speedup);
            counted += 1;
            std.debug.print("{s: <26}{d: >5}%{d: >5}%{d: >10.1}{d: >10.1}{d: >8.2}x  {s}\n", .{
                row.pat,                                pct,     found * 100 / doc.len,
                ship_us,                                seed_us, speedup,
                if (agree) "both true" else "DISAGREE",
            });
        }
    }
    if (counted == 0) return;
    std.debug.print(
        \\
        \\  geomean {d:.2}x over {d} (row x split) pairs. The offset is already computed
        \\  and already discarded, so whatever this reads is bought at zero cost — the
        \\  ONE number that has to clear a bar is the control rows' 1.0x.
        \\
    , .{ @exp(geo / @as(f64, @floatFromInt(counted))), counted });
    try leadAdverse(gpa, io, failed);
}

/// The adverse half of the lead arm: the same documents with NO witness spliced, so
/// every row answers `false` and the seam can save nothing. A `.candidate` miss is
/// the trivial case (one scan, both paths identical); the case worth timing is a
/// literal the fill DOES spell, which nominates a line and then fails to match — the
/// full ladder runs and the suffix is nearly the whole buffer. Nothing here may read
/// below 1.0x: that is what makes the win above free rather than traded.
fn leadAdverse(gpa: std.mem.Allocator, io: anytype, failed: *bool) !void {
    std.debug.print(
        \\
        \\── inner-lead adverse: no match anywhere, so the seam can only cost ──
        \\{s: <26}{s: >7}{s: >10}{s: >10}{s: >9}  {s}
        \\
    , .{ "pattern", "lead%", "ship us", "seed us", "ratio", "verdict" });

    var worst: f64 = std.math.floatMax(f64);
    var rows: usize = 0;
    for (slate) |row| {
        const fill = row.fill orelse continue;
        var re = Regex.compile(gpa, row.pat) catch continue;
        defer re.deinit();
        const d = re.dfa orelse continue;
        const set = if (re.literal_scan) |s| s else continue;
        if (re.required.len == 0) continue;

        const doc = try documentOf(gpa, fill, doc_bytes);
        defer gpa.free(doc);
        if (d.docMatch(doc)) continue; // not match-free; the lead arm already flagged it

        var ship_us: f64 = std.math.floatMax(f64);
        var seed_us: f64 = std.math.floatMax(f64);
        var ship_v = true;
        var seed_v = true;
        for (0..lead_trials) |_| {
            var sp = Span.open(io);
            const a = switch (set.presence(doc)) {
                .exact => |m| m,
                .candidate => |n| n and d.docMatch(doc),
            };
            ship_us = @min(ship_us, @as(f64, @floatFromInt(sp.read(io).ns())) / 1000.0);
            sp = Span.open(io);
            const b = switch (set.find(doc, 0)) {
                .exact => |p| p != null,
                .candidate => |p| p != null and d.docMatch(doc[lineHead(doc, p.?)..]),
            };
            seed_us = @min(seed_us, @as(f64, @floatFromInt(sp.read(io).ns())) / 1000.0);
            ship_v = a;
            seed_v = b;
        }
        // Both must reject. A `true` here would mean the suffix invented a match the
        // whole buffer does not hold, which is the one way this seam could be unsound.
        if (ship_v or seed_v) {
            std.debug.print("{s: <26}  MATCHED a match-free document (ship {}, seed {})\n", .{ row.pat, ship_v, seed_v });
            failed.* = true;
            continue;
        }
        const found = switch (set.find(doc, 0)) {
            .exact => |p| p,
            .candidate => |p| p,
        };
        const ratio = ship_us / @max(seed_us, 1e-9);
        worst = @min(worst, ratio);
        rows += 1;
        var lead_buf: [8]u8 = undefined;
        const lead = if (found) |p|
            std.fmt.bufPrint(&lead_buf, "{d}%", .{p * 100 / doc.len}) catch "?"
        else
            "absent";
        std.debug.print("{s: <26}{s: >7}{d: >10.1}{d: >10.1}{d: >8.2}x  {s}\n", .{
            row.pat,
            lead,
            ship_us,
            seed_us,
            ratio,
            if (ratio >= 0.95) "no cost" else "REGRESSED",
        });
    }
    if (rows == 0) return;
    std.debug.print("\n  worst {d:.2}x over {d} rows — the seam is free on the documents it cannot help.\n", .{ worst, rows });
}

/// Start of the line holding `p` — the seam a suffix may begin at without changing
/// what any line means.
fn lineHead(doc: []const u8, p: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, doc[0..p], '\n')) |nl| nl + 1 else 0;
}

/// A document that tiles `unit`, newline-terminated every `line_len` bytes. Tiled
/// rather than sampled because this arm needs match-freedom to be a PROPERTY OF THE
/// CONSTRUCTION: drawing bytes randomly from an alphabet containing a literal's
/// letters eventually spells the literal, and a row that quietly starts matching
/// measures the match position instead of the prefilter.
fn tiledDoc(gpa: std.mem.Allocator, unit: []const u8) ![]u8 {
    const doc = try gpa.alloc(u8, doc_bytes);
    for (doc, 0..) |*b, i| b.* = if (i % line_len == line_len - 1) '\n' else unit[i % unit.len];
    return doc;
}

/// The widest alternation still dispatched to Teddy, found by asking the engine
/// rather than by importing its constant or copying the number. Probing upward until
/// the chosen kernel's tag changes proves where the boundary IS; a literal `64` here
/// would only restate where it was believed to be, and would go on passing after the
/// tier was widened. Null if no flip appears below `limit`.
fn teddyCeiling(gpa: std.mem.Allocator, limit: usize) !?usize {
    var n: usize = 2;
    var last: usize = 0;
    while (n <= limit) : (n += 1) {
        const pat = try wideAlternation(gpa, n);
        defer gpa.free(pat);
        var re = Regex.compile(gpa, pat) catch continue;
        defer re.deinit();
        const set = re.literal_scan orelse continue;
        if (std.mem.eql(u8, @tagName(set.strategy), "teddy")) last = n else if (last != 0) return last;
    }
    return null;
}

/// An alternation of `n` distinct three-byte literals sharing ONE leading byte —
/// the adversarial shape for a lead-keyed prefilter, where every `z` in the document
/// is a candidate and almost none completes. Caller owns the returned pattern.
fn wideAlternation(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var pat: std.ArrayList(u8) = .empty;
    for (0..n) |i| {
        if (i != 0) try pat.append(gpa, '|');
        try pat.print(gpa, "z{c}{c}", .{ 'a' + @as(u8, @intCast(i / 26)), 'a' + @as(u8, @intCast(i % 26)) });
    }
    return pat.toOwnedSlice(gpa);
}

/// C9's premise, priced: `scan/literal_set.zig` picks its kernel by NEEDLE COUNT
/// alone (0/1/≤64/beyond), while the corpus-priced selectivity the engine already
/// computes — `prefilter.Economics`, whose `beatsDense` the dwell tier consults —
/// never reaches the decision. The claim is that selectivity is the right currency.
///
/// The falsifiable question is not whether the cascade is *principled* but whether
/// it is ever *wrong*: is there a row where arming the literal prefilter loses to
/// standing it down, and would the corpus prior have known? Both arms are the SAME
/// compiled program with one field nulled, so nothing but the prefilter differs, and
/// the stood-down arm must agree on the answer or the row is void.
fn runSift(gpa: std.mem.Allocator, io: anytype, failed: *bool) !void {
    std.debug.print(
        \\
        \\── sift: does the count-keyed literal cascade ever arm a prefilter that loses? (C9's premise) ──
        \\   armed    = shipped `docMatch` (literal_scan as the lowering built it)
        \\   stood    = the same program with `literal_scan` nulled — automaton only
        \\   stride   = the CORPUS-priced expected skip for the pattern's lead bytes,
        \\              and `pays` is what `Economics.beatsDense({d})` would answer.
        \\              A row where `armed` loses while `pays` says yes is a prior that
        \\              mispredicted; one where it loses while `pays` says no is a gate
        \\              C9 could actually build.
        \\{s: <52}{s: >8}{s: >7}{s: >6}{s: >9}{s: >9}{s: >9}
        \\
    , .{
        dwell_mod.min_profitable_stride, "pattern · document",
        "kernel",                        "strid",
        "pays",                          "armed",
        "stood",                         "armed/stood",
    });

    var wins: usize = 0;
    var losses: usize = 0;
    var worst: f64 = std.math.floatMax(f64);
    var all_log: f64 = 0;
    var real_log: f64 = 0;
    var real_rows: usize = 0;
    // The declared slate, then the two rows straddling the cascade's upper boundary.
    // Generated, because writing 65 alternatives by hand is how a boundary goes
    // untested — and located by probe, so the rows follow the tier if it moves.
    const ceiling = (try teddyCeiling(gpa, 128)) orelse {
        std.debug.print("  no Teddy→Aho boundary found below 128 needles — the cascade's shape changed\n", .{});
        failed.* = true;
        return;
    };
    const wide = try wideAlternation(gpa, ceiling);
    defer gpa.free(wide);
    const wider = try wideAlternation(gpa, ceiling + 1);
    defer gpa.free(wider);
    var ceil_note: [48]u8 = undefined;
    var over_note: [48]u8 = undefined;
    var rows: [sift_slate.len + 2]SiftRow = undefined;
    rows[0..sift_slate.len].* = sift_slate;
    rows[sift_slate.len] = .{
        .pat = wide,
        .unit = "z ",
        .note = std.fmt.bufPrint(&ceil_note, "{d} needles (the Teddy ceiling), one lead", .{ceiling}) catch "ceiling",
    };
    rows[sift_slate.len + 1] = .{
        .pat = wider,
        .unit = "z ",
        .note = std.fmt.bufPrint(&over_note, "{d} needles (one past it), one lead", .{ceiling + 1}) catch "over",
    };

    for (&rows) |row| {
        var re = Regex.compile(gpa, row.pat) catch |e| {
            std.debug.print("{s: <52}  would not compile: {s}\n", .{ row.note, @errorName(e) });
            failed.* = true;
            continue;
        };
        defer re.deinit();
        const set = re.literal_scan orelse {
            // Not a failure: a pattern the lowering finds no literal fact for has
            // no dispatch decision to audit, and saying so is the honest row.
            std.debug.print("{s: <52}{s: >8}\n", .{ row.note, "none" });
            continue;
        };
        const kernel = @tagName(set.strategy);
        const econ = re.first.economics;

        const doc = try tiledDoc(gpa, row.unit);
        defer gpa.free(doc);
        var sim = try Regex.Sim.init(gpa, &re);
        defer sim.deinit();
        if (re.docMatch(&sim, doc)) {
            std.debug.print("{s: <52}  document MATCHES — the row measures a hit position, not the sift\n", .{row.note});
            failed.* = true;
            continue;
        }

        var best_armed: i128 = std.math.maxInt(i128);
        var best_stood: i128 = std.math.maxInt(i128);
        for (0..sweeps) |_| {
            var sp = Span.open(io);
            for (0..sweeps) |_| std.mem.doNotOptimizeAway(re.docMatch(&sim, doc));
            best_armed = @min(best_armed, sp.read(io).ns());

            // The one line of difference. Restored before `deinit`, which owns the
            // set's memory — a stood-down handle must not also be a leaking one.
            re.literal_scan = null;
            if (re.docMatch(&sim, doc)) {
                std.debug.print("{s: <52}  DISAGREE with the prefilter stood down\n", .{row.note});
                failed.* = true;
            }
            sp = Span.open(io);
            for (0..sweeps) |_| std.mem.doNotOptimizeAway(re.docMatch(&sim, doc));
            best_stood = @min(best_stood, sp.read(io).ns());
            re.literal_scan = set;
        }

        const scanned: f64 = @floatFromInt(doc.len * sweeps);
        const nsb_armed = @as(f64, @floatFromInt(best_armed)) / scanned;
        const nsb_stood = @as(f64, @floatFromInt(best_stood)) / scanned;
        const ratio = nsb_stood / nsb_armed; // >1 ⇒ arming the prefilter paid
        if (ratio >= 1.0) wins += 1 else losses += 1;
        worst = @min(worst, ratio);
        all_log += @log(ratio);
        if (std.mem.eql(u8, row.unit, code_unit)) {
            real_log += @log(ratio);
            real_rows += 1;
        }
        std.debug.print("{s: <52}{s: >8}{d: >7}{s: >6}{d: >9.4}{d: >9.4}{d: >8.2}x\n", .{
            row.note,
            kernel,
            econ.stride,
            if (econ.beatsDense(dwell_mod.min_profitable_stride)) "yes" else "no",
            nsb_armed,
            nsb_stood,
            ratio,
        });
    }
    const total = wins + losses;
    if (total == 0) return;
    std.debug.print(
        "\n  arming paid on {d} of {d} rows; worst {d:.2}x, geomean {d:.2}x.\n" ++
            "  On real-code documents alone ({d} rows): geomean {d:.2}x.\n" ++
            "  Read the paired rows before the aggregate: a pattern whose two documents\n" ++
            "  disagree cannot be gated by anything derived from the pattern.\n",
        .{ wins, total, worst, @exp(all_log / @as(f64, @floatFromInt(total))), real_rows, @exp(real_log / @as(f64, @floatFromInt(@max(real_rows, 1)))) },
    );
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var section: Section = .all;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    if (it.next()) |a| section = std.meta.stringToEnum(Section, a) orelse {
        std.debug.print("usage: automata-rung [shape|build|search|area|width|dwell|reduce|inner|sift|all]\n", .{});
        std.process.exit(2);
    };

    std.debug.print(
        \\automata rung — the machine algebra, priced per function · abi v{d}
        \\machine: {s} · zig {s} · section: {s}
        \\
    , .{ gist.abi(), @tagName(builtin.target.cpu.arch), builtin.zig_version_string, @tagName(section) });

    var failed = false;
    if (section == .shape or section == .all) try runShape(gpa, io);
    if (section == .build or section == .all) try runBuild(gpa, io);
    if (section == .width or section == .all) try runWidth(gpa);
    if (section == .area or section == .all) try runArea(gpa, io);
    if (section == .dwell or section == .all) {
        try runDwell(gpa, &failed);
        try runDwellCost(gpa, io, &failed);
    }
    if (section == .reduce or section == .all) try runReduce(gpa, io, &failed);
    if (section == .inner or section == .all) {
        try runInner(gpa, &failed);
        try runLead(gpa, io, &failed);
    }
    if (section == .sift or section == .all) try runSift(gpa, io, &failed);
    if (section == .search or section == .all) {
        if (try runSearch(gpa, io, &failed)) |geo| {
            std.debug.print("\ngeomean speedup: {d:.3}x  (ns/byte, scalar per-line walk)\n", .{geo});
        }
    }
    if (failed) {
        std.debug.print("\nFAIL: a row disagreed, matched its own document, or would not compile\n", .{});
        std.process.exit(1);
    }
}

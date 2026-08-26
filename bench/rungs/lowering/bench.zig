//! Lowering — what compiling a pattern costs, attributed to the stage that
//! spends it.
//!
//! Every other rung under `bench/rungs/` prices a **scan**: bytes per second
//! against a rival binary or against the shipped ladder. This one prices the
//! part that runs before a single haystack byte is read, and it exists because
//! the compile side had no instrument at all. The engine's own numbers said
//! things like "`\w+X` costs 8.4 million NFA-state visits" — a real fact, and
//! useless for deciding what to change, because a visit count is not a
//! microsecond and four different stages were inside the same `compileOpts`
//! call. `(\w)(\w)(\w)(\w)` taking 963 µs was found by *guessing* which stage,
//! and that is the guess this rung retires.
//!
//! Four sections, four questions, deliberately not mixed:
//!
//!   1. **`stage`** — one row per pattern, the compile split into parse, Thompson
//!      lowering, the symbolic road's four phases, and the residue (analyses +
//!      byte powerset). The stages are re-run over the artifacts the shipped
//!      compile produced, min-of-N, so each is the shipped construction rather
//!      than a transcription of it. `resid` is total minus the parts, and it is
//!      the honest home of everything not named — read it as a bound on what is
//!      still unattributed, not as a stage.
//!   2. **`occurrence`** — the same codepoint class repeated k times. `lowerUtf8`
//!      weaves a UTF-8 trie per class OCCURRENCE, so the claim under test is that
//!      Thompson lowering is linear in k with a slope worth removing. The section
//!      prints the fitted µs/occurrence, which is the number a fix has to move.
//!   3. **`range`** — classes built to hold an exact, chosen number of codepoint
//!      ranges, so cost against range count is measured on a controlled axis
//!      instead of inferred from `\d` vs `\w` vs `\p{L}` (which differ in range
//!      count AND in shape). Fitted µs/range.
//!   4. **`gate`** — the pair space the symbolic road's admission gate reads:
//!      the free upper bound, the horizon's exact count, the product that
//!      actually got built, and which tier the pattern ended on. A row where
//!      `bound` is over the ceiling and `pairs` is under it is a pattern being
//!      declined by arithmetic rather than by size.
//!
//! **The rung is fail-closed on meaning, not only on speed.** Compile time is a
//! number you can always make smaller by building something else, so before any
//! stage is timed every eligible pattern is compiled down BOTH determinizations
//! and the two are held against each other — and against the Pike VM — over
//! haystacks laced with malformed UTF-8, where a product construction goes
//! wrong. A disagreement fails the run instead of publishing a µs.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");

const Regex = gist.regex.Regex;
const lower = gist.regex.lower;
const syn = gist.regex.syntax;
const compile_mod = gist.regex.compile;
const symbolic = gist.regex.symbolic;
const sym_program = symbolic.phase.program_mod;
const sym_determinize = symbolic.phase.determinize_mod;
const transcribe = symbolic.phase.transcribe_mod;
const decoder = symbolic.phase.decoder_mod;
const horizon = symbolic.phase.horizon_mod;
const powerset = gist.regex.determinize;
const Span = gist.assay.Span;

/// Interference from the ~10 coworker agents on this box only ever *slows* a
/// trial, so min-of-N across trials is the cleanest estimate of the true
/// per-core cost (the rationale every other rung here uses).
///
/// Compile stages are microseconds where a scan is seconds, so this is well
/// above the scan rungs' 9 — and affordable precisely because each trial is
/// microseconds.
const trials = 25;

/// Unicode is the whole subject: a `uclass` is what pays the trie tax, and
/// `(?-u)` patterns compile through a path this rung has nothing to say about.
/// `force_dfa` keeps a class-run-decidable pattern from skipping the
/// determinization that is being priced.
const opts: lower.Options = .{ .unicode = true, .force_dfa = true };
const byte_opts: lower.Options = .{ .unicode = true, .force_dfa = true, .symbolic = .off };

/// The slate. Three blocks, and the block a row is in says what it is here to
/// prove.
const slate = [_][]const u8{
    // ── the everyday set: what the dominance races actually search for ────────
    "func\\s+\\w+\\(",
    "pgxpool\\.\\w+",
    "\\w+\\.\\w+\\(",
    "const\\s+\\w+\\s*=",
    "^package\\s+\\w+",
    "\\w{3,8}",
    "\\w+X",
    "\\d+\\.\\d+\\.\\d+\\.\\d+",
    // ── the word-context set: the two patterns the horizon could not help ─────
    // `\b` puts the program on the byte road outright (the codepoint alphabet
    // cannot express a boundary), and there `reduce` declines as well. Both
    // facts are cost, not semantics, and both are visible here as a `tier` that
    // is not `symbolic`.
    "\\b\\w+@\\w+\\.\\w+\\b",
    "\\s*(\\S+)\\s*:\\s*(\\S+)",
    "\\bfunc\\b",
    "\\<\\w+\\>",
    // ── the wide-class set: where a per-occurrence trie weave dominates ───────
    "\\p{L}+",
    "\\p{Greek}\\w+",
    "(\\w)(\\w)",
    "(\\w)(\\w)(\\w)(\\w)",
    "[^\\x00-\\x7f]\\w+",
};

/// One compile, split. Every field is nanoseconds, min-of-`trials`, except the
/// counts.
const Split = struct {
    total: i128 = 0,
    parse: i128 = 0,
    thompson: i128 = 0,
    minterm: i128 = 0,
    codepoint: i128 = 0,
    cross: i128 = 0,
    /// The crossing's two sub-steps, carved out of `cross` rather than added to
    /// it: `cross − dec − hor` is the product walk plus the reduction and the
    /// freeze, which is the part with no cheaper form.
    dec: i128 = 0,
    hor: i128 = 0,
    nfa: usize = 0,
    /// The shipped automaton's own shape. `ncls` is the multiplier on every
    /// per-state cost in the crossing — the walk interns `2 × ncls` landings per
    /// product state — so a `walk` column read without it is a number without a
    /// denominator.
    ncls: u16 = 0,
    dfa_states: u32 = 0,
    stats: symbolic.Stats = .{},
    /// Which construction the shipped compile actually shipped.
    tier: []const u8 = "-",

    /// The byte powerset, priced on its own terms — because `resid` says how long
    /// the fallback took and nothing about whether it was worth taking. `bvisits`
    /// is the NFA-state meter its budget is spent against, and `verdict` is what
    /// it decided: an eager automaton, or a decline whose whole cost was
    /// speculative work thrown away. A row where the budget passed and the clock
    /// says a hundred milliseconds is a budget calibrated in the wrong unit.
    bpow: i128 = 0,
    bvisits: u64 = 0,
    bstates: u32 = 0,
    verdict: []const u8 = "-",

    /// Everything the named stages did not account for: the analyses, the byte
    /// powerset when the symbolic road declined, the handle's owned copies.
    /// Clamped at zero — the parts are separate min-of-N measurements, so on a
    /// pattern whose stages are all noise the sum can nudge past the total, and
    /// a negative residue would be reporting the timer rather than the compile.
    fn resid(s: Split) i128 {
        const parts = s.parse + s.thompson + s.minterm + s.codepoint + s.cross;
        return if (s.total > parts) s.total - parts else 0;
    }

    /// The product walk, the reduction and the freeze — the crossing minus the
    /// two sub-steps that have their own column. Clamped for the same reason
    /// `resid` is: three independent minima can cross on a cheap pattern.
    fn walk(s: Split) i128 {
        const known = s.dec + s.hor;
        return if (s.cross > known) s.cross - known else 0;
    }
};

fn us(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

/// Time the whole shipped compile, min-of-N. This is the number a user waits on
/// and the denominator every stage share is read against.
fn totalNs(gpa: std.mem.Allocator, io: std.Io, pat: []const u8) ?i128 {
    var best: i128 = std.math.maxInt(i128);
    for (0..trials) |_| {
        const sp = Span.open(io);
        var re = Regex.compileOpts(gpa, pat, opts) catch return null;
        const ns = sp.read(io).ns();
        re.deinit();
        best = @min(best, ns);
    }
    return best;
}

/// Time `parse` and `compileNode` over one arena, min-of-N.
///
/// Both are re-run rather than observed in place, and the arena is rebuilt each
/// trial: an arena that already holds the previous trial's AST hands back warm
/// pages, which would price the second parse and not the first. The Thompson
/// arm reuses ONE arena's AST across its trials on purpose — it is the lowering
/// under test, and re-parsing inside its timer would fold the parse back in.
fn frontNs(gpa: std.mem.Allocator, io: std.Io, pat: []const u8, out: *Split) !bool {
    var best_parse: i128 = std.math.maxInt(i128);
    for (0..trials) |_| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const sp = Span.open(io);
        _ = lower.parse(arena_state.allocator(), pat, opts) catch return false;
        best_parse = @min(best_parse, sp.read(io).ns());
    }
    out.parse = best_parse;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const ast = lower.parse(arena_state.allocator(), pat, opts) catch return false;

    var best_low: i128 = std.math.maxInt(i128);
    for (0..trials) |_| {
        var c = compile_mod.Compiler{ .gpa = gpa };
        defer c.loom.deinit(gpa);
        defer c.states.deinit(gpa);
        const sp = Span.open(io);
        const match_idx = try c.push(.match);
        _ = try c.compileNode(ast, match_idx);
        best_low = @min(best_low, sp.read(io).ns());
        out.nfa = c.states.items.len;
    }
    out.thompson = best_low;
    return true;
}

/// Time the symbolic road's three phases over the AST the shipped compile
/// lowers, min-of-N each. Leaves them at zero when the road declines this
/// pattern — the stage genuinely did not run, and reporting a number for it
/// would be inventing one.
///
/// Three and not four: the minterm partition is not a separate call to time, it
/// is what `program.lower` does on its way through (predicates intern as
/// instructions emit, and `finish()` solves the partition at the end). Splitting
/// it would mean re-implementing the lowering here, which is the one thing a
/// price rung may not do.
fn symbolicNs(gpa: std.mem.Allocator, io: std.Io, pat: []const u8, out: *Split) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const ast = lower.parse(arena_state.allocator(), pat, opts) catch return;
    if (!symbolic.eligible(ast)) return;

    const anchored = gist.regex.analysis.startsAnchored(ast);

    var best_prog: i128 = std.math.maxInt(i128);
    for (0..trials) |_| {
        const sp = Span.open(io);
        var p = sym_program.lower(gpa, ast) catch return;
        best_prog = @min(best_prog, sp.read(io).ns());
        p.deinit();
    }
    out.minterm = best_prog;

    var prog = sym_program.lower(gpa, ast) catch return;
    defer prog.deinit();

    var best_det: i128 = std.math.maxInt(i128);
    for (0..trials) |_| {
        const sp = Span.open(io);
        var aut = sym_determinize.build(gpa, &prog, anchored) catch return;
        best_det = @min(best_det, sp.read(io).ns());
        aut.deinit();
    }
    out.codepoint = best_det;

    var aut = sym_determinize.build(gpa, &prog, anchored) catch return;
    defer aut.deinit();
    out.stats.visits = aut.visits;

    var best_dec: i128 = std.math.maxInt(i128);
    for (0..trials) |_| {
        var pruned: u16 = 0;
        const sp = Span.open(io);
        var d = decoder.build(gpa, &prog.alpha, &aut, &pruned) catch return;
        best_dec = @min(best_dec, sp.read(io).ns());
        d.deinit();
    }
    out.dec = best_dec;

    var pruned: u16 = 0;
    var dec = decoder.build(gpa, &prog.alpha, &aut, &pruned) catch return;
    defer dec.deinit();

    var best_hor: i128 = std.math.maxInt(i128);
    for (0..trials) |_| {
        const sp = Span.open(io);
        var h = horizon.build(gpa, &dec, &aut) catch return;
        best_hor = @min(best_hor, sp.read(io).ns());
        h.deinit();
    }
    out.hor = best_hor;

    var best_cross: i128 = std.math.maxInt(i128);
    var declined = false;
    for (0..trials) |_| {
        var st: symbolic.Stats = .{};
        const sp = Span.open(io);
        const d = transcribe.transcribe(gpa, &aut, &prog.alpha, anchored, &st) catch {
            declined = true;
            // The gate's own numbers are the point of the `gate` section, and a
            // declining walk fills them before it refuses — so keep them.
            st.visits = aut.visits;
            out.stats = st;
            break;
        };
        best_cross = @min(best_cross, sp.read(io).ns());
        st.visits = aut.visits;
        out.stats = st;
        d.deinit();
    }
    if (!declined) out.cross = best_cross;
}

/// Price the byte powerset on the same program the shipped compile hands it, in
/// the same mode.
///
/// The mode matters more than anything else in this function. `lower.zig` spends
/// the `max_visits` budget only when the caller has NOT asked for a DFA
/// outright: `force_dfa` builds `.unbudgeted`, which is to say it builds the
/// automaton however long that takes. This rung sets `force_dfa` (it exists to
/// price a determinization, so it must not measure a pattern skipping one) —
/// therefore `bpow` is the unbudgeted build, which is what `resid` holds on a
/// `powerset` row, and reading a budget verdict there would be reading a
/// different compile than the one on the line.
///
/// So both are taken. `bpow`/`bvis` are the unbudgeted clock and the NFA-state
/// meter; `verdict` is what the SAME program does when the budget is in force,
/// i.e. what a caller who did not demand a DFA would get. A row reading
/// `too_costly` beside a large `bpow` is a pattern production sends to the Pike
/// VM and this rung deliberately does not.
fn byteNs(gpa: std.mem.Allocator, io: std.Io, pat: []const u8, out: *Split) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const ast = lower.parse(arena_state.allocator(), pat, byte_opts) catch return;

    var c = compile_mod.Compiler{ .gpa = gpa };
    defer c.loom.deinit(gpa);
    defer c.states.deinit(gpa);
    const match_idx = c.push(.match) catch return;
    const start = c.compileNode(ast, match_idx) catch return;

    // The anchoring the shipped compile would pass, not a guess at it.
    const anchored = gist.regex.analysis.startsAnchored(ast);
    const mode: powerset.Budget = if (byte_opts.force_dfa) .unbudgeted else .budgeted;

    var best: i128 = std.math.maxInt(i128);
    for (0..trials) |_| {
        const sp = Span.open(io);
        const outcome = powerset.build(gpa, c.states.items, start, anchored, byte_opts.unicode, mode) catch return;
        best = @min(best, sp.read(io).ns());
        switch (outcome) {
            .built => |d| {
                out.bvisits = d.visits;
                out.bstates = d.nstates;
                d.deinit();
            },
            .declined => {},
        }
        // One trial is enough on a pattern that takes tens of milliseconds — and
        // an unbudgeted build is exactly where that happens.
        if (best > 10 * std.time.ns_per_ms) break;
    }
    out.bpow = best;

    switch (powerset.build(gpa, c.states.items, start, anchored, byte_opts.unicode, .budgeted) catch return) {
        .built => |d| {
            out.verdict = "eager";
            d.deinit();
        },
        .declined => |why| out.verdict = @tagName(why),
    }
}

fn measure(gpa: std.mem.Allocator, io: std.Io, pat: []const u8) !?Split {
    var out: Split = .{};
    out.total = totalNs(gpa, io, pat) orelse return null;
    if (!try frontNs(gpa, io, pat, &out)) return null;
    try symbolicNs(gpa, io, pat, &out);
    byteNs(gpa, io, pat, &out);

    var re = Regex.compileOpts(gpa, pat, opts) catch return null;
    defer re.deinit();
    if (re.dfa) |d| {
        out.ncls = d.ncls;
        out.dfa_states = d.nstates;
    }
    out.tier = if (re.dfa == null) "pike" else if (out.cross != 0) "symbolic" else "powerset";
    return out;
}

fn runStage(gpa: std.mem.Allocator, io: std.Io) !void {
    std.debug.print(
        \\
        \\── stage: one compile, attributed · min of {d} ──
        \\   `parse` AST · `thomp` Thompson NFA (this is where a per-occurrence UTF-8
        \\   trie weave lands) · `mint` minterm lowering, partition included ·
        \\   `cpdet` codepoint subset construction · then the crossing, split into
        \\   `dec` UTF-8 decoder · `hor` horizon · `walk` the product walk with the
        \\   reduction and freeze after it · `resid` total − every named part
        \\   (analyses, and the byte powerset when the symbolic road declined).
        \\   A `tier` of `powerset` means the road declined, the crossing columns
        \\   are blank because they never ran, and `resid` IS the byte powerset.
        \\   `bpow`/`bvis` price that fallback on its own terms — wall time and
        \\   the NFA-state meter its 750 K budget is spent against — and `verdict`
        \\   is what it decided. `too_costly` means the whole `bpow` was thrown
        \\   away; `eager` beside a large `bpow` means the budget's ~2-3 ns/visit
        \\   calibration does not hold for that shape.
        \\{s: <30}{s: >9}{s: >7}{s: >7}{s: >7}{s: >7}{s: >7}{s: >7}{s: >8}{s: >9}{s: >7}{s: >10}{s: >9}  {s: <11}{s}
        \\
    , .{
        trials,  "pattern", "total_us",
        "parse", "thomp",   "mint",
        "cpdet", "dec",     "hor",
        "walk",  "resid",   "nfa",
        "bpow",  "bvis",    "verdict",
        "tier",
    });
    var worst: f64 = 0;
    var worst_pat: []const u8 = "-";
    for (slate) |pat| {
        const s = (try measure(gpa, io, pat)) orelse {
            std.debug.print("{s: <30}  would not compile\n", .{pat});
            continue;
        };
        const share = us(s.thompson) / us(s.total);
        if (share > worst) {
            worst = share;
            worst_pat = pat;
        }
        std.debug.print("{s: <30}{d: >9.1}{d: >7.1}{d: >7.1}{d: >7.1}{d: >7.1}{d: >7.1}{d: >7.1}{d: >8.1}{d: >9.1}{d: >7}{d: >10.1}{d: >9}  {s: <11}{s}\n", .{
            pat,            us(s.total),   us(s.parse),
            us(s.thompson), us(s.minterm), us(s.codepoint),
            us(s.dec),      us(s.hor),     us(s.walk()),
            us(s.resid()),  s.nfa,         us(s.bpow),
            s.bvisits,      s.verdict,     s.tier,
        });
    }
    std.debug.print("\n   worst Thompson share: {d:.0}% on /{s}/\n", .{ worst * 100.0, worst_pat });
}

/// A least-squares slope of µs against a count, which is the only summary a
/// linear cost deserves: the intercept is the fixed compile, the slope is the
/// per-unit bill a fix has to remove.
fn slope(xs: []const f64, ys: []const f64) f64 {
    var sx: f64 = 0;
    var sy: f64 = 0;
    for (xs, ys) |x, y| {
        sx += x;
        sy += y;
    }
    const n: f64 = @floatFromInt(xs.len);
    const mx = sx / n;
    const my = sy / n;
    var num: f64 = 0;
    var den: f64 = 0;
    for (xs, ys) |x, y| {
        num += (x - mx) * (y - my);
        den += (x - mx) * (x - mx);
    }
    return if (den == 0) 0 else num / den;
}

const max_points = 10;

fn runOccurrence(gpa: std.mem.Allocator, io: std.Io) !void {
    std.debug.print(
        \\
        \\── occurrence: the same class, k times · min of {d} ──
        \\   `lowerUtf8` weaves a UTF-8 trie per class OCCURRENCE, so if that weave
        \\   is the bill, `thomp` is linear in k and the slope is what a shared trie
        \\   would reclaim. `nfa` growing linearly too is the trie being rebuilt —
        \\   a SHARED one keeps the states and drops the walk, so after a fix `nfa`
        \\   should be unchanged and `thomp` flat.
        \\{s: <30}{s: >4}{s: >9}{s: >8}{s: >8}{s: >7}  {s}
        \\
    , .{ trials, "pattern", "k", "total_us", "parse", "thomp", "nfa", "tier" });

    for ([_][]const u8{ "(\\w)", "\\p{L}", "\\p{Greek}" }) |unit| {
        var xs: [max_points]f64 = undefined;
        var ys: [max_points]f64 = undefined;
        var n: usize = 0;
        var buf: [256]u8 = undefined;
        for (1..7) |k| {
            var w: usize = 0;
            for (0..k) |_| {
                @memcpy(buf[w..][0..unit.len], unit);
                w += unit.len;
            }
            const pat = buf[0..w];
            const s = (try measure(gpa, io, pat)) orelse continue;
            xs[n] = @floatFromInt(k);
            ys[n] = us(s.thompson);
            n += 1;
            std.debug.print("{s: <30}{d: >4}{d: >9.1}{d: >8.1}{d: >8.1}{d: >7}  {s}\n", .{
                pat, k, us(s.total), us(s.parse), us(s.thompson), s.nfa, s.tier,
            });
        }
        if (n >= 3) std.debug.print(
            "{s: <30}  → {d:.1} us per occurrence of `{s}`\n\n",
            .{ "", slope(xs[0..n], ys[0..n]), unit },
        );
    }
}

/// A class holding exactly `ranges` disjoint non-ASCII codepoint ranges, spaced
/// so no two can coalesce. Non-ASCII on purpose: an ASCII-only class never
/// becomes a `uclass`, so it would measure a different construction entirely.
fn rangeClass(buf: []u8, ranges: usize) ![]const u8 {
    var w: usize = 0;
    buf[w] = '[';
    w += 1;
    for (0..ranges) |i| {
        const lo = 0x100 + i * 4;
        w += (try std.fmt.bufPrint(buf[w..], "\\x{{{x}}}-\\x{{{x}}}", .{ lo, lo + 1 })).len;
    }
    // `+` so the class is a real quantified consume rather than a single
    // instruction the analyses might answer without a determinization.
    w += (try std.fmt.bufPrint(buf[w..], "]+", .{})).len;
    return buf[0..w];
}

fn runRange(gpa: std.mem.Allocator, io: std.Io) !void {
    std.debug.print(
        \\
        \\── range: one class, r disjoint codepoint ranges · min of {d} ──
        \\   The controlled axis. `\d` vs `\w` vs `\p{{L}}` differ in range count AND
        \\   in shape, so a slope read off them conflates the two; these differ only
        \\   in count. The slope is µs per range per occurrence — the unit the
        \\   per-occurrence weave is billed in.
        \\{s: <36}{s: >4}{s: >9}{s: >8}{s: >7}  {s}
        \\
    , .{ trials, "pattern", "r", "total_us", "thomp", "nfa", "tier" });

    var xs: [max_points]f64 = undefined;
    var ys: [max_points]f64 = undefined;
    var n: usize = 0;
    var buf: [1024]u8 = undefined;
    for ([_]usize{ 1, 2, 4, 8, 16, 32 }) |r| {
        const pat = try rangeClass(&buf, r);
        const s = (try measure(gpa, io, pat)) orelse continue;
        xs[n] = @floatFromInt(r);
        ys[n] = us(s.thompson);
        n += 1;
        const shown = if (pat.len <= 34) pat else pat[0..34];
        std.debug.print("{s: <36}{d: >4}{d: >9.1}{d: >8.1}{d: >7}  {s}\n", .{
            shown, r, us(s.total), us(s.thompson), s.nfa, s.tier,
        });
    }
    if (n >= 3) std.debug.print("{s: <36}  → {d:.2} us per codepoint range\n", .{ "", slope(xs[0..n], ys[0..n]) });
}

fn runGate(gpa: std.mem.Allocator, io: std.Io) !void {
    std.debug.print(
        \\
        \\── gate: the pair space the symbolic road is admitted on ──
        \\   `bound` is the free rectangle `nodes × states`; `pairs` is the
        \\   horizon's per-node class count; `kinds` is how many DISTINCT horizons
        \\   those nodes share between them; `prod` is what the walk interned. The
        \\   gate reads `min(bound, pairs)`, so a row whose `bound` clears the
        \\   ceiling while `pairs` does not is a pattern the rectangle alone would
        \\   have sent to the on-demand tier by ARITHMETIC. `slack` is bound/pairs.
        \\   `ncls` is what every product state is multiplied by — the walk interns
        \\   `2 × ncls` landings per state — and `dfa` is what shipped after the
        \\   reduction, so `prod`/`dfa` is how much of the walk was thrown away.
        \\{s: <30}{s: >7}{s: >7}{s: >9}{s: >8}{s: >6}{s: >7}{s: >7}{s: >6}{s: >6}  {s}
        \\
    , .{ "pattern", "nodes", "states", "bound", "pairs", "kinds", "prod", "slack", "ncls", "dfa", "tier" });

    var rescued: usize = 0;
    for (slate) |pat| {
        const s = (try measure(gpa, io, pat)) orelse continue;
        const st = s.stats;
        if (st.nodes == 0) {
            std.debug.print("{s: <30}  not offered (no codepoint class, or unsupported)\n", .{pat});
            continue;
        }
        const slack = if (st.pairs > 0)
            @as(f64, @floatFromInt(st.bound)) / @as(f64, @floatFromInt(st.pairs))
        else
            0;
        if (st.bound >= transcribe.max_states and st.pairs < transcribe.max_states) rescued += 1;
        std.debug.print("{s: <30}{d: >7}{d: >7}{d: >9}{d: >8}{d: >6}{d: >7}{d: >7.2}{d: >6}{d: >6}  {s}\n", .{
            pat,               st.nodes, st.pat_states,
            st.bound,          st.pairs, st.kinds,
            st.product_states, slack,    s.ncls,
            s.dfa_states,      s.tier,
        });
    }
    std.debug.print(
        "\n   ceiling {d} pairs · rows the rectangle alone would have declined: {d}\n",
        .{ transcribe.max_states, rescued },
    );
}

/// Bytes the agreement probes draw from: ASCII word/non-word, whole multi-byte
/// scalars, and the malformed units — a lone continuation byte, an unpaired
/// lead, and the surrogate lead `ED`. The resync path is where a product
/// construction goes wrong, so that is where the probes concentrate.
const probe_bytes = [_]u8{ 'a', 'X', '_', '1', ' ', '.', '@', ':', '\n', 0xC3, 0xA9, 0xE4, 0xB8, 0xAD, 0xCE, 0xA3, 0x80, 0xBF, 0xED, 0xA0, 0xFF };

/// Hold every slate pattern's shipped compile against BOTH oracles before any
/// stage is timed. A compile-cost rung that did not do this would be free to
/// report any number it liked, because building the wrong automaton is always
/// cheaper than building the right one.
fn runAgree(gpa: std.mem.Allocator, failed: *bool) !void {
    std.debug.print(
        \\
        \\── agree: every slate pattern, both determinizations and the Pike VM ──
        \\
    , .{});
    var prng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15);
    const r = prng.random();
    var line: [24]u8 = undefined;
    var decisions: usize = 0;
    var compared: usize = 0;

    for (slate) |pat| {
        var sym = Regex.compileOpts(gpa, pat, opts) catch continue;
        defer sym.deinit();
        var byte = Regex.compileOpts(gpa, pat, byte_opts) catch continue;
        defer byte.deinit();
        var sim = try Regex.Sim.init(gpa, &sym);
        defer sim.deinit();
        compared += 1;

        for (0..400) |t| {
            const len = if (t == 0) 0 else r.uintLessThan(usize, line.len + 1);
            for (line[0..len]) |*b| b.* = probe_bytes[r.uintLessThan(usize, probe_bytes.len)];
            const hay = line[0..len];
            const want = sym.lineMatchPike(&sim, hay);
            if (sym.lineMatch(&sim, hay) != want) {
                std.debug.print("  DIVERGENCE (shipped vs pike) pat=/{s}/ line={x}\n", .{ pat, hay });
                failed.* = true;
            }
            if (byte.lineMatch(&sim, hay) != want) {
                std.debug.print("  DIVERGENCE (byte road vs pike) pat=/{s}/ line={x}\n", .{ pat, hay });
                failed.* = true;
            }
            decisions += 1;
        }
    }
    std.debug.print("   {d} line decisions over {d} patterns, {s}\n", .{
        decisions, compared, if (failed.*) "DIVERGED" else "0 divergences",
    });
}

const Section = enum { agree, stage, occurrence, range, gate, all };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var section: Section = .all;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    if (it.next()) |a| section = std.meta.stringToEnum(Section, a) orelse {
        std.debug.print("usage: lowering-rung [agree|stage|occurrence|range|gate|all]\n", .{});
        std.process.exit(2);
    };

    std.debug.print(
        \\lowering rung — what a compile costs, per stage · abi v{d}
        \\machine: {s} · zig {s} · section: {s}
        \\
    , .{ gist.abi(), @tagName(builtin.target.cpu.arch), builtin.zig_version_string, @tagName(section) });

    var failed = false;
    if (section == .agree or section == .all) try runAgree(gpa, &failed);
    if (section == .stage or section == .all) try runStage(gpa, io);
    if (section == .occurrence or section == .all) try runOccurrence(gpa, io);
    if (section == .range or section == .all) try runRange(gpa, io);
    if (section == .gate or section == .all) try runGate(gpa, io);

    if (failed) {
        std.debug.print("\nFAIL: a pattern's compiled automaton disagreed with the Pike VM\n", .{});
        std.process.exit(1);
    }
}

//! irregex — `-o` leftmost-first spans.
//!
//! `lineMatch`/`docMatch` answer *whether* a line matches; `-o`/--only-matching
//! needs *where* — each non-overlapping match's byte span, so a face can emit the
//! matched text alone (extraction: function names, idents, URLs, …) exactly as
//! ripgrep does. The DFA is boolean, so spans run the Pike VM with a per-state
//! start-offset map. Semantics are rg's `(?-u)`: leftmost start, then the
//! highest-priority thread wins the end — earlier alternation branches and
//! greedy quantifiers extend maximally (verified: `a|ab`→`a`, `a+`→greedy).
//!
//! Three reductions pre-empt the VM when they are provably exact: a pure-literal
//! alternation resolves by SIMD substring scan (`litSpan`), a span-exact class
//! run by the SIMD window kernel — neither pays a thread closure — and
//! everything left is offered to the caliper (`../caliper/`), which measures the
//! extent with two determinized table walks instead of a per-byte thread
//! closure. This file remains the definition of the semantics all three must
//! reproduce, the differential oracle they are fuzzed against, and the engine
//! that answers whenever one of them declines.

const std = @import("std");
const core = @import("../program/core.zig");
const word = @import("../../syntax/word.zig");
const simd = @import("../../../scan/simd.zig");
const prefilter = @import("../../analysis/prefilter.zig");
const dwell = @import("../automata/dwell.zig");
const scratch = @import("scratch.zig");
const eps = @import("closure.zig");
const caliper = @import("../caliper/caliper.zig");

const Regex = core.Regex;
const SpanSim = scratch.SpanSim;
const ThreadList = scratch.ThreadList;

/// A byte span `[start, end)` of one match within a line. `end == start` is a
/// zero-width match (the `-o` caller advances past it to avoid looping).
pub const Span = caliper.Span;

/// What to search and what to read while searching (`../caliper/caliper.zig`) —
/// `matchWindow`'s argument, and `matchSpan`'s whole haystack when nobody bounds
/// it.
pub const Window = caliper.Window;

/// The highest-priority match in a priority-ordered thread `list`: the first
/// `.match` state and where its thread began (`starts`), paired with `end`.
/// Also returns its list index (`cut`) so the caller drops every lower-priority
/// thread — none can yield a preferred match. `null` ⇒ no match at this position.
fn firstMatch(re: *const Regex, list: []const u32, starts: []const usize, end: usize) ?struct { span: Span, cut: usize } {
    for (list, 0..) |s, k| if (re.states[s] == .match)
        return .{ .span = .{ .start = starts[s], .end = end }, .cut = k };
    return null;
}

/// Leftmost-first span of a PURE-LITERAL pattern (`re.lits` non-empty), found
/// by SIMD substring scan instead of the Pike VM — the code-search common
/// case (`TODO`, `func`, `panic|0x`, symbol names). `re.lits` is set only for
/// an assertion-free alternation of pure literals (`analysis.pureLiterals`,
/// per-line only), so the match span IS a literal occurrence: leftmost START
/// dominates branch priority, and at a shared start the lowest branch index
/// (pattern order) wins — exactly the Pike-VM `matchWindow` result. Nothing
/// reads a byte it doesn't consume, so the window's bound is enforced by
/// searching its `region`: a literal that would run past `to` simply doesn't
/// fit, which is the answer wanted and costs nothing to get.
///
/// **One fused multi-literal jump**, not one scan per literal. The obvious loop
/// — `indexOfPos` per literal, keep the earliest — re-scans the whole remaining
/// haystack once per literal *per span*, so a walk over N spans of a K-literal
/// alternation costs N·K full scans and the literals that never occur cost the
/// most (`foo|zzzzq` on a 1 MB line: 314 ms, of which 313 is re-proving `zzzzq`
/// is absent 26,000 times). `simd.indexOfAnyPos` answers the same question —
/// leftmost position where ANY needle starts — in a single pass whose per-block
/// cost is one `anyLane` gate, and it is byte-exact with the per-needle minimum
/// it replaces (`leftmostOf` is its own documented fallback). Measured on a
/// 1 MB line: **248× for `foo|zzzzq`, 1230× for `foo|bar|zzzzq|qqqqw`**,
/// spans identical.
///
/// The position decides the branch, so the ordering rule survives verbatim: at
/// the winning position `p`, the first literal in pattern order that occurs
/// there is the branch leftmost-first prefers, and no literal occurring at `p`
/// can have an earlier leftmost occurrence than `p`.
fn litSpan(re: *const Regex, sim: *SpanSim, region: []const u8, from: usize) ?Span {
    if (from > region.len) return null;
    // A single literal IS the span, so the position needs no attribution — and
    // this is the shape most code searches have (a bare `AcmeStore`), so it
    // stays exactly the one scan and one add it was before the fused jump.
    if (re.lits.len == 1) {
        const lit = re.lits[0];
        // The anchor pair, priced on this region's own bytes rather than on the
        // byte-frequency table shipped in the binary. `litPlan` memoizes on the
        // slice, which is what makes it safe to ask here: this function is
        // re-entered once per span (a `-U` walk of a 200 MB buffer re-enters it
        // millions of times), and the sample must be paid once per haystack. The
        // memo declines below its size gate, so a per-line walk is unaffected.
        const p = simd.indexOfAnyPosWith(region, from, re.lits, sim.litPlan(re, region)) orelse return null;
        return .{ .start = p, .end = p + lit.len };
    }
    const p = simd.indexOfAnyPos(region, from, re.lits) orelse return null;
    for (re.lits) |lit| {
        if (std.mem.startsWith(u8, region[p..], lit)) return .{ .start = p, .end = p + lit.len };
    }
    // `indexOfAnyPos` returns a position it verified some needle at, so this is
    // unreachable for any `lits` set — only an EMPTY literal could report a
    // position nothing occurs at, and `analysis.pureLiterals` never emits one
    // (a zero-width branch disqualifies the whole reduction). Fail closed to the
    // engine below rather than trust an invariant this file cannot enforce.
    return null;
}

/// The first-byte skip policy the span engines may drive, or null to walk every
/// gap. Two conditions, both about profit — soundness is the *engine's* to
/// check, and `automaton.Cache.zeroWidth` is where it does:
///
///   1. a first-byte set exists at all (`analysis.analyzeFirst` proved one), and
///   2. the shared corpus prior expects it to skip further than stepping costs
///      — priced against the *span* walk, which is `min_profitable_span_stride`
///      and not the boolean DFA's bar. Same prior, same question, different
///      walker: see that constant for why the two numbers cannot be one.
fn skipPolicy(re: *const Regex) ?*const prefilter.Prefilter {
    if (re.first.count() == 0) return null;
    if (!re.first.economics.beatsDense(dwell.min_profitable_span_stride)) return null;
    return &re.first;
}

/// Leftmost-first match of the pattern within `line[from..]`, as a byte span, or
/// null — the unbounded window, which is what every caller that isn't measuring
/// a sub-region wants. See `matchWindow` for the semantics.
pub fn matchSpan(re: *const Regex, sim: *SpanSim, line: []const u8, from: usize) ?Span {
    return matchWindow(re, sim, Window.whole(line, from));
}

/// Leftmost-first match of the pattern **inside the window** `w`, as a byte
/// span, or null: it starts at or after `w.from`, ends at or before `w.to`, and
/// every assertion in it reads the full `w.hay` (see `Window` for why that is
/// not the same as searching a slice). Priority-ordered semantics either way:
/// earlier starts win (leftmost), and among threads sharing a start the earliest
/// alternation branch / greediest quantifier wins (rg `(?-u)`). Once any thread
/// matches, new starts stop being seeded (leftmost) while strictly
/// higher-priority survivors keep running, so a greedy branch can still extend
/// the end — up to the bound.
///
/// The bound reaches each engine as a **ceiling on the walk**, never as a
/// truncated haystack: the Pike loop stops seeding and stepping at `w.to` while
/// its closures still read `w.hay`'s real edges, and the caliper's forward jaw
/// does the same. The two reductions above it consume nothing they don't match,
/// so for them the ceiling *is* a slice and `w.region()` applies it for free.
pub fn matchWindow(re: *const Regex, sim: *SpanSim, w: Window) ?Span {
    const to = @min(w.to, w.hay.len);
    if (w.from > to) return null;
    const line = w.hay;
    // Pure-literal fast path: one fused SIMD jump, no Pike VM (see `litSpan`).
    if (re.lits.len > 0) return litSpan(re, sim, line[0..to], w.from);
    // Span-exact class run (`\w+`, `[a-z]{3,8}` — `analysis.classSpanShape`):
    // the SIMD window kernel chunks member runs directly, no thread
    // closures. Final only when the kernel settles high bytes itself
    // (byte-exact set, or the full codepoint class in hand).
    if (re.classrun) |*cr| if (cr.span and (cr.exact or cr.cp != null)) {
        const sp = cr.nextSpan(line[0..to], w.from) orelse return null;
        return .{ .start = sp.start, .end = sp.end };
    };
    // The caliper: a forward leftmost-first table walk for the end, a backward
    // one for the start (`../caliper/`). It carries the patterns no reduction
    // above covers — the multi-segment shapes that are the whole reason `-o` is
    // slower than the boolean pass. A decline is a budget verdict, never a
    // semantic one, and falls straight through to the VM below.
    if (re.caliper) |_| if (sim.jaws) |*j| switch (caliper.measure(j, w, skipPolicy(re))) {
        .found => |sp| return sp,
        .none => return null,
        .decline => {},
    };
    sim.gen += 1;
    sim.cur.len = 0;
    var cl = eps.closure(re, sim, &sim.cur, eps.atStart(re, line, w.from), eps.atEnd(re, line, w.from), word.sides(re.unicode, line, w.from));
    // `line` is the whole haystack handed to the span engine (a line in
    // the per-line default, the buffer under multiline), so its edges
    // ARE the `\A`/`\z` buffer edges in both modes — and stay so under a
    // bound, which moves the walk's ceiling and not the text's edges.
    cl.at_buf_start = w.from == 0;
    cl.at_buf_end = w.from == line.len;
    cl.starts = sim.scur;
    cl.cur_start = w.from;
    _ = cl.add(re.start);

    var best: ?Span = null;
    var cut: usize = sim.cur.len;
    if (firstMatch(re, sim.cur.slice(), sim.scur, w.from)) |m| {
        best = m.span;
        cut = m.cut; // process only threads strictly higher-priority than the match
    }

    var i: usize = w.from;
    while (i < to) : (i += 1) {
        const c = line[i];
        sim.nxt.len = 0;
        sim.gen += 1;
        const at_start = eps.atStart(re, line, i + 1); // multiline: a `\n` at i makes i+1 a line start
        const at_end = eps.atEnd(re, line, i + 1);
        const at_buf_end = i + 1 == line.len; // position i+1 ≥ 1 is never the buffer start
        const sides = word.sides(re.unicode, line, i + 1);
        const slice = sim.cur.slice();
        for (slice[0..cut]) |s| switch (re.states[s]) {
            .consume => |cn| if (cn.set.has(c)) {
                var nc = eps.Closure{ .re = re, .list = &sim.nxt, .seen = sim.seen, .gen = sim.gen, .at_start = at_start, .at_end = at_end, .at_buf_start = false, .at_buf_end = at_buf_end, .sides = sides, .starts = sim.snxt, .cur_start = sim.scur[s] };
                _ = nc.add(cn.out);
            },
            else => {},
        };
        // Re-seed a fresh start at i+1 (lowest priority) only while unmatched.
        if (best == null) {
            var sc = eps.Closure{ .re = re, .list = &sim.nxt, .seen = sim.seen, .gen = sim.gen, .at_start = at_start, .at_end = at_end, .at_buf_start = false, .at_buf_end = at_buf_end, .sides = sides, .starts = sim.snxt, .cur_start = i + 1 };
            _ = sc.add(re.start);
        }
        std.mem.swap(ThreadList, &sim.cur, &sim.nxt);
        std.mem.swap([]usize, &sim.scur, &sim.snxt);
        cut = sim.cur.len;
        if (firstMatch(re, sim.cur.slice(), sim.scur, i + 1)) |m| {
            best = m.span; // a survivor (strictly higher priority) extends/overrides
            cut = m.cut;
        }
        if (best != null and cut == 0) break; // no higher-priority survivor left
    }
    return best;
}

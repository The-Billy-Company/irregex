//! gist — `-o` leftmost-first spans.
//!
//! `lineMatch`/`docMatch` answer *whether* a line matches; `-o`/--only-matching
//! needs *where* — each non-overlapping match's byte span, so gist can emit the
//! matched text alone (extraction: function names, idents, URLs, …) exactly as
//! ripgrep does. The DFA is boolean, so spans run the Pike VM with a per-state
//! start-offset map. Semantics are rg's `(?-u)`: leftmost start, then the
//! highest-priority thread wins the end — earlier alternation branches and
//! greedy quantifiers extend maximally (verified: `a|ab`→`a`, `a+`→greedy).
//!
//! Two reductions pre-empt the VM when they are provably exact: a pure-literal
//! alternation resolves by SIMD substring scan (`litSpan`), and a span-exact
//! class run by the SIMD window kernel — neither pays a thread closure.

const std = @import("std");
const core = @import("../program/core.zig");
const word = @import("../../syntax/word.zig");
const simd = @import("../../../scan/simd.zig");
const scratch = @import("scratch.zig");
const eps = @import("closure.zig");

const Regex = core.Regex;
const SpanSim = scratch.SpanSim;
const ThreadList = scratch.ThreadList;
const wordAt = word.wordAt;
const wordBefore = word.wordBefore;

/// A byte span `[start, end)` of one match within a line. `end == start` is a
/// zero-width match (the `-o` caller advances past it to avoid looping).
pub const Span = struct { start: usize, end: usize };

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
/// (pattern order) wins — exactly the Pike-VM `matchSpan` result. Iterating
/// `re.lits` in order and taking the strictly-earliest occurrence (keeping the
/// first on a positional tie) yields that lowest-index-at-leftmost-start rule,
/// because no literal occurring at the winning position `p` can have its own
/// leftmost occurrence before `p`. One SIMD `indexOfPos` per literal (≤ 8)
/// replaces per-byte closure work — the 6–15× loss on literal/alternation
/// queries vs ripgrep's memmem/Teddy prefilters.
fn litSpan(re: *const Regex, line: []const u8, from: usize) ?Span {
    var best: usize = std.math.maxInt(usize);
    var end: usize = 0;
    for (re.lits) |lit| {
        const q = simd.indexOfPos(line, from, lit) orelse continue;
        if (q < best) {
            best = q;
            end = q + lit.len;
            if (q == from) break; // can't beat a hit at the search origin
        }
    }
    if (best == std.math.maxInt(usize)) return null;
    return .{ .start = best, .end = end };
}

/// Leftmost-first match of the pattern within `line[from..]`, as a byte span,
/// or null. Priority-ordered Pike VM: earlier starts win (leftmost), and among
/// threads sharing a start the earliest alternation branch / greediest
/// quantifier wins (rg `(?-u)` semantics). Once any thread matches we stop
/// seeding new starts (leftmost) but keep strictly-higher-priority survivors
/// running, so a greedy branch can still extend the end.
pub fn matchSpan(re: *const Regex, sim: *SpanSim, line: []const u8, from: usize) ?Span {
    // Pure-literal fast path: SIMD substring scan, no Pike VM (see `litSpan`).
    if (re.lits.len > 0) return litSpan(re, line, from);
    // Span-exact class run (`\w+`, `[a-z]{3,8}` — `analysis.classSpanShape`):
    // the SIMD window kernel chunks member runs directly, no thread
    // closures. Final only when the kernel settles high bytes itself
    // (byte-exact set, or the full codepoint class in hand).
    if (re.classrun) |*cr| if (cr.span and (cr.exact or cr.cp != null)) {
        const sp = cr.nextSpan(line, from) orelse return null;
        return .{ .start = sp.start, .end = sp.end };
    };
    sim.gen += 1;
    sim.cur.len = 0;
    var cl = eps.closure(re, sim, &sim.cur, eps.atStart(re, line, from), eps.atEnd(re, line, from), wordBefore(re.unicode, line, from), wordAt(re.unicode, line, from));
    // `line` is the whole haystack handed to the span engine (a line in
    // the per-line default, the buffer under multiline), so its edges
    // ARE the `\A`/`\z` buffer edges in both modes.
    cl.at_buf_start = from == 0;
    cl.at_buf_end = from == line.len;
    cl.starts = sim.scur;
    cl.cur_start = from;
    _ = cl.add(re.start);

    var best: ?Span = null;
    var cut: usize = sim.cur.len;
    if (firstMatch(re, sim.cur.slice(), sim.scur, from)) |m| {
        best = m.span;
        cut = m.cut; // process only threads strictly higher-priority than the match
    }

    var i: usize = from;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        sim.nxt.len = 0;
        sim.gen += 1;
        const at_start = eps.atStart(re, line, i + 1); // multiline: a `\n` at i makes i+1 a line start
        const at_end = eps.atEnd(re, line, i + 1);
        const at_buf_end = i + 1 == line.len; // position i+1 ≥ 1 is never the buffer start
        const wb = wordBefore(re.unicode, line, i + 1);
        const wa = wordAt(re.unicode, line, i + 1);
        const slice = sim.cur.slice();
        for (slice[0..cut]) |s| switch (re.states[s]) {
            .consume => |cn| if (cn.set.has(c)) {
                var nc = eps.Closure{ .re = re, .list = &sim.nxt, .seen = sim.seen, .gen = sim.gen, .at_start = at_start, .at_end = at_end, .at_buf_start = false, .at_buf_end = at_buf_end, .word_before = wb, .word_after = wa, .starts = sim.snxt, .cur_start = sim.scur[s] };
                _ = nc.add(cn.out);
            },
            else => {},
        };
        // Re-seed a fresh start at i+1 (lowest priority) only while unmatched.
        if (best == null) {
            var sc = eps.Closure{ .re = re, .list = &sim.nxt, .seen = sim.seen, .gen = sim.gen, .at_start = at_start, .at_end = at_end, .at_buf_start = false, .at_buf_end = at_buf_end, .word_before = wb, .word_after = wa, .starts = sim.snxt, .cur_start = i + 1 };
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

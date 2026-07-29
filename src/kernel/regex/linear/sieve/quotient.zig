//! gist — the SP-partition lattice harvest: where a sieve's over-approximating
//! automata come from.
//!
//! A partition of a DFA's states has the **substitution property** (Hartmanis &
//! Stearns, *Algebraic Structure Theory of Sequential Machines*, Prentice-Hall
//! 1966) when it is closed under the transition function: `s ~ t` implies
//! `δ(s,a) ~ δ(t,a)` for every input. A closed partition induces a **quotient**
//! automaton on its blocks, and marking a block accepting whenever ANY member
//! state accepts makes that quotient recognize a SUPERSET of the original
//! language. Superset ⇒ a quotient-reject is an original-reject, conclusively.
//! That is the whole soundness argument, and it is 1966 mathematics.
//!
//! What this file owns is the *generator*: project the shipped byte-class `Dfa`
//! onto its interior-reachable core, close every state pair into the smallest
//! SP partition identifying it (the lattice's join-irreducible floor), keep the
//! ones coarse enough to live in a 16-lane shuffle register, and rank them by
//! how small a slice of their own state space accepts. Selection and the
//! selectivity model live here too, because both are properties of the
//! partition rather than of the kernel that runs it.
//!
//! The filter CONTRACT is not ours and is not claimed: a compact
//! over-approximating automaton used as a sound reject stage in front of an
//! exact verifier is Luchaup, De Carli, Jha & Bach, *Deep packet inspection
//! with DFA-trees and parametrized language overapproximation*, INFOCOM 2014
//! (doi:10.1109/INFOCOM.2014.6847977) — whose Definition 7 is `|D'| < |D|` with
//! `L(D) ⊆ L(D')`, and which calls its shrunk DFAs "a special case of quotient
//! automaton"; restated as a multi-stage cascade of crude over-approximating
//! NFAs by Češka et al., arXiv:1904.10786 (2019); and shipping as Hyperscan's
//! `HS_FLAG_PREFILTER`, whose matches are documented as a superset to be
//! confirmed by an exact matcher. See `README.md` for what IS ours.

const std = @import("std");
const Dfa = @import("../dfa/dfa.zig").Dfa;
const unknown = @import("../dfa/subset.zig").unknown;

/// Sheng residency bound: a 16-lane `tbl`/`pshufb` holds one transition row, so
/// a quotient must partition into at most this many blocks to run register-
/// resident with no gather (Langdale, *Say Hello To My Little Friend*, 2018 —
/// the execution technique, applied here to an over-approximation rather than
/// to an exact small DFA).
pub const cap: u8 = 16;

/// How many quotients may be conjoined. Two independent `tbl` chains issue in
/// parallel and their per-position conjunction costs three throughput ops, so
/// the second one is nearly free; a third adds a register chain for a filter
/// that is already at its selectivity floor on this corpus.
pub const max_conjuncts: usize = 2;

/// Harvest ceiling on the interior-reachable core. Pair closure is O(n²)
/// closures of O(n·ncls) each, so this is a COST policy exactly like
/// `powerset.max_visits` — above it the lattice walk would outweigh the scan it
/// accelerates, and the sieve declines rather than slowing compilation down.
pub const max_core_states: u16 = 96;

/// Union-find steps the whole harvest may spend before it stops looking. A
/// partial harvest is deterministic (pair order is fixed) and still sound — it
/// just sees fewer candidates.
pub const max_closure_steps: u64 = 1_500_000;

/// Distinct closed partitions kept before ranking.
const max_candidates: usize = 64;

const none: u16 = std.math.maxInt(u16);

/// The interior-reachable projection of a shipped `Dfa`: dense compact state
/// ids, the one interior transition table the sieve ever walks, and the two
/// structural licenses the sieve's soundness rests on.
///
/// `fin_safe` — every `trans_fin` accept is also a `trans_in` accept, so a run
/// that uses the interior table on a line's LAST byte can only over-count
/// accepts relative to the real matcher (which resolves `$` there). `nl_reset`
/// — every state steps to the start state on `\n`, so one continuous run over a
/// whole buffer is byte-identical to the per-line model.
pub const Core = struct {
    gpa: std.mem.Allocator,
    n: u16,
    ncls: u16,
    delta: []u16, // [n * ncls] compact successor ids
    acc: []bool, // [n]
    start: u16,
    nl_reset: bool,
    class: [256]u8,

    pub fn deinit(c: *Core) void {
        c.gpa.free(c.delta);
        c.gpa.free(c.acc);
        c.* = undefined;
    }

    fn step(c: *const Core, s: u16, k: u16) u16 {
        return c.delta[@as(usize, s) * c.ncls + k];
    }
};

/// Project a `Dfa` onto the core a sieve can reason about, or decline.
///
/// Every declinature here is a soundness precondition, not a taste call, and
/// each is checked against the finished tables rather than inferred from the
/// pattern's syntax:
///   * a word-context DFA carries a second determinization axis (`trans_in_w`)
///     this single-table run does not model;
///   * an `^`-anchored DFA never re-seeds, so a continuous run is not its run;
///   * a zero-width / BOL match makes every position accept anyway;
///   * a skippable start dwell already skips most of the haystack, and LADDER's
///     shared gate says a per-byte rung must stand down behind it;
///   * an unfilled table slot means the caller handed us a lazily-built
///     automaton, whose rows this fixpoint reasoning does not hold for.
pub fn project(gpa: std.mem.Allocator, d: *const Dfa) std.mem.Allocator.Error!?Core {
    if (d.word_ctx or d.anchored or d.empty_match or d.start_dwell != null) return null;
    if (d.isMatch(d.start)) return null;
    const ncls: usize = d.ncls;

    const ids = try gpa.alloc(u16, d.nstates);
    defer gpa.free(ids);
    @memset(ids, none);
    var order = try gpa.alloc(u16, max_core_states);
    defer gpa.free(order);

    const start_id: u32 = d.start / d.ncls;
    ids[start_id] = 0;
    order[0] = @intCast(start_id);
    var n: u16 = 1;
    var head: u16 = 0;
    while (head < n) : (head += 1) {
        const s: usize = order[head];
        const base = s * ncls;
        for (0..ncls) |k| {
            const off = d.trans_in[base + k];
            if (off == unknown) return null;
            const t: u32 = off / d.ncls;
            if (ids[t] != none) continue;
            if (n == max_core_states) return null; // cost policy, not a bound on correctness
            ids[t] = n;
            order[n] = @intCast(t);
            n += 1;
        }
    }

    // The two structural licenses, proven over the reachable rows.
    const nl_col = d.class['\n'];
    var nl_reset = true;
    for (order[0..n]) |s| {
        const base = @as(usize, s) * ncls;
        if (d.trans_in[base + nl_col] != d.start) nl_reset = false;
        for (0..ncls) |k| {
            const fin = d.trans_fin[base + k];
            if (fin == unknown) return null;
            if (d.isMatch(fin) and !d.isMatch(d.trans_in[base + k])) return null;
        }
    }

    const delta = try gpa.alloc(u16, @as(usize, n) * ncls);
    errdefer gpa.free(delta);
    const acc = try gpa.alloc(bool, n);
    errdefer gpa.free(acc);
    for (order[0..n], 0..) |s, i| {
        const base = @as(usize, s) * ncls;
        acc[i] = d.isMatch(@intCast(base));
        for (0..ncls) |k| delta[i * ncls + k] = ids[d.trans_in[base + k] / d.ncls];
    }
    return .{
        .gpa = gpa,
        .n = n,
        .ncls = d.ncls,
        .delta = delta,
        .acc = acc,
        .start = 0,
        .nl_reset = nl_reset,
        .class = d.class,
    };
}

/// A ≤16-state quotient, byte-expanded into the exact form the shuffle kernel
/// consumes: `rows[b]` is the 16-lane transition row for byte `b`, indexed by
/// the current block. Blocks are renumbered so the accepting ones are the top
/// `nb - th`, which turns "did this quotient accept?" into one unsigned compare
/// against a splat rather than a second table lookup.
pub const Quotient = struct {
    nb: u8,
    th: u8, // accepting ⟺ block ≥ th
    start: u8,
    rows: [256][16]u8,
};

/// Disjoint-set forest over compact state ids, with path halving.
const Dsu = struct {
    p: []u16,

    fn reset(d: *Dsu, n: u16) void {
        for (d.p[0..n], 0..) |*x, i| x.* = @intCast(i);
    }

    fn find(d: *Dsu, x0: u16) u16 {
        var x = x0;
        while (d.p[x] != x) {
            d.p[x] = d.p[d.p[x]];
            x = d.p[x];
        }
        return x;
    }

    fn join(d: *Dsu, a: u16, b: u16) bool {
        const ra, const rb = .{ d.find(a), d.find(b) };
        if (ra == rb) return false;
        d.p[ra] = rb;
        return true;
    }
};

/// Scratch for one harvest: the forest, the pair worklist, and the candidate
/// block-vector arena. Sized once from the core so the O(n²) pair sweep never
/// touches the allocator.
const Scratch = struct {
    gpa: std.mem.Allocator,
    dsu: Dsu,
    stack: []u16, // flat (a,b) pairs
    sp: usize = 0,
    block: []u8, // the partition being canonicalized
    canon: [max_core_states]u16 = @splat(none),
    steps: u64 = 0,

    fn init(gpa: std.mem.Allocator, n: u16) std.mem.Allocator.Error!Scratch {
        const p = try gpa.alloc(u16, n);
        errdefer gpa.free(p);
        // Every union pushes at most `ncls` pairs and there are < n unions, but
        // the worklist can transiently hold duplicates; 2·n·cap is ample and the
        // push is bounds-checked below regardless.
        const st = try gpa.alloc(u16, @as(usize, n) * 2 * cap * 2);
        errdefer gpa.free(st);
        return .{ .gpa = gpa, .dsu = .{ .p = p }, .stack = st, .block = try gpa.alloc(u8, n) };
    }

    fn deinit(s: *Scratch) void {
        s.gpa.free(s.dsu.p);
        s.gpa.free(s.stack);
        s.gpa.free(s.block);
    }

    fn push(s: *Scratch, a: u16, b: u16) void {
        if (s.sp + 2 > s.stack.len) return; // worklist saturated: closure stays coarser, never wronger — the caller re-verifies closure before trusting a partition
        s.stack[s.sp] = a;
        s.stack[s.sp + 1] = b;
        s.sp += 2;
    }
};

/// The smallest closed partition identifying `(p, q)`, written into
/// `sc.block` as canonical block ids. Returns the block count, or null when the
/// harvest's step budget ran out.
///
/// This is the classic pair-graph closure: merging two states forces their
/// successors to merge, transitively. Because the forest already carries
/// transitivity, propagating only the representative pair is complete.
fn spClosure(core: *const Core, sc: *Scratch, p: u16, q: u16) ?u8 {
    sc.dsu.reset(core.n);
    sc.sp = 0;
    sc.push(p, q);
    while (sc.sp >= 2) {
        sc.sp -= 2;
        const a, const b = .{ sc.stack[sc.sp], sc.stack[sc.sp + 1] };
        if (!sc.dsu.join(a, b)) continue;
        sc.steps += core.ncls;
        if (sc.steps > max_closure_steps) return null;
        for (0..core.ncls) |k| {
            const x, const y = .{ core.step(a, @intCast(k)), core.step(b, @intCast(k)) };
            if (sc.dsu.find(x) != sc.dsu.find(y)) sc.push(x, y);
        }
    }
    @memset(sc.canon[0..core.n], none);
    var nb: u16 = 0;
    for (0..core.n) |i| {
        const r = sc.dsu.find(@intCast(i));
        if (sc.canon[r] == none) {
            if (nb == cap) return cap + 1; // too coarse to hold in a register
            sc.canon[r] = nb;
            nb += 1;
        }
        sc.block[i] = @intCast(sc.canon[r]);
    }
    return @intCast(nb);
}

/// Does `q` already distinguish everything `p` does — i.e. does adding `p` to a
/// conjunction that holds `q` buy no discriminating power at all?
fn refines(q: []const u8, p: []const u8) bool {
    var seen: [cap]i16 = @splat(-1);
    for (q, p) |a, b| {
        if (seen[a] < 0) seen[a] = b else if (seen[a] != b) return false;
    }
    return true;
}

/// Build the quotient a closed partition induces, or null when the partition
/// turns out not to be closed (fail-closed: we never trust the harvest's
/// arithmetic, we re-derive it), when its start block accepts (it would then
/// accept at every position), or when every block accepts (it would reject
/// nothing).
fn induce(core: *const Core, block: []const u8, nb: u8) ?Quotient {
    var block_acc: [cap]bool = @splat(false);
    for (core.acc, 0..) |a, i| if (a) {
        block_acc[block[i]] = true;
    };
    var th: u8 = 0;
    for (block_acc[0..nb]) |a| th += @intFromBool(!a);
    if (th == 0 or th == nb) return null; // accepts everything / nothing worth running

    // Renumber: non-accepting blocks first, so `state >= th` is the accept test.
    var relabel: [cap]u8 = @splat(0);
    var lo: u8 = 0;
    var hi: u8 = th;
    for (block_acc[0..nb], 0..) |a, b| {
        if (a) {
            relabel[b] = hi;
            hi += 1;
        } else {
            relabel[b] = lo;
            lo += 1;
        }
    }
    if (relabel[block[core.start]] >= th) return null; // start block accepts

    // Re-derive the quotient transition from the raw partition and reject any
    // disagreement. The harvest is not trusted: a saturated worklist could hand
    // back a partition that is not actually closed, and an unclosed partition
    // does not over-approximate anything.
    var qd: [cap][256]u8 = undefined;
    var filled: [cap]bool = @splat(false);
    for (0..core.n) |i| {
        const from = relabel[block[i]];
        if (!filled[from]) {
            for (0..core.ncls) |k| qd[from][k] = relabel[block[core.step(@intCast(i), @intCast(k))]];
            filled[from] = true;
        } else for (0..core.ncls) |k| {
            if (qd[from][k] != relabel[block[core.step(@intCast(i), @intCast(k))]]) return null;
        }
    }
    for (filled[0..nb]) |f| if (!f) return null; // an unreachable block means the renumbering lied

    var q: Quotient = .{ .nb = nb, .th = th, .start = relabel[block[core.start]], .rows = undefined };
    for (0..256) |b| {
        const col = core.class[b];
        for (0..16) |s| q.rows[b][s] = if (s < nb) qd[s][col] else 0;
    }
    return q;
}

/// Harvest the lattice and return the conjunction, most selective first.
/// `out` is filled with at most `max_conjuncts` quotients; the count is
/// returned. Zero means no closed partition small enough to hold in a register
/// carried any discriminating power.
pub fn harvest(gpa: std.mem.Allocator, core: *const Core, out: *[max_conjuncts]Quotient) std.mem.Allocator.Error!usize {
    var sc = try Scratch.init(gpa, core.n);
    defer sc.deinit();

    const arena = try gpa.alloc(u8, max_candidates * core.n);
    defer gpa.free(arena);
    var kept: usize = 0;
    var score: [max_candidates]f32 = undefined;

    var p: u16 = 0;
    sweep: while (p < core.n) : (p += 1) {
        var q: u16 = p + 1;
        while (q < core.n) : (q += 1) {
            const nb = spClosure(core, &sc, p, q) orelse break :sweep;
            if (nb <= 1 or nb > cap) continue;
            const quo = induce(core, sc.block, nb) orelse continue;
            const cand = arena[kept * core.n ..][0..core.n];
            var dup = false;
            for (0..kept) |i| {
                if (std.mem.eql(u8, arena[i * core.n ..][0..core.n], sc.block)) dup = true;
            }
            if (dup) continue;
            @memcpy(cand, sc.block);
            // Rank by how small a slice of its own state space accepts, ties to
            // the finer partition (closer to the truth it over-approximates).
            score[kept] = @as(f32, @floatFromInt(nb - quo.th)) / @as(f32, @floatFromInt(nb)) -
                @as(f32, @floatFromInt(nb)) * 1e-4;
            kept += 1;
            if (kept == max_candidates) break :sweep;
        }
    }

    // Greedy by score, skipping any partition an already-chosen one already
    // distinguishes everything about — a conjunct that adds no discriminating
    // power is a second register chain bought for nothing.
    var picked: usize = 0;
    var chosen: [max_conjuncts][]const u8 = undefined;
    var used: [max_candidates]bool = @splat(false);
    while (picked < max_conjuncts) {
        var best: ?usize = null;
        for (0..kept) |i| {
            if (used[i]) continue;
            if (best == null or score[i] < score[best.?]) best = i;
        }
        const b = best orelse break;
        used[b] = true;
        const blk = arena[b * core.n ..][0..core.n];
        var redundant = false;
        for (chosen[0..picked]) |c| redundant = redundant or refines(c, blk);
        if (redundant) continue;
        out[picked] = induce(core, blk, blockCount(blk)) orelse continue;
        chosen[picked] = blk;
        picked += 1;
    }
    return picked;
}

fn blockCount(blk: []const u8) u8 {
    var m: u8 = 0;
    for (blk) |b| m = @max(m, b);
    return m + 1;
}

// ── the training-free selectivity model ──────────────────────────────────────
//
// The abort criterion the prior art already mapped: CODFA measured a 26%
// worst-case slowdown when the whole tree has to be walked, and our own
// harvested quotients are bimodal — five of ten patterns reject ≥99.4% of
// positions and one rejects 0.23%. A filter that rejects nothing is pure
// overhead on every byte, so the question "does this sieve pay?" has to be
// answered before the scan starts.
//
// It is answered structurally, from the quotient's own Markov chain, with no
// calibration haystack and nothing learned at runtime: build the block-to-block
// transition matrix under a byte distribution, take the Cesàro average of the
// power iteration (which is the long-run fraction of positions in each block
// even when the chain is periodic), and sum the accepting blocks. Two
// distributions are evaluated and the PESSIMISTIC one decides, so a pattern
// arms only when it looks selective whether the haystack is uniform random
// bytes or English-shaped source text.

/// Byte distributions the model integrates over. `uniform` assumes nothing at
/// all. `text` is one fixed built-in prior — a compile-time constant, never
/// re-derived from a corpus and never updated at runtime — whose coarse buckets
/// come from the byte histogram of this repository's own source tree
/// (space 0.200, lower-case 0.575, punctuation 0.125, upper-case 0.060,
/// line breaks 0.027, digits 0.014, non-ASCII ~1e-4).
pub const Prior = enum { uniform, text };

fn weights(comptime prior: Prior) [256]f64 {
    @setEvalBranchQuota(4000);
    var w: [256]f64 = @splat(0);
    for (0..256) |b| w[b] = switch (prior) {
        .uniform => 1.0 / 256.0,
        .text => switch (b) {
            ' ' => 0.2,
            'a'...'z' => 0.0221,
            '\t', '\n', '\r' => 0.0089,
            'A'...'Z' => 0.0023,
            '0'...'9' => 0.0014,
            0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E => 0.0039,
            0x80...0xFF => 8e-7,
            else => 1e-6,
        },
    };
    var sum: f64 = 0;
    for (w) |x| sum += x;
    for (&w) |*x| x.* /= sum;
    return w;
}

const priors = [_][256]f64{ weights(.uniform), weights(.text) };

/// The long-run fraction of byte positions at which this quotient accepts,
/// under `prior`. This is the sieve's fallthrough rate: the share of the
/// haystack it hands on to the real matcher instead of retiring.
pub fn fallthroughRate(q: *const Quotient, prior: Prior) f64 {
    const w = &priors[@intFromEnum(prior)];
    var m: [cap][cap]f64 = @splat(@splat(0));
    for (0..256) |b| for (0..q.nb) |s| {
        m[s][q.rows[b][s]] += w[b];
    };
    var p: [cap]f64 = @splat(0);
    var avg: [cap]f64 = @splat(0);
    p[q.start] = 1.0;
    const iters = 512;
    for (0..iters) |_| {
        var nx: [cap]f64 = @splat(0);
        for (0..q.nb) |s| {
            if (p[s] == 0) continue;
            for (0..q.nb) |t| nx[t] += p[s] * m[s][t];
        }
        p = nx;
        for (0..q.nb) |s| avg[s] += p[s];
    }
    var rate: f64 = 0;
    for (q.th..q.nb) |s| rate += avg[s] / @as(f64, iters);
    return rate;
}

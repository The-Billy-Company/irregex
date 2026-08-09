//! refine — the coarsest partition a transition table cannot tell apart.
//!
//! Given `n` states, a labelled transition function `δ(state, symbol)`, and an
//! initial colouring of the states, find the coarsest partition that refines
//! the colouring and is **stable**: if two states share a block then, for every
//! symbol, their successors share a block too. Fix what the colour means and
//! that one definition is several familiar problems:
//!
//! | Colouring is… | the stable partition is… |
//! |---|---|
//! | accept vs reject | the Myhill–Nerode congruence — DFA minimization |
//! | a parse-action row | action-bisimulation — the LR-table quotient |
//! | a single colour | the automaton's reachable-behaviour classes |
//!
//! **Two engines, one answer.** `moore` re-partitions every state by the
//! signature `(own block, successors' blocks)` until the block count stops
//! falling. `hopcroft` inverts δ once and splits blocks against a queue of
//! splitters, taking only the smaller half of each split, which is where the
//! `n log n` comes from. They return *byte-identical* output, not merely
//! equivalent partitions — the seeding is shared and blocks are renumbered by
//! first appearance in state order before either returns. That is the point of
//! shipping both: each is the other's oracle on random automata, which is
//! stronger evidence than any hand-written expectation about a partition.
//!
//! **This does not overturn `regex/linear/automata/reduce.zig`.** That file
//! chooses Moore and argues against Hopcroft, and it is right where it stands:
//! at ≤ 4096 states over ~100 byte classes the quadratic worst case never
//! arrives and Hopcroft's queue buys nothing measurable. What that argument does
//! not cover is the other regime this floor has to serve. An LR parser's action
//! table is thousands of states over hundreds of grammar symbols, and Moore's
//! cost there is `O(passes · n · k)` where `passes` is the automaton's
//! distinguishing depth — a number nobody can see before running it.
//!
//! So `auto` does not guess, and carries no threshold somebody measured on one
//! machine. It runs Moore, and escalates to Hopcroft if the partition has not
//! settled within `log₂ n` passes — handing over the partition Moore reached,
//! which is a legitimate head start rather than wasted work: the coarsest stable
//! partition refining an intermediate refinement is the same one, since any
//! stable partition refining it also refines the original colouring. One Moore
//! pass costs `O(n · k)` and Hopcroft's whole run is `O(k · n · log n)`, so the
//! passes spent before escalating are at most a constant factor of the bound
//! they escalate into. `auto` therefore lands within a constant factor of
//! whichever engine was right, on every input, without knowing in advance which
//! one that was.
//!
//! **A missing transition is a distinct sink, not a wildcard.** `nowhere` never
//! shares a block with a real state, so two states are separated when one steps
//! somewhere and the other steps nowhere — even if a dead state made them
//! language-equivalent. That is strictly conservative: it can leave a partition
//! finer than the language requires, and can never merge two states a suffix
//! tells apart. `reduce.zig` makes the same trade for the same reason, and both
//! engines here make it identically, which is why they still agree.
//!
//! Prior art worth reading rather than name-dropping:
//! [Moore, *Gedanken-experiments on sequential
//! machines*](https://doi.org/10.1515/9781400882618-006) (Automata Studies,
//! 1956) — the signature refinement below;
//! [Hopcroft, *An n log n algorithm for minimizing states in a finite
//! automaton*](https://doi.org/10.1016/B978-0-12-417750-5.50022-1) (Theory of
//! Machines and Computations, 1971) — the splitter queue, and the
//! process-the-smaller-half argument that bounds it;
//! [Knuutila, *Re-describing an algorithm by
//! Hopcroft*](https://doi.org/10.1016/S0304-3975(99)00150-4) (TCS 250, 2001) —
//! worth reading before trusting any short description of that algorithm,
//! including this one, since most published ones are subtly wrong;
//! [Valmari, *Fast brief practical DFA
//! minimization*](https://doi.org/10.1016/j.ipl.2011.12.004) (IPL 112(6), 2012)
//! — the refinable-partition structure `Blocks` below is, where a split costs
//! the side that moved rather than the block that held it.
//!
//! **Paige–Tarjan is deliberately absent.** [*Three partition refinement
//! algorithms*](https://doi.org/10.1137/0216062) (SIAM J. Comput. 16(6), 1987)
//! generalizes this to a *relation* — a state and symbol reaching a set of
//! successors rather than one — which is bisimulation on a nondeterministic
//! transition system. It is a different algorithm, not a flag on this one: the
//! count-per-(state, block) bookkeeping that makes it work has nothing to count
//! when δ is a function. Nothing in either package reduces a nondeterministic
//! automaton today — every road goes NFA → subset construction → determinized
//! table — so it would be a page of code with no caller. When one exists it
//! belongs beside this file, not inside it.

const std = @import("std");
const mix = @import("mix.zig");

/// A transition target that does not exist. Every state agrees with every other
/// state about it, and no state agrees with it.
pub const nowhere: u32 = std.math.maxInt(u32);

/// The transition function, dense and row-major: `delta[s * symbols + a]` is
/// where state `s` goes on symbol `a`, or `nowhere`.
///
/// Dense because both engines read every row — Moore builds a signature from all
/// `k` successors, Hopcroft inverts the whole table once. A sparse caller pays
/// `nowhere` for its holes, which costs a word per hole and keeps both engines
/// indexing rather than searching.
pub const Table = struct {
    states: u32,
    symbols: u32,
    delta: []const u32,

    fn row(t: Table, s: u32) []const u32 {
        const w: usize = t.symbols;
        return t.delta[@as(usize, s) * w ..][0..w];
    }
};

/// Which engine actually ran. Under `.auto` this is the observable that says
/// whether the escalation fired, which is the only way a test can tell a working
/// budget from one that never trips.
pub const Engine = enum { moore, hopcroft };

/// What a refinement cost, beside what it found. `passes` counts Moore passes
/// including any abandoned before an escalation, so the two engines' work is
/// separately attributable from one call.
pub const Refinement = struct {
    blocks: u32,
    engine: Engine,
    passes: u32,
};

/// Which engine computes the partition. The answer does not depend on this —
/// only the time and the memory spent reaching it do.
pub const Plan = enum {
    /// Moore for `log₂ n` passes, then Hopcroft from where Moore got to. The
    /// right answer for a caller who does not know their own shape, and the only
    /// one that needs no threshold.
    auto,
    /// Signature refinement. Cheapest on a shallow automaton of any size, and on
    /// a small one whatever its depth. Allocates no inverse.
    moore,
    /// Splitter queue over the inverted table. Bounded `O(k · n · log n)`, at the
    /// cost of holding the inverse — about twice the table again.
    hopcroft,
};

/// Refine `colour` into the coarsest stable partition, writing `block[s]` for
/// every state and returning the block count.
///
/// `colour` is any labelling — values need be neither dense nor ordered, and
/// all-equal means one initial block. `block` may alias nothing else, and both
/// slices hold at least `t.states` entries.
///
/// Blocks are numbered by first appearance in state order. Two consequences
/// worth relying on: the answer is canonical, so two engines — or two runs, or
/// two machines — number the same input identically; and the representative of
/// block `b`, the first state mapping to it, is never at an index below `b`, so
/// a caller can compact rows in place, writing every row strictly below the row
/// it reads.
pub fn refine(
    gpa: std.mem.Allocator,
    t: Table,
    colour: []const u32,
    block: []u32,
    plan: Plan,
) std.mem.Allocator.Error!Refinement {
    std.debug.assert(t.delta.len == @as(usize, t.states) * t.symbols);
    std.debug.assert(colour.len >= t.states);
    std.debug.assert(block.len >= t.states);
    if (t.states == 0) return .{ .blocks = 0, .engine = .moore, .passes = 0 };

    // Both engines start from the same dense seeding, which is half of why they
    // agree. It also closes a hazard the raw colouring carries: a colour that
    // happened to equal `nowhere` would read, in a Moore signature, as a step
    // into the sink rather than into a state.
    var seeded = try condense(gpa, t.states, colour, block);

    var engine: Engine = .moore;
    var passes: u32 = 0;
    switch (plan) {
        .moore => {
            const got = try moore(gpa, t, block, seeded, null);
            seeded = got.blocks;
            passes = got.passes;
        },
        .hopcroft => {
            engine = .hopcroft;
            seeded = try hopcroft(gpa, t, block, seeded);
        },
        .auto => {
            // ⌈log₂ n⌉ + 1 passes: what a settling automaton of this size is
            // allowed before its depth is itself the evidence that Hopcroft's
            // bound is the cheaper thing to be paying.
            const budget = std.math.log2_int_ceil(u32, @max(2, t.states)) + 1;
            const got = try moore(gpa, t, block, seeded, budget);
            passes = got.passes;
            seeded = got.blocks;
            if (!got.stable) {
                engine = .hopcroft;
                seeded = try hopcroft(gpa, t, block, seeded);
            }
        },
    }
    return .{
        .blocks = try canonicalize(gpa, t.states, block, seeded),
        .engine = engine,
        .passes = passes,
    };
}

/// Number the distinct colours by first appearance, writing dense ids to `out`.
fn condense(
    gpa: std.mem.Allocator,
    states: u32,
    colour: []const u32,
    out: []u32,
) std.mem.Allocator.Error!u32 {
    var ids = std.AutoHashMap(u32, u32).init(gpa);
    defer ids.deinit();
    try ids.ensureTotalCapacity(states);
    var count: u32 = 0;
    for (colour[0..states], out[0..states]) |c, *slot| {
        const gop = ids.getOrPutAssumeCapacity(c);
        if (!gop.found_existing) {
            gop.value_ptr.* = count;
            count += 1;
        }
        slot.* = gop.value_ptr.*;
    }
    return count;
}

/// Renumber blocks by the state order in which they first appear. Moore already
/// numbers this way; Hopcroft finishes on whatever order its splits produced,
/// and this is what makes the two one answer rather than two that would have to
/// be compared as sets.
fn canonicalize(
    gpa: std.mem.Allocator,
    states: u32,
    block: []u32,
    nblocks: u32,
) std.mem.Allocator.Error!u32 {
    // Offset by one so zero reads as "not seen yet" and the map needs no
    // initializing sweep past `@memset`.
    const seen = try gpa.alloc(u32, nblocks);
    defer gpa.free(seen);
    @memset(seen, 0);
    var next: u32 = 0;
    for (block[0..states]) |*b| {
        if (seen[b.*] == 0) {
            next += 1;
            seen[b.*] = next;
        }
        b.* = seen[b.*] - 1;
    }
    return next;
}

const SigCtx = mix.SliceCtx(u32);
const SigMap = std.HashMap([]const u32, u32, SigCtx, std.hash_map.default_max_load_percentage);

/// How far Moore got: the block count, and whether that count is the answer or
/// just where the budget ran out. An unsettled partition is still a legitimate
/// place for Hopcroft to start, which is why this reports the count either way
/// rather than throwing the work away with a `null`.
const Reached = struct { blocks: u32, stable: bool, passes: u32 };

/// Moore's refinement: re-partition by `(own block, successors' blocks)` until
/// the block count stops falling, starting from the `blocks` already in `part`.
///
/// The fixpoint test is the count, not the assignment, and that is sound because
/// refinement is monotone: a pass can only split, so a pass that splits nothing
/// has reached the congruence. Signatures live in one flat buffer, letting the
/// hash map key on slices of it without duplicating any: within a pass, row `s`
/// is written once and read only by the probe that wrote it.
fn moore(
    gpa: std.mem.Allocator,
    t: Table,
    part: []u32,
    blocks: u32,
    budget: ?u32,
) std.mem.Allocator.Error!Reached {
    const n = t.states;
    const w: usize = 1 + @as(usize, t.symbols); // own block, then one per symbol

    const sigs = try gpa.alloc(u32, @as(usize, n) * w);
    defer gpa.free(sigs);
    const next = try gpa.alloc(u32, n);
    defer gpa.free(next);
    var table = SigMap.init(gpa);
    defer table.deinit();
    try table.ensureTotalCapacity(n);

    var settled = blocks;
    var passes: u32 = 0;
    while (true) {
        table.clearRetainingCapacity();
        var found: u32 = 0;
        for (0..n) |s| {
            const sig = sigs[s * w ..][0..w];
            sig[0] = part[s];
            for (t.row(@intCast(s)), sig[1..]) |target, *slot|
                slot.* = if (target == nowhere) nowhere else part[target];
            const gop = table.getOrPutAssumeCapacity(sig);
            if (gop.found_existing) {
                next[s] = gop.value_ptr.*;
            } else {
                gop.key_ptr.* = sig;
                gop.value_ptr.* = found;
                next[s] = found;
                found += 1;
            }
        }
        @memcpy(part[0..n], next);
        passes += 1;
        // A pass that found exactly as many blocks as it was given split
        // nothing, so the partition it was given was already stable.
        if (found == settled) return .{ .blocks = found, .stable = true, .passes = passes };
        settled = found;
        if (budget) |cap| if (passes >= cap)
            return .{ .blocks = found, .stable = false, .passes = passes };
    }
}

/// A partition that splits in time proportional to the side that moved, not the
/// block it moved out of — Valmari's structure.
///
/// States of one block are contiguous in `elems`, `at` inverts that placement,
/// and `mid` cuts each block into the marked prefix `[first, mid)` and the rest.
/// Marking is a swap, so a block accumulates marks in any order and still splits
/// in one step.
const Blocks = struct {
    elems: []u32,
    at: []u32,
    first: []u32,
    end: []u32,
    mid: []u32,
    of: []u32,
    count: u32,
    /// Blocks holding at least one mark, so `split` visits those and no others.
    touched: std.ArrayList(u32) = .empty,

    /// Lay out `n` states already labelled with `count` dense block ids.
    fn init(
        gpa: std.mem.Allocator,
        n: u32,
        seed: []const u32,
        count: u32,
    ) std.mem.Allocator.Error!Blocks {
        var b: Blocks = .{
            .elems = try gpa.alloc(u32, n),
            .at = try gpa.alloc(u32, n),
            .first = try gpa.alloc(u32, n),
            .end = try gpa.alloc(u32, n),
            .mid = try gpa.alloc(u32, n),
            .of = try gpa.alloc(u32, n),
            .count = count,
        };
        @memcpy(b.of[0..n], seed[0..n]);

        // Counting sort into contiguous runs: `end` accumulates the sizes, then
        // becomes each block's exclusive bound as the prefix sum rolls forward.
        @memset(b.end[0..count], 0);
        for (b.of[0..n]) |g| b.end[g] += 1;
        var acc: u32 = 0;
        for (0..count) |g| {
            b.first[g] = acc;
            acc += b.end[g];
            b.end[g] = acc;
            b.mid[g] = b.first[g];
        }
        const cursor = try gpa.alloc(u32, count);
        defer gpa.free(cursor);
        @memcpy(cursor, b.first[0..count]);
        for (0..n) |s| {
            const g = b.of[s];
            b.elems[cursor[g]] = @intCast(s);
            b.at[s] = cursor[g];
            cursor[g] += 1;
        }
        return b;
    }

    fn deinit(b: *Blocks, gpa: std.mem.Allocator) void {
        gpa.free(b.elems);
        gpa.free(b.at);
        gpa.free(b.first);
        gpa.free(b.end);
        gpa.free(b.mid);
        gpa.free(b.of);
        b.touched.deinit(gpa);
    }

    fn size(b: *const Blocks, g: u32) u32 {
        return b.end[g] - b.first[g];
    }

    fn members(b: *const Blocks, g: u32) []const u32 {
        return b.elems[b.first[g]..b.end[g]];
    }

    fn mark(b: *Blocks, gpa: std.mem.Allocator, s: u32) std.mem.Allocator.Error!void {
        const g = b.of[s];
        const i = b.at[s];
        const m = b.mid[g];
        if (i < m) return; // already in the marked prefix
        if (m == b.first[g]) try b.touched.append(gpa, g);
        const other = b.elems[m];
        b.elems[m] = s;
        b.elems[i] = other;
        b.at[s] = m;
        b.at[other] = i;
        b.mid[g] = m + 1;
    }

    /// Split every touched block at its mark, appending `(kept, split_off)` for
    /// each one that split. A block marked in full does not split — every member
    /// agreed, which is the case marking cannot distinguish.
    fn split(
        b: *Blocks,
        gpa: std.mem.Allocator,
        out: *std.ArrayList([2]u32),
    ) std.mem.Allocator.Error!void {
        for (b.touched.items) |g| {
            const m = b.mid[g];
            if (m == b.end[g]) {
                b.mid[g] = b.first[g];
                continue;
            }
            const fresh = b.count;
            b.count += 1;
            b.first[fresh] = b.first[g];
            b.end[fresh] = m;
            b.mid[fresh] = b.first[g];
            for (b.elems[b.first[g]..m]) |s| b.of[s] = fresh;
            b.first[g] = m;
            b.mid[g] = m;
            try out.append(gpa, .{ g, fresh });
        }
        b.touched.clearRetainingCapacity();
    }
};

/// Hopcroft's refinement: hold a queue of blocks still owed a turn as splitter,
/// and for each, split every block whose members disagree about whether this
/// symbol leads into it.
///
/// The `n log n` rests on one line — when a block splits, only the *smaller*
/// half is queued. Stability against a whole block plus stability against one of
/// its halves implies stability against the other, so the larger half is already
/// paid for, and a state can be inside a queued block at most `log₂ n` times.
/// That implication needs δ to be a *function*, which is also why the sink below
/// is not optional.
fn hopcroft(
    gpa: std.mem.Allocator,
    t: Table,
    part: []u32,
    blocks: u32,
) std.mem.Allocator.Error!u32 {
    var run = try Run.init(gpa, t, part, blocks);
    defer run.deinit();

    // The sink is a block of the partition like any other, and the one the
    // caller cannot pass: without it δ is partial, the disjointness the omission
    // rule below stands on fails, and this engine would part ways with Moore on
    // any table with a hole. It splits nothing off itself, so it needs exactly
    // one turn and never a place in the queue.
    try run.sweep(&.{run.sink});

    // Every remaining block but the widest. Stability against all the others
    // implies it: the pre-images of distinct blocks are disjoint (δ is a
    // function) and together cover every state, so a block already uniform about
    // each of the others is uniform about what is left.
    {
        var widest: u32 = 0;
        for (1..run.part.count) |g| if (run.part.size(@intCast(g)) > run.part.size(widest)) {
            widest = @intCast(g);
        };
        for (0..run.part.count) |g| if (g != widest) try run.enqueue(@intCast(g));
    }

    while (run.queue.pop()) |splitter| {
        run.pending[splitter] = false;
        // Read out the members before anything moves: the set scheduled is the
        // set used, even when the splitter is one of the blocks this turn splits.
        run.roster.clearRetainingCapacity();
        try run.roster.appendSlice(gpa, run.part.members(splitter));
        try run.sweep(run.roster.items);
    }

    @memcpy(part[0..t.states], run.part.of[0..t.states]);
    return run.part.count;
}

/// One Hopcroft run: the partition, the inverted table, and the queue of blocks
/// still owed a turn.
const Run = struct {
    gpa: std.mem.Allocator,
    part: Blocks,
    /// `δ⁻¹` as one CSR keyed by `(symbol, target)`, where target `sink` collects
    /// the transitions that go nowhere. Every `(state, symbol)` pair lands in
    /// exactly one cell, so this is the table again, transposed and grouped.
    start: []u32,
    inv: []u32,
    sink: u32,
    symbols: u32,
    queue: std.ArrayList(u32) = .empty,
    pending: []bool,
    roster: std.ArrayList(u32) = .empty,
    fresh: std.ArrayList([2]u32) = .empty,

    fn init(
        gpa: std.mem.Allocator,
        t: Table,
        seed: []const u32,
        blocks: u32,
    ) std.mem.Allocator.Error!Run {
        const n = t.states;
        const targets: usize = @as(usize, n) + 1; // real states, then the sink
        const cells = @as(usize, t.symbols) * targets;

        var r: Run = .{
            .gpa = gpa,
            .part = try Blocks.init(gpa, n, seed, blocks),
            .start = try gpa.alloc(u32, cells + 1),
            .inv = try gpa.alloc(u32, @as(usize, n) * t.symbols),
            .sink = n,
            .symbols = t.symbols,
            .pending = try gpa.alloc(bool, n),
        };
        @memset(r.pending, false);

        @memset(r.start, 0);
        for (0..n) |s| for (t.row(@intCast(s)), 0..) |target, a| {
            const to = if (target == nowhere) r.sink else target;
            r.start[a * targets + to + 1] += 1;
        };
        for (1..cells + 1) |i| r.start[i] += r.start[i - 1];
        const cursor = try gpa.alloc(u32, cells);
        defer gpa.free(cursor);
        @memcpy(cursor, r.start[0..cells]);
        for (0..n) |s| for (t.row(@intCast(s)), 0..) |target, a| {
            const cell = a * targets + (if (target == nowhere) r.sink else target);
            r.inv[cursor[cell]] = @intCast(s);
            cursor[cell] += 1;
        };
        return r;
    }

    fn deinit(r: *Run) void {
        r.part.deinit(r.gpa);
        r.gpa.free(r.start);
        r.gpa.free(r.inv);
        r.gpa.free(r.pending);
        r.queue.deinit(r.gpa);
        r.roster.deinit(r.gpa);
        r.fresh.deinit(r.gpa);
    }

    fn enqueue(r: *Run, g: u32) std.mem.Allocator.Error!void {
        if (r.pending[g]) return;
        try r.queue.append(r.gpa, g);
        r.pending[g] = true;
    }

    /// One splitter's whole turn: for each symbol, mark everything that steps
    /// into `targets` and split whatever that divides.
    fn sweep(r: *Run, targets: []const u32) std.mem.Allocator.Error!void {
        const stride: usize = @as(usize, r.sink) + 1;
        for (0..r.symbols) |a| {
            for (targets) |to| {
                const cell = a * stride + to;
                for (r.inv[r.start[cell]..r.start[cell + 1]]) |pred|
                    try r.part.mark(r.gpa, pred);
            }
            try r.part.split(r.gpa, &r.fresh);
            for (r.fresh.items) |pair| {
                const kept, const born = pair;
                // `kept` still owing a turn means the whole of it is coming, so
                // the half that left needs one of its own. Otherwise the whole
                // was already spent and the smaller half is all that is left to
                // pay — the line the log factor rests on.
                const owed = if (r.pending[kept])
                    born
                else if (r.part.size(born) <= r.part.size(kept))
                    born
                else
                    kept;
                try r.enqueue(owed);
            }
            r.fresh.clearRetainingCapacity();
        }
    }
};
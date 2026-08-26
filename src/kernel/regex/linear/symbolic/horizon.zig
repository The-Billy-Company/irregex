//! irregex — how much of the pattern a decoder node can still see.
//!
//! `transcribe.zig` crosses the UTF-8 decoder with the codepoint automaton and
//! the reachable pairs become the byte DFA. That product is honestly built and
//! systematically too big, for a reason that has nothing to do with either
//! factor being sloppy: **mid-codepoint, the pattern is not running.** A
//! continuation byte carries the pattern state through untouched, so the only
//! thing `(node, q)` can ever do with `q` is hand it to the transition table
//! once a codepoint completes — and only for the minterms whose leaves are still
//! reachable from `node`.
//!
//! That set is a node's **horizon**. Deep inside the trie for Unicode `\w` the
//! horizon is a single minterm, so every pattern state that agrees on that one
//! column is, from there, the same state. `reduce.zig` discovers exactly this
//! afterwards, by hashing a `1 + 2·ncls` signature per state per pass over a
//! table three times larger than the answer. The horizon is the same congruence
//! read off the two factors *before* a pair is interned, which costs one
//! ascending sweep of the decoder DAG.
//!
//! ## Why it is exact and not an approximation
//!
//! `(n, q₁) ~ (n, q₂)` iff every byte agrees, and `transcribe`'s `stepByte` has
//! only three outcomes: an edge to a **leaf** minterm `m` lands on
//! `(root, tbl[q, m])`, an edge to a **child** node `t` lands on `(t, q)`, and a
//! **lost sync** re-reads the byte from the root against `aut.reseed` — with no
//! reference to `q` at all. So the relation is: agree on `trans_in` and
//! `trans_fin` for every leaf minterm directly on `n`, *and* be related at every
//! child. Unrolled over the DAG that is precisely "agree on every minterm in the
//! horizon", which is why one bitset per node settles it.
//!
//! Decoder nodes are interned children-first (`decoder.weave` recurses to build
//! a target before `intern`ing the parent that points at it), so a child's id is
//! always below its parent's and one ascending pass over the union is a
//! fixpoint. That ordering is load-bearing here and is the decoder's to keep.
//!
//! ## The root is held apart, deliberately
//!
//! At the root a codepoint boundary has just passed: the horizon is every
//! decoded minterm, and `transcribe` reads `is_match` there and nowhere else
//! (`at_boundary`). Both facts point the same way, so rather than encode
//! `is_match` into the signature for one node out of hundreds, the root maps
//! every state to itself. It is where the pattern's genuinely distinct states
//! are supposed to live.
//!
//! Measured, the two together account for the whole collapse `reduce` was
//! finding: `\w+X` is 316 nodes × 3 states = 948 pairs, and 3 + 315 = **318** —
//! the exact table the byte road ships. `\w{3,8}`'s counter keeps three of its
//! four states apart under a one-minterm horizon, giving 4 + 315×3 = **949**,
//! also exact. This does not make the automaton smaller; it stops building the
//! part that was never going to survive.
//!
//! ## The quotient is per HORIZON, not per node
//!
//! Two nodes with the same horizon compute the same signatures over the same
//! columns and therefore the same classes — the node id never enters the
//! signature. So the interesting object is the horizon, and there are far fewer
//! of them than there are nodes: Unicode `\w`'s 316-node trie has **6** distinct
//! horizons, because the deep interior is hundreds of nodes all seeing the same
//! single minterm. Keying the work on the horizon turns the signature pass from
//! `nodes × |horizon| × states` into `horizons × |horizon| × states`, and shrinks
//! the resident tables from `nodes × states` to `horizons × states` — 948 u32 to
//! 18 on `\w+X`. Nothing about the answer changes; the sweep just stops
//! re-deriving a row it already has.
//!
//! ## And it addresses the product's table exactly
//!
//! Once the classes are known per horizon, so is each node's class COUNT, so the
//! product's `(node, state) -> id` table can be addressed as
//! `base[node] + dense[horizon][state]` — a block per node, sized to that node's
//! classes rather than to every state the automaton has. That array is then
//! exactly `pairs` long instead of `nodes × states`, which on `func\s+\w+\(` is
//! 658 slots where the rectangle wanted 3792. The saving is not the memory; it is
//! the `@memset` that has to precede every walk, and it is why `transcribe` can
//! now afford to consult this before deciding whether to walk at all.

const std = @import("std");
const mix = @import("../../../math/mix.zig");
const decoder_mod = @import("decoder.zig");
const determinize = @import("determinize.zig");

const leaf = decoder_mod.leaf;
const SigMap = std.HashMap([]const u32, u32, mix.SliceCtx(u32), std.hash_map.default_max_load_percentage);
const SetMap = std.HashMap([]const u64, u32, mix.SliceCtx(u64), std.hash_map.default_max_load_percentage);

/// The identity quotient, reserved so the root can never share a kind with a
/// node that merely sees the same minterms. `rep` and `dense` are both `q` there,
/// which is what lets `transcribe`'s anchored collapse address `(root, dead)`
/// without a lookup.
const identity: u32 = 0;

/// The per-horizon quotient of the pattern automaton, the exact pair count that
/// falls out of it, and the block addressing that count implies.
pub const Horizon = struct {
    gpa: std.mem.Allocator,
    nstates: u32,
    /// Which quotient each decoder node uses — its horizon's id, not its own.
    kind: []u32,
    /// `rep[kind * nstates + q]` — the state `(node, q)` is indistinguishable
    /// from. Idempotent: `rep[k][rep[k][q]] == rep[k][q]`, because a class's
    /// representative is a member of it.
    rep: []u32,
    /// `dense[kind * nstates + q]` — which of that kind's classes `q` falls in,
    /// numbered `0..classes(kind)`. The representative's rank, so it is stable
    /// under `rep` and dense by construction.
    dense: []u32,
    /// `base[node]` — where this node's block starts in a `pairs`-long table.
    /// A `u32` holds it by construction and not by luck: `pairs` cannot exceed
    /// `decoder.max_nodes × determinize.max_states`, both 4096, so the largest
    /// prefix sum expressible here is under 2²⁴.
    base: []u32,
    /// Distinct pairs the product can reach, summed over nodes. Exact for the
    /// unanchored canon and an upper bound under the anchored one, which folds
    /// `(node, dead)` onto a single absorbing pair.
    pairs: u64,
    /// Distinct horizons behind all of it — what the dedup actually bought,
    /// reported so a rung can see the ratio rather than infer it.
    kinds: u32,

    pub fn deinit(h: *Horizon) void {
        h.gpa.free(h.kind);
        h.gpa.free(h.rep);
        h.gpa.free(h.dense);
        h.gpa.free(h.base);
    }

    /// The representative of `q` at `node` — what to intern instead of `q`.
    /// Stepping from a representative yields the same successors as stepping from
    /// any member, which is what makes substituting it a congruence rather than
    /// an approximation.
    pub fn canon(h: *const Horizon, node: u32, q: u32) u32 {
        return h.rep[@as(usize, h.kind[node]) * h.nstates + q];
    }

    /// Where `(node, q)` lives in a `pairs`-long interning table. Every distinct
    /// pair gets its own slot and no slot is shared, so a table this size is not
    /// a gamble — it is the count this module just proved.
    pub fn slot(h: *const Horizon, node: u32, q: u32) usize {
        return h.base[node] + h.dense[@as(usize, h.kind[node]) * h.nstates + q];
    }
};

/// Read each decoder node's minterm horizon, quotient the pattern's states
/// against each DISTINCT one, then lay the nodes' blocks end to end. One
/// ascending sweep for the horizons, one signature pass per distinct horizon.
pub fn build(
    gpa: std.mem.Allocator,
    dec: *const decoder_mod.Decoder,
    aut: *const determinize.Automaton,
) std.mem.Allocator.Error!Horizon {
    const nodes = dec.count();
    const ns = aut.nstates;
    const nmt: usize = aut.nmt;
    const words = (nmt + 63) / 64;

    const seen = try gpa.alloc(u64, @as(usize, nodes) * words);
    defer gpa.free(seen);
    @memset(seen, 0);
    for (0..nodes) |n| {
        const mine = seen[n * words ..][0..words];
        for (dec.edgesOf(@intCast(n))) |e| {
            if (e.target & leaf != 0) {
                const m: usize = e.target & ~leaf;
                mine[m >> 6] |= @as(u64, 1) << @truncate(m);
            } else for (seen[@as(usize, e.target) * words ..][0..words], mine) |src, *dst| dst.* |= src;
        }
    }

    const kind = try gpa.alloc(u32, nodes);
    errdefer gpa.free(kind);
    const base = try gpa.alloc(u32, nodes);
    errdefer gpa.free(base);

    // Kind 0 is the reserved identity, so both tables open with one row each and
    // grow only when a genuinely new horizon appears.
    var rep: std.ArrayList(u32) = .empty;
    errdefer rep.deinit(gpa);
    var dense: std.ArrayList(u32) = .empty;
    errdefer dense.deinit(gpa);
    try rep.ensureTotalCapacity(gpa, ns);
    try dense.ensureTotalCapacity(gpa, ns);
    for (0..ns) |q| {
        rep.appendAssumeCapacity(@intCast(q));
        dense.appendAssumeCapacity(@intCast(q));
    }
    var count: std.ArrayList(u32) = .empty;
    defer count.deinit(gpa);
    try count.append(gpa, ns);

    // One buffer per kind's signatures, so the map can key on slices of it: two
    // columns per horizon minterm, and never more than the alphabet is wide.
    const sigs = try gpa.alloc(u32, @as(usize, ns) * 2 * @max(nmt, 1));
    defer gpa.free(sigs);
    var table = SigMap.init(gpa);
    defer table.deinit();
    try table.ensureTotalCapacity(ns);

    // Horizon bitset -> kind. Keyed on the slice living in `seen`, which outlives
    // the loop, so no copy is needed.
    var kinds = SetMap.init(gpa);
    defer kinds.deinit();

    const stride = 2 * @max(nmt, 1);
    var pairs: u64 = 0;
    for (0..nodes) |n| {
        base[n] = @intCast(pairs);
        if (@as(u32, @intCast(n)) == dec.root) {
            kind[n] = identity;
            pairs += ns;
            continue;
        }
        const mine = seen[n * words ..][0..words];
        const known = try kinds.getOrPut(mine);
        if (known.found_existing) {
            kind[n] = known.value_ptr.*;
            pairs += count.items[known.value_ptr.*];
            continue;
        }
        const k: u32 = @intCast(count.items.len);
        known.value_ptr.* = k;
        kind[n] = k;

        // Keys live in `sigs`, which the next line starts overwriting — so the
        // previous kind's entries have to go before, not after.
        table.clearRetainingCapacity();
        // The signature's width is the horizon's population — a node that can
        // still reach one minterm compares one column, not `nmt` of them — and
        // every state reads the same columns, so it is measured once.
        var w: usize = 0;
        for (0..nmt) |m| {
            if (mine[m >> 6] & (@as(u64, 1) << @truncate(m)) == 0) continue;
            for (0..ns) |q| {
                sigs[q * stride + w] = aut.trans_in[q * nmt + m];
                sigs[q * stride + w + 1] = aut.trans_fin[q * nmt + m];
            }
            w += 2;
        }
        try rep.resize(gpa, (@as(usize, k) + 1) * ns);
        try dense.resize(gpa, (@as(usize, k) + 1) * ns);
        const rep_row = rep.items[@as(usize, k) * ns ..][0..ns];
        const dense_row = dense.items[@as(usize, k) * ns ..][0..ns];
        var classes: u32 = 0;
        for (0..ns) |q| {
            const sig = sigs[q * stride ..][0..w];
            const gop = table.getOrPutAssumeCapacity(sig);
            if (gop.found_existing) {
                rep_row[q] = gop.value_ptr.*;
                dense_row[q] = dense_row[gop.value_ptr.*];
            } else {
                gop.key_ptr.* = sig;
                gop.value_ptr.* = @intCast(q);
                rep_row[q] = @intCast(q);
                dense_row[q] = classes;
                classes += 1;
            }
        }
        try count.append(gpa, classes);
        pairs += classes;
    }
    return .{
        .gpa = gpa,
        .nstates = ns,
        .kind = kind,
        .rep = try rep.toOwnedSlice(gpa),
        .dense = try dense.toOwnedSlice(gpa),
        .base = base,
        .pairs = pairs,
        .kinds = @intCast(count.items.len),
    };
}

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

const std = @import("std");
const mix = @import("../../../math/mix.zig");
const decoder_mod = @import("decoder.zig");
const determinize = @import("determinize.zig");

const leaf = decoder_mod.leaf;
const SigCtx = mix.SliceCtx(u32);
const SigMap = std.HashMap([]const u32, u32, SigCtx, std.hash_map.default_max_load_percentage);

/// The per-node quotient of the pattern automaton, and the exact pair count that
/// falls out of it.
pub const Horizon = struct {
    gpa: std.mem.Allocator,
    nstates: u32,
    /// `rep[node * nstates + q]` — the state `(node, q)` is indistinguishable
    /// from. Idempotent: `rep[node][rep[node][q]] == rep[node][q]`, because a
    /// class's representative is a member of it.
    rep: []u32,
    /// Distinct pairs the product can reach, summed over nodes. Exact for the
    /// unanchored canon and an upper bound under the anchored one, which folds
    /// `(node, dead)` onto a single absorbing pair.
    pairs: u64,

    pub fn deinit(h: *Horizon) void {
        h.gpa.free(h.rep);
    }

    /// The representative of `q` at `node` — what to intern instead of `q`.
    /// Stepping from a representative yields the same successors as stepping from
    /// any member, which is what makes substituting it a congruence rather than
    /// an approximation.
    pub fn canon(h: *const Horizon, node: u32, q: u32) u32 {
        return h.rep[@as(usize, node) * h.nstates + q];
    }
};

/// Read each decoder node's minterm horizon, then quotient the pattern's states
/// against it. One ascending sweep for the horizons, one signature pass per node
/// for the classes.
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

    const rep = try gpa.alloc(u32, @as(usize, nodes) * ns);
    errdefer gpa.free(rep);

    // One buffer per node's signatures, so the map can key on slices of it: two
    // columns per horizon minterm, and never more than the alphabet is wide.
    const sigs = try gpa.alloc(u32, @as(usize, ns) * 2 * @max(nmt, 1));
    defer gpa.free(sigs);
    var table = SigMap.init(gpa);
    defer table.deinit();
    try table.ensureTotalCapacity(ns);

    const stride = 2 * @max(nmt, 1);
    var pairs: u64 = 0;
    for (0..nodes) |n| {
        const slot = rep[n * ns ..][0..ns];
        if (@as(u32, @intCast(n)) == dec.root) {
            for (slot, 0..) |*r, q| r.* = @intCast(q);
            pairs += ns;
            continue;
        }
        // The signature's width is the horizon's population — a node that can
        // still reach one minterm compares one column, not `nmt` of them — and
        // every state reads the same columns, so it is measured once.
        const mine = seen[n * words ..][0..words];
        var w: usize = 0;
        for (0..nmt) |m| {
            if (mine[m >> 6] & (@as(u64, 1) << @truncate(m)) == 0) continue;
            for (0..ns) |q| {
                sigs[q * stride + w] = aut.trans_in[q * nmt + m];
                sigs[q * stride + w + 1] = aut.trans_fin[q * nmt + m];
            }
            w += 2;
        }
        table.clearRetainingCapacity();
        for (slot, 0..) |*r, q| {
            const sig = sigs[q * stride ..][0..w];
            const gop = table.getOrPutAssumeCapacity(sig);
            if (gop.found_existing) {
                r.* = gop.value_ptr.*;
            } else {
                gop.key_ptr.* = sig;
                gop.value_ptr.* = @intCast(q);
                r.* = @intCast(q);
                pairs += 1;
            }
        }
    }
    return .{ .gpa = gpa, .nstates = ns, .rep = rep, .pairs = pairs };
}

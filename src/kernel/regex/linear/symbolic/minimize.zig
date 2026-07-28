//! gist — collapsing the product back down to the automaton it means.
//!
//! Crossing a UTF-8 decoder with a pattern automaton is exact but redundant:
//! the decoder carries a phase the pattern cannot observe, so `\w+X` lands on
//! ~960 pairs where the byte-trie powerset finds 318. The pairs are not extra
//! *information* — most are indistinguishable — so the size claim ("the same
//! table as today's, discovered for a fraction of the visits") is only true
//! with a minimization pass. The byte path gets this for free: subset
//! construction interns on the NFA-state set, which already quotients the trie.
//!
//! Moore's partition refinement, not Hopcroft's: at these sizes (≤ 4096 states)
//! the O(n²) worst case never materializes and the honest cost is a handful of
//! linear passes, while Hopcroft's splitter queue would double the code for a
//! win nothing here can measure.
//!
//! Two wrinkles the classic algorithm does not have:
//!   * There are TWO transition tables — the interior byte's and the line's
//!     last byte's — so a signature carries both. `trans_fin` targets are
//!     terminal (only their verdict is ever read), so demanding they be fully
//!     equivalent is stricter than necessary: sound, never unsound.
//!   * A state reached only through `trans_fin` has no interior row at all
//!     (`unknown`). It gets its own successor block, which keeps it from
//!     merging with an expanded state — again strictly conservative.

const std = @import("std");
const mix = @import("../../../math/mix.zig");
const subset = @import("../dfa/subset.zig");

const unknown = subset.unknown;
/// The successor block of a transition that was never expanded. Distinct from
/// every real block, and equal to itself — two unfilled rows agree.
const nowhere: u32 = std.math.maxInt(u32);

const SigCtx = mix.SliceCtx(u32);
const SigMap = std.HashMap([]const u32, u32, SigCtx, std.hash_map.default_max_load_percentage);

/// Merge indistinguishable states in place. `map[old] = new` on return, tables
/// and `is_match` are rewritten to the quotient's first `nstates` rows, and the
/// new state count is returned. State 0 stays state 0 — blocks are numbered by
/// first appearance — so the caller's start state needs no special handling
/// beyond reading it out of `map`.
pub fn run(
    gpa: std.mem.Allocator,
    ns: u32,
    ncls: u16,
    tin: []u32,
    tfin: []u32,
    is_match: []bool,
    map: []u32,
) std.mem.Allocator.Error!u32 {
    if (ns == 0) return 0;
    const w: usize = 1 + 2 * @as(usize, ncls); // own block, then both successors per class

    // Signatures live in one flat buffer so the hash map can key on slices of it
    // without duplicating a single one: within a pass, row `s` is written once
    // and read only by the probe that wrote it.
    const sigs = try gpa.alloc(u32, @as(usize, ns) * w);
    defer gpa.free(sigs);
    const next = try gpa.alloc(u32, ns);
    defer gpa.free(next);
    var table = SigMap.init(gpa);
    defer table.deinit();
    try table.ensureTotalCapacity(ns);

    for (map[0..ns], 0..) |*m, s| m.* = @intFromBool(is_match[s]);

    var nb: u32 = 0;
    while (true) {
        table.clearRetainingCapacity();
        var newn: u32 = 0;
        for (0..ns) |s| {
            const sig = sigs[s * w ..][0..w];
            sig[0] = map[s];
            for (0..ncls) |k| {
                sig[1 + 2 * k] = blockOf(map, tin[s * ncls + k]);
                sig[2 + 2 * k] = blockOf(map, tfin[s * ncls + k]);
            }
            const gop = table.getOrPutAssumeCapacity(sig);
            if (gop.found_existing) {
                next[s] = gop.value_ptr.*;
            } else {
                gop.key_ptr.* = sig;
                gop.value_ptr.* = newn;
                next[s] = newn;
                newn += 1;
            }
        }
        @memcpy(map[0..ns], next);
        if (newn == nb) break; // refinement is monotone: equal count ⇒ fixed point
        nb = newn;
    }

    // Compact. Blocks were numbered by first appearance, so the representative
    // of block `b` is the first state mapping to it and is never below `b` —
    // every row is written strictly below the row it reads.
    var b: u32 = 0;
    for (0..ns) |s| {
        if (map[s] != b) continue;
        for (0..ncls) |k| {
            tin[@as(usize, b) * ncls + k] = remap(map, tin[s * ncls + k]);
            tfin[@as(usize, b) * ncls + k] = remap(map, tfin[s * ncls + k]);
        }
        is_match[b] = is_match[s];
        b += 1;
    }
    std.debug.assert(b == nb);
    return nb;
}

fn blockOf(map: []const u32, t: u32) u32 {
    return if (t == unknown) nowhere else map[t];
}

fn remap(map: []const u32, t: u32) u32 {
    return if (t == unknown) unknown else map[t];
}

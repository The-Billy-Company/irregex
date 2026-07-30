//! gist — collapsing a finished determinization down to the automaton it means.
//!
//! A determinizer stops when it runs out of reachable states, and reachable is
//! not the same as *distinguishable*. Both roads overshoot, for different
//! reasons: the symbolic product carries a decoder phase the pattern cannot
//! observe (`\w+X` lands on ~960 pairs where the byte trie finds 318), and the
//! byte powerset interns on the NFA-state SET, which quotients the trie but says
//! nothing about two different sets accepting the same suffixes. Neither road
//! ships the automaton its language actually requires unless something asks.
//!
//! A finished dense table is over-refined in **two dimensions**, and this file
//! owns both because they are one question asked of the two axes:
//!
//!   * **Rows** — two states are indistinguishable when no suffix separates
//!     them. Merging them is Moore's partition refinement: the coarsest
//!     partition below the accept partition that is still closed under δ, which
//!     is the Myhill–Nerode congruence.
//!   * **Columns** — two byte classes are indistinguishable when no state
//!     routes them differently, i.e. their table columns coincide outright.
//!
//! **The order is load-bearing and only runs one way.** Merging states is what
//! makes whole columns coincide — two classes that separated only the states
//! that just merged now route identically — so rows first, then columns.
//! Reversed, both dimensions stay over-refined: column merging can never create
//! a row merge, because it does not change which suffixes distinguish a state.
//! That asymmetry is why this is one operation with a fixed internal order
//! rather than two passes a caller sequences, and it is the whole reason the two
//! halves live in one file.
//!
//! Moore's refinement, not Hopcroft's: at these sizes (≤ 4096 states) the O(n²)
//! worst case never materializes and the honest cost is a handful of linear
//! passes, while Hopcroft's splitter queue would double the code for a win
//! nothing here can measure. rust-`regex-automata` ships Hopcroft and ships it
//! *off* by default, documenting that it costs "an order of magnitude more time
//! than compiling the initial DFA" — so the bar this has to clear is not
//! Hopcroft's asymptotics, it is being cheap enough to leave on.
//!
//! Two wrinkles the classic algorithm does not have:
//!   * There are TWO transition tables — the interior byte's and the line's
//!     last byte's — so a signature carries both. `trans_fin` targets are
//!     terminal (only their verdict is ever read), so demanding they be fully
//!     equivalent is stricter than necessary: sound, never unsound.
//!   * A state reached only through `trans_fin` has no interior row at all
//!     (`unknown`). It gets its own successor block, which keeps it from
//!     merging with an expanded state — again strictly conservative.
//!
//! **What does not belong here, and why it looks like it does.** The sieve's
//! `../sieve/quotient.zig` also computes closed partitions of a finished
//! automaton, which reads like the same engine with a different stopping rule.
//! It is the *dual*, and the two cannot share a core. Both live on the lattice
//! of δ-closed partitions, but Moore **descends** it — start at the accept
//! partition and split until closed, finding the greatest closed partition below
//! accept — while the sieve's SP closure **ascends** it, starting at a single
//! merged pair and unioning until closed, finding the least closed partition
//! above that pair. Opposite direction, opposite extremum, and therefore
//! different machinery: refinement wants a signature hash per pass, closure
//! wants a disjoint-set forest. Worse, the sieve deliberately does *not* respect
//! the accept partition — merging an accepting state with a rejecting one is
//! precisely what makes its quotient over-approximate. A shared core would be an
//! enum switch over two disjoint loops that agree on a predicate and nothing
//! else. The membership rule this folder is built on asks what a file answers,
//! and "the coarsest exact automaton" and "a sound crude one" are two answers.

const std = @import("std");
const mix = @import("../../../math/mix.zig");
const subset = @import("../dfa/subset.zig");
const freeze = @import("freeze.zig");

const unknown = subset.unknown;
/// The successor block of a transition that was never expanded. Distinct from
/// every real block, and equal to itself — two unfilled rows agree.
const nowhere: u32 = std.math.maxInt(u32);

const SigCtx = mix.SliceCtx(u32);
const SigMap = std.HashMap([]const u32, u32, SigCtx, std.hash_map.default_max_load_percentage);

/// The dimensions a reduction landed on. Compare against what went in and the
/// two deltas are the two dimensions' collapses, separately attributable.
pub const Extent = struct { nstates: u32, ncls: u16 };

/// The two tables and the byte-class partition `run` operates on, and the
/// sentinel for a transition that was never expanded. Re-exported because a caller
/// cannot call `run` without holding these or recognizing that, and reaching
/// around a module for the type of its own parameter is how a seal springs a leak.
/// `Tables` is `freeze`'s: the same struct flows through a reduction and then into
/// the automaton it becomes.
pub const Tables = freeze.Tables;
pub const Classes = subset.Classes;
pub const unexpanded = unknown;

/// Which dimensions to quotient.
///
/// Not a tuning knob — the two dimensions answer to different roads. The symbolic
/// product is redundant in its ROWS (a decoder phase the pattern cannot observe),
/// and collapsing those rows is what makes its columns coincide, so it needs
/// `both`. A byte powerset construction has already quotiented its rows by
/// interning on the NFA-state set, but its byte classes were refined once per
/// consuming state's set — before any of them had a column to compare — so it can
/// be over-refined in COLUMNS while exactly minimal in rows. `columns` is that
/// case: it skips a refinement that has been measured to find nothing there and
/// keeps the one that finds a 4.5x table.
pub const Plan = enum { both, columns };

/// Quotient a finished determinization in place, or decline.
///
/// `map[old] = new` on return, the tables are rewritten to the quotient's first
/// `nstates` rows and shrunk to their new extent, and `cls` is re-partitioned to
/// the surviving columns. State 0 stays state 0 — blocks are numbered by first
/// appearance — so a caller's start state needs no special handling beyond
/// reading it out of `map`.
///
/// Declines (leaving everything untouched) on a word-context automaton: its
/// interior transition splits on a second axis, the next byte's word-ness, and a
/// signature over two tables does not model a third. That is a soundness
/// precondition rather than a cost policy, which is why it is checked here next
/// to the algorithm that needs it rather than trusted to each caller.
///
/// `map.len` must be at least `nstates`. Runs BEFORE `freeze.freeze`: this
/// renumbers states and merges columns, so every id and stride a caller holds
/// changes, and premultiplied values would be meaningless to refine.
pub fn run(
    gpa: std.mem.Allocator,
    cls: *subset.Classes,
    t: freeze.Tables,
    nstates: u32,
    map: []u32,
    plan: Plan,
) std.mem.Allocator.Error!?Extent {
    if (t.interior_word != null) return null;
    var ns = nstates;
    if (plan == .both) {
        ns = try states(gpa, nstates, cls.ncls, t.interior.items, t.final.items, t.is_match, map);
        t.interior.shrinkRetainingCapacity(@as(usize, ns) * cls.ncls);
        t.final.shrinkRetainingCapacity(@as(usize, ns) * cls.ncls);
    } else for (map[0..nstates], 0..) |*m, s| m.* = @intCast(s);

    const ncls = try classes(gpa, cls, ns, t.interior.items, t.final.items);
    t.interior.shrinkRetainingCapacity(@as(usize, ns) * ncls);
    t.final.shrinkRetainingCapacity(@as(usize, ns) * ncls);
    return .{ .nstates = ns, .ncls = ncls };
}

/// Merge indistinguishable states in place, returning the new state count.
/// Moore's refinement: partition by accept status, then repeatedly re-partition
/// by (own block, successors' blocks) until the block count stops falling.
fn states(
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

/// Merge byte classes whose table columns coincide, returning the new class
/// count — the over-refinement class construction accepts for soundness, paid
/// back once the columns exist to compare. Hash each column once so the
/// O(ncls²) pairwise confirmation only runs on collisions; the confirmation is
/// exact, so a hash collision costs a compare and never a wrong answer.
fn classes(
    gpa: std.mem.Allocator,
    cls: *subset.Classes,
    ns: u32,
    tin: []u32,
    tfin: []u32,
) std.mem.Allocator.Error!u16 {
    const ncls = cls.ncls;
    var col = try gpa.alloc(u64, ncls);
    defer gpa.free(col);
    for (0..ncls) |k| {
        var h = std.hash.Wyhash.init(0);
        for (0..ns) |s| {
            h.update(std.mem.asBytes(&tin[s * ncls + k]));
            h.update(std.mem.asBytes(&tfin[s * ncls + k]));
        }
        col[k] = h.final();
    }
    var remap_col = try gpa.alloc(u16, ncls);
    defer gpa.free(remap_col);
    var newn: u16 = 0;
    for (0..ncls) |k| {
        remap_col[k] = newn;
        for (0..k) |j| if (col[j] == col[k] and sameColumn(ncls, ns, tin, tfin, @intCast(j), @intCast(k))) {
            remap_col[k] = remap_col[j];
            break;
        };
        if (remap_col[k] == newn) newn += 1;
    }
    if (newn == ncls) return ncls;
    for (0..ns) |s| for (0..ncls) |k| {
        tin[s * newn + remap_col[k]] = tin[s * ncls + k];
        tfin[s * newn + remap_col[k]] = tfin[s * ncls + k];
    };
    for (0..256) |bi| cls.class[bi] = @intCast(remap_col[cls.class[bi]]);
    for (0..256) |bi| cls.rep[cls.class[bi]] = @intCast(bi);
    cls.ncls = newn;
    return newn;
}

fn sameColumn(ncls: u16, ns: u32, tin: []const u32, tfin: []const u32, j: u16, k: u16) bool {
    for (0..ns) |s| {
        if (tin[s * ncls + j] != tin[s * ncls + k]) return false;
        if (tfin[s * ncls + j] != tfin[s * ncls + k]) return false;
    }
    return true;
}

fn blockOf(map: []const u32, t: u32) u32 {
    return if (t == unknown) nowhere else map[t];
}

fn remap(map: []const u32, t: u32) u32 {
    return if (t == unknown) unknown else map[t];
}

//! irregex — collapsing a finished determinization down to the automaton it
//! means.
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
//! **The row half is not implemented here.** It is `../../../math/refine.zig`
//! called with `.moore` — the coarsest stable partition of a labeled transition
//! table, which is what Myhill–Nerode asks for once "the color" is fixed to be
//! accept-vs-reject.
//!
//! Moore and not `.auto`, and that is a measurement rather than a preference.
//! Moore's price is `O(depth · states · classes)`, and a symbolic product that
//! merges NOTHING still spends a dozen passes proving it — exactly the unknown
//! distinguishing depth `.auto` exists to insure against. But at this scale the
//! insurance costs more than the risk, and the whole lowering slate now says so
//! rather than one pattern:
//!
//!   * Small, where Hopcroft's inverse dominates: 89 states **45 µs Moore vs
//!     77 µs auto**, 104 states 62 vs 104, 133 states 88 vs 119.
//!   * Large, where its `n log n` was supposed to pay: 1265 states 914 vs 930,
//!     1897 states 1802 vs 1735. A wash — inside run-to-run spread.
//!
//! So there is no crossover to find here, only a floor to lose. Both engines are
//! streaming a `states × axes·classes` table and both are bound by that, which is
//! why the algorithm choice stops mattering above a few hundred states and only
//! Hopcroft's setup is left to distinguish them. Both return the same numbering,
//! so this is a pure time choice nothing downstream can observe. Re-measure
//! before flipping it; the numbers to beat are the lowering rung's.
//!
//! Which also says where the next win is not: it is not in this engine, it is in
//! the **width of the signature** handed to it. A symbolic product row is
//! `axes · classes` wide, and all but a handful of its columns are the shared
//! resync row every state at that node carries — so the information in a row is
//! its node's live edges, about six of ninety-six. Refining on those alone would
//! be a twentyfold narrower table, and it is not done here because it is not the
//! same partition: two nodes with different live sets whose live targets coincide
//! with the resync ones have identical rows today and would stop merging. Finer
//! is sound and it is still a different automaton, so it owes its own
//! differentials rather than riding along inside a cost change.
//!
//! What this file still owns about the rows is the two shapes the classic
//! algorithm does not have:
//!   * There is more than one transition table — the interior byte's, the line's
//!     last byte's, and for a word-context program the interior byte's again
//!     under a following word byte — which is ONE transition function over that
//!     many copies of the alphabet, and the conversion is right here. A
//!     line-final target is terminal (only its verdict is ever read), so
//!     demanding those be fully equivalent is stricter than necessary: sound,
//!     never unsound. The word axis is not terminal and carries no slack — two
//!     states agreeing on every interior byte still differ if the byte after
//!     them being a word byte routes them apart, which is exactly the
//!     distinction `\b` exists to draw.
//!   * A state reached only through a line-final byte has no interior row at all
//!     (`unknown`). The floor treats a missing transition as a distinct sink, so
//!     it never merges with an expanded state — again strictly conservative.
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
const refine = @import("../../../math/refine.zig");
const subset = @import("../dfa/subset.zig");
const freeze = @import("freeze.zig");

const unknown = subset.unknown;

comptime {
    // The row question is delegated to the math floor, which spells the sentinel
    // its own way. They are the same value, and the delegation is only sound
    // while they are: an unexpanded transition has to read as the floor's
    // distinct sink rather than as a state id.
    std.debug.assert(unknown == refine.nowhere);
}

/// The dimensions a reduction landed on. Compare against what went in and the
/// two deltas are the two dimensions' collapses, separately attributable.
pub const Extent = struct { nstates: u32, ncls: u16 };

/// The transition tables and the byte-class partition `run` operates on, and the
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

/// How many successor axes a reduction can be asked about at once: the interior
/// byte's table, the line-final byte's, and — for a word-context program — the
/// interior byte's again under a following word byte. Every axis in `Tables` is
/// one, and `run` asserts as much rather than trusting the count.
const max_axes = 3;

/// Quotient a finished determinization in place.
///
/// `map[old] = new` on return, the tables are rewritten to the quotient's first
/// `nstates` rows and shrunk to their new extent, and `cls` is re-partitioned to
/// the surviving columns. State 0 stays state 0 — blocks are numbered by first
/// appearance — so a caller's start state needs no special handling beyond
/// reading it out of `map`.
///
/// Every axis a `Tables` can carry is refined, including the word one, so a
/// word-context program is reduced rather than declined. It cannot answer
/// partially: an axis this file did not know about would be a transition
/// function it merged states across without reading, and the way to keep that
/// impossible is for `Tables` to be the enumeration and for the two to be
/// checked against each other here.
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
) std.mem.Allocator.Error!Extent {
    comptime {
        // Three transition fields plus `is_match` and `pats`, which are per-state
        // and not successor axes. A fourth table added to `Tables` lands here as a
        // compile error rather than as a silently unrefined dimension.
        std.debug.assert(@typeInfo(freeze.Tables).@"struct".fields.len == max_axes + 2);
    }
    var lists: [max_axes]*std.ArrayList(u32) = undefined;
    var n: usize = 0;
    for ([_]?*std.ArrayList(u32){ t.interior, t.final, t.interior_word }) |maybe| {
        if (maybe) |list| {
            lists[n] = list;
            n += 1;
        }
    }
    const present = lists[0..n];
    var held: [max_axes][]u32 = undefined;
    const axes = held[0..n];
    for (present, axes) |list, *a| a.* = list.items;

    var ns = nstates;
    if (plan == .both) {
        ns = try rows(gpa, nstates, cls.ncls, axes, t.is_match, map);
    } else for (map[0..nstates], 0..) |*m, s| m.* = @intCast(s);

    // Every axis is the same shape, so one extent shrinks all of them — twice,
    // because merging rows and merging columns each move the stride.
    shrink(present, axes, @as(usize, ns) * cls.ncls);
    const ncls = try classes(gpa, cls, ns, axes);
    shrink(present, axes, @as(usize, ns) * ncls);
    return .{ .nstates = ns, .ncls = ncls };
}

/// Truncate every axis to `len` and refresh the caller's slices in place — a
/// shrink invalidates the ones it was holding.
fn shrink(present: []const *std.ArrayList(u32), axes: [][]u32, len: usize) void {
    for (present, axes) |list, *a| {
        list.shrinkRetainingCapacity(len);
        a.* = list.items;
    }
}

/// Merge indistinguishable states in place, returning the new state count — the
/// math floor's partition refinement, seeded by accept status, over every
/// successor axis read as one transition function.
///
/// Public because the row question is asked of two very different tables and the
/// second one is where it pays. `run` asks it of a finished BYTE table, thousands
/// of states over ~100 classes. The symbolic road asks it of the **codepoint
/// automaton** instead — `determinize.minimize` —
/// which is the same question on the small factor: a dozen states over a dozen
/// minterms, hundreds of times cheaper, and answering it there is what lets
/// `horizon.zig`'s one-step quotient be exact rather than approximate. A
/// determinizer interns on the NFA-state SET, and two different sets routinely
/// accept the same suffixes; left unmerged, each surviving twin multiplies
/// through every decoder node in the product.
///
/// Takes plain slices rather than `Tables` for exactly that reason: the
/// codepoint automaton is not a byte table and never becomes one. Every axis is
/// `ns * ncls` and they are all read as successors of the same states, so how
/// many there are is the caller's business and never this function's.
pub fn rows(
    gpa: std.mem.Allocator,
    ns: u32,
    ncls: u16,
    axes: []const []u32,
    is_match: []bool,
    map: []u32,
) std.mem.Allocator.Error!u32 {
    if (ns == 0) return 0;

    // The axes are one transition function over that many copies of the
    // alphabet: the interior byte's classes, then the line's last byte's, then
    // the word one if there is one. `refine` wants it dense and contiguous, and
    // this is the only place any of them is copied anywhere — every pass
    // afterwards reads this one buffer.
    //
    // Laid out axis-major within each state rather than interleaved because that
    // makes each state one `memcpy` per axis. Symbol ORDER cannot matter: blocks
    // are numbered by first appearance in STATE order, so any permutation of the
    // alphabet returns the identical partition.
    const syms: usize = axes.len * @as(usize, ncls);
    const delta = try gpa.alloc(u32, @as(usize, ns) * syms);
    defer gpa.free(delta);
    const color = try gpa.alloc(u32, ns);
    defer gpa.free(color);
    for (0..ns) |s| {
        for (axes, 0..) |t, i| {
            @memcpy(delta[s * syms + i * ncls ..][0..ncls], t[s * ncls ..][0..ncls]);
        }
        color[s] = @intFromBool(is_match[s]);
    }

    const got = try refine.refine(gpa, .{
        .states = ns,
        .symbols = @intCast(syms),
        .delta = delta,
    }, color, map, .moore);
    // Discrete already: nothing merged, and `refine` numbers blocks by first
    // appearance, which over `ns` distinct blocks IS the identity map. Worth its
    // own exit because "nothing merged" is the common case once the codepoint
    // automaton is minimal and the horizon has pre-quotiented the product.
    if (got.blocks == ns) return ns;

    // Compact. Blocks are numbered by first appearance, so the representative of
    // block `b` is the first state mapping to it and is never below `b` — every
    // row is written strictly below the row it reads.
    var b: u32 = 0;
    for (0..ns) |s| {
        if (map[s] != b) continue;
        for (axes) |t| {
            for (0..ncls) |k| t[@as(usize, b) * ncls + k] = remap(map, t[s * ncls + k]);
        }
        is_match[b] = is_match[s];
        b += 1;
    }
    std.debug.assert(b == got.blocks);
    return got.blocks;
}

/// Merge byte classes whose table columns coincide, returning the new class
/// count — the over-refinement class construction accepts for soundness, paid
/// back once the columns exist to compare.
///
/// **Both passes below read the table ROW-major, and that is the whole
/// performance story of this file.** A column question over a
/// `[state * ncls + class]` table invites walking one column at a time, which
/// touches a fresh cache line per element: on the symbolic product of
/// `(\w)(\w)(\w)(\w)` — 1265 states × 96 classes × two tables — that is ~243 K
/// line-sized strides, and it measured **~700 µs of a 900 µs reduction**, more
/// than the entire product walk that built the table. Carrying one accumulator
/// per column instead, and streaming the table in the order it is laid out,
/// turns the same work into a linear sweep of ~1 MB. Nothing about the answer
/// changes; do not "simplify" either loop back to column-at-a-time.
///
/// The rolling fold replaces a per-column Wyhash for the same reason — a
/// sequential hasher wants its bytes in column order, which is exactly the order
/// that is expensive. It is a filter, not the verdict: content equality implies
/// hash equality, so a group is a superset of an equivalence class, and the
/// row-major confirmation sweep below is what turns it back into one. Should the
/// sweep ever catch a 64-bit collision it hands the whole question to the
/// exhaustive pairwise pass, which is the definition being approximated — so the
/// partition, and therefore the table, does not depend on the hash at all.
fn classes(
    gpa: std.mem.Allocator,
    cls: *subset.Classes,
    ns: u32,
    axes: []const []u32,
) std.mem.Allocator.Error!u16 {
    const ncls = cls.ncls;
    const col = try gpa.alloc(u64, ncls);
    defer gpa.free(col);
    @memset(col, 0);
    for (0..ns) |s| {
        for (axes) |t| {
            for (col, t[s * ncls ..][0..ncls]) |*h, v| h.* = (h.* ^ v) *% mix.odd;
        }
    }

    // `twin[k]` is the lowest class whose hash k shares — the smallest set k's
    // equivalence class can be hiding in. Quadratic in the class count, which is
    // ≤ 256 and compared register-to-register.
    const twin = try gpa.alloc(u16, ncls);
    defer gpa.free(twin);
    for (0..ncls) |k| {
        twin[k] = @intCast(k);
        for (0..k) |j| if (col[j] == col[k]) {
            twin[k] = twin[j];
            break;
        };
    }
    // Confirm every candidate against the real bytes in one row-major sweep.
    var collided = false;
    sweep: for (0..ns) |s| {
        for (axes) |t| {
            const r = t[s * ncls ..][0..ncls];
            for (twin, 0..) |tw, k| {
                if (tw == k) continue;
                if (r[k] != r[tw]) {
                    collided = true;
                    break :sweep;
                }
            }
        }
    }
    if (collided) exact(ncls, ns, axes, twin);

    const remap_col = try gpa.alloc(u16, ncls);
    defer gpa.free(remap_col);
    var newn: u16 = 0;
    // `twin[k] <= k` by construction, so one forward pass resolves every group.
    for (0..ncls) |k| {
        if (twin[k] == k) {
            remap_col[k] = newn;
            newn += 1;
        } else remap_col[k] = remap_col[twin[k]];
    }
    if (newn == ncls) return ncls;
    for (axes) |t| {
        for (0..ns) |s| for (0..ncls) |k| {
            t[s * newn + remap_col[k]] = t[s * ncls + k];
        };
    }
    for (0..256) |bi| cls.class[bi] = @intCast(remap_col[cls.class[bi]]);
    for (0..256) |bi| cls.rep[cls.class[bi]] = @intCast(bi);
    cls.ncls = newn;
    return newn;
}

/// The partition `classes` computes by hash, computed by definition instead:
/// every class against every lower one, column by column. Reached only when the
/// fold's confirmation sweep caught a hash collision, which is to say never
/// observed — it exists so the answer is defined by equality rather than by a
/// multiplier. Column equality is transitive, so pairing `k` with the first
/// equal `j` and inheriting `twin[j]` numbers each class by its lowest member.
fn exact(ncls: u16, ns: u32, axes: []const []u32, twin: []u16) void {
    for (0..ncls) |k| {
        twin[k] = @intCast(k);
        for (0..k) |j| {
            if (same(ncls, ns, axes, j, k)) {
                twin[k] = twin[j];
                break;
            }
        }
    }
}

/// Do columns `j` and `k` coincide on every state, on every axis?
fn same(ncls: u16, ns: u32, axes: []const []u32, j: usize, k: usize) bool {
    for (axes) |t| {
        var s: usize = 0;
        while (s < ns) : (s += 1) {
            const r = s * ncls;
            if (t[r + j] != t[r + k]) return false;
        }
    }
    return true;
}

fn remap(map: []const u32, t: u32) u32 {
    return if (t == unknown) unknown else map[t];
}

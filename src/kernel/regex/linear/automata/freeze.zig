//! gist — freezing a finished determinization into the immutable `Dfa`.
//!
//! Two determinizers reach this point by different roads: the byte powerset
//! construction (`../dfa/powerset.zig`) and the symbolic path's decoder product
//! (`../symbolic/transcribe.zig`). What they hand over is the same thing — dense
//! id-indexed transition tables, a match flag per state, and the three
//! distinguished ids — and what has to happen next is the same too. It used to
//! happen twice, once per road, which meant every layout invariant had two
//! chances to be established and one chance to be forgotten.
//!
//! Which is why this file sits in `automata/` rather than in either road. It
//! belongs to neither and serves both; parked under `dfa/` it read like a byte-
//! path detail that `symbolic/` was reaching across a boundary to borrow. See
//! this folder's README for the membership rule.
//!
//! The layout tricks only a *finished* automaton admits, in the order they must
//! run:
//!   1. **Match-first renumbering** — so `is_match` collapses into a bound.
//!   2. **The start state's dwell** — read off the start row, which needs state
//!      identity, so it must precede premultiplication (`dwell.zig`).
//!   3. **Premultiplication** — every state value becomes its row offset.
//!
//! Freezing is the LAST operation on a determinization. Step 1 renumbers states,
//! so any subset map the caller still holds stops agreeing with these ids the
//! moment it returns; callers must be done interning.

const std = @import("std");
const subset = @import("../dfa/subset.zig");
const dwell = @import("dwell.zig");
const Dfa = @import("../dfa/dfa.zig").Dfa;
const unknown = subset.unknown;

/// The mutable tables a determinizer finished with, permuted and premultiplied in
/// place and then handed to the automaton. `interior_word` exists only for
/// word-context programs, whose interior table splits on the next byte's
/// word-ness. `is_match` is id-indexed and consumed here — the frozen automaton
/// carries the partition instead of the array.
pub const Tables = struct {
    interior: *std.ArrayList(u32),
    interior_word: ?*std.ArrayList(u32) = null,
    final: *std.ArrayList(u32),
    is_match: []bool,
};

/// Everything about the automaton that is not a transition: how many states, the
/// three distinguished ids (all id-based on the way in, premultiplied on the way
/// out), and the semantic flags the scan loops read.
pub const Shape = struct {
    nstates: u32,
    start: u32,
    /// The word-context start (first byte a word byte). Equal to `start` when
    /// `word_ctx` is false, where nothing reads it.
    start_word: u32,
    /// `unknown` when the non-matching sink was never reached.
    dead: u32,
    empty_match: bool,
    anchored: bool,
    word_ctx: bool = false,
    unicode_word: bool = false,
    /// NFA-state visits the determinization charged (`Subset.visits`) — what the
    /// automaton COST to discover, carried on the automaton itself.
    ///
    /// The eager driver already budgets on this number; until now it was the only
    /// thing that could see it, so everyone else had to infer closure width from
    /// the decline it caused. Divided by `nstates * ncls` it gives mean closure
    /// width, which is the difference between a wide NFA whose closures are narrow
    /// (where clearing scratch per step is waste) and one whose closures are as
    /// wide as it is (where clearing in bulk is already the right algorithm).
    /// Defaulted so the symbolic road, which counts its work differently, need not
    /// pretend to a number it does not have.
    visits: u64 = 0,
};

/// Renumber states so every match state precedes every non-match one, and report
/// how many match states there are. The frozen automaton then answers "did we
/// match?" with `s < match_hi` — one unsigned compare on a value already in a
/// register — where the `is_match[s]` it replaces was a second dependent load on
/// the byte after the transition load that produced `s`, into an array that was
/// `ncls`-sparse by construction (one live byte per row) and therefore mostly
/// padding in cache.
///
/// rust-`regex`-`automata` reaches the same compare by shuffling its *special*
/// states — dead, quit, match, accelerated, start — into a contiguous prefix and
/// testing `id <= special.max` (`dfa/special.rs`). It needs a power-of-two stride
/// to recover an index from a premultiplied id, and pays for that padding in
/// every row of every table. We need neither: premultiplication is monotone in
/// the id, so a contiguous id range is a contiguous offset range at ANY stride,
/// and one bound suffices because the low end is zero.
///
/// The renumbering is an isomorphism — rows move with their state and every
/// target is rewritten — so nothing downstream that reasons about the automaton
/// as a graph can observe it. Stable inside each group, so the discovery order,
/// and the locality the determinizer's own traversal gave it, survives.
fn sortMatchFirst(gpa: std.mem.Allocator, ncls: u16, t: Tables, sh: *Shape) std.mem.Allocator.Error!u32 {
    const n: usize = sh.nstates;

    // `old_of[new] = old` in one stable pass per group, which also yields the
    // match count as the boundary between them.
    const old_of = try gpa.alloc(u32, n);
    defer gpa.free(old_of);
    var next: u32 = 0;
    for (t.is_match[0..n], 0..) |m, id| if (m) {
        old_of[next] = @intCast(id);
        next += 1;
    };
    const nmatch = next;
    for (t.is_match[0..n], 0..) |m, id| if (!m) {
        old_of[next] = @intCast(id);
        next += 1;
    };
    if (nmatch == 0 or nmatch == n) return nmatch; // already partitioned; no rows to move

    const new_of = try gpa.alloc(u32, n);
    defer gpa.free(new_of);
    for (old_of, 0..) |old, new| new_of[old] = @intCast(new);

    // Rewrite targets first, while ids still mean what the tables say. `unknown`
    // rows belong to states no interior byte reaches; they are never indexed, so
    // the sentinel passes through untouched.
    for (tableList(t)) |items| {
        for (items) |*v| if (v.* != unknown) {
            v.* = new_of[v.*];
        };
    }

    // Then move the rows themselves. Cycle-following keeps the scratch at one row
    // rather than a whole second copy of every table, and walking all three
    // tables inside one cycle pass amortizes the bookkeeping across them.
    const moved = try gpa.alloc(bool, n);
    defer gpa.free(moved);
    @memset(moved, false);
    const tmp = try gpa.alloc(u32, ncls);
    defer gpa.free(tmp);
    for (0..n) |head| {
        if (moved[head]) continue;
        for (tableList(t)) |items| {
            if (items.len == 0) continue; // absent table (no word-context split)
            const row = @as(usize, ncls);
            @memcpy(tmp, items[head * row ..][0..row]);
            var cur = head;
            while (true) {
                const src = old_of[cur];
                if (src == head) {
                    @memcpy(items[cur * row ..][0..row], tmp);
                    break;
                }
                @memcpy(items[cur * row ..][0..row], items[@as(usize, src) * row ..][0..row]);
                cur = src;
            }
        }
        var cur = head;
        while (!moved[cur]) {
            moved[cur] = true;
            cur = old_of[cur];
        }
    }

    // The flags are now their own sort key, which is the whole point.
    @memset(t.is_match[0..nmatch], true);
    @memset(t.is_match[nmatch..n], false);

    sh.start = new_of[sh.start];
    sh.start_word = new_of[sh.start_word];
    if (sh.dead != unknown) sh.dead = new_of[sh.dead];
    return nmatch;
}

/// The tables that actually exist, so every layout pass writes one loop instead
/// of one loop per table plus a null check.
fn tableList(t: Tables) [3][]u32 {
    return .{
        t.interior.items,
        t.final.items,
        if (t.interior_word) |w| w.items else &.{},
    };
}

/// Freeze the finished tables into the immutable, thread-shareable automaton,
/// taking ownership of their memory. `cls` is the final byte-class partition —
/// final in the strong sense: the symbolic path merges columns before it gets
/// here, and merging after this point would invalidate every premultiplied
/// offset.
pub fn freeze(
    gpa: std.mem.Allocator,
    cls: *const subset.Classes,
    t: Tables,
    shape: Shape,
) std.mem.Allocator.Error!*Dfa {
    var sh = shape;
    const ncls = cls.ncls;
    const nmatch = try sortMatchFirst(gpa, ncls, t, &sh);

    // The start state's skippable dwell: the bytes that can't contribute to a
    // match are the ones the scanner may SIMD-skip past. Read off one row of state
    // identities, so it has to precede premultiplication. Word-context programs
    // forgo it — their split start and doubled interior table don't fit the shape
    // it models, an optimization rather than a correctness lever.
    const start_dwell = if (sh.word_ctx) null else dwell.ofStart(
        sh.anchored,
        sh.empty_match,
        t.interior.items,
        t.final.items,
        t.is_match,
        &cls.class,
        ncls,
        sh.start,
    );

    // Premultiply (rust-regex / RE2 dense-DFA trick): rewrite every state value
    // to its row offset `id*ncls`, so the hot loop's per-byte index collapses
    // from a loop-carried `madd(s, ncls, class)` to a fold-into-addressing
    // `s + class[b]` — one fewer instruction on the latency-bound transition
    // recurrence. Targets no interior byte reaches keep their `unknown`
    // sentinel (their row is never indexed), so skip those rather than
    // overflowing the multiply.
    const nc: u32 = ncls;
    for (tableList(t)) |items| {
        for (items) |*v| if (v.* != unknown) {
            v.* *= nc;
        };
    }

    const dfa = try gpa.create(Dfa);
    errdefer gpa.destroy(dfa);
    dfa.* = .{
        .class = cls.class,
        .ncls = ncls,
        .nstates = sh.nstates,
        .trans_in = try t.interior.toOwnedSlice(gpa),
        .trans_fin = try t.final.toOwnedSlice(gpa),
        .match_hi = nmatch * nc,
        .start = sh.start * nc,
        .empty_match = sh.empty_match,
        .anchored = sh.anchored,
        .dead = if (sh.dead == unknown) unknown else sh.dead * nc,
        .start_dwell = start_dwell,
        .word_ctx = sh.word_ctx,
        .unicode_word = sh.unicode_word,
        .trans_in_w = if (t.interior_word) |w| try w.toOwnedSlice(gpa) else &.{},
        .start_w = sh.start_word * nc,
        .visits = sh.visits,
        .allocator = gpa,
    };
    return dfa;
}

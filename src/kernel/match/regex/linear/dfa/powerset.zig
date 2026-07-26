//! gist — the EAGER driver of the subset construction: determinizes the Thompson
//! NFA in `syntax.zig` to fixpoint at compile time and freezes the result into the
//! immutable byte-class `Dfa` (`dfa.zig`), which is scratch-free and freely shared
//! across threads.
//!
//! The construction itself — byte classes, the assertion-resolving epsilon-closure,
//! the transition step, subset interning — lives in `subset.zig` and is shared with
//! the on-demand driver in `lazy.zig`, so the two can never disagree about what a
//! pattern means. What this file owns is the *policy*: walk a worklist until no new
//! state appears, then apply the layout tricks that only a finished automaton
//! admits.
//!
//! Eager-only optimizations applied here:
//!   * **Line anchors** — `lineMatch` runs on a single line, so the only boundaries
//!     are BOL (before byte 0) and EOL (after the last byte). `^` is resolved once
//!     in the start state (`at_start=true`); `$` is resolved by a separate **final**
//!     transition table closed with `at_end=true` — the single-line analogue of
//!     RE2's one-byte match delay / EOI sentinel.
//!   * **Start-state acceleration** — derived from the finished start row.
//!   * **Premultiplication** — every state value rewritten to its row offset.
//!
//! Blow-up is bounded on ONE axis: `max_visits`, the NFA-state visits the walk is
//! allowed to charge. Size alone is the wrong bound — `\w+X` determinizes to just
//! 332 states, yet every one of its closures runs over the ~10³-state UTF-8 trie
//! that Unicode `\w` (137,936 codepoints in 748 ranges) lowers to, so an
//! unbudgeted eager walk spends ~15 ms discovering a small automaton. Counting
//! visits prices that directly, and bounds size as a consequence.
//!
//! Declining is a cost decision with no semantic content: `../program/lower.zig`
//! hands the pattern to `lazy.zig`, which determinizes the same automaton one
//! visited state at a time, and the Pike VM stands behind both as the oracle.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const subset = @import("subset.zig");
const State = syn.State;
const Dfa = @import("dfa.zig").Dfa;
const unknown = subset.unknown;

/// Effort cap for the eager build, in NFA-state visits (`Subset.visits`) — the
/// unit that actually costs time, since one closure's price is the size of the
/// subset it walks, not the fact that it happened. Anything hungrier belongs to
/// `lazy.zig`, which pays only for the states a haystack visits.
///
/// This is deliberately the ONLY bound. A state cap paired with an effort cap is
/// redundant by arithmetic — visits grow at least as fast as states × classes, so
/// the effort ceiling is always crossed first and the state ceiling is unreachable
/// dead code. Memory follows for free: the table cannot outgrow what the visits
/// that filled it were allowed to pay for.
///
/// Calibrated, not chosen: a visit costs ~2-3 ns, holding an eager build near two
/// milliseconds. Both arms of the trade were measured. Raising the cap hands more
/// patterns to this driver, which beat the on-demand one by 1.36-1.56x on scans no
/// prefilter can skip (`[A-Z][a-z]+ [A-Z][a-z]+`, `a.*b.*c`, `\d+\.\d+\.\d+\.\d+`)
/// and merely tied everywhere a skip carries the search. Raising it also taxes
/// every pattern that ends up declining, whose eager attempt is speculative work
/// thrown away at the cap. So the cap is set to the smallest round value admitting
/// every pattern measured to *benefit* (the largest was 549,396 visits); past that
/// it buys nothing and still charges. Re-derive by sweeping it against a scan-bound
/// and a compile-bound pattern set — the optimum is a broad, flat minimum.
pub const max_visits: u64 = 750_000;

/// Why the eager driver produced no automaton.
pub const Decline = enum {
    /// Not determinizable this way at all: a buffer anchor (`\A`/`\z`) means
    /// multiline, where position flags are content-dependent.
    unsupported,
    /// Over `max_visits`. A cost verdict with no semantic content — `lazy.zig`
    /// builds the same automaton on demand, and the Pike VM stands behind both.
    ///
    /// There is deliberately no second budget arm here. Splitting the decline into
    /// "too large ⇒ Pike VM" and "too costly ⇒ lazy" was tried and measured wrong
    /// on both counts: the arms were not reachable independently, and the
    /// alternations the split existed to keep on the Pike VM were losing to it for
    /// an unrelated reason — the on-demand driver had no start-state acceleration.
    /// Giving it one (`Lazy.accel`) beat the Pike VM outright, so nothing needs
    /// routing away from the DFA.
    too_costly,
};

/// An eager build either produced the automaton or declined for a reason the
/// caller must see.
pub const Outcome = union(enum) {
    built: *Dfa,
    declined: Decline,
};

/// The eager driver's expansion frontier. State ids are dense and handed out in
/// order, so `queued` grows one slot per interned state and needs no map.
const Worklist = struct {
    gpa: std.mem.Allocator,
    queued: std.ArrayList(bool) = .empty,
    items: std.ArrayList(u32) = .empty,

    fn deinit(w: *Worklist) void {
        w.queued.deinit(w.gpa);
        w.items.deinit(w.gpa);
    }

    /// Enqueue `id` for expansion unless it is already spoken for. Takes the
    /// determinizer rather than a state count so the frontier is sized against
    /// `nstates` as it stands *after* the caller's `expand` — reading that count
    /// into an argument alongside the `expand` that grows it would evaluate it one
    /// state too early.
    fn push(w: *Worklist, sub: *const subset.Subset, id: u32) std.mem.Allocator.Error!void {
        while (w.queued.items.len < sub.nstates) try w.queued.append(w.gpa, false);
        if (w.queued.items[id]) return;
        w.queued.items[id] = true;
        try w.items.append(w.gpa, id);
    }
};

/// Determinize the Thompson NFA (`states`, entry `start`) into an immutable
/// byte-class DFA, or decline — the walk exceeds `max_visits`, or the program
/// carries a buffer anchor (multiline, where no DFA is built). `anchored` mirrors
/// `analysis.startsAnchored`: every match begins at line start, so we never re-seed.
pub fn build(gpa: std.mem.Allocator, states: []const State, start: u32, anchored: bool, unicode: bool) std.mem.Allocator.Error!Outcome {
    // Buffer anchors (`\A`/`\z`) exist only under multiline, where no DFA is built
    // at all — decline before interning so `close` never meets one.
    if (subset.hasBufferAnchor(states)) return .{ .declined = .unsupported };
    // Word-boundary assertions (`\b`/`\B`, one-sided `\<`/`\>`) gate on the
    // word-ness of the bytes straddling a gap — a second determinization axis.
    // We resolve it as a look-AHEAD-selected transition (see `Dfa`): classes are
    // refined by word-ness so the just-consumed byte fixes `word_before`, and the
    // interior table is doubled on the next byte's word-ness.
    const word_ctx = subset.hasWordContext(states);
    const cls = subset.Classes.build(states, word_ctx);
    const ncls = cls.ncls;

    var sub = try subset.Subset.init(gpa, states, start, anchored, word_ctx, cls);
    // The determinizer's scratch + subset map are discarded once the immutable
    // tables are sliced out (or on a bail). On success `toOwnedSlice` empties the
    // table lists, so their deinit is then a no-op; on a bail or an error the
    // deinits reclaim them. Either way one teardown serves every path.
    defer sub.deinit();

    var wl = Worklist{ .gpa = gpa };
    defer wl.deinit();

    const empty_match = sub.closeStart(true, true, false); // empty line: BOL ∧ EOL, no first byte ⇒ word_after=false
    // The unanchored start splits on the FIRST byte's word-ness (word_ctx): `start`
    // when it is a non-word byte (also the sole start when !word_ctx, where the
    // word_after arg is inert), `start_w` when it is a word byte. `word_before` is
    // false at BOL. Both resolve `$` at EOL via the final table like any state.
    const start_id = (try sub.intern(sub.closeStart(true, false, false))).id;
    try wl.push(&sub, start_id);
    const start_w_id = if (word_ctx) blk: {
        const id = (try sub.intern(sub.closeStart(true, false, true))).id;
        try wl.push(&sub, id);
        break :blk id;
    } else start_id;

    var wcur: usize = 0;
    while (wcur < wl.items.items.len) : (wcur += 1) {
        const id = wl.items.items[wcur];
        var k: u16 = 0;
        while (k < ncls) : (k += 1) {
            // Interior, next byte a non-word byte (or the sole interior transition when !word_ctx).
            try wl.push(&sub, try sub.expand(id, k, .interior));
            // Interior, next byte a word byte — the second determinization axis (word_ctx only).
            if (word_ctx) try wl.push(&sub, try sub.expand(id, k, .interior_word));
            // Last byte (at_end=true, word_after=false) resolves `$`/`\b`-at-EOL. Targets are terminal — the line ends right after — so interned for `is_match` but not enqueued.
            _ = try sub.expand(id, k, .final);
            if (sub.visits > max_visits) return .{ .declined = .too_costly };
        }
    }

    // Start-state acceleration: the "relevant" bytes from the unanchored start
    // state are the only ones that can contribute to a match; when there are few,
    // the scanner SIMD-skips to them. Anchored programs never re-seed (ineligible).
    // Computed on the id-based tables BEFORE premultiplication below (it reasons
    // about state identity, not the flattened offset).
    // Start-state acceleration reasons about a single unanchored start row and one
    // interior table; the word-context start split + doubled table don't fit that
    // shape, so word patterns forgo it (an optimization, never a correctness lever
    // — the trigram prefilter still selects on their bounded literal).
    const accel = if (word_ctx) null else subset.startAccel(anchored, empty_match, sub.trans_in.items, sub.trans_fin.items, sub.is_match.items, &cls.class, ncls, start_id);

    // Premultiply (rust-regex / RE2 dense-DFA trick): rewrite every state value to
    // its row offset `id*ncls`, so the hot loop's per-byte index collapses from a
    // loop-carried `madd(s, ncls, class)` to a fold-into-addressing `s + class[b]`
    // — one fewer instruction on the latency-bound transition recurrence. Targets
    // never reached by an interior byte keep their `unknown` sentinel (their row is
    // never indexed), so skip those to avoid overflowing the multiply.
    const nc: u32 = ncls;
    for (sub.trans_in.items) |*t| if (t.* != unknown) {
        t.* *= nc;
    };
    for (sub.trans_in_w.items) |*t| if (t.* != unknown) {
        t.* *= nc;
    };
    for (sub.trans_fin.items) |*t| if (t.* != unknown) {
        t.* *= nc;
    };
    // `is_match` re-laid-out by offset: `is_match_pm[id*ncls] = is_match[id]`, so the
    // hot loop reads `is_match[s]` with the premultiplied `s` and never divides. The
    // inter-row slots are never indexed (every live `s` is a multiple of `ncls`).
    const im_pm = try gpa.alloc(bool, @as(usize, sub.nstates) * ncls);
    errdefer gpa.free(im_pm);
    @memset(im_pm, false);
    for (sub.is_match.items, 0..) |m, id| im_pm[id * ncls] = m;
    const dead_pm = if (sub.dead == unknown) unknown else sub.dead * nc;

    const dfa = try gpa.create(Dfa);
    errdefer gpa.destroy(dfa);
    dfa.* = .{
        .class = cls.class,
        .ncls = ncls,
        .nstates = sub.nstates,
        .trans_in = try sub.trans_in.toOwnedSlice(gpa),
        .trans_fin = try sub.trans_fin.toOwnedSlice(gpa),
        .is_match = im_pm,
        .start = start_id * nc,
        .empty_match = empty_match,
        .anchored = anchored,
        .dead = dead_pm,
        .accel = accel,
        .word_ctx = word_ctx,
        .unicode_word = word_ctx and unicode,
        .trans_in_w = if (word_ctx) try sub.trans_in_w.toOwnedSlice(gpa) else &.{},
        .start_w = start_w_id * nc,
        .allocator = gpa,
    };
    return .{ .built = dfa };
}

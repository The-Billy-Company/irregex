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
//! Blow-up is bounded by `max_states`: past it the eager build bails to null and
//! the caller keeps the Pike VM, which stays the correctness reference (the
//! differential-fuzz oracle). Counted repetition (`a{1000}`) yields a linear, not
//! exponential, DFA, so the cap only ever trips on genuinely pathological
//! alternations.
//!
//! A state cap alone does NOT bound compile time, which is why the lazy driver
//! exists: `\w+X` determinizes to only 332 states, yet each closure runs over the
//! ~10³-state UTF-8 trie that Unicode `\w` (137,936 codepoints in 748 ranges)
//! lowers to, so this eager walk spends ~15 ms discovering a small automaton.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const prefilter = @import("../../analysis/prefilter.zig");
const subset = @import("subset.zig");
const State = syn.State;
const Dfa = @import("dfa.zig").Dfa;
const unknown = subset.unknown;

/// Start-state acceleration eligibility (mirrors rust-regex `accel.rs`): only
/// accelerate when the start state's escape set is ≤ this many bytes, past which
/// the SIMD skip stops being selective (e.g. `\w`'s 63 bytes) and a plain dense
/// scan wins. memchr/range-skip earns its keep at 1–3 exit bytes.
const max_accel_bytes: usize = 3;

/// Powerset state cap. Beyond this the eager build bails to null (Pike fallback).
/// Sized so a linear `{n}`-expanded program (DFA ≈ n states) always fits while a
/// pathological exponential alternation can't blow compile time or memory.
pub const max_states: u32 = 4096;

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
/// byte-class DFA, or null when it isn't worth it — the automaton exceeds
/// `max_states`, the effort exceeds `max_work`, or the program carries a buffer
/// anchor (multiline, where no DFA is built). `anchored` mirrors
/// `analysis.startsAnchored`: every match begins at line start, so we never re-seed.
pub fn build(gpa: std.mem.Allocator, states: []const State, start: u32, anchored: bool, unicode: bool) std.mem.Allocator.Error!?*Dfa {
    // Buffer anchors (`\A`/`\z`) exist only under multiline, where no DFA is built
    // at all — decline before interning so `close` never meets one.
    if (subset.hasBufferAnchor(states)) return null;
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
            if (sub.nstates > max_states) return null; // powerset blow-up ⇒ keep the Pike VM
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
    const accel = if (word_ctx) null else computeAccel(anchored, empty_match, sub.trans_in.items, sub.trans_fin.items, sub.is_match.items, &cls.class, ncls, start_id);

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
    return dfa;
}

/// Derive start-state acceleration from the finished transition tables. A byte is
/// "relevant" — must stop the SIMD skip — when, from the unanchored start state,
/// it either (a) moves to a *different* interior state (`trans_in` ≠ start, the
/// match-beginning case) or (b) produces a match at end-of-line (`trans_fin` is a
/// match state, the `$`-anchored-literal case like `;$`, where the byte keeps
/// `trans_in` in start yet matches as the line's last byte). Every other byte both
/// keeps start in itself AND can't match under `$`, so it is provably skippable.
/// Returns a `Prefilter` over the relevant set iff it is non-empty and
/// ≤ `max_accel_bytes`; else null (dense scan).
///
/// `\n` is added to the needle **only when the skip can't safely cross a line** —
/// i.e. when an empty line can match (`empty_match`) or `\n` is itself relevant.
/// Otherwise crossing `\n` in the start state is a pure no-op, so we omit it: the
/// scanner then `memchr`s straight across newlines (rg's exact `;$` strategy) and,
/// for a single relevant byte, the prefilter collapses to a one-byte `memchr`
/// instead of a two-range scan. The byte-at-a-time inner loop still stops at `\n`,
/// so `$`/line-end resolution stays correct.
fn computeAccel(anchored: bool, empty_match: bool, trans_in: []const u32, trans_fin: []const u32, is_match: []const bool, class: *const [256]u8, ncls: u16, start_id: u32) ?prefilter.Prefilter {
    if (anchored) return null;
    const base = @as(usize, start_id) * ncls;
    var relevant: syn.ByteSet = .{};
    var n: usize = 0;
    for (0..256) |bi| {
        const b: u8 = @intCast(bi);
        if (b == '\n') continue; // line-boundary stop, decided separately below
        const off = base + class[b];
        if (trans_in[off] != start_id or is_match[trans_fin[off]]) {
            relevant.set(b);
            n += 1;
        }
    }
    if (n == 0 or n > max_accel_bytes) return null;
    // Keep the skip inside one line only when it must: an empty line can match, or
    // `\n` itself is relevant. Otherwise let the skip `memchr` across newlines.
    const nl = base + class['\n'];
    const nl_relevant = trans_in[nl] != start_id or is_match[trans_fin[nl]];
    if (empty_match or nl_relevant) relevant.set('\n');
    return prefilter.Prefilter.init(relevant);
}

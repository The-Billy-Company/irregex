//! irregex — the EAGER driver of the subset construction: determinizes the
//! Thompson NFA in `syntax.zig` to fixpoint at compile time and freezes the
//! result into the immutable byte-class `Dfa` (`dfa.zig`), which is
//! scratch-free and freely shared across threads.
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
//!
//! The layout that a *finished* automaton admits — match-first renumbering, start
//! acceleration, premultiplication — is `freeze.zig`'s, shared with the symbolic
//! path so neither road can establish one invariant and forget another.
//!
//! Two bounds, and they are different KINDS of thing. `max_visits` is the cost
//! policy: size alone is the wrong meter, since `\w+X` determinizes to just 332
//! states yet runs every closure over the ~10³-state UTF-8 trie that Unicode `\w`
//! (137,936 codepoints in 748 ranges) lowers to, spending ~15 ms to discover a
//! small automaton. Counting NFA-state visits prices that directly. `max_states`
//! is the safety bound: it caps memory and guarantees termination, and no caller
//! may lift it. Only the policy is negotiable (`Budget`, via `force_dfa`).
//!
//! Declining is a cost decision with no semantic content: `../program/lower.zig`
//! hands the pattern to `lazy.zig`, which determinizes the same automaton one
//! visited state at a time, and the Pike VM stands behind both as the oracle.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const subset = @import("subset.zig");
const freeze = @import("../automata/freeze.zig");
const State = syn.State;
const Dfa = @import("dfa.zig").Dfa;

/// Default ceiling on the automaton's SIZE: it caps table memory and guarantees
/// termination on an exponential powerset. Under the visit budget it is normally
/// unreachable — visits grow at least as fast as states × classes, so the cost
/// ceiling is crossed first — and it becomes load-bearing exactly when a caller
/// waives that budget, which is what lets the differential tests determinize
/// every pattern they generate without risking a blow-up.
///
/// A ceiling is mandatory; *this* ceiling is a memory policy, and `Budget.states`
/// is how a caller with different memory arithmetic names its own (see `slate`).
pub const max_states: u32 = 4096;

/// Size ceiling for a lexer slate (`Budget.slate`), where the arithmetic that set
/// `max_states` does not hold.
///
/// Calibrated the way `max_visits` was: the smallest round value admitting every
/// automaton measured to need it. Over the thirty-grammar tree-sitter corpus the
/// largest terminal is markdown's `entity_reference` — the HTML entity table,
/// 2,231 literal alternatives sharing prefixes — at **5,991 states over 110 byte
/// classes**. It was the only one past 4,096 and the sole reason that corpus had
/// a pattern the engine would not build; second place is scala at 2,945, and no
/// other grammar reaches 2,200. So 4,096 was right for twenty-nine of thirty and
/// wrong for one, which is a ceiling set against the wrong population rather than
/// a pattern that deserved refusing.
///
/// Priced, not waved through. Tables are `u32` targets, so an automaton costs
/// `states × classes × 4` per table and there are two (three under word context):
/// `entity_reference` is 5.3 MiB, and a state-maxed automaton at the corpus's
/// widest alphabet (179 classes, haskell) would be 11.7 MiB. That is affordable
/// exactly because a slate is built once per grammar and then amortized over
/// every byte of every file for the life of the process — the same asymmetry
/// `munch.voice` invokes to waive the visit budget, which is a COST policy. This
/// is the SIZE policy, and it is raised rather than removed: the powerset is still
/// bounded, the build still terminates, and a genuine blow-up still declines.
pub const slate_states: u32 = 8192;

/// Effort cap for the eager build, in NFA-state visits (`Subset.visits`) — the
/// unit that actually costs time, since one closure's price is the size of the
/// subset it walks, not the fact that it happened. Anything hungrier belongs to
/// `lazy.zig`, which pays only for the states a haystack visits.
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

/// What a caller will spend to get the automaton, on the two axes that are not
/// the same question: TIME to discover it (`visits`) and MEMORY to hold it
/// (`states`). Folding them into one word is what hid `entity_reference` — the
/// lexer waived the cost cap and inherited a size cap set for somebody else.
///
/// The named seats are the whole vocabulary; nothing constructs this literally.
pub const Budget = struct {
    /// Enforce `max_visits`. False says the caller wants the automaton whatever
    /// it costs to *find*.
    visits: bool = true,
    /// Ceiling on the automaton's size. Never optional — it is the termination
    /// guarantee on an exponential powerset, so a caller may raise it and may
    /// not waive it.
    states: u32 = max_states,

    /// A pattern typed a second ago, to run against one haystack. Both caps.
    pub const budgeted: Budget = .{};
    /// `force_dfa` — the differential oracles, which need every generated
    /// pattern to actually reach the DFA rather than only the cheap ones.
    pub const unbudgeted: Budget = .{ .visits = false };
    /// A lexer slate: compiled once per grammar, amortized over every byte of
    /// every file for the process's life. See `slate_states`.
    pub const slate: Budget = .{ .visits = false, .states = slate_states };
};

/// Why the eager driver produced no automaton.
pub const Decline = enum {
    /// Not determinizable this way at all: a buffer anchor (`\A`/`\z`) means
    /// multiline, where position flags are content-dependent.
    unsupported,
    /// Past `budget.states` — the automaton itself is too big to hold.
    too_large,
    /// Past `max_visits` — small enough to hold, too expensive to discover.
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
/// byte-class DFA, or decline — the automaton exceeds `budget.states`, the walk
/// exceeds `max_visits` (unless `budget` waives it), or the program carries a
/// buffer anchor (multiline, where no DFA is built). `anchored` mirrors
/// `analysis.startsAnchored`: every match begins at line start, so we never re-seed.
pub fn build(gpa: std.mem.Allocator, states: []const State, start: u32, anchored: bool, unicode: bool, budget: Budget) std.mem.Allocator.Error!Outcome {
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

    const empty_pats = sub.closeStart(true, true, false); // empty line: BOL ∧ EOL, no first byte ⇒ word_after=false
    const empty_match = empty_pats != 0;
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
            if (sub.nstates > budget.states) return .{ .declined = .too_large };
            if (budget.visits and sub.visits > max_visits) return .{ .declined = .too_costly };
        }
    }

    const tables: freeze.Tables = .{
        .interior = &sub.trans_in,
        .interior_word = if (word_ctx) &sub.trans_in_w else null,
        .final = &sub.trans_fin,
        .is_match = sub.is_match.items,
        // Empty for the single-terminal programs that are every ordinary
        // compile, which keeps the frozen automaton's attribution table null and
        // its match test the same lone `s < match_hi` compare it has always been.
        .pats = if (sub.pats.items.len == 0) null else sub.pats.items,
    };

    // No quotient runs here, in EITHER dimension, and `../automata/reduce.zig` — the
    // module that owns both — is deliberately not called. The pass is cheap and it
    // does find things; it is declined because what it finds does not move the walk.
    // `bench/rungs/automata -- reduce` re-measures all of it every run, over three
    // slates, and times the SAME walker on the raw and the reduced table:
    //
    //   * ROWS, on an ASCII program. 1 automaton in 32 collapses, by one state, for
    //     a geomean 19% of determinization. Interning on the NFA-state SET has
    //     already landed this construction on the Myhill-Nerode quotient: two
    //     reachable states differ here only when their sets differ, which is nearly
    //     always a suffix difference too.
    //   * COLUMNS, on an ASCII program. `Classes.build` refines once per consuming
    //     set, before any class has a column to compare, so a finished table CAN
    //     hold columns that coincide — over those same 32, exactly one does (an
    //     eight-way single-byte alternation, 9 columns to 2, 792 bytes to 176).
    //   * A UTF-8 TRIE, which is the shape that should have paid. Force a Unicode
    //     pattern down this road and the decoder gives the pass real work: columns
    //     collapse on 4 rows in 5 for 0.6% of determinization, and `\w{3,8}` sheds a
    //     quarter of its states (1264 -> 949, a 1.0 MB table to 729 KB).
    //
    // And the walk does not notice, which is the finding. C2 had already measured
    // table AREA free at constant touched breadth (85x growth, no cost); this says
    // the same law still holds at a quarter-megabyte. Rows whose table did not change
    // at all scan at 0.92x-1.05x, so the instrument's floor is about +-8%, and every
    // row whose table DID shrink lands inside it (`\w+X` 267 KB -> 247 KB across four
    // runs: 1.00x, 0.93x, 0.99x, 0.98x). The one material row collapse cannot even be
    // timed honestly: `\w{3,8}` accepts any three word bytes, so NO alphabet holding a
    // word byte can spell a document it misses, and a table touched for tens of bytes
    // was never going to repay a 190 ms determinization by being smaller. Its row
    // prints `matched` rather than a ratio earned on a prefix.
    //
    // Those trie rows are also not this road's traffic. In production they belong to
    // `../symbolic/`, which reaches the same automaton in 144 NFA-state visits where
    // this road spends 68 million — and which DOES call `reduce`, because its product
    // carries a decoder phase the pattern cannot observe, so its rows are genuinely
    // redundant and collapsing them is what makes its columns coincide. The byte road
    // sees a trie only when the symbolic path declines a construct outright.
    //
    // The residual ASCII columns are a FRONT-END artifact rather than an automaton
    // fact, and that is where the fix belongs: `compile.zig` lowers the parser's
    // tree, where `(a|b|…|h)` is eight `consume` states, while `ast/algebra.zig`
    // already knows an alternation of byte classes IS a byte class. Folding it there
    // gives one consuming set instead of eight, a narrower NFA, and a determinization
    // that is not this slate's third slowest at 59 µs for 11 states — none of which a
    // post-hoc column merge can recover. See `research/automata/CLAIM.md` C5.

    // The automaton is complete; everything from here is layout, and it is the
    // same layout the symbolic path's product needs — match-first renumbering,
    // start acceleration, premultiplication — so it lives once in `freeze.zig`.
    return .{ .built = try freeze.freeze(gpa, &cls, tables, .{
        .nstates = sub.nstates,
        .start = start_id,
        .start_word = start_w_id,
        .dead = sub.dead,
        .empty_match = empty_match,
        .empty_pats = empty_pats,
        .anchored = anchored,
        .word_ctx = word_ctx,
        .unicode_word = word_ctx and unicode,
        .visits = sub.visits,
    }) };
}

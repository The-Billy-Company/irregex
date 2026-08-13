//! irregex — T2 byte-class DFA: the O(1)/byte automaton that puts this
//! package's regex verify at the same hardware floor ripgrep/RE2 hit, then wins
//! on top of it via the trigram prefilter + parallel candidate reads. Lineage:
//! Cox's "Regular Expression Matching Can Be Simple And Fast" → RE2 /
//! rust-`regex` hybrid (lazy) DFA. ADR-pending.
//!
//! Why it exists: the Pike VM is O(active-threads)/byte — it loses to rg on the
//! no-prefilter scan tail (a SELECTIVE but COMMON first byte — `;$`, `[0-9]{4}`,
//! `panic|0x` — re-seeds a closure at nearly every byte). A DFA instead spends ONE
//! table lookup per byte regardless of match density: `state = trans[state*ncls +
//! class[byte]]`, and `docMatch` runs that loop over the whole document in a
//! single fused pass (one byte-touch). It is the sole non-Pike engine: it
//! subsumes every earlier fast-path (dense, selective, anchored) at the same floor.
//!
//! This file is the immutable, scratch-free automaton — read-only after build and
//! freely shared across threads, exactly like the bit engine it supersedes. It is
//! determinized **eagerly** at compile time by the powerset construction in
//! `powerset.zig` (which collapses the byte alphabet into classes, resolves
//! `^`/`$` line anchors into the `start`/`trans_fin` tables, and — for
//! word-boundary patterns — refines classes by word-ness and doubles the interior
//! table so `matchWord` resolves `\b`/`\B`/`\<`/`\>` at the floor); `Dfa` only
//! consumes the finished tables.

const std = @import("std");
const prefilter = @import("../../analysis/prefilter.zig");
const word = @import("../../syntax/word.zig");

/// The unfilled-slot sentinel a transition row keeps when nothing can step from
/// its state — see the note on `Dfa` below, which is the reason this is public.
pub const unfilled: u32 = std.math.maxInt(u32);

/// Which table layout a walk steps through — see `Dfa.Wide`.
const Shape = enum { classed, direct };

/// One transition, over whichever layout the caller chose. The classed tables need
/// the byte's equivalence class first — `trans[s + class[b]]`, a load whose result
/// the next load depends on — where the byte-indexed mirror has already absorbed
/// that column and reads `trans[s + b]`. It is the only line `Shape` changes, and
/// deleting that one load is the whole of the doc walk's speedup (`Dfa.Wide`).
inline fn step(comptime shape: Shape, t: []const u32, cls: *const [256]u8, s: u32, b: u8) u32 {
    return switch (shape) {
        .classed => t[s + cls[b]],
        .direct => t[s + b],
    };
}

/// An immutable byte-class DFA. `class[b]` maps a byte to its equivalence-class
/// column; `trans_in`/`trans_fin` are row-major `[state][class]` next-state
/// tables (interior vs last-byte, the latter resolving `$`); `isMatch(s)` reports
/// whether a state's defining closure reached the NFA match. All fields are
/// read-only after `build`, so one `Dfa` serves every thread with no scratch.
///
/// **Premultiplied** (rust-regex / RE2): a state is represented by its row offset
/// `id*ncls`, not its id. So every table entry, `start`, and `dead` is already a
/// row offset, and the hot loop indexes `trans[s + class[b]]` — no per-byte
/// multiply on the loop-carried critical path.
///
/// **Match-partitioned** (`freeze.zig`): match states are renumbered to the front,
/// so "did we match?" is `s < match_hi` — a compare against a register, not a
/// second dependent load. This is why there is no `is_match` array to index.
///
/// **The transition tables are NOT total, and every exhaustive reader must know
/// it.** A state reached only as a `trans_fin` target is terminal — the line ends
/// the instant it is entered — so the determinizer interns it for its match flag
/// and never enqueues it, leaving its whole row on `subset.unknown`
/// (`maxInt(u32)`). `isMatch(off)` is valid for such a state — it reads no table
/// at all; `trans_in[off + c]` and `trans_fin[off + c]` are not, and using one as
/// an index faults. The
/// byte-at-a-time walks below never notice, because they only ever index a row
/// they stepped into. A consumer that sweeps the table instead — a rung lowering
/// it, a quotient harvesting it — must skip a state whose row is `unfilled`,
/// which cell zero witnesses for the whole row (rows are filled all-or-nothing).
pub const Dfa = struct {
    class: [256]u8,
    ncls: u16,
    nstates: u32,
    trans_in: []const u32, // entries are premultiplied targets (`id*ncls`)
    trans_fin: []const u32,
    /// One past the last matching row offset: `isMatch(s) == s < match_hi`. Zero
    /// when no state matches, `nstates*ncls` when every state does.
    match_hi: u32,
    /// The match partition subdivided by WHICH patterns a state accepts — empty
    /// for the single-pattern automata that are every ordinary compile, where
    /// `match_hi` already answers the only question there is.
    ///
    /// Id-indexed over the match prefix (`s / ncls`, valid below `match_hi`),
    /// one `u64` per match state, so `patternsAt` is a single load. It used to
    /// be a handful of (bound, mask) runs walked linearly, on the theory that
    /// attribution runs once per reported end — but `munch`'s filtered walks
    /// ask it at every *accepting byte*, and an identifier accepts at all of
    /// them, so the runs were a per-byte loop in the hottest loop a lexer has.
    /// The dense row is at most `nmatch × 8` bytes beside a `reach` table that
    /// already carries `nstates × 8`; the run form survives only as the wire
    /// encoding (`PatRun`), where its compactness still buys something.
    pats: []const u64 = &.{},
    /// Which patterns still have an accept reachable from each state — the
    /// forward-looking twin of `pats`, which says only what a state accepts
    /// *here*. Id-indexed (not premultiplied); empty for an unattributed
    /// automaton, where there is no subset of patterns to ask about.
    ///
    /// It exists for one caller and one question: a walk told to report only
    /// some of a union's patterns needs to know when the rest of the union is
    /// the only thing keeping it alive. See `reachableFrom` and `munch.reach`.
    reach: []const u64 = &.{},
    start: u32, // premultiplied start row offset (at_start=true, at_end=false)
    empty_match: bool, // does the pattern match an empty line? (^$, a*, …)
    empty_pats: u64 = 0, // WHICH patterns an empty haystack accepts — the one verdict no interned state holds

    anchored: bool, // `^`-anchored ⇒ never re-seed; dead state ⇒ no match
    // ── Word-context axis (`\b \B \< \>`; the `matchWord` path only) ──
    // A word-boundary assertion gates on the word-ness of the bytes straddling a
    // gap — a second determinization axis a plain byte-class DFA lacks. Rather
    // than carry look-behind in the state, we resolve it as a look-AHEAD-selected
    // transition (RE2 / rust-`regex`-`automata`): byte classes are refined by
    // ASCII word-ness so the *just-consumed* byte fixes `word_before`, and the
    // interior table is split by the *next* byte's word-ness — `trans_in` when it
    // is a non-word byte, `trans_in_w` when it is a word byte (`trans_fin`, the
    // EOL table, already carries `word_after=false`). The start likewise splits on
    // the first byte's word-ness (`start`=non-word, `start_w`=word). `trans_in_w`
    // is empty and `start_w == start` unless `word_ctx`.
    word_ctx: bool = false,
    unicode_word: bool = false, // `word_ctx` under Unicode: a byte ≥0x80 straddling a gap needs its full scalar decoded, which this ASCII-classed DFA can't — `matchWord` QUITS (returns null) so the Pike VM (the oracle) resolves that haystack. `(?-u)` word patterns never quit (a byte ≥0x80 is non-word, byte-for-byte).
    trans_in_w: []const u32 = &.{}, // word-context interior table: NEXT byte is a word byte
    start_w: u32 = 0, // word-context start when the FIRST byte is a word byte
    visits: u64 = 0, // NFA-state visits this determinization charged — what the automaton COST to find, not what it costs to run. `visits / (nstates*ncls)` is mean closure width. Zero from the symbolic road, which counts its work differently.
    dead: u32, // premultiplied offset of the empty/non-matching sink (maxInt if unreachable)
    // The start state's skippable dwell (rust-regex / RE2 call this start-state
    // acceleration — see `accel.rs`): when the unanchored start state's exit set is
    // a few bytes (e.g. `;` for `;$`), SIMD-skip to the next exit byte instead of
    // paying a table lookup per byte. Derived by `../automata/dwell.zig` only when
    // the set stays selective (≤ `dwell.max_exit_bytes`, and the corpus economics
    // agree); null ⇒ plain dense scan. `\n` is in the set whenever the skip may not
    // cross a line, so line boundaries stop it without a second pass. Sound because
    // a byte that keeps the start state in itself can neither begin a match nor
    // match under `trans_fin` (`$`).
    start_dwell: ?prefilter.Prefilter = null,
    /// The byte-indexed mirror of the two tables, when one is affordable
    /// (`Wide.afford`). Only the multi-line doc walk consults it.
    wide: ?Wide = null,
    allocator: std.mem.Allocator,
    /// Do the tables belong to someone else? An automaton assembled over memory
    /// the caller owns - a mapping, one inflate buffer, an arena it will drop
    /// whole - is walked exactly like a determinized one, and differs only in
    /// who frees it. False for everything `powerset.zig` builds, so a caller
    /// that never sets it sees the automaton it always did.
    borrowed: bool = false,

    /// One contiguous block of match states accepting the same pattern set:
    /// every premultiplied offset below `hi` (and at or above the previous run's)
    /// accepts exactly `mask`. The wire encoding of `pats` — `freeze.zig` sorts
    /// match states by accepted-pattern set, so equal sets are contiguous and
    /// the table serializes as a handful of pairs; a reader inflates them back
    /// to the dense row.
    pub const PatRun = struct { hi: u32, mask: u64 };

    /// The same automaton with the byte-class column folded INTO the tables: one
    /// row per state per raw byte, so a step is `trans[s + b]` and the class
    /// translation — a load the transition load waits on — disappears. This is
    /// RE2's dense layout, and rust-`regex`'s `dense::DFA` before its
    /// `ByteClasses` alphabet, which exists to shrink exactly this table.
    ///
    /// It **mirrors** rather than replaces. `class`, `ncls`, `trans_in`, and
    /// `trans_fin` stay byte-for-byte what the determinizer froze, so every other
    /// reader of this automaton — the dwell derivation, the quotient sieve, the
    /// shuffle lowering, the symbolic transcription — sees the numbers it always
    /// did, and the mirror can be absent with no consumer caring. Offsets inside
    /// it are premultiplied by `Wide.stride`, never by `ncls`.
    ///
    /// Two tests in `dfa_test.zig` hold that mirroring claim, and a single
    /// corrupted cell reddens both: one checks every state × all 256 bytes against
    /// the classed cell the byte's class names, the other fuzzes `docMatch` with
    /// the mirror present and then withheld and demands the same verdict.
    ///
    /// **What it is worth.** `bench/rungs/automata … burst` races body × width ×
    /// shape over an 8 MiB match-free document. Against the classed four-lane walk
    /// (M4, ns/byte; `rows` counts the table rows that document's bytes actually
    /// reached, which is the number that explains every anomaly here):
    ///
    ///   | mirror  | states | rows | classed | mirrored |  gain |
    ///   | ------- | ------ | ---- | ------- | -------- | ----- |
    ///   |   6 KiB |      3 |    2 |  0.3154 |   0.2312 | 1.36× |
    ///   |  14 KiB |      7 |    1 |  0.3261 |   0.2418 | 1.35× |
    ///   |  16 KiB |      8 |    1 |  0.3286 |   0.2396 | 1.37× |
    ///   |  28 KiB |     14 |    9 |  0.3665 |   0.3502 | 1.05× |
    ///   |  68 KiB |     34 |   33 |  0.3602 |   0.3534 | 1.02× |
    ///   | 128 KiB |     64 |    1 |  0.3134 |   0.2296 | 1.37× |
    ///   | 132 KiB |     66 |   65 |  0.3692 |   0.3569 | 1.03× |
    ///
    /// The gain tracks `rows`, not size: a walk whose touched rows are L1-resident
    /// keeps the whole win, and one that wanders over 33 rows spends it back on
    /// misses the class load was never the bottleneck for. Both directions are
    /// wins, which is why the mirror is taken whenever it is affordable and no
    /// second judgment is made about it.
    ///
    /// **Width was raced and rejected, deliberately.** Twelve lanes over the
    /// mirror cost a flat ~0.31 at every width — enough dependent-load chains in
    /// flight to cover the miss wherever it lives — which beats four lanes on the
    /// wandering rows (0.3184 against 0.3502) and loses badly on the L1-resident
    /// ones (0.3103 against 0.2296). Wider lanes shorten the burst, because a
    /// burst runs to the SHORTEST lane's line end and the minimum over twelve
    /// remainders is far shorter than over four, so the `$`-resolve-and-reseed
    /// tail runs proportionally more often; sixteen lanes lose everywhere
    /// (0.43–0.45) once that tail dominates and the frame spills too. Summed over
    /// the slate the two widths tie inside run-to-run variance, and choosing
    /// between them needs the DOCUMENT rather than the automaton — the same 14 KiB
    /// automaton parks on prose and wanders over hex.
    ///
    /// That last sentence is now a measurement rather than a claim, and it is the
    /// standing answer to "just dispatch twelve lanes on the wandering automata".
    /// `burst_control` re-runs the four patterns that want twelve — over a
    /// document their own class rejects instead of one drawn from it. Same
    /// compiled program, same state count, same mirror, same everything a
    /// freeze-time predicate could read; the states they visit collapse (9, 9, 33,
    /// 65 → 1 each) and all four flip from winning ~1.13× on twelve lanes to
    /// LOSING ~1.31× on them. A per-automaton predicate is not underdetermined
    /// here, it is unavailable: the label is a function of bytes the predicate
    /// never sees. So the engine carries one width, and the ladder keeps racing
    /// twelve as the measured ceiling: over repeat runs the shipped width geomeans
    /// 1.27×–1.29× against the classed walk, and a per-row best-arm oracle ~1.29×,
    /// so the gap left on the table belongs to whoever makes the walk
    /// working-set-aware at RUN time, not to a better freeze-time guess.
    pub const Wide = struct {
        trans_in: []const u32,
        trans_fin: []const u32,
        start: u32,
        match_hi: u32,

        /// Row stride: the whole byte alphabet, unclassed.
        pub const stride = 256;

        /// The most a mirror may cost before an automaton keeps only its classed
        /// tables. `bench/rungs/automata … burst` measures the mirror paying from
        /// 6 KiB out to 132 KiB, so the ceiling sits just past the widest width
        /// measured rather than extrapolating past it.
        pub const budget = 160 << 10;

        /// Resident bytes the mirror costs — the price of the load it drops.
        /// Deliberately NOT folded into `Dfa.tableBytes`: that number prices the
        /// classed walk the ladder routes on, and a mirror only the doc walk
        /// reads must not move a routing decision it has nothing to do with.
        pub fn bytes(self: *const Wide) usize {
            return (self.trans_in.len + self.trans_fin.len) * @sizeOf(u32);
        }

        /// Would a mirror of `nstates` rows fit the budget? Asked before building
        /// one, so a wide automaton never pays the allocation to then discard it.
        pub fn afford(nstates: u32) bool {
            return @as(usize, nstates) * stride * 2 * @sizeOf(u32) <= budget;
        }
    };

    /// The transition tables' resident footprint — every table a walk of this
    /// automaton can index, and nothing else.
    ///
    /// This is the automaton's PRICE, not a diagnostic. The hot loop is one
    /// loop-carried dependent load, so its cost is the latency of whichever
    /// cache level answers that load; which level that is, is this number
    /// against the host's. `ladder/price.zig` is the consumer, and the reason
    /// this lives here rather than in three callers computing it three ways.
    pub fn tableBytes(self: *const Dfa) usize {
        return (self.trans_in.len + self.trans_fin.len + self.trans_in_w.len) * @sizeOf(u32);
    }

    pub fn deinit(self: *Dfa) void {
        const a = self.allocator;
        // Derived rather than frozen, so it is owned even when the tables are
        // borrowed: a reader inflating a serialized automaton builds it fresh.
        if (self.pats.len != 0) a.free(self.pats);
        // The handle is still ours to release; the tables under it are not.
        if (self.borrowed) return a.destroy(self);
        a.free(self.trans_in);
        a.free(self.trans_fin);
        if (self.trans_in_w.len != 0) a.free(self.trans_in_w);
        if (self.reach.len != 0) a.free(self.reach);
        if (self.wide) |w| {
            a.free(w.trans_in);
            a.free(w.trans_fin);
        }
        a.destroy(self);
    }

    /// Which patterns does the premultiplied state `s` accept — bit `i` for
    /// pattern `i`, zero for a non-match state. The single-pattern answer is the
    /// match flag itself, so an ordinary automaton pays one compare and no load.
    ///
    /// On the byte-at-a-time path: `munch`'s filtered walks ask this at every
    /// accepting byte, and an identifier accepts at all of them, which is why
    /// the answer is one dense load and not a search of any shape.
    pub inline fn patternsAt(self: *const Dfa, s: u32) u64 {
        if (self.pats.len == 0) return @intFromBool(s < self.match_hi);
        return if (s < self.match_hi) self.pats[s / self.ncls] else 0;
    }

    /// Which patterns can still reach an accept from the premultiplied state
    /// `s` — everything `patternsAt` might yet report at this position or any
    /// later one, including through `trans_fin` on the last byte.
    ///
    /// All ones when the automaton carries no such table, which is the honest
    /// answer rather than a convenient one: an unattributed automaton cannot
    /// rule any pattern out, so a caller filtering on this learns nothing and
    /// keeps walking exactly as it did before.
    ///
    /// The divide is the price of storing one mask per state instead of one per
    /// row, and it is paid only on a walk that is filtering — which is a walk
    /// this table is about to cut short. See the measurement in `munch.reach`.
    pub inline fn reachableFrom(self: *const Dfa, s: u32) u64 {
        if (self.reach.len == 0) return ~@as(u64, 0);
        return self.reach[s / self.ncls];
    }

    /// Does the premultiplied state `s` match? The match states were renumbered
    /// to the front of the id space (`freeze.zig`), and premultiplication is
    /// monotone in the id, so the whole question is one unsigned compare — no
    /// load, at any stride. Valid for every reachable `s`, including the
    /// `trans_fin`-only terminal states whose transition rows are `unfilled`.
    pub inline fn isMatch(self: *const Dfa, s: u32) bool {
        return s < self.match_hi;
    }

    /// Does the pattern match any substring of `line`? Linear, one table lookup
    /// per byte. The last byte takes the `trans_fin` table so `$` can fire.
    pub fn match(self: *const Dfa, line: []const u8) bool {
        std.debug.assert(!self.word_ctx); // word-boundary DFAs go through `matchWord`
        if (line.len == 0) return self.empty_match;
        if (self.start_dwell) |*exits| return self.matchDwell(line, exits);
        var s = self.start; // premultiplied: `s` IS the row offset `id*ncls`
        if (self.isMatch(s)) return true;
        const last = line.len - 1;
        for (line[0..last]) |c| {
            s = self.trans_in[s + self.class[c]];
            if (self.isMatch(s)) return true;
            if (self.anchored and s == self.dead) return false; // no re-seed ⇒ dead
        }
        s = self.trans_fin[s + self.class[line[last]]];
        return self.isMatch(s);
    }

    /// `match` while the start state's dwell is skippable: parked in the unanchored
    /// start state, SIMD-skip the dead run to the next exit byte. The subtlety: a
    /// skipped byte keeps start in itself (no interior match), but the line's *last*
    /// byte can still match under `trans_fin` via `$` even when it's a non-exit byte
    /// (e.g. `d` for `\w+$`). So when the skip reaches line end without an exit
    /// byte, we still resolve the final byte with `trans_fin[start]`. `!anchored`.
    fn matchDwell(self: *const Dfa, line: []const u8, pf: *const prefilter.Prefilter) bool {
        const start = self.start; // premultiplied row offset
        var s = start;
        if (self.isMatch(s)) return true;
        const last = line.len - 1;
        var i: usize = 0;
        while (i < line.len) {
            if (s == start) {
                const j = pf.nextStart(line, i) orelse line.len;
                if (j >= line.len) { // dead tail: only the last byte can match (`$`)
                    s = self.trans_fin[start + self.class[line[last]]];
                    return self.isMatch(s);
                }
                i = j; // skipped non-exit bytes [i, j); landed on an exit byte
            }
            if (i == last) { // resolve the final byte with `$` (trans_fin)
                s = self.trans_fin[s + self.class[line[i]]];
                return self.isMatch(s);
            }
            s = self.trans_in[s + self.class[line[i]]];
            i += 1;
            if (self.isMatch(s)) return true;
        }
        return false;
    }

    /// Word-context line matcher (`word_ctx`): resolves `\b`/`\B`/`\<`/`\>` at
    /// the byte-class-DFA floor by selecting the interior table on the *next*
    /// byte's ASCII word-ness (and the start on the first byte's). Returns null
    /// — "quit, run the Pike VM" — only under `unicode_word`, the instant a gap
    /// abuts a byte ≥0x80 whose scalar this ASCII-classed automaton can't judge
    /// (rust-`regex`-`automata`'s quit-byte strategy). `(?-u)` word patterns
    /// never quit: a byte ≥0x80 is a non-word byte, byte-for-byte, so every gap
    /// is decidable. Equivalence to the Pike VM is held by the differential fuzz
    /// (`dfa_test.zig`) and the exhaustive NFA-spec proof (`powerset_test.zig`).
    pub fn matchWord(self: *const Dfa, line: []const u8) ?bool {
        std.debug.assert(self.word_ctx);
        if (line.len == 0) return self.empty_match;
        const uni = self.unicode_word;
        if (uni and line[0] >= 0x80) return null; // first scalar non-ASCII ⇒ can't fix `word_after` at BOL
        var s = if (word.isWordByte(line[0])) self.start_w else self.start;
        if (self.isMatch(s)) return true;
        const last = line.len - 1;
        var j: usize = 0;
        while (j < last) : (j += 1) {
            const nb = line[j + 1]; // the byte after the gap we're about to land on
            if (uni and nb >= 0x80) return null; // its scalar's word-ness is undecidable here
            const tbl = if (word.isWordByte(nb)) self.trans_in_w else self.trans_in;
            s = tbl[s + self.class[line[j]]];
            if (self.isMatch(s)) return true;
            if (self.anchored and s == self.dead) return false;
        }
        // Last content byte: EOL gap ⇒ `word_after=false`, resolved by `trans_fin`.
        s = self.trans_fin[s + self.class[line[last]]];
        return self.isMatch(s);
    }

    /// Does the pattern match any line of `doc`? Fused whole-buffer pass — `\n`
    /// is resolved inline (per line the last content byte takes `trans_fin` so
    /// `$` fires; `^` re-seeds `start` at each line head), so each byte is touched
    /// once, avoiding the memchr-then-rescan double byte-traffic of a per-line
    /// matcher. Three shapes, all held equivalent to the per-line path by the
    /// doc-level differential fuzz vs the Pike VM in `dfa_test.zig`:
    ///   * `start_dwell` — SIMD-skip the dead start run (`docMatchDwell`);
    ///   * `!anchored` — the pure latency-bound table walk, run multi-lane so the
    ///     loop-carried load chain overlaps across independent lines
    ///     (`docMatchDense`);
    ///   * anchored    — the scalar per-line walk that dead-states early
    ///     (`docMatchScalar`).
    pub fn docMatch(self: *const Dfa, doc: []const u8) bool {
        std.debug.assert(!self.word_ctx); // word-boundary DFAs go per-line through `matchWord`
        if (self.start_dwell) |*exits| return self.docMatchDwell(doc, exits);
        if (self.anchored) return self.docMatchScalar(doc);
        // The mirror when this automaton has one, its classed tables otherwise —
        // the same walk either way, and the shape is comptime for every byte of it.
        if (self.wide) |*w| return self.docMatchDense(.direct, w, doc);
        return self.docMatchDense(.classed, self, doc);
    }

    /// Per-line scalar scan: `\n` detected inline, the last content byte resolved
    /// via `trans_fin` (`$`), `^` re-seeded at each line head. It serves the
    /// `^`-anchored program — which dead-states to `false` the instant its
    /// anchored thread drains, then SIMD-`memchr`s straight to the next line
    /// rather than walking the dead tail byte-by-byte — and is the byte-exact
    /// reference the multi-lane `docMatchDense` replays (its non-`\n` tail drain).
    fn docMatchScalar(self: *const Dfa, doc: []const u8) bool {
        const n = doc.len;
        var i: usize = 0;
        while (i < n) {
            if (doc[i] == '\n') { // empty line
                if (self.empty_match) return true;
                i += 1;
                continue;
            }
            var s = self.start; // premultiplied: `s` IS the row offset `id*ncls`
            if (self.isMatch(s)) return true; // BOL / zero-width match
            var prev = s;
            var hit_dead = false;
            while (i < n and doc[i] != '\n') {
                prev = s;
                s = self.trans_in[s + self.class[doc[i]]];
                i += 1;
                if (self.isMatch(s)) return true;
                if (self.anchored and s == self.dead) { // `^`-anchored thread set drained
                    // …but only abandon if content remains: the LAST content byte still gets `trans_fin` below, whose `$`-resolving (at_end) closure can match where the interior (at_end=false) one died.
                    if (i < n and doc[i] != '\n') hit_dead = true;
                    break;
                }
            }
            if (!hit_dead) { // resolve the line's last content byte (`doc[i-1]`) with `$`
                s = self.trans_fin[prev + self.class[doc[i - 1]]];
                if (self.isMatch(s)) return true;
                if (i < n) i += 1; // skip the '\n'
            } else { // dead `^`-thread: SIMD-`memchr` past the rest of this dead line
                i = std.mem.indexOfScalarPos(u8, doc, i, '\n') orelse n;
                if (i < n) i += 1;
            }
        }
        return false;
    }

    /// The `!anchored`, `accel == null` doc scan — the pure latency-bound table
    /// walk (`[0-9a-f]{8}-[0-9a-f]{4}` and every no-start-skip DFA). The scalar
    /// recurrence `s = trans_in[s + class[b]]` is a single loop-carried dependent
    /// LOAD (≈4 cyc/byte on Apple M4 — a pointer chase, not throughput-bound), so
    /// one stream idles the load pipeline. We therefore run `lanes` streams at
    /// once: the out-of-order engine keeps `lanes` transition loads in flight and
    /// overlaps the load-use latency — the interleaved pointer-chase that exposes
    /// memory-level parallelism (Chen/Ailamaki group-prefetching for hash probes;
    /// the same multi-block idea Hyperscan's DFA uses).
    ///
    /// **A lane owns a REGION of the document, not a line.** Matches never cross
    /// `\n` and this scan answers only whether SOME line matches, so the document
    /// can be cut into `lanes` contiguous ranges at line boundaries and read in
    /// any order. `\n` is handled where it is met — resolve `$` through
    /// `trans_fin` off the `prev` the body already keeps, reset to `start`,
    /// continue — so the lanes never have to agree about anything.
    ///
    /// The carve this replaced gave each lane a LINE and burst to the shortest
    /// lane's line end, which sounds equivalent and is not: it stopped the walk
    /// every time any one lane ran out. On a document whose lines are all one
    /// length that costs nothing, because all four lanes end together and a burst
    /// is a whole line. On the line lengths of real source the burst is the
    /// minimum over four remainders — 22.5 bytes, and often far fewer — and a
    /// burst that short never gets four dependent load chains in flight before it
    /// drains them again. Regions measure 1.50–1.58x the line carve across every
    /// row of the `burst` rung's source-geometry half, and still win on the
    /// uniform half wherever the automaton actually wanders; the one shape they
    /// lose on is a parked automaton reading lines of identical length, where the
    /// line carve's bookkeeping was already amortized to nothing.
    ///
    /// Each lane replays `docMatchScalar`'s per-line logic byte-for-byte (interior
    /// `trans_in`, then the `$`-resolving `trans_fin` on the last content byte), so
    /// the doc-level DFA-vs-Pike differential fuzz proves equivalence.
    ///
    /// `tab` supplies the four numbers the walk steps through — `trans_in`,
    /// `trans_fin`, `start`, `match_hi` — and is either this `Dfa` (classed rows,
    /// `ncls`-strided) or its `Wide` mirror (raw-byte rows, 256-strided). Both
    /// spell those fields identically, so one body serves both layouts with no
    /// wrapper between them, and `shape` selects only how a byte indexes a row
    /// (`step`).
    fn docMatchDense(self: *const Dfa, comptime shape: Shape, tab: anytype, doc: []const u8) bool {
        const lanes = 4;
        const trans = tab.trans_in;
        const tfin = tab.trans_fin;
        const cls = &self.class;
        const mhi = tab.match_hi;
        const start = tab.start;

        // Both of these are properties of the AUTOMATON, so they are decided once
        // for the document instead of re-tested at every line the way a per-line
        // seed had to. `start < mhi` also cannot stay in the body: once a `\n`
        // resets a lane to `start`, a start-matching automaton would trip the
        // group match test on a document that has no content line at all.
        if (start < mhi) { // BOL / zero-width: any content line matches
            for (doc) |b| if (b != '\n') return true;
            return self.empty_match and doc.len > 0; // all `\n`: only empty lines left
        }

        var s: [lanes]u32 = undefined;
        var prev: [lanes]u32 = undefined;
        var cur: [lanes]usize = undefined;
        var stop: [lanes]usize = undefined;
        var lb: [lanes]usize = undefined; // where this lane's current line began

        // The regions are cut per WINDOW, not once over the whole document. Both
        // halves of that matter and they pull against each other:
        //
        //   * A region has to be long enough to keep `lanes` dependent load chains
        //     in flight, which is the entire point of the carve. `window / lanes`
        //     is that floor, and 16 KiB clears it by three orders of magnitude.
        //   * A region must not be so long that a lane is reading the far end of
        //     the document while the answer sits near the front. `docMatch` returns
        //     on the FIRST match, and a whole-document carve puts lane 0 alone on
        //     the front — so a match at byte `p` costs `p` steps where the line
        //     carve, with all four lanes bunched at the head, spent `p / lanes`.
        //     Measured on the real product binary that is a 1.3x LOSS on a matching
        //     document, against a 1.03–1.09x win on one that never matches: the
        //     bench could not see it because every row there scans to the end.
        //
        // Windowing bounds the overshoot at one window instead of one document, so
        // the early return costs a fixed 64 KiB of extra scan however large the
        // input, and the sync at a window edge is paid once per 64 KiB rather than
        // the once per ~22 bytes that made the line carve throttle.
        const window = 64 << 10;
        var base: usize = 0;
        while (base < doc.len) {
            // A window ends at a line boundary, so no state crosses one and every
            // lane may start from `start` again below. `wend - 1` is therefore a
            // `\n` unless this is the document's own end — the invariant the tail
            // check in the drain rests on.
            const aim_end = base +| window;
            const wend = if (aim_end >= doc.len)
                doc.len
            else if (std.mem.indexOfScalarPos(u8, doc, aim_end, '\n')) |nl| nl + 1 else doc.len;

            // Cut on line boundaries: aim for an even split, take the next `\n`. A
            // cut that runs past the window leaves an empty region, which the drain
            // finishes as the degenerate case it is rather than a case of its own —
            // which is also what makes a window shorter than `lanes` correct here.
            const span = wend - base;
            var cut: usize = base;
            inline for (0..lanes) |i| {
                s[i] = start;
                prev[i] = start;
                cur[i] = cut;
                lb[i] = cut;
                const aim = base + span / lanes * (i + 1);
                cut = if (i + 1 == lanes) wend else if (aim <= cut)
                    cut
                else if (std.mem.indexOfScalarPos(u8, doc, aim, '\n')) |nl| @min(nl + 1, wend) else wend;
                stop[i] = cut;
            }

            // The body: one byte per lane per step, `\n` included. The `\n` arm is
            // taken about once per line, so it predicts; unlike a burst boundary it
            // never drains the chains in flight. The inner loop re-derives the
            // shared step count only when a region ends, which is once per window.
            while (true) {
                var n = stop[0] - cur[0];
                inline for (1..lanes) |i| n = @min(n, stop[i] - cur[i]);
                if (n == 0) break;
                while (n > 0) : (n -= 1) {
                    inline for (0..lanes) |i| {
                        const b = doc[cur[i]];
                        cur[i] += 1;
                        if (b == '\n') {
                            if (cur[i] - 1 == lb[i]) {
                                if (self.empty_match) return true; // `^$`, `a*`
                            } else if (step(shape, tfin, cls, prev[i], doc[cur[i] - 2]) < mhi) return true;
                            s[i] = start;
                            prev[i] = start;
                            lb[i] = cur[i];
                        } else {
                            prev[i] = s[i];
                            s[i] = step(shape, trans, cls, s[i], b);
                        }
                    }
                    inline for (0..lanes) |i| if (s[i] < mhi) return true;
                }
            }

            // Drain: the regions differ by at most one line, so this is a line's
            // worth per lane — plus the document's own final line when it does not
            // end in `\n`, the one line no `\n` will ever resolve. An interior
            // region always ends just past a `\n`, so the tail check below can only
            // fire on that final line, never at a window seam.
            inline for (0..lanes) |i| {
                while (cur[i] < stop[i]) {
                    const b = doc[cur[i]];
                    cur[i] += 1;
                    if (b == '\n') {
                        if (cur[i] - 1 == lb[i]) {
                            if (self.empty_match) return true;
                        } else if (step(shape, tfin, cls, prev[i], doc[cur[i] - 2]) < mhi) return true;
                        s[i] = start;
                        prev[i] = start;
                        lb[i] = cur[i];
                    } else {
                        prev[i] = s[i];
                        s[i] = step(shape, trans, cls, s[i], b);
                        if (s[i] < mhi) return true;
                    }
                }
                if (stop[i] > lb[i] and doc[stop[i] - 1] != '\n') {
                    if (step(shape, tfin, cls, prev[i], doc[stop[i] - 1]) < mhi) return true;
                }
            }
            base = wend;
        }
        return false;
    }

    /// `docMatch` while the start state's dwell is skippable. Structurally identical
    /// to `docMatch` (same per-line `^`/`$`/`\n` handling, same `trans_fin` last-byte
    /// resolution) plus one move: whenever the scan is parked in the unanchored
    /// start state, SIMD-skip the dead run to the next exit byte **or `\n`** (the
    /// exit set carries `\n` here so the skip never crosses a line boundary). Built
    /// only for `!anchored`, so the dense-state drain path is unreachable here.
    fn docMatchDwell(self: *const Dfa, doc: []const u8, pf: *const prefilter.Prefilter) bool {
        const n = doc.len;
        const start = self.start; // premultiplied row offset
        var i: usize = 0;
        while (i < n) {
            if (doc[i] == '\n') { // empty line
                if (self.empty_match) return true;
                i += 1;
                continue;
            }
            var s = start;
            if (self.isMatch(s)) return true; // BOL / zero-width match
            var prev = s;
            var line_done = false; // dead-tail already resolved its `$` inside the loop
            while (i < n and doc[i] != '\n') {
                if (s == start) { // skip the dead run to the next exit byte / `\n`
                    const j = pf.nextStart(doc, i) orelse n;
                    if (j >= n or doc[j] == '\n') {
                        // Non-exit tail to the line end: no interior byte can match
                        // (start self-loops), but the last content byte `doc[j-1]`
                        // can still match `$` — resolve it from the *start* state
                        // (the live state across the skip), not the stale `prev`.
                        s = self.trans_fin[start + self.class[doc[j - 1]]];
                        if (self.isMatch(s)) return true;
                        i = j;
                        line_done = true;
                        break;
                    }
                    i = j;
                }
                prev = s;
                s = self.trans_in[s + self.class[doc[i]]];
                i += 1;
                if (self.isMatch(s)) return true;
            }
            // Contiguous-processing exit (hit `\n`/EOF): resolve the line's last
            // content byte with `$` from `prev` (the state right before it), exactly
            // as the dense `docMatch` does. Skipped tails handled `line_done` above.
            if (!line_done and i > 0 and doc[i - 1] != '\n') {
                s = self.trans_fin[prev + self.class[doc[i - 1]]];
                if (self.isMatch(s)) return true;
            }
            if (i < n and doc[i] == '\n') i += 1;
        }
        return false;
    }
};

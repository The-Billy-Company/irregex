//! gist — the ON-DEMAND driver of the subset construction: the same automaton
//! `powerset.zig` builds, except a state is determinized the first time a haystack
//! actually walks into it. RE2 / rust-`regex`'s hybrid DFA, in Billy's shape.
//!
//! Why it exists — the eager driver's cost is `nstates × ncls` subset closures paid
//! at COMPILE time, before a single byte is read, and for a large Unicode class
//! that bill is enormous relative to the automaton it discovers. Measured on this
//! tree: `\w+X` determinizes to 332 states yet costs ~15 ms eagerly, because every
//! closure runs over the ~10³-state UTF-8 trie that `\w` (137,936 codepoints in 748
//! ranges) lowers to. rust-`regex` compiles the same pattern in 0.141 ms and spends
//! 0.003 ms on the first search — not by deferring the work but by never doing it:
//! ASCII input visits a handful of those states and never touches the rest.
//!
//! The division of labour with `powerset.zig` is a cost judgement, not a semantic
//! one. Both drive `subset.zig`, so they agree by construction, and the eager
//! build simply runs first under a visit budget while this driver picks up what
//! that budget declines.
//!
//! How much that costs is measured, not assumed. On scans where a prefilter — a
//! start-state skip or an extractable literal — carries the search, the two
//! drivers TIE: the bytes that reach the transition loop are too few for its shape
//! to matter. Where nothing can be skipped and every byte is walked, eager wins
//! 1.36-1.56x on the strength of its premultiplied immutable tables, its lack of a
//! per-byte memo check, and its multi-lane document scan. That gap, not any
//! semantic difference, is the whole reason the eager driver goes first.
//!
//! **Quitting is a first-class answer.** Every entry point returns `?bool`, and
//! null means "I decline this haystack — run the Pike VM", exactly the protocol
//! `Dfa.matchWord` already uses for an undecidable Unicode word gap. A cache that
//! outgrows its cap quits rather than thrashing, and an allocation failure quits
//! rather than propagating: the Pike VM is the correctness oracle and always
//! available, so declining costs throughput and never an answer.
//!
//! Threading mirrors the rest of the engine: `Lazy` is immutable and shared, while
//! the mutable `Cache` is per-thread scratch owned by the caller's `Sim` — the same
//! split that lets one compiled `Regex` serve every worker.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const subset = @import("subset.zig");
const prefilter = @import("../../analysis/prefilter.zig");
const word = @import("../../syntax/word.zig");
const State = syn.State;
const unknown = subset.unknown;

/// Cap on states a single cache may materialize before it declines the haystack.
/// Only states an input actually visits are counted, so reaching this means the
/// haystack is genuinely walking a pathological automaton — the Pike VM's
/// O(active-threads)/byte is the better machine for that, and it is exact.
pub const max_cached_states: u32 = 4096;

/// The immutable half: everything about the pattern that determinization does not
/// have to run to discover. Shared across threads; carries no transition table of
/// its own, because every table lives in a per-thread `Cache`.
pub const Lazy = struct {
    states: []const State, // borrowed from the owning `Regex`
    start_nfa: u32,
    cls: subset.Classes,
    anchored: bool,
    word_ctx: bool,
    /// `word_ctx` under Unicode: a byte ≥0x80 straddling a gap needs its full
    /// scalar decoded, which this ASCII-classed automaton cannot do, so the word
    /// walk quits and the Pike VM resolves that haystack. `(?-u)` never quits.
    unicode_word: bool,
    /// Start-state acceleration, derived at build time from the start row alone
    /// (see `startAccel`). Not an eager-only luxury: the patterns that reach this
    /// driver include big alternations whose start state escapes on a single byte,
    /// where the skip is worth more than the whole automaton. Without it a
    /// 1000-branch alternation walked all 332 MB of a corpus the Pike VM's own
    /// first-byte skip flew over, and lost to it by 2.2x.
    accel: ?prefilter.Prefilter,
    allocator: std.mem.Allocator,

    /// Prepare on-demand determinization for a program, or null when this engine
    /// cannot serve it — a buffer anchor (`\A`/`\z`) means multiline, where no DFA
    /// is built at all.
    ///
    /// Nearly free: byte-class refinement is one pass over the program, and the
    /// only determinization is the start row (`2×ncls` closures) that start-state
    /// acceleration reads. That row is bounded by the class count no matter how
    /// large the automaton behind it is, so this stays flat where the eager
    /// driver's `nstates × ncls` bill is what made it decline in the first place.
    pub fn build(
        gpa: std.mem.Allocator,
        states: []const State,
        start: u32,
        anchored: bool,
        unicode: bool,
    ) std.mem.Allocator.Error!?*Lazy {
        if (subset.hasBufferAnchor(states)) return null;
        const word_ctx = subset.hasWordContext(states);
        const cls = subset.Classes.build(states, word_ctx);
        // A word-context program forgoes acceleration (its start splits in two and
        // its interior table is doubled — the shape `startAccel` doesn't model), so
        // don't pay the probe for one.
        const accel = if (word_ctx) null else try probeAccel(gpa, states, start, anchored, cls);
        const lz = try gpa.create(Lazy);
        lz.* = .{
            .states = states,
            .start_nfa = start,
            .cls = cls,
            .anchored = anchored,
            .word_ctx = word_ctx,
            .unicode_word = word_ctx and unicode,
            .accel = accel,
            .allocator = gpa,
        };
        return lz;
    }

    /// Determinize just the start row in a throwaway subset and read the skip out
    /// of it. Thrown away because acceleration is a *byte set* — 256 bits, copied
    /// into the immutable `Lazy` — while the row it was derived from belongs to
    /// whichever per-thread cache rediscovers it. Rebuilding two rows per cache is
    /// cheaper than sharing a table across threads.
    fn probeAccel(
        gpa: std.mem.Allocator,
        states: []const State,
        start: u32,
        anchored: bool,
        cls: subset.Classes,
    ) std.mem.Allocator.Error!?prefilter.Prefilter {
        var sub = try subset.Subset.init(gpa, states, start, anchored, false, cls);
        defer sub.deinit();
        const empty_match = sub.closeStart(true, true, false);
        const start_id = (try sub.intern(sub.closeStart(true, false, false))).id;
        try sub.forceStartRow(start_id);
        return subset.startAccel(anchored, empty_match, sub.trans_in.items, sub.trans_fin.items, sub.is_match.items, &cls.class, cls.ncls, start_id);
    }

    pub fn deinit(self: *Lazy) void {
        self.allocator.destroy(self);
    }
};

/// The mutable half: one thread's memo of the automaton discovered so far. Holds
/// the determinizer plus the start states, which are the only subsets interned up
/// front — everything else appears when a byte demands it.
///
/// Not premultiplied, unlike the eager `Dfa`: rows are appended as states are
/// interned, so a state's row offset would have to be rewritten across the whole
/// table on every growth. The per-byte multiply is the price of growability, and
/// it is paid only by patterns the eager driver already declined.
pub const Cache = struct {
    lazy: *const Lazy,
    sub: subset.Subset,
    start_id: u32,
    start_w_id: u32, // == start_id unless `word_ctx`
    empty_match: bool, // does the pattern match an empty line? (`^$`, `a*`)
    quit: bool = false, // sticky: this cache has outgrown its cap or failed to allocate

    pub fn init(gpa: std.mem.Allocator, lz: *const Lazy) std.mem.Allocator.Error!Cache {
        var sub = try subset.Subset.init(gpa, lz.states, lz.start_nfa, lz.anchored, lz.word_ctx, lz.cls);
        errdefer sub.deinit();
        // Empty line: BOL ∧ EOL, no first byte ⇒ word_after=false.
        const empty_match = sub.closeStart(true, true, false);
        // The unanchored start splits on the FIRST byte's word-ness (word_ctx):
        // `start_id` when it is a non-word byte (also the sole start when
        // !word_ctx, where the word_after arg is inert), `start_w_id` when it is a
        // word byte. `word_before` is false at BOL.
        const start_id = (try sub.intern(sub.closeStart(true, false, false))).id;
        const start_w_id = if (lz.word_ctx) (try sub.intern(sub.closeStart(true, false, true))).id else start_id;
        return .{
            .lazy = lz,
            .sub = sub,
            .start_id = start_id,
            .start_w_id = start_w_id,
            .empty_match = empty_match,
        };
    }

    pub fn deinit(c: *Cache) void {
        c.sub.deinit();
        c.* = undefined;
    }

    fn isMatch(c: *const Cache, id: u32) bool {
        return c.sub.is_match.items[id];
    }

    /// True once the automaton has proven this state can never match — the empty
    /// consume-set sink. Discovered during interning, so before it is reached
    /// `sub.dead` is `unknown` and nothing is dead yet.
    fn isDead(c: *const Cache, id: u32) bool {
        return c.sub.dead != unknown and id == c.sub.dead;
    }

    /// The successor of `id` on class `k` in `table`, determinizing it if this is
    /// the first time anything asked. Null means the cache declines — it hit the
    /// state cap or could not allocate — and the caller must quit to the Pike VM.
    fn next(c: *Cache, id: u32, k: u16, table: subset.Subset.Table) ?u32 {
        const off = @as(usize, id) * c.lazy.cls.ncls + k;
        const memo = c.sub.tableItems(table)[off];
        if (memo != unknown) return memo;
        if (c.sub.nstates >= max_cached_states) {
            c.quit = true;
            return null;
        }
        return c.sub.expand(id, k, table) catch {
            c.quit = true;
            return null;
        };
    }

    /// Does the pattern match any substring of `line`? Mirrors `Dfa.match`
    /// transition for transition; null ⇒ quit to the Pike VM.
    pub fn match(c: *Cache, line: []const u8) ?bool {
        std.debug.assert(!c.lazy.word_ctx); // word-boundary programs go through `matchWord`
        if (line.len == 0) return c.empty_match;
        if (c.lazy.accel) |*pf| return c.matchAccel(line, pf);
        const cls = &c.lazy.cls.class;
        var s = c.start_id;
        if (c.isMatch(s)) return true;
        const last = line.len - 1;
        for (line[0..last]) |ch| {
            s = c.next(s, cls[ch], .interior) orelse return null;
            if (c.isMatch(s)) return true;
            if (c.lazy.anchored and c.isDead(s)) return false; // no re-seed ⇒ dead
        }
        s = c.next(s, cls[line[last]], .final) orelse return null;
        return c.isMatch(s);
    }

    /// `match` with start-state acceleration, mirroring `Dfa.matchAccel`: while
    /// parked in the unanchored start state, SIMD-skip the dead run to the next
    /// exit byte. The subtlety is the same one the eager walk handles — a skipped
    /// byte keeps start in itself, but the line's *last* byte can still match under
    /// the final table via `$`, so a skip that reaches line end still resolves it.
    fn matchAccel(c: *Cache, line: []const u8, pf: *const prefilter.Prefilter) ?bool {
        const cls = &c.lazy.cls.class;
        const start = c.start_id;
        var s = start;
        if (c.isMatch(s)) return true;
        const last = line.len - 1;
        var i: usize = 0;
        while (i < line.len) {
            if (s == start) {
                const j = pf.nextStart(line, i) orelse line.len;
                if (j >= line.len) { // dead tail: only the last byte can match (`$`)
                    s = c.next(start, cls[line[last]], .final) orelse return null;
                    return c.isMatch(s);
                }
                i = j; // skipped non-exit bytes [i, j); landed on an exit byte
            }
            if (i == last) { // resolve the final byte with `$`
                s = c.next(s, cls[line[i]], .final) orelse return null;
                return c.isMatch(s);
            }
            s = c.next(s, cls[line[i]], .interior) orelse return null;
            i += 1;
            if (c.isMatch(s)) return true;
        }
        return false;
    }

    /// Word-context line matcher (`word_ctx`), mirroring `Dfa.matchWord`: selects
    /// the interior table on the *next* byte's ASCII word-ness (and the start on
    /// the first byte's). Quits under `unicode_word` the instant a gap abuts a byte
    /// ≥0x80 whose scalar this ASCII-classed automaton cannot judge.
    pub fn matchWord(c: *Cache, line: []const u8) ?bool {
        std.debug.assert(c.lazy.word_ctx);
        if (line.len == 0) return c.empty_match;
        const uni = c.lazy.unicode_word;
        if (uni and line[0] >= 0x80) return null; // first scalar non-ASCII ⇒ can't fix `word_after` at BOL
        const cls = &c.lazy.cls.class;
        var s = if (word.isWordByte(line[0])) c.start_w_id else c.start_id;
        if (c.isMatch(s)) return true;
        const last = line.len - 1;
        var j: usize = 0;
        while (j < last) : (j += 1) {
            const nb = line[j + 1]; // the byte after the gap we're about to land on
            if (uni and nb >= 0x80) return null; // its scalar's word-ness is undecidable here
            const table: subset.Subset.Table = if (word.isWordByte(nb)) .interior_word else .interior;
            s = c.next(s, cls[line[j]], table) orelse return null;
            if (c.isMatch(s)) return true;
            if (c.lazy.anchored and c.isDead(s)) return false;
        }
        // Last content byte: EOL gap ⇒ `word_after=false`, resolved by the final table.
        s = c.next(s, cls[line[last]], .final) orelse return null;
        return c.isMatch(s);
    }

    /// Does any line of `doc` match? The per-line scalar walk, mirroring
    /// `Dfa.docMatchScalar` — `\n` detected inline, the last content byte resolved
    /// through the final table so `$` fires, `^` re-seeded at each line head.
    ///
    /// No multi-lane variant here on purpose: `docMatchDense` overlaps four
    /// independent transition loads to hide pointer-chase latency, which only pays
    /// once the tables are settled. A lane that misses mid-burst would have to
    /// determinize inside the interleaved loop, serializing exactly what the
    /// interleaving buys. Patterns reaching this driver were otherwise bound for
    /// the Pike VM, so the scalar walk is already the faster machine.
    pub fn docMatch(c: *Cache, doc: []const u8) ?bool {
        std.debug.assert(!c.lazy.word_ctx); // word-boundary programs go per line
        if (c.lazy.accel) |*pf| return c.docMatchAccel(doc, pf);
        const cls = &c.lazy.cls.class;
        const n = doc.len;
        var i: usize = 0;
        while (i < n) {
            if (doc[i] == '\n') { // empty line
                if (c.empty_match) return true;
                i += 1;
                continue;
            }
            var s = c.start_id;
            if (c.isMatch(s)) return true; // BOL / zero-width match
            var prev = s;
            var hit_dead = false;
            while (i < n and doc[i] != '\n') {
                prev = s;
                s = c.next(s, cls[doc[i]], .interior) orelse return null;
                i += 1;
                if (c.isMatch(s)) return true;
                if (c.lazy.anchored and c.isDead(s)) { // `^`-anchored thread set drained
                    // …but only abandon if content remains: the LAST content byte still gets the final table, whose `$`-resolving (at_end) closure can match where the interior (at_end=false) one died.
                    if (i < n and doc[i] != '\n') hit_dead = true;
                    break;
                }
            }
            if (!hit_dead) { // resolve the line's last content byte (`doc[i-1]`) with `$`
                s = c.next(prev, cls[doc[i - 1]], .final) orelse return null;
                if (c.isMatch(s)) return true;
                if (i < n) i += 1; // skip the '\n'
            } else { // dead `^`-thread: SIMD-`memchr` past the rest of this dead line
                i = std.mem.indexOfScalarPos(u8, doc, i, '\n') orelse n;
                if (i < n) i += 1;
            }
        }
        return false;
    }

    /// `docMatch` with start-state acceleration, mirroring `Dfa.docMatchAccel`:
    /// the same per-line `^`/`$`/`\n` handling plus one move — whenever the scan is
    /// parked in the unanchored start state, SIMD-skip the dead run to the next
    /// exit byte **or `\n`** (the needle carries `\n` whenever the skip may not
    /// cross a line). This is the rung that matters most for this driver: it is
    /// what lets a haystack determinize a handful of states and then fly over the
    /// bytes that visit none of them. `!anchored` by construction, so the
    /// dense-state drain path of `docMatch` is unreachable here.
    fn docMatchAccel(c: *Cache, doc: []const u8, pf: *const prefilter.Prefilter) ?bool {
        const cls = &c.lazy.cls.class;
        const n = doc.len;
        const start = c.start_id;
        var i: usize = 0;
        while (i < n) {
            if (doc[i] == '\n') { // empty line
                if (c.empty_match) return true;
                i += 1;
                continue;
            }
            var s = start;
            if (c.isMatch(s)) return true; // BOL / zero-width match
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
                        s = c.next(start, cls[doc[j - 1]], .final) orelse return null;
                        if (c.isMatch(s)) return true;
                        i = j;
                        line_done = true;
                        break;
                    }
                    i = j;
                }
                prev = s;
                s = c.next(s, cls[doc[i]], .interior) orelse return null;
                i += 1;
                if (c.isMatch(s)) return true;
            }
            // Contiguous-processing exit (hit `\n`/EOF): resolve the line's last
            // content byte with `$` from `prev`, exactly as the dense walk does.
            // Skipped tails already handled themselves via `line_done`.
            if (!line_done and i > 0 and doc[i - 1] != '\n') {
                s = c.next(prev, cls[doc[i - 1]], .final) orelse return null;
                if (c.isMatch(s)) return true;
            }
            if (i < n and doc[i] == '\n') i += 1;
        }
        return false;
    }
};

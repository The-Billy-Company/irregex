//! gist — T2 byte-class DFA: the O(1)/byte automaton that puts gist's regex
//! verify at the same hardware floor ripgrep/RE2 hit, then wins on top of it via
//! the trigram prefilter + parallel candidate reads. Lineage: Cox's "Regular
//! Expression Matching Can Be Simple And Fast" → RE2 / rust-`regex` hybrid (lazy)
//! DFA. ADR-pending.
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
const prefilter = @import("../analysis/prefilter.zig");
const word = @import("../syntax/word.zig");

/// An immutable byte-class DFA. `class[b]` maps a byte to its equivalence-class
/// column; `trans_in`/`trans_fin` are row-major `[state][class]` next-state
/// tables (interior vs last-byte, the latter resolving `$`); `is_match[s]` marks
/// states whose defining closure reached the NFA match. All fields are read-only
/// after `build`, so one `Dfa` serves every thread with no scratch.
///
/// **Premultiplied** (rust-regex / RE2): a state is represented by its row offset
/// `id*ncls`, not its id. So every table entry, `start`, and `dead` is already a
/// row offset, the hot loop indexes `trans[s + class[b]]` (no per-byte multiply on
/// the loop-carried critical path), and `is_match` is laid out by offset (length
/// `nstates*ncls`; only the `ncls`-aligned slots are ever read).
pub const Dfa = struct {
    class: [256]u8,
    ncls: u16,
    nstates: u32,
    trans_in: []const u32, // entries are premultiplied targets (`id*ncls`)
    trans_fin: []const u32,
    is_match: []const bool, // indexed by row offset: `is_match[id*ncls]`
    start: u32, // premultiplied start row offset (at_start=true, at_end=false)
    empty_match: bool, // does the pattern match an empty line? (^$, a*, …)
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
    dead: u32, // premultiplied offset of the empty/non-matching sink (maxInt if unreachable)
    // Start-state acceleration (rust-regex / RE2 trick — see `accel.rs`): when the
    // unanchored start state's only escape is a few "exit bytes" (e.g. `;` for
    // `;$`), SIMD-skip the dead run to the next exit byte (or `\n`) instead of a
    // table lookup per byte. Built by `powerset` only when the exit set is small
    // enough to stay selective (≤ `max_accel_bytes`); null ⇒ plain dense scan. The
    // needle set includes `\n` so the skip stops at line boundaries (fused, no
    // second pass). Sound because a byte that keeps the start state in itself can
    // neither begin a match nor match under `trans_fin` (`$`).
    accel: ?prefilter.Prefilter = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Dfa) void {
        const a = self.allocator;
        a.free(self.trans_in);
        a.free(self.trans_fin);
        a.free(self.is_match);
        if (self.trans_in_w.len != 0) a.free(self.trans_in_w);
        a.destroy(self);
    }

    /// Does the pattern match any substring of `line`? Linear, one table lookup
    /// per byte. The last byte takes the `trans_fin` table so `$` can fire.
    pub fn match(self: *const Dfa, line: []const u8) bool {
        std.debug.assert(!self.word_ctx); // word-boundary DFAs go through `matchWord`
        if (line.len == 0) return self.empty_match;
        if (self.accel) |*pf| return self.matchAccel(line, pf);
        var s = self.start; // premultiplied: `s` IS the row offset `id*ncls`
        if (self.is_match[s]) return true;
        const last = line.len - 1;
        for (line[0..last]) |c| {
            s = self.trans_in[s + self.class[c]];
            if (self.is_match[s]) return true;
            if (self.anchored and s == self.dead) return false; // no re-seed ⇒ dead
        }
        s = self.trans_fin[s + self.class[line[last]]];
        return self.is_match[s];
    }

    /// `match` with start-state acceleration: while parked in the unanchored start
    /// state, SIMD-skip the dead run to the next exit byte. The subtlety: a skipped
    /// byte keeps start in itself (no interior match), but the line's *last* byte
    /// can still match under `trans_fin` via `$` even when it's a non-exit byte
    /// (e.g. `d` for `\w+$`). So when the skip reaches line end without an exit
    /// byte, we still resolve the final byte with `trans_fin[start]`. `!anchored`.
    fn matchAccel(self: *const Dfa, line: []const u8, pf: *const prefilter.Prefilter) bool {
        const start = self.start; // premultiplied row offset
        var s = start;
        if (self.is_match[s]) return true;
        const last = line.len - 1;
        var i: usize = 0;
        while (i < line.len) {
            if (s == start) {
                const j = pf.nextStart(line, i) orelse line.len;
                if (j >= line.len) { // dead tail: only the last byte can match (`$`)
                    s = self.trans_fin[start + self.class[line[last]]];
                    return self.is_match[s];
                }
                i = j; // skipped non-exit bytes [i, j); landed on an exit byte
            }
            if (i == last) { // resolve the final byte with `$` (trans_fin)
                s = self.trans_fin[s + self.class[line[i]]];
                return self.is_match[s];
            }
            s = self.trans_in[s + self.class[line[i]]];
            i += 1;
            if (self.is_match[s]) return true;
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
        if (self.is_match[s]) return true;
        const last = line.len - 1;
        var j: usize = 0;
        while (j < last) : (j += 1) {
            const nb = line[j + 1]; // the byte after the gap we're about to land on
            if (uni and nb >= 0x80) return null; // its scalar's word-ness is undecidable here
            const tbl = if (word.isWordByte(nb)) self.trans_in_w else self.trans_in;
            s = tbl[s + self.class[line[j]]];
            if (self.is_match[s]) return true;
            if (self.anchored and s == self.dead) return false;
        }
        // Last content byte: EOL gap ⇒ `word_after=false`, resolved by `trans_fin`.
        s = self.trans_fin[s + self.class[line[last]]];
        return self.is_match[s];
    }

    /// Does the pattern match any line of `doc`? A single fused pass over the
    /// whole buffer — `\n` is detected inline inside the transition loop, so each
    /// byte is touched exactly once (the per-line `match` path memchr-scans for
    /// `\n` AND then re-scans the bytes in the DFA: double byte-traffic, the
    /// dominant cost of a no-prefilter full scan). Per line the last content byte
    /// takes `trans_fin` so `$` fires; `^` is reset by re-seeding `start` at each
    /// line head. Equivalence to the per-line path is held by the doc-level
    /// differential fuzz vs the Pike VM in `dfa_test.zig`.
    pub fn docMatch(self: *const Dfa, doc: []const u8) bool {
        std.debug.assert(!self.word_ctx); // word-boundary DFAs go per-line through `matchWord`
        if (self.accel) |*pf| return self.docMatchAccel(doc, pf);
        const n = doc.len;
        var i: usize = 0;
        while (i < n) {
            if (doc[i] == '\n') { // empty line
                if (self.empty_match) return true;
                i += 1;
                continue;
            }
            var s = self.start; // premultiplied: `s` IS the row offset `id*ncls`
            if (self.is_match[s]) return true; // BOL / zero-width match
            var prev = s;
            var hit_dead = false;
            while (i < n and doc[i] != '\n') {
                prev = s;
                s = self.trans_in[s + self.class[doc[i]]];
                i += 1;
                if (self.is_match[s]) return true;
                if (self.anchored and s == self.dead) { // `^`-anchored thread set drained
                    // …but only abandon if content remains: the LAST content byte still gets `trans_fin` below, whose `$`-resolving (at_end) closure can match where the interior (at_end=false) one died.
                    if (i < n and doc[i] != '\n') hit_dead = true;
                    break;
                }
            }
            if (!hit_dead) { // resolve the line's last content byte (`doc[i-1]`) with `$`
                s = self.trans_fin[prev + self.class[doc[i - 1]]];
                if (self.is_match[s]) return true;
                if (i < n) i += 1; // skip the '\n'
            } else { // dead: skip the rest of this line
                while (i < n and doc[i] != '\n') i += 1;
                if (i < n) i += 1;
            }
        }
        return false;
    }

    /// `docMatch` with start-state acceleration. Structurally identical to
    /// `docMatch` (same per-line `^`/`$`/`\n` handling, same `trans_fin` last-byte
    /// resolution) plus one move: whenever the scan is parked in the unanchored
    /// start state, SIMD-skip the dead run to the next exit byte **or `\n`** (the
    /// needle carries `\n` so the skip never crosses a line boundary). Built only
    /// for `!anchored`, so the dense-state drain path is unreachable here.
    fn docMatchAccel(self: *const Dfa, doc: []const u8, pf: *const prefilter.Prefilter) bool {
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
            if (self.is_match[s]) return true; // BOL / zero-width match
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
                        if (self.is_match[s]) return true;
                        i = j;
                        line_done = true;
                        break;
                    }
                    i = j;
                }
                prev = s;
                s = self.trans_in[s + self.class[doc[i]]];
                i += 1;
                if (self.is_match[s]) return true;
            }
            // Contiguous-processing exit (hit `\n`/EOF): resolve the line's last
            // content byte with `$` from `prev` (the state right before it), exactly
            // as the dense `docMatch` does. Skipped tails handled `line_done` above.
            if (!line_done and i > 0 and doc[i - 1] != '\n') {
                s = self.trans_fin[prev + self.class[doc[i - 1]]];
                if (self.is_match[s]) return true;
            }
            if (i < n and doc[i] == '\n') i += 1;
        }
        return false;
    }
};

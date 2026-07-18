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
//! `powerset.zig` (which collapses the byte alphabet into classes and resolves
//! `^`/`$` line anchors into the `start`/`trans_fin` tables); `Dfa` only consumes
//! the finished tables.

const std = @import("std");
const prefilter = @import("../analysis/prefilter.zig");

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
        a.destroy(self);
    }

    /// Does the pattern match any substring of `line`? Linear, one table lookup
    /// per byte. The last byte takes the `trans_fin` table so `$` can fire.
    pub fn match(self: *const Dfa, line: []const u8) bool {
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

    /// Does the pattern match any line of `doc`? A single fused pass over the
    /// whole buffer — `\n` is detected inline inside the transition loop, so each
    /// byte is touched exactly once (the per-line `match` path memchr-scans for
    /// `\n` AND then re-scans the bytes in the DFA: double byte-traffic, the
    /// dominant cost of a no-prefilter full scan). Per line the last content byte
    /// takes `trans_fin` so `$` fires; `^` is reset by re-seeding `start` at each
    /// line head. Equivalence to the per-line path is held by the doc-level
    /// differential fuzz vs the Pike VM in `dfa_test.zig`.
    pub fn docMatch(self: *const Dfa, doc: []const u8) bool {
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

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

/// An immutable byte-class DFA. `class[b]` maps a byte to its equivalence-class
/// column; `trans_in`/`trans_fin` are row-major `[state][class]` next-state
/// tables (interior vs last-byte, the latter resolving `$`); `is_match[s]` marks
/// states whose defining closure reached the NFA match. All fields are read-only
/// after `build`, so one `Dfa` serves every thread with no scratch.
pub const Dfa = struct {
    class: [256]u8,
    ncls: u16,
    nstates: u32,
    trans_in: []const u32,
    trans_fin: []const u32,
    is_match: []const bool,
    start: u32, // start state for a non-empty line (at_start=true, at_end=false)
    empty_match: bool, // does the pattern match an empty line? (^$, a*, …)
    anchored: bool, // `^`-anchored ⇒ never re-seed; dead state ⇒ no match
    dead: u32, // id of the empty/non-matching sink (maxInt if unreachable)
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
        const ncls: usize = self.ncls;
        var s = self.start;
        if (self.is_match[s]) return true;
        const last = line.len - 1;
        for (line[0..last]) |c| {
            s = self.trans_in[@as(usize, s) * ncls + self.class[c]];
            if (self.is_match[s]) return true;
            if (self.anchored and s == self.dead) return false; // no re-seed ⇒ dead
        }
        s = self.trans_fin[@as(usize, s) * ncls + self.class[line[last]]];
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
        const ncls: usize = self.ncls;
        const n = doc.len;
        var i: usize = 0;
        while (i < n) {
            if (doc[i] == '\n') { // empty line
                if (self.empty_match) return true;
                i += 1;
                continue;
            }
            var s = self.start;
            if (self.is_match[s]) return true; // BOL / zero-width match
            var prev = s;
            var hit_dead = false;
            while (i < n and doc[i] != '\n') {
                prev = s;
                s = self.trans_in[@as(usize, s) * ncls + self.class[doc[i]]];
                i += 1;
                if (self.is_match[s]) return true;
                if (self.anchored and s == self.dead) { // `^`-anchored thread set drained
                    // …but only abandon if content remains: the LAST content byte still gets `trans_fin` below, whose `$`-resolving (at_end) closure can match where the interior (at_end=false) one died.
                    if (i < n and doc[i] != '\n') hit_dead = true;
                    break;
                }
            }
            if (!hit_dead) { // resolve the line's last content byte (`doc[i-1]`) with `$`
                s = self.trans_fin[@as(usize, prev) * ncls + self.class[doc[i - 1]]];
                if (self.is_match[s]) return true;
                if (i < n) i += 1; // skip the '\n'
            } else { // dead: skip the rest of this line
                while (i < n and doc[i] != '\n') i += 1;
                if (i < n) i += 1;
            }
        }
        return false;
    }
};

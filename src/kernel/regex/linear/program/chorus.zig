//! irregex — MANY patterns, one automaton, and every voice still nameable.
//!
//! A `Chorus` lowers N patterns into a single Thompson program whose N `.match`
//! terminals sit at indices `0..N-1`, determinizes it once, and walks it once.
//! What comes back is not "something matched" but *which* patterns matched and
//! *where* — from the same byte traffic a one-pattern scan already pays.
//!
//! Three questions, one walk (`Ends`):
//!
//!   * **Attribution** — which of the N patterns match this haystack. Used to
//!     cost N engine confirms, one per pattern, every document.
//!   * **Overlapping matches** — every end offset at which *any* pattern
//!     accepts, including ends that a leftmost-first scan would swallow. On
//!     `foofoofoo` against `foo|foofoo|foofoofoo` that is ends 3, 6 and 9, each
//!     naming the patterns that ended there.
//!   * **HalfMatch** — an end offset and its patterns, with no start. The
//!     backward jaw of the caliper never runs, because nothing asked where the
//!     match began.
//!
//! **Why the overlapping answer is free here.** rust-`regex` needs
//! `MatchKind::All` to see ends 6 and 9: its determinizer breaks out of the NFA
//! walk on the first `Match` state unless that flag is set, so its default
//! construction has already discarded the longer alternatives, and switching the
//! flag on costs a second, larger automaton *and* a slower search loop (its
//! overlapping path forgoes the 4-byte unroll and the unchecked transition).
//! Our determinizer never had a priority to preserve — leftmost-first lives
//! downstream in `../caliper/`, not in the subset construction — so every
//! pattern that accepts at a position is already in the state's mask. All-mode
//! is not a mode we enter; it is the only mode the recognizer ever had.
//!
//! **Fail-open, always.** `compile` returns null whenever the union cannot be
//! built or determinized honestly — a body outside the linear syntax, a buffer
//! anchor, a powerset past its budget. A null chorus is not an error and never
//! changes an answer; the caller falls back to the per-pattern path it would
//! have run anyway. That is what lets `slate/patterns.zig` adopt this as a pure
//! accelerator and prove equality with it both on and off.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const compile_mod = @import("../../compile/compile.zig");
const powerset = @import("../dfa/powerset.zig");
const subset = @import("../dfa/subset.zig");
const word = @import("../../syntax/word.zig");
const lower = @import("lower.zig");
const Dfa = @import("../dfa/dfa.zig").Dfa;

/// Most patterns one chorus can name — the width of the mask each DFA state
/// carries. Callers with a wider slate sing it in chunks.
pub const max_patterns: usize = subset.max_patterns;

/// One position at which the union accepts: the exclusive end offset, and the
/// patterns that ended there. The unit of every answer this module gives —
/// attribution folds these, overlapping search enumerates them, and a HalfMatch
/// *is* one.
pub const End = struct { at: usize, pats: u64 };

pub const Chorus = struct {
    dfa: *Dfa,
    npat: usize,

    /// Lower `patterns` into one program and determinize it, or null if any step
    /// declines. Every pattern is parsed under the same `opts` — a chorus sings
    /// in one key, and a caller holding a mixed slate must not build one.
    ///
    /// The union is built at the PROGRAM layer rather than by concatenating
    /// `(?:p0)|(?:p1)|…` into text and re-parsing it. Text fusion loses exactly
    /// the thing this module exists to keep: once the alternation is a string,
    /// every branch shares one terminal and no automaton downstream can say
    /// which branch accepted.
    pub fn compile(gpa: std.mem.Allocator, patterns: []const []const u8, opts: lower.Options) syn.ParseError!?Chorus {
        if (patterns.len == 0 or patterns.len > max_patterns) return null;

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var c = compile_mod.Compiler{ .gpa = gpa };
        defer c.states.deinit(gpa);

        // The terminals first, so state index i IS pattern ordinal i — the
        // contract `subset.ordinals` reads back when it builds the mask.
        for (patterns) |_| _ = try c.push(.match);

        const entries = try arena.alloc(u32, patterns.len);
        for (patterns, entries, 0..) |src, *entry, i| {
            const ast = lower.parse(arena, src, opts) catch return null;
            entry.* = try c.compileNode(ast, @intCast(i));
        }

        const start = try splitTree(&c, entries);
        const states = c.states.items;

        // Unanchored regardless of what the patterns assert. Re-seeding the start
        // at interior positions cannot manufacture a match for an anchored
        // pattern — `^` resolves against the gap's own `at_start`, which is false
        // everywhere but position zero — so this is a cost choice, not a
        // semantic one, and it is the only choice correct for a MIXED slate.
        const outcome = try powerset.build(gpa, states, start, false, opts.unicode, .budgeted);
        return switch (outcome) {
            .declined => null,
            .built => |dfa| .{ .dfa = dfa, .npat = patterns.len },
        };
    }

    pub fn deinit(self: *Chorus) void {
        self.dfa.deinit();
    }

    /// Every pattern that matches anywhere in `line`, as a bitmask. One pass, and
    /// it stops early once every pattern is spoken for — a wide slate over a
    /// dense line usually settles long before the last byte.
    ///
    /// The per-byte cost over a plain "does anything match?" scan is zero: the
    /// loop already tests `isMatch` to decide whether to return, and this reads
    /// the run table only on the bytes where that test fires.
    pub fn lineMask(self: *const Chorus, line: []const u8) u64 {
        const all: u64 = if (self.npat == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(self.npat)) - 1;
        var mask: u64 = 0;
        var it = self.ends(line);
        while (it.next()) |e| {
            mask |= e.pats;
            if (mask == all) break;
        }
        return mask;
    }

    /// Does any pattern match `line`? Distinct from `lineMask` only in stopping
    /// at the first end rather than the last new pattern.
    pub fn anyMatch(self: *const Chorus, line: []const u8) bool {
        var it = self.ends(line);
        return it.next() != null;
    }

    /// Every pattern matching any LINE of `doc`. The per-line model is the
    /// semantics the single-pattern engine already implements, so a document is
    /// its lines: `^`/`$` resolve at each `\n`, and no match spans one. Still one
    /// pass over the bytes, and it abandons the rest of the document the moment
    /// every pattern is accounted for.
    pub fn docMask(self: *const Chorus, doc: []const u8) u64 {
        const all: u64 = if (self.npat == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(self.npat)) - 1;
        var mask: u64 = 0;
        var lines = std.mem.splitScalar(u8, doc, '\n');
        while (lines.next()) |line| {
            mask |= self.lineMask(line);
            if (mask == all) break;
        }
        return mask;
    }

    /// Does any pattern match any line of `doc`? The cheap rejection a batch
    /// workload spends most of its time in.
    pub fn docAny(self: *const Chorus, doc: []const u8) bool {
        var lines = std.mem.splitScalar(u8, doc, '\n');
        while (lines.next()) |line| if (self.anyMatch(line)) return true;
        return false;
    }

    /// Walk `line` yielding one `End` per accepting position — the overlapping
    /// search, and the HalfMatch tier, and the thing `lineMask` folds.
    pub fn ends(self: *const Chorus, line: []const u8) Ends {
        return .{ .dfa = self.dfa, .line = line };
    }
};

/// The union walk: a byte-at-a-time pass that reports every position where the
/// automaton accepts, with the patterns that accepted there.
///
/// One transcription of the stepping rule serves all three answers above, for
/// the same reason `subset.close` is one transcription of the assertion rule —
/// a second copy is a second chance to disagree about what a pattern means.
/// Both determinization axes are honored here: the last content byte takes the
/// `final` table so `$` can fire, and a word-context automaton selects its
/// interior table on the *next* byte's word-ness.
pub const Ends = struct {
    dfa: *const Dfa,
    line: []const u8,
    i: usize = 0,
    s: u32 = unstarted,
    done: bool = false,

    const unstarted = std.math.maxInt(u32);

    pub fn next(self: *Ends) ?End {
        if (self.done) return null;
        const d = self.dfa;

        if (self.s == unstarted) {
            if (self.line.len == 0) {
                self.done = true;
                return if (d.empty_match) .{ .at = 0, .pats = d.empty_pats } else null;
            }
            // A word-context automaton splits its start on the FIRST byte's
            // word-ness; a plain one has `start_w == start` and never notices.
            self.s = if (d.word_ctx and word.isWordByte(self.line[0])) d.start_w else d.start;
            if (d.isMatch(self.s)) return .{ .at = 0, .pats = d.patternsAt(self.s) };
        }

        const last = self.line.len - 1;
        while (self.i <= last) {
            // Parked in the unanchored start state, SIMD-skip the bytes that
            // cannot begin a match (`../automata/dwell.zig`). Without this the
            // walk pays a table lookup for every byte of filler, and a slate of
            // literals loses outright to N separate memmem scans — measured, on
            // the way to this line. Sound for the same reason the single-pattern
            // `matchDwell` is: a skipped byte keeps start in itself, so it can
            // neither begin a match nor end one, and the line's LAST byte is
            // never skipped past because `$` can still fire there under
            // `trans_fin`.
            if (d.start_dwell) |*pf| {
                if (self.s == d.start and self.i < last) {
                    const j = pf.nextStart(self.line, self.i) orelse self.line.len;
                    self.i = if (j >= last) last else j;
                }
            }
            const j = self.i;
            self.i += 1;
            if (j < last) {
                const nb = self.line[j + 1]; // the byte after the gap we land on
                // Unicode word context cannot fix a non-ASCII scalar's word-ness
                // from a byte-classed table. The single-pattern engine QUITS here
                // and lets the Pike VM answer; a chorus has no oracle behind it,
                // so it stops and the caller's fallback covers the haystack.
                if (d.unicode_word and nb >= 0x80) break;
                const tbl = if (d.word_ctx and word.isWordByte(nb)) d.trans_in_w else d.trans_in;
                self.s = tbl[self.s + d.class[self.line[j]]];
            } else {
                self.s = d.trans_fin[self.s + d.class[self.line[j]]];
            }
            if (d.isMatch(self.s)) return .{ .at = j + 1, .pats = d.patternsAt(self.s) };
        }
        self.done = true;
        return null;
    }
};

/// A balanced ε-split tree over `entries`, returning its root.
///
/// Balanced buys DEPTH, not work. A union over N branches is N-1 split states in
/// any shape, and `subset.close` pushes both children of every split it pops, so
/// one closure visits all N-1 whichever way they are stacked — a right-leaning
/// chain (rust-`regex`'s `c_alt_iter`) costs the determinizer exactly the same.
/// What balance bounds is this function's own recursion and the closure's stack
/// depth, at `log2 N` rather than `N`.
///
/// It used to be worth more than that, and the reason it no longer is belongs
/// here: this tree sits directly behind the NFA start, so an unanchored
/// determinization that re-seeds the start on every transition re-walked the
/// whole union once per (state x class). `subset.Subset.seeds` hoists that walk
/// out of the loop — the tree is now closed eight times in total, once per
/// distinguishable gap — which is where the 1.3-2.3x in `bench/rungs/patternid`
/// came from and why the shape of this tree is no longer measurable at all.
fn splitTree(c: *compile_mod.Compiler, entries: []const u32) syn.ParseError!u32 {
    if (entries.len == 1) return entries[0];
    const mid = entries.len / 2;
    return c.push(.{ .split = .{
        .a = try splitTree(c, entries[0..mid]),
        .b = try splitTree(c, entries[mid..]),
    } });
}

//! gist — the composition rung: a byte-class DFA re-expressed as transformations
//! so the scan becomes a REDUCTION instead of a pointer chase.
//!
//! The eager DFA's hot loop is `s = trans[s + class[b]]` — a single loop-carried
//! DEPENDENT LOAD, so it runs at load-use latency (≈3.6 cyc/byte on an Apple M4
//! Max) no matter how few states it has. Nine states and seventy-three measure
//! the same, because the cost is the chase, not the table. This rung changes the
//! bound type rather than the constant: each byte's whole transition FUNCTION is
//! a 16- or 32-byte vector, those vectors are combined pairwise in a tree (see
//! `lanes.zig` for why re-association is free), and only one composition per
//! chunk stays on the critical path. Measured 2.26 B/cycle against the shipped
//! engine's 0.335 on the same buffer in the same process (`bench/compose/`,
//! 206 MiB of the real corpus) — a load-port-bound 0.44 cyc/byte where the DFA
//! is latency-bound at 3.0.
//!
//! Dispatch only, never semantics: this rung answers identically to the Pike VM
//! or it declines. It is a DECIDER — it says no at COMPILE time by being a null
//! field on `Regex`, and once armed it is total.
//!
//! ## What the lowering has to solve
//!
//! Composition yields a chunk's FINAL state and throws the intermediate ones
//! away, but a line matches if it EVER touched an accepting state. So "ever" has
//! to live in the state: every accepting DFA state folds into one absorbing
//! MATCH lane, after which "some prefix accepted" ≡ "the final lane is MATCH" —
//! exactly what a reduction computes. A `\n` row maps every live lane back to
//! START, which reproduces the per-line model (`^` re-seeds, a match never
//! crosses a line) inside ONE fused pass over the whole buffer.
//!
//! `$` is the subtle one. The DFA resolves it with a second table consulted only
//! on a line's last content byte, which composition cannot do after the fact —
//! there is no "after". The lowering instead DETECTS whether any `(lane, class)`
//! accepts under the end-of-line table without also accepting under the interior
//! one; that is precisely a `$` that can fire where the interior step did not
//! already report a match. When it can, the table doubles to 512 rows indexed by
//! `byte | (next_is_newline_or_eof << 8)` and the kernel reads one byte ahead.
//! The index still depends only on input bytes, so the loads stay independent
//! and the parallelism survives. Detecting this rather than assuming "no `$` in
//! the pattern" is what keeps the 256-row fast path sound.
//!
//! ## Where it stands down
//!
//! Above 31 non-accepting states (32 lanes with MATCH) a transformation needs
//! four registers and `TBL`'s 4-register form retires at a third of the
//! throughput — the technique returns ~1.2× there and is not worth a code path.
//! And when the DFA has a start-state accelerator armed, this rung must NOT
//! preempt it: composition retires every byte where a `memchr` skip retires
//! almost none, measured 6× SLOWER on `qzx.*jvw.*mkp`. Faster per byte loses to
//! touching a twentieth of them.
//!
//! Lineage: transformation monoids over an automaton's transition functions —
//! the same algebra behind parallel prefix scans (Ladner–Fischer 1980) and
//! behind Sheng's register-resident `PSHUFB` state step (Hyperscan). What is new
//! here is treating the match question as a *reduction* rather than a scan, and
//! folding the end-of-line decision into the table index so the whole per-line
//! model survives one sequential pass.

const std = @import("std");
/// The lane algebra, re-exported: it is the shareable half of this rung (a
/// sibling wanting the `TBL` primitive imports it directly and depends on no
/// rung), and callers read `lanes.native` to know whether the rung can arm at
/// all before they ask it to.
pub const lanes = @import("../../../scan/lanes.zig");

/// The most non-accepting states a machine may have and still be lowered: 31
/// plus the absorbing MATCH lane fills a 32-lane transformation exactly.
pub const max_states: u8 = 31;

/// The determinizer's unfilled-slot sentinel (`dfa/subset.zig`'s `unknown`),
/// spelled locally so this module keeps depending on the eager `Dfa`'s SHAPE
/// and not on its package. A transition table is not total: a state reached
/// only at end-of-line is interned for its match flag and never enqueued, so
/// its row is never written. Every exhaustive reader of the table has to know
/// that — the byte-at-a-time walk the tables were built for never does, because
/// it only ever indexes rows it stepped into.
const unfilled: u32 = std.math.maxInt(u32);

/// A lowered machine: a byte-indexed table of transformations plus the two
/// lanes that give the reduction its meaning. Immutable after `build` and
/// scratch-free, so one `Compose` serves every thread — same contract as `Dfa`.
pub const Compose = struct {
    /// `rows × width` transformation vectors, row-major by table index.
    table: []const u8,
    width: lanes.Width,
    index: lanes.Index,
    /// Where a line begins, and where a `\n` row sends every live lane.
    start_lane: u8,
    /// The absorbing accept lane. A fixed point of every row, `\n` included.
    match_lane: u8,
    /// Does the pattern match an EMPTY line (`^$`, `a*`)? An empty line carries
    /// no byte, so no byte transformation can represent it and `docMatch`
    /// resolves it separately.
    empty_match: bool,
    /// Proven at lowering time: this machine's `\n` row is what the DFA does on
    /// a `\n` anyway, so it reads a terminator as an ordinary byte and answers
    /// the SLICE question as well as the per-line one. See `lower`, which
    /// derives it, and `sliceSafe`, which is how the ladder asks.
    slice_safe: bool,
    allocator: std.mem.Allocator,

    /// CAN this machine be represented as transformations? The rung's ONE
    /// entry point, and the only way it ever declines — at COMPILE time, by
    /// returning null, never mid-scan.
    ///
    /// It used to have a sibling, `build`, carrying one line of DISPATCH policy:
    /// `if (dfa.start_dwell != null) return null`, because a DFA that skips
    /// nineteen bytes in twenty beats a rung that must retire all of them
    /// (measured 6.7× slower on a `.*`-chain with an armed skip). That judgment
    /// was right and its spelling was wrong — a boolean, on a quantity the seam
    /// contract's 2026-07-26 addendum measures across a 30× spread. It now lives
    /// where every other dispatch judgment does: the fallback bids its skip's
    /// own expected stride and this rung bids its measured per-byte width, and
    /// the cheaper one wins (`ladder/price.zig`). Same outcome on the boundary
    /// pattern, a defensible one on the patterns the boolean got wrong, and no
    /// rung deciding a contest it is a party to.
    ///
    /// `dfa` is taken structurally rather than by type so this module imports
    /// nothing from the engine around it: the bench and the quotient sieve can
    /// drive the same lowering from their own module instances. It must expose
    /// the eager `Dfa` shape — `class`, `ncls`, `nstates`, `trans_in`,
    /// `trans_fin`, `isMatch`, `start`, `empty_match`, `word_ctx`, `accel`.
    ///
    /// Each refusal is a real hole rather than a convenience:
    ///   * not AArch64 — the kernel is one instruction and there is no portable
    ///     equivalent worth arming;
    ///   * `\b`/`\B` word context — resolved per line by a second table axis
    ///     this lowering does not carry;
    ///   * more than `max_states` non-accepting states;
    ///   * the start closure already accepts — START and MATCH would be the same
    ///     lane, and the DFA answers such patterns in O(1) anyway.
    pub fn lower(gpa: std.mem.Allocator, dfa: anytype) !?*Compose {
        return lowerFor(lanes.native, gpa, dfa);
    }

    /// `lower` with the target predicate passed in, mirroring the parabix rung's
    /// `admit.planFor`. `lanes.native` is a DISPATCH judgment — the 32-lane form
    /// wants `TBL`'s two-register list and the 16-lane form on `pshufb` has never
    /// been measured — but everything below it is architecture-independent: the
    /// lane assignment, the end-of-line axis detection, the `slice_safe` proof,
    /// and the table itself are the same on every target, and `lanes.run` already
    /// carries a portable fold for them to be driven through. The test suite
    /// passes `true` so that all of that is exercised wherever CI runs, rather
    /// than only on the architecture that happens to arm the kernel. Production
    /// never passes anything but `lanes.native`.
    pub fn lowerFor(comptime armed: bool, gpa: std.mem.Allocator, dfa: anytype) !?*Compose {
        if (comptime !armed) return null;
        if (dfa.word_ctx) return null;
        if (dfa.isMatch(dfa.start)) return null;

        const ncls: usize = dfa.ncls;
        const nstates: usize = dfa.nstates;

        // One lane per non-accepting state that can be STEPPED FROM; every
        // accepting state collapses into the single absorbing lane after them.
        const lane_of = try gpa.alloc(u8, nstates);
        defer gpa.free(lane_of);
        // Lane 0 floors the states that never earn one, so every entry stays in
        // range and a read of this array is a structural question rather than a
        // memory one. Accepting states are overwritten just below; unsteppable
        // ones are never read at all (see the loop).
        @memset(lane_of, 0);
        var offset_of: [max_states]usize = @splat(0);
        var live: u8 = 0;
        for (0..nstates) |s| {
            const off = s * ncls; // states are premultiplied by their row width
            if (dfa.isMatch(@intCast(off))) continue;
            // A state reachable ONLY as a `trans_fin` target is interned for its
            // match flag and never enqueued, so the determinizer leaves its whole
            // row on the `unfilled` sentinel. Nothing can step from it — the line
            // ended when it was entered — so it is not a lane, and the reduction
            // can never occupy one. Skipping it is what keeps the two row reads
            // below in bounds; it also shrinks `live`, which is how a `$` pattern
            // can fall back under the 16-lane width.
            if (dfa.trans_in[off] == unfilled) continue;
            if (live == max_states) return null;
            lane_of[s] = live;
            offset_of[live] = off;
            live += 1;
        }
        const match_lane = live;
        for (0..nstates) |s| if (dfa.isMatch(@intCast(s * ncls))) {
            lane_of[s] = match_lane;
        };

        // Can `$` fire where the interior step did not already report a match?
        // If it cannot, every byte takes one interior row and the table stays
        // at 256 rows with no lookahead.
        var index: lanes.Index = .byte;
        outer: for (offset_of[0..live]) |off| {
            for (0..ncls) |c| {
                if (dfa.isMatch(dfa.trans_fin[off + c]) and !dfa.isMatch(dfa.trans_in[off + c])) {
                    index = .byte_eol;
                    break :outer;
                }
            }
        }

        const width: lanes.Width = if (match_lane < 16) .lanes16 else .lanes32;
        const stride = width.stride();
        const table = try gpa.alloc(u8, lanes.tableBytes(width, index));
        errdefer gpa.free(table);
        const start_lane = lane_of[@as(usize, dfa.start) / ncls];

        // WHICH of the ladder's two questions can THIS machine answer?
        //
        // The `\n` row below forces every lane back to START, which is the
        // per-line model — so by default this rung answers "does any line
        // match" and the ladder may only ask it at the document grain. But when
        // the DFA would do that anyway on a `\n`, the reset row is an ordinary
        // byte row, the two models coincide, and the machine also answers "does
        // this slice match" — which is what the per-line callers ask.
        //
        // Three conditions, one per way they could disagree:
        //   * `$` resolved by the second table (`byte_eol`) fires at every
        //     terminator here and only at a slice's end there;
        //   * an anchored program never re-seeds, so resetting after a `\n`
        //     would invent a `^` the DFA does not have;
        //   * and if `\n` can step a live lane anywhere but START, or into a
        //     match, the language crosses a line and the reset drops it.
        //
        // Measured worth (a same-`Regex` A/B, 64 MiB, 1.74M lines): 2.2-2.4x on the
        // per-line path for the patterns this admits. Both controls matter —
        // an anchored pattern is 3.4x SLOWER through here than through the
        // ladder's line-start-only walk, because it scans what the ladder skips.
        const nl_cls: usize = dfa.class['\n'];
        var slice_safe = index == .byte and !dfa.anchored;
        if (slice_safe) for (offset_of[0..live]) |off| {
            const t = dfa.trans_in[off + nl_cls];
            if (dfa.isMatch(t) or lane_of[@as(usize, t) / ncls] != start_lane) {
                slice_safe = false;
                break;
            }
        };

        for (0..table.len / stride) |idx| {
            const b: u8 = @truncate(idx);
            const at_eol = idx >= 256;
            const row = table[idx * stride .. idx * stride + stride];

            // Unreachable lanes hold the identity — never read, but an
            // out-of-range lane value would read back as zero under `TBL` and
            // silently alias lane 0 rather than fault. It also makes MATCH a
            // fixed point of every row for free, `\n` included, which is the
            // one precondition the kernel cannot check for itself.
            for (row, 0..) |*lane, l| lane.* = @intCast(l);
            if (b == '\n') { // the terminator: the next line begins at START
                @memset(row[0..live], start_lane);
                continue;
            }
            const c: usize = dfa.class[b];
            for (row[0..live], offset_of[0..live]) |*lane, off| {
                const interior = dfa.trans_in[off + c];
                lane.* = if (at_eol)
                    // A line's last content byte is resolved by the shipped
                    // walk through the end-of-line table, whose closure is a
                    // superset of the interior one's; either accepting means
                    // the line matched. Where a non-matching lane lands is
                    // immaterial — the `\n` row, or the end of the buffer,
                    // follows and only MATCH survives either.
                    if (dfa.isMatch(interior) or dfa.isMatch(dfa.trans_fin[off + c])) match_lane else start_lane
                else if (dfa.isMatch(interior))
                    match_lane
                else
                    lane_of[@as(usize, interior) / ncls];
            }
        }

        const self = try gpa.create(Compose);
        self.* = .{
            .table = table,
            .width = width,
            .index = index,
            .start_lane = start_lane,
            .match_lane = match_lane,
            .empty_match = dfa.empty_match,
            .slice_safe = slice_safe,
            .allocator = gpa,
        };
        return self;
    }

    pub fn deinit(self: *Compose) void {
        const gpa = self.allocator;
        gpa.free(self.table);
        gpa.destroy(self);
    }

    /// May the ladder ask this machine the SLICE question — "does the pattern
    /// match a substring of exactly these bytes" — and not only the per-line
    /// one? True when `lower` proved the `\n` row is an ordinary byte row.
    ///
    /// The ladder calls this by name (`rungs.zig` looks the declaration up at
    /// comptime), so a rung that never grows the method is simply held to its
    /// static model. Conservative by construction: `false` costs throughput,
    /// never correctness.
    pub fn sliceSafe(self: *const Compose) bool {
        return self.slice_safe;
    }

    /// Does the pattern match any substring of `line`?
    ///
    /// `line` must be `\n`-free unless `sliceSafe`, and that is this rung's own
    /// precondition rather than one the ladder supplies. `verdict.lineMatch`
    /// promises nothing about `\n`: it asks whether the pattern matches a
    /// substring of the bytes it was handed, with `^`/`$` bound to that slice's
    /// own edges. A machine whose `\n` row resets to START answers the OTHER
    /// question — "does any line match" — and the two diverge on exactly the
    /// anchored patterns (`^x` after an embedded `\n`) and the `$` ones. When
    /// `lower` could prove the reset row is an ordinary byte row it sets
    /// `slice_safe`, the two questions coincide, and the precondition lifts.
    pub fn match(self: *const Compose, line: []const u8) bool {
        std.debug.assert(self.slice_safe or std.mem.indexOfScalar(u8, line, '\n') == null);
        if (line.len == 0) return self.empty_match;
        return self.reduce(line);
    }

    /// Does any line of `doc` match? One fused pass over the raw buffer — `\n`
    /// is a table row, so lines never cost a split and every byte is touched
    /// once.
    pub fn docMatch(self: *const Compose, doc: []const u8) bool {
        if (doc.len == 0) return false; // zero lines, so nothing to match
        if (self.reduce(doc)) return true;
        // An empty line carries no byte for the reduction to fold, so the one
        // pattern class that matches one is resolved by looking for the line
        // itself: a leading terminator, or two in a row. Only reachable when the
        // scan already came back false, so it is off the hot path.
        return self.empty_match and
            (doc[0] == '\n' or std.mem.indexOf(u8, doc, "\n\n") != null);
    }

    fn reduce(self: *const Compose, bytes: []const u8) bool {
        const t = self.table;
        const s = self.start_lane;
        const m = self.match_lane;
        return switch (self.width) {
            inline else => |w| switch (self.index) {
                inline else => |ix| lanes.run(w, ix, bytes, t, s, m),
            },
        };
    }
};

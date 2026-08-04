//! irregex — maximal munch: the longest of N patterns, starting exactly here.
//!
//! A `Chorus` answers *which patterns appear somewhere in this haystack*. A
//! `Munch` answers a different question the same machinery can be pointed at:
//! **starting at this exact offset, which pattern matches furthest?** That is
//! the rule every lexer in the world runs on — maximal munch, longest wins —
//! and it is the missing primitive between "does this regex match" and
//! "tokenize this file".
//!
//! Three differences from a chorus, and each one is the same word: *anchored*.
//!
//!   * The determinization is anchored, so the start state is never re-seeded
//!     at interior positions and a dead state ends the walk immediately. A
//!     token that cannot start here is refused in the bytes it takes to know.
//!   * The walk reports the **last** accepting position rather than the first,
//!     because a lexer wants `>>=`, not `>`.
//!   * The offset is the caller's. `longest` is called once per token, from
//!     wherever the previous token ended, and never scans forward looking for
//!     somewhere a pattern would have fit.
//!
//! Three things it hides, because they are what a caller would otherwise get
//! wrong separately:
//!
//! **Any number of patterns.** One automaton's attribution mask is 64 bits
//! wide; a real lexer wants a hundred and fifty terminals. A `Munch` holds as
//! many automata as it needs and takes the longest across them.
//!
//! **A slate is not all-or-nothing.** One pattern outside the linear syntax,
//! or one group whose powerset overruns its budget, must not cost the other
//! hundred and fifty. Groups are admitted by bisection: a group that declines
//! is halved and both halves retried, so a refusal is attributed to the
//! smallest set that actually causes it and everything else still lexes. What
//! could not be taken is named in `declined`, ascending — a caller with a
//! fallback can run it for exactly those patterns, and a caller without one at
//! least knows what it is blind to.
//!
//! **Ties are the grammar's business.** Longest is not the whole rule; a lexer
//! also has to break ties, and the tie-break is a property of the language
//! (declared token precedence, literal-beats-regex, first-declared-wins) rather
//! than of the automaton. So a match reports *every* pattern that reached the
//! winning length, ascending, and has no opinion about which deserves it.
//!
//! **The slate can be narrowed per call.** A real lexer is state-directed: only
//! some terminals are legal where it currently stands, and the longest match
//! among *those* is a different answer from the longest match overall. This is
//! lex's start conditions, tree-sitter's valid-symbol set, and Lezer's
//! contextual tokenizer — and it cannot be recovered by filtering afterward,
//! because a long illegal match hides every short legal one behind it. So the
//! restriction rides the walk (`longestAmong`), where it costs one AND per
//! reported end and nothing per byte.
//!
//! `longest` neither allocates nor fails: the widest possible answer is the
//! number of patterns admitted, and that is known at compile time, so the
//! per-token path is a walk and a sort over a buffer that already exists.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const compile_mod = @import("../../compile/compile.zig");
const powerset = @import("../dfa/powerset.zig");
const subset = @import("../dfa/subset.zig");
const lower = @import("lower.zig");
const split = @import("split.zig");

/// Patterns one automaton can name — the width of its attribution mask.
const per_automaton: usize = subset.max_patterns;

/// The longest match starting at the requested offset.
pub const Match = struct {
    /// Bytes consumed. Zero is a real answer — a pattern like `a*` accepts the
    /// empty string — and a lexer that advances on it will not terminate, so
    /// refusing that is the caller's job and not a thing to hide here.
    len: usize,
    /// Every pattern ordinal reaching exactly `len`, ascending. Borrowed from
    /// the `Munch`, valid until the next call.
    patterns: []const u32,
};

pub const Munch = struct {
    /// The automaton a `Voice` names. Reachable through the field's type
    /// either way; spelled here so that a caller of `adopt` can say it, and
    /// under `Munch` rather than at the root so that it stays the automaton
    /// this seam takes rather than a second public face on the engine.
    pub const Dfa = @import("../dfa/dfa.zig").Dfa;

    /// What `compile` was told. Nameable so that a caller storing the automata
    /// it produced can record the options beside them: the same patterns under
    /// different options are different machines, and only the caller holding
    /// both can say whether what it saved still answers the question it asks.
    pub const Options = lower.Options;

    gpa: std.mem.Allocator,
    voices: []Voice,
    /// Ordinals this slate could not take, ascending. Empty is the normal case.
    declined: []const u32,
    /// Why each of `declined` was refused, in the same order. A refusal that
    /// will not say which of the three it is leaves the caller unable to tell a
    /// pattern this engine cannot express from one it merely would not build,
    /// and those have different owners and different fixes.
    ///
    /// Empty when the `Munch` came from `adopt`, which restores automatons
    /// rather than compiling and so has no refusals of its own to explain.
    because: []const Because,
    /// Rewritten by each `longest`; sized once, to the widest answer possible.
    winners: []u32,
    /// Caller ordinal -> where its bit lives. The inverse of `Voice.ordinals`,
    /// kept so an `Allow` can be filled in the caller's numbering without the
    /// caller ever learning that voices exist.
    seats: []const Seat,

    /// The three ways a pattern can fail to become an automaton. Exhaustive by
    /// construction: `voice` is the only place a refusal is minted.
    pub const Because = enum {
        /// The parser would not accept the pattern's syntax.
        syntax,
        /// The subset construction reached the `max_states` safety bound. Not a
        /// statement about regular languages; a statement about this build.
        states,
        /// A word-boundary assertion reached through the pattern body, which the
        /// caller never asked for by flag. The automaton was built and dropped.
        word_context,
    };

    /// One anchored automaton and the caller ordinals its mask bits stand for.
    /// The indirection is what lets a refusal be a hole rather than a renumber:
    /// bit `i` means `ordinals[i]`, whatever bisection ended up grouping.
    ///
    /// Public for `adopt`, and only for it. `compile` is still the way a slate
    /// becomes a `Munch`; this is the shape a caller has to speak if it wants
    /// to hand back one it stored earlier.
    pub const Voice = struct {
        dfa: *Dfa,
        ordinals: []const u32,
    };

    const Seat = struct {
        voice: u32,
        bit: u6,
        /// False for an ordinal in `declined`, which has no seat anywhere.
        live: bool,
    };

    /// Which patterns a scan may end on. Built once per slate and refilled per
    /// call, so a lexer asking a different question at every token allocates
    /// nothing after the first.
    ///
    /// Addressed in the caller's own ordinals: admitting a pattern the slate
    /// refused is a no-op rather than an error, because a caller that has a
    /// fallback for its blind terminals should not also have to remember which
    /// ones they were.
    pub const Allow = struct {
        words: []u64,

        pub fn deinit(a: *Allow, gpa: std.mem.Allocator) void {
            gpa.free(a.words);
            a.* = undefined;
        }

        pub fn admit(a: *Allow, m: *const Munch, ordinal: u32) void {
            if (ordinal >= m.seats.len) return;
            const seat = m.seats[ordinal];
            if (seat.live) a.words[seat.voice] |= @as(u64, 1) << seat.bit;
        }

        pub fn forbidAll(a: *Allow) void {
            @memset(a.words, 0);
        }

        pub fn admitAll(a: *Allow) void {
            @memset(a.words, ~@as(u64, 0));
        }
    };

    /// An empty permission set sized to this slate.
    pub fn allowNone(m: *const Munch, gpa: std.mem.Allocator) !Allow {
        const words = try gpa.alloc(u64, m.voices.len);
        @memset(words, 0);
        return .{ .words = words };
    }

    /// Lower `patterns` into anchored automata under one set of options.
    ///
    /// Null only when the slate is empty, or when nothing in it could be taken
    /// at all — a partial refusal is reported through `declined` and is not a
    /// failure. Also null for a word-boundary slate: `\b` resolves against the
    /// bytes straddling a gap, and the byte before the caller's offset is not
    /// in the haystack this automaton was determinized over, so the honest
    /// answer is to decline the question rather than answer it from the wrong
    /// context.
    pub fn compile(
        gpa: std.mem.Allocator,
        patterns: []const []const u8,
        opts: lower.Options,
    ) syn.ParseError!?Munch {
        if (patterns.len == 0 or opts.word) return null;

        var voices: std.ArrayList(Voice) = .empty;
        var declined: std.ArrayList(u32) = .empty;
        var because: std.ArrayList(Because) = .empty;
        const all = try gpa.alloc(u32, patterns.len);
        defer gpa.free(all);
        for (all, 0..) |*o, i| o.* = @intCast(i);

        errdefer {
            for (voices.items) |*v| release(gpa, v);
            voices.deinit(gpa);
            declined.deinit(gpa);
            because.deinit(gpa);
        }
        try admit(gpa, patterns, all, opts, &voices, &declined, &because);

        if (voices.items.len == 0) {
            voices.deinit(gpa);
            declined.deinit(gpa);
            because.deinit(gpa);
            return null;
        }

        var taken: usize = 0;
        for (voices.items) |v| taken += v.ordinals.len;

        const seats = try gpa.alloc(Seat, patterns.len);
        @memset(seats, .{ .voice = 0, .bit = 0, .live = false });
        for (voices.items, 0..) |v, vi| {
            for (v.ordinals, 0..) |o, bit| {
                seats[o] = .{ .voice = @intCast(vi), .bit = @intCast(bit), .live = true };
            }
        }

        return .{
            .gpa = gpa,
            .voices = try voices.toOwnedSlice(gpa),
            .declined = try declined.toOwnedSlice(gpa),
            .because = try because.toOwnedSlice(gpa),
            .winners = try gpa.alloc(u32, taken),
            .seats = seats,
        };
    }

    /// Assemble a `Munch` over automata the caller already has, rather than
    /// determinizing a slate to get them.
    ///
    /// Determinization is the expensive half of `compile` and its result is a
    /// pure function of the slate, so a caller holding a slate that does not
    /// change - one shipped inside an artifact - can pay it once, elsewhere,
    /// and arrive here with the answer. `voices` and every `ordinals` inside it
    /// pass to the `Munch` and are freed by its `deinit`; whether the DFA
    /// tables under them are freed too is each `Dfa`'s own `borrowed` flag.
    ///
    /// `npatterns` is the caller's ordinal space, which is wider than the
    /// seated ordinals exactly when something declined. Nothing here re-derives
    /// what a compile would have concluded: an ordinal absent from every voice
    /// and from `declined` simply has no seat, and asking about it is the
    /// documented no-op that asking about a declined one already is.
    pub fn adopt(
        gpa: std.mem.Allocator,
        npatterns: usize,
        voices: []Voice,
        declined: []const u32,
    ) std.mem.Allocator.Error!Munch {
        var taken: usize = 0;
        for (voices) |v| taken += v.ordinals.len;

        const seats = try gpa.alloc(Seat, npatterns);
        errdefer gpa.free(seats);
        @memset(seats, .{ .voice = 0, .bit = 0, .live = false });
        for (voices, 0..) |v, vi| {
            for (v.ordinals, 0..) |o, bit| {
                if (o >= npatterns or bit >= per_automaton) continue;
                seats[o] = .{ .voice = @intCast(vi), .bit = @intCast(bit), .live = true };
            }
        }

        return .{
            .gpa = gpa,
            .voices = voices,
            .declined = declined,
            // `adopt` restores automatons someone else already built, so it has
            // no refusals of its own to explain.
            .because = &.{},
            .winners = try gpa.alloc(u32, taken),
            .seats = seats,
        };
    }

    pub fn deinit(m: *Munch) void {
        for (m.voices) |*v| release(m.gpa, v);
        m.gpa.free(m.voices);
        m.gpa.free(m.declined);
        if (m.because.len > 0) m.gpa.free(m.because);
        m.gpa.free(m.winners);
        m.gpa.free(m.seats);
        m.* = undefined;
    }

    /// The longest match beginning at `at`. Null when nothing starts there.
    ///
    /// `at == haystack.len` is legal and asks the only question left at the end
    /// of the input: does anything accept the empty string.
    pub fn longest(m: *Munch, haystack: []const u8, at: usize) ?Match {
        return m.scan(haystack, at, null);
    }

    /// The longest match beginning at `at` **among the permitted patterns**.
    ///
    /// Not the same as calling `longest` and discarding a result you did not
    /// want: a forbidden pattern reaching further hides every permitted one
    /// behind it, so the restriction has to be part of the walk. It is — one
    /// mask AND per accepting state, nothing per byte.
    pub fn longestAmong(m: *Munch, haystack: []const u8, at: usize, allow: *const Allow) ?Match {
        return m.scan(haystack, at, allow);
    }

    fn scan(m: *Munch, haystack: []const u8, at: usize, allow: ?*const Allow) ?Match {
        std.debug.assert(at <= haystack.len);
        var best: usize = 0;
        var found = false;
        var n: usize = 0;

        for (m.voices, 0..) |v, vi| {
            const permitted = if (allow) |a| a.words[vi] else ~@as(u64, 0);
            if (permitted == 0) continue;
            const end = reach(v.dfa, haystack, at, permitted) orelse continue;
            if (!found or end.at > best) {
                best = end.at;
                found = true;
                n = 0;
            } else if (end.at < best) continue;
            var mask = end.pats;
            while (mask != 0) : (mask &= mask - 1) {
                m.winners[n] = v.ordinals[@ctz(mask)];
                n += 1;
            }
        }
        if (!found) return null;

        // Bits within one voice ascend, but a later voice can tie an earlier
        // one, so the union is not ordered by construction. Saying "ascending"
        // is worth more to a caller applying a first-declared-wins tie-break
        // than "some order that depends on how bisection grouped the slate".
        std.mem.sort(u32, m.winners[0..n], {}, std.sort.asc(u32));
        return .{ .len = best - at, .patterns = m.winners[0..n] };
    }

    /// How many patterns this slate actually lexes with.
    pub fn admitted(m: *const Munch) usize {
        return m.winners.len;
    }

    fn release(gpa: std.mem.Allocator, v: *Voice) void {
        v.dfa.deinit();
        gpa.free(v.ordinals);
    }
};

const End = struct { at: usize, pats: u64 };

/// Walk one automaton forward from `at`, keeping the last position it accepted
/// **with a permitted pattern**. The walk itself is unchanged by `permitted` —
/// same bytes, same states, same dead-state exit — because a forbidden pattern
/// may still be on the path to a permitted longer one.
fn reach(d: *const Munch.Dfa, haystack: []const u8, at: usize, permitted: u64) ?End {
    if (at >= haystack.len) {
        const pats = d.empty_pats & permitted;
        return if (d.empty_match and pats != 0) .{ .at = at, .pats = pats } else null;
    }

    var s = d.start;
    var best: ?End = accepted(d, s, permitted, at);

    const last = haystack.len - 1;
    var i = at;
    while (i <= last) : (i += 1) {
        // The final table resolves `$`, and is correct only on the true last
        // byte of the text — the caller's slice, exactly as for every other
        // walk in this package.
        const tbl = if (i < last) d.trans_in else d.trans_fin;
        s = tbl[s + d.class[haystack[i]]];
        if (s == d.dead) break;
        if (accepted(d, s, permitted, i + 1)) |end| best = end;
    }
    return best;
}

inline fn accepted(d: *const Munch.Dfa, s: u32, permitted: u64, at: usize) ?End {
    if (!d.isMatch(s)) return null;
    const pats = d.patternsAt(s) & permitted;
    return if (pats == 0) null else .{ .at = at, .pats = pats };
}

/// Take `ordinals` as one automaton if it fits and builds; otherwise halve and
/// try both sides.
///
/// One recursion covers two jobs that would otherwise be two mechanisms: a
/// slate wider than one attribution mask has to be split anyway, and a group
/// that declines has to be narrowed to find out who is responsible. Halving
/// answers both, and a group of one that still declines is the answer —
/// that pattern, by name.
fn admit(
    gpa: std.mem.Allocator,
    patterns: []const []const u8,
    ordinals: []const u32,
    opts: lower.Options,
    voices: *std.ArrayList(Munch.Voice),
    declined: *std.ArrayList(u32),
    because: *std.ArrayList(Munch.Because),
) syn.ParseError!void {
    if (ordinals.len == 0) return;
    if (ordinals.len <= per_automaton) {
        switch (try voice(gpa, patterns, ordinals, opts)) {
            .built => |dfa| {
                errdefer dfa.deinit();
                try voices.append(gpa, .{ .dfa = dfa, .ordinals = try gpa.dupe(u32, ordinals) });
                return;
            },
            .refused => |why| if (ordinals.len == 1) {
                // A group's refusal says nothing about any one pattern in it,
                // so only a lone ordinal's reason is recorded; the rest bisect
                // until each names its own.
                try declined.append(gpa, ordinals[0]);
                return because.append(gpa, why);
            },
        }
    }
    const mid = ordinals.len / 2;
    try admit(gpa, patterns, ordinals[0..mid], opts, voices, declined, because);
    try admit(gpa, patterns, ordinals[mid..], opts, voices, declined, because);
}

/// One anchored union over `ordinals`. Terminals first, so state index `i` is
/// mask bit `i` — the contract `subset.ordinals` reads back when it builds the
/// mask, and what `Voice.ordinals` translates on the way out.
fn voice(
    gpa: std.mem.Allocator,
    patterns: []const []const u8,
    ordinals: []const u32,
    opts: lower.Options,
) syn.ParseError!union(enum) { built: *Munch.Dfa, refused: Munch.Because } {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = compile_mod.Compiler{ .gpa = gpa };
    defer c.states.deinit(gpa);

    for (ordinals) |_| _ = try c.push(.match);
    const entries = try arena.alloc(u32, ordinals.len);
    for (ordinals, entries, 0..) |o, *entry, i| {
        const ast = lower.parse(arena, patterns[o], opts) catch return .{ .refused = .syntax };
        entry.* = try c.compileNode(ast, @intCast(i));
    }

    // Balance bounds this recursion and the determinizer's closure stack at
    // `log2 N`; it buys no work, for the reasons `split.tree` records at length.
    const start = try split.tree(&c, entries);
    // Unbudgeted, and this is the one place in the package where that is the
    // conservative choice rather than the reckless one. `max_visits` is a COST
    // policy calibrated for a pattern the user typed a second ago and will run
    // against one haystack; a lexer slate is compiled once and then amortized
    // over every byte of every file for the life of the process, so refusing an
    // automaton to save two milliseconds of build is a trade in the wrong
    // direction by several orders of magnitude. Measured, the budget refuses
    // `\w+`, `\p{L}+`, and `[_\p{XID_Start}][_\p{XID_Continue}]*` — respectively
    // the most common token body in any grammar and how Go, Java, C, Rust, and
    // JavaScript each spell `identifier`. All three build unbudgeted.
    //
    // `max_states` is the SAFETY bound and still applies, so the automaton is
    // still bounded in memory and the build still terminates; a group too large
    // to hold declines exactly as before and `admit` bisects it.
    const outcome = try powerset.build(gpa, c.states.items, start, true, opts.unicode, .unbudgeted);
    return switch (outcome) {
        .declined => .{ .refused = .states },
        .built => |dfa| if (dfa.word_ctx) blk: {
            // An assertion the caller did not ask for by flag, reached through
            // a pattern body. Same reasoning as `opts.word`, discovered later.
            dfa.deinit();
            break :blk .{ .refused = .word_context };
        } else .{ .built = dfa },
    };
}

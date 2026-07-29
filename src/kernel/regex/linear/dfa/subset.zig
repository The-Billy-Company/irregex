//! gist — the subset construction itself, factored out of any policy about *when*
//! to run it. This is the shared determinizer core: byte-class refinement, the
//! epsilon-closure that resolves zero-width assertions, the one-class transition
//! step, and the interning that gives a subset its DFA state id.
//!
//! Two drivers sit on top and they must never disagree about what a pattern means:
//!   * `powerset.zig` runs it **eagerly** to fixpoint over a worklist, then freezes
//!     the tables into the immutable, scratch-free `Dfa`;
//!   * `lazy.zig` runs it **on demand** from inside the search loop, materializing
//!     only the states the haystack actually visits.
//!
//! They share this file rather than each carrying a copy, because the subtle part
//! of determinization is not the worklist — it is `close`, where `^ $ \b \B \< \>`
//! are resolved against position flags. Two transcriptions of that would be two
//! chances to drift, and the differential oracle would then be policing a
//! divergence this factoring makes unrepresentable.

const std = @import("std");
const mix = @import("../../../math/mix.zig");
const syn = @import("../../syntax/syntax.zig");
const bits = @import("../../../math/bits.zig");
const word = @import("../../syntax/word.zig");
const prefilter = @import("../../analysis/prefilter.zig");
const State = syn.State;
const B64 = bits.Field(u64);

/// Unfilled transition slot. In the eager tables this marks a target no interior
/// byte ever reaches (its row is never indexed); in the lazy tables it is the
/// cache-miss sentinel the search loop tests against.
pub const unknown: u32 = std.math.maxInt(u32);

/// What is true of the position BETWEEN two bytes — everything a zero-width
/// assertion is allowed to ask. `word_before`/`word_after` are the word-ness of
/// the bytes straddling the gap; at a haystack edge the absent side is false.
pub const Gap = struct { at_start: bool, at_end: bool, word_before: bool, word_after: bool };

/// The state a zero-width assertion passes control to at this gap, or null when
/// it blocks. THE one transcription of `^ $ \b \B \< \>` in the determinized
/// tier: `subset.close` resolves its worklist through it, and so does the
/// caliper's priority worklist (`../caliper/`). Two traversal policies, one
/// predicate — which is the only part of determinization where a second
/// transcription could silently disagree about what a pattern means.
///
/// `\A`/`\z` are absent by construction: buffer anchors exist only under
/// multiline, where no determinized engine is built at all — every driver
/// declines before it can reach one.
pub fn passes(st: State, g: Gap) ?u32 {
    return switch (st) {
        .assert_start => |o| if (g.at_start) o else null,
        .assert_end => |o| if (g.at_end) o else null,
        .assert_word_b => |o| if (g.word_before != g.word_after) o else null,
        .assert_not_word_b => |o| if (g.word_before == g.word_after) o else null,
        .assert_word_start => |o| if (!g.word_before and g.word_after) o else null,
        .assert_word_end => |o| if (g.word_before and !g.word_after) o else null,
        .assert_buf_start, .assert_buf_end => unreachable,
        .consume, .split, .match => null,
    };
}

/// The byte alphabet collapsed to equivalence classes: two bytes share a class iff
/// no consuming state distinguishes them, which shrinks the transition table from
/// 256 columns to a handful. (RE2 / rust-`regex` `ByteClasses`.)
pub const Classes = struct {
    class: [256]u8,
    rep: [256]u8, // representative byte per class (for `set.has`)
    ncls: u16,

    /// Partition 0..255 and record a representative byte per class. Refines once
    /// per consuming `set`; under `word_ctx` a final refinement by ASCII word-ness
    /// ensures every class is uniformly word or non-word, so a consumed byte's
    /// class fixes its `word_before`.
    pub fn build(states: []const State, word_ctx: bool) Classes {
        var c: Classes = .{ .class = undefined, .rep = undefined, .ncls = 1 };
        @memset(&c.class, 0);
        for (states) |st| switch (st) {
            .consume => |cn| {
                c.ncls = refineBySet(&c.class, &cn.set);
                if (c.ncls == 256) break; // maximally refined — no set can split further
            },
            else => {},
        };
        if (word_ctx and c.ncls < 256) {
            var wset: syn.ByteSet = .{};
            for (0..256) |bi| if (word.isWordByte(@intCast(bi))) wset.set(@intCast(bi));
            c.ncls = refineBySet(&c.class, &wset);
        }
        // Any byte in a class is a valid representative (all members behave identically under every set), so last-write-wins needs no "seen" tracking.
        for (0..256) |bi| c.rep[c.class[bi]] = @intCast(bi);
        return c;
    }
};

/// Split the current partition by one membership predicate: two bytes stay in a
/// class only if they already shared one AND agree on `set`. Returns the new
/// class count. The textbook `ByteClassSet` refinement (RE2/rust-`regex`).
fn refineBySet(class: *[256]u8, set: *const syn.ByteSet) u16 {
    var seen = [_]i16{-1} ** 512; // key = old_class*2 + member ∈ [0,511]
    var newn: u16 = 0;
    for (0..256) |bi| {
        const b: u8 = @intCast(bi);
        const member: usize = @intFromBool(set.has(b));
        const k = @as(usize, class[b]) * 2 + member;
        if (seen[k] < 0) {
            seen[k] = @intCast(newn);
            newn += 1;
        }
        class[b] = @intCast(seen[k]);
    }
    return newn;
}

/// Does the program carry a word-boundary assertion (`\b \B \< \>`)? That is a
/// second determinization axis — see `Dfa`'s word-context notes.
pub fn hasWordContext(states: []const State) bool {
    for (states) |st| switch (st) {
        .assert_word_b, .assert_not_word_b, .assert_word_start, .assert_word_end => return true,
        else => {},
    };
    return false;
}

/// Does the program carry a buffer anchor (`\A`/`\z`)? Those exist only under
/// multiline, where no DFA is built at all, so both drivers decline up front and
/// `close` may treat them as unreachable.
pub fn hasBufferAnchor(states: []const State) bool {
    for (states) |st| switch (st) {
        .assert_buf_start, .assert_buf_end => return true,
        else => {},
    };
    return false;
}

const SetCtx = mix.SliceCtx(u64);
const SetMap = std.HashMap([]const u64, u32, SetCtx, std.hash_map.default_max_load_percentage);

/// The determinizer: the subset map, the NFA-closure scratch, and the transition
/// tables being filled. Each DFA state's key is one heap `[]u64` of length
/// `words+1`: the consume-set bits followed by the match flag (which joins the
/// identity). `map` and `sets` share that buffer; `sets` owns it.
///
/// Rows are appended to `trans_in` / `trans_fin` (+ `trans_in_w` under `word_ctx`)
/// as states are interned, every slot initialized to `unknown`. The eager driver
/// then overwrites every slot; the lazy driver overwrites them as the search asks.
pub const Subset = struct {
    gpa: std.mem.Allocator,
    states: []const State, // the Thompson NFA program
    start_nfa: u32,
    anchored: bool,
    word_ctx: bool, // program carries `\b`/`\B`/`\<`/`\>` ⇒ resolve word context
    words: usize, // u64s per NFA-state bitset = ceil(states.len / 64)
    cls: Classes,

    map: SetMap,
    sets: std.ArrayList([]u64) = .empty, // sets[id] = consume bits ++ [match flag]
    is_match: std.ArrayList(bool) = .empty,
    trans_in: std.ArrayList(u32) = .empty, // interior, NEXT byte non-word (or the sole interior table when !word_ctx)
    trans_in_w: std.ArrayList(u32) = .empty, // interior, NEXT byte a word byte (word_ctx only)
    trans_fin: std.ArrayList(u32) = .empty,
    nstates: u32 = 0,
    dead: u32 = unknown,

    visited: []u64, // closure dedup (one pass)
    out: []u64, // consume-set accumulated by one closure
    stack: []u32, // closure worklist
    key_scratch: []u64, // reusable interning-probe key (`out` ++ match flag)
    sp: usize = 0,
    /// NFA-state visits charged so far — the honest unit of determinization work.
    /// One closure is NOT one unit of cost: it walks the subset it starts from plus
    /// every state its epsilon-edges reach, so a `\w` closure over the ~10³-state
    /// UTF-8 trie costs orders of magnitude more than an alternation's. Counting
    /// closures instead measures `nstates × ncls` — table AREA, a restatement of
    /// size that says nothing about cost, and which crosses any effort ceiling
    /// strictly before a state ceiling it is paired with. The eager driver budgets
    /// on this; the on-demand driver lets it run and never reads it.
    visits: u64 = 0,

    pub fn init(
        gpa: std.mem.Allocator,
        states: []const State,
        start: u32,
        anchored: bool,
        word_ctx: bool,
        cls: Classes,
    ) std.mem.Allocator.Error!Subset {
        const words = B64.words(states.len);
        var s: Subset = .{
            .gpa = gpa,
            .states = states,
            .start_nfa = start,
            .anchored = anchored,
            .word_ctx = word_ctx,
            .words = words,
            .cls = cls,
            .map = SetMap.init(gpa),
            .visited = try gpa.alloc(u64, words),
            .out = try gpa.alloc(u64, words),
            .stack = try gpa.alloc(u32, states.len),
            .key_scratch = try gpa.alloc(u64, words + 1),
        };
        errdefer s.deinit();
        return s;
    }

    /// Release everything the determinizer owns. Safe after a driver has taken the
    /// tables with `toOwnedSlice` (those lists are then empty and their deinit is a
    /// no-op), so success and failure paths share one teardown.
    pub fn deinit(s: *Subset) void {
        s.map.deinit();
        for (s.sets.items) |k| s.gpa.free(k);
        s.sets.deinit(s.gpa);
        s.is_match.deinit(s.gpa);
        s.trans_in.deinit(s.gpa);
        s.trans_in_w.deinit(s.gpa);
        s.trans_fin.deinit(s.gpa);
        s.gpa.free(s.visited);
        s.gpa.free(s.out);
        s.gpa.free(s.stack);
        s.gpa.free(s.key_scratch);
    }

    /// The consume-set of an interned state — the input `step` reads.
    pub fn setOf(s: *const Subset, id: u32) []const u64 {
        return s.sets.items[id][0..s.words];
    }

    fn pushIf(s: *Subset, st: u32) void {
        s.visits += 1;
        if (B64.get(s.visited, st)) return;
        B64.set(s.visited, st);
        s.stack[s.sp] = st;
        s.sp += 1;
    }

    /// Clear the closure scratch (dedup bitset, accumulator, stack) for a fresh pass.
    fn reset(s: *Subset) void {
        @memset(s.visited, 0);
        @memset(s.out, 0);
        s.sp = 0;
    }

    /// Epsilon-close everything currently on the stack into `s.out`, resolving
    /// zero-width assertions through the shared `passes` predicate. Returns
    /// whether `match` was reached. Iterative so a `{1000}`-deep program can't
    /// overflow the call stack.
    fn close(s: *Subset, at_start: bool, at_end: bool, word_before: bool, word_after: bool) bool {
        const g: Gap = .{ .at_start = at_start, .at_end = at_end, .word_before = word_before, .word_after = word_after };
        var matched = false;
        while (s.sp > 0) {
            s.sp -= 1;
            const st = s.stack[s.sp];
            switch (s.states[st]) {
                .consume => B64.set(s.out, st),
                .split => |sp| {
                    s.pushIf(sp.a);
                    s.pushIf(sp.b);
                },
                .match => matched = true,
                else => if (passes(s.states[st], g)) |o| s.pushIf(o),
            }
        }
        return matched;
    }

    /// Seed the start NFA state and epsilon-close it at the given position flags;
    /// result in `s.out`. Used for the start state(s) (BOL) and the empty-line
    /// verdict. `word_before` is always false at BOL (no byte precedes it).
    pub fn closeStart(s: *Subset, at_start: bool, at_end: bool, word_after: bool) bool {
        s.reset();
        s.pushIf(s.start_nfa);
        return s.close(at_start, at_end, false, word_after);
    }

    /// The transition out of consume-set `from` on a byte of class `k`: gather the
    /// `out` of every member accepting the class's representative byte, re-seed the
    /// NFA start when unanchored, then epsilon-close at the resulting gap. `at_start`
    /// is always false (only the start state sits at BOL); `word_before` is the
    /// word-ness of the byte just consumed — well-defined because `word_ctx` classes
    /// are refined by word-ness, so a class is uniformly word or non-word — and
    /// `word_after` (the next byte's word-ness, 0/1, or false at EOL) is supplied by
    /// the caller, which is why the interior table splits into `trans_in`/`trans_in_w`.
    /// Result lands in `s.out`; returns matched.
    pub fn step(s: *Subset, from: []const u64, k: u16, word_after: bool, at_end: bool) bool {
        s.reset();
        const rep = s.cls.rep[k];
        var it = B64.ones(from);
        while (it.next()) |st| {
            s.visits += 1;
            if (s.states[st].consume.set.has(rep)) s.pushIf(s.states[st].consume.out);
        }
        if (!s.anchored) s.pushIf(s.start_nfa);
        return s.close(false, at_end, if (s.word_ctx) word.isWordByte(rep) else false, word_after);
    }

    /// Intern `s.out` + `matched` as a DFA state: id + whether freshly created (so
    /// a driver knows to expand it). The match flag joins the identity — an empty
    /// consume-set that reached `match` (e.g. via `$`) is a distinct state from a
    /// dead one.
    pub fn intern(s: *Subset, matched: bool) std.mem.Allocator.Error!struct { id: u32, is_new: bool } {
        // Probe with the reusable scratch key first — in any real determinization
        // most transitions land on an already-interned state, so allocating a
        // fresh key per call (only to free it on the dup path) is pure churn. Copy
        // into a permanent key only once the state proves genuinely new.
        @memcpy(s.key_scratch[0..s.words], s.out);
        s.key_scratch[s.words] = @intFromBool(matched);
        if (s.map.get(s.key_scratch)) |id| return .{ .id = id, .is_new = false };
        const key = try s.gpa.dupe(u64, s.key_scratch);
        errdefer s.gpa.free(key);
        const id = s.nstates;
        s.nstates += 1;
        try s.map.put(key, id);
        try s.sets.append(s.gpa, key);
        try s.is_match.append(s.gpa, matched);
        try s.trans_in.appendNTimes(s.gpa, unknown, s.cls.ncls);
        try s.trans_fin.appendNTimes(s.gpa, unknown, s.cls.ncls);
        if (s.word_ctx) try s.trans_in_w.appendNTimes(s.gpa, unknown, s.cls.ncls);
        if (!matched and B64.none(s.out)) s.dead = id;
        return .{ .id = id, .is_new = true };
    }

    /// Intern the subset reached from state `id` on class `k` under the given gap
    /// flags, and record it in the matching table. The one operation both drivers
    /// perform; the only difference is when they choose to perform it.
    pub fn expand(s: *Subset, id: u32, k: u16, table: Table) std.mem.Allocator.Error!u32 {
        const matched = s.step(s.setOf(id), k, table.wordAfter(), table.atEnd());
        const r = try s.intern(matched);
        s.tableItems(table)[@as(usize, id) * s.cls.ncls + k] = r.id;
        return r.id;
    }

    /// Which of the three transition tables a lookup belongs to — the interior
    /// byte's successor being a non-word byte, a word byte (`word_ctx` only), or
    /// the line's last byte, where `$` and an EOL `\b` resolve.
    pub const Table = enum {
        interior,
        interior_word,
        final,

        fn wordAfter(t: Table) bool {
            return t == .interior_word;
        }
        fn atEnd(t: Table) bool {
            return t == .final;
        }
    };

    pub fn tableItems(s: *Subset, table: Table) []u32 {
        return switch (table) {
            .interior => s.trans_in.items,
            .interior_word => s.trans_in_w.items,
            .final => s.trans_fin.items,
        };
    }

    /// Materialize the unanchored start state's whole row — every class, interior
    /// and final — so `dwell.ofStart` can read it. The one part of determinization
    /// that is worth doing eagerly even in the on-demand driver: it costs `2×ncls`
    /// closures (≈200 for `\w`, ≈26 for an alternation) and is the difference
    /// between SIMD-skipping a haystack and walking every byte of it.
    pub fn forceStartRow(s: *Subset, start_id: u32) std.mem.Allocator.Error!void {
        var k: u16 = 0;
        while (k < s.cls.ncls) : (k += 1) {
            _ = try s.expand(start_id, k, .interior);
            _ = try s.expand(start_id, k, .final);
        }
    }
};

// The start state's skippable dwell used to be derived here. It moved to
// `../automata/dwell.zig`: the exit set is read off transition rows, so it cannot
// tell which road built them, and both drivers plus the frozen automaton want the
// same rule. This file stays the determinizer core.

//! irregex — subset construction over **minterms**.
//!
//! Structurally this is `dfa/subset.zig` + `dfa/powerset.zig` with the byte
//! alphabet swapped for the predicate one, and it is deliberately the same
//! algorithm: seed, epsilon-close against the position flags, step per symbol,
//! intern, repeat to fixpoint. What changes is the price. A `\w` closure in the
//! byte determinizer walks the ~900-state UTF-8 trie every time it happens;
//! here `\w` is one instruction and one bitmask test, so the visit count
//! collapses to what the pattern's own structure costs — the ASCII figure.
//!
//! The word-context axis and buffer anchors are absent by construction:
//! `program.zig` rejects both, so `close` has four arms and the interior table
//! is single. Everything else the byte determinizer resolves — `^` in the start
//! state, `$` in a separate final table, the unanchored re-seed — is resolved
//! here identically, because the product in `transcribe.zig` inherits it.

const std = @import("std");
const mix = @import("../../../math/mix.zig");
const bits = @import("../../../math/bits.zig");
const program = @import("program.zig");
const alphabet = @import("alphabet.zig");

const CpState = program.CpState;
const B64 = bits.Field(u64);

/// Ceiling on the codepoint-level automaton. Far below the product's own cap:
/// the pattern DFA is the small factor (`\w+X` determinizes to a handful of
/// states) and anything past this is a pathological alternation the byte path
/// should judge instead.
pub const max_states: u32 = 4096;

// File-private control flow (the fault-channel taxonomy): converted to `.declined` at the
// symbolic module boundary — not members of the declared fault taxonomy.
const Decline = error{TooLarge};
const Error = Decline || std.mem.Allocator.Error;

const SetCtx = mix.SliceCtx(u64);
const SetMap = std.HashMap([]const u64, u32, SetCtx, std.hash_map.default_max_load_percentage);

/// The determinized codepoint automaton. Tables are `[state * nmt + minterm]`
/// state ids (never premultiplied — the product reads identities, not offsets).
pub const Automaton = struct {
    gpa: std.mem.Allocator,
    nmt: u16, // minterm count = alphabet size
    nstates: u32,
    trans_in: []u32,
    trans_fin: []u32,
    is_match: []bool,
    start: u32, // BOL: at_start = true
    /// Where a lost UTF-8 sync lands: mid-line the only threads that may still
    /// begin a match are the unanchored re-seed's, and an anchored program has
    /// none — so this is the dead state there.
    reseed: u32,
    /// `reseed` closed at end-of-line, for a resync on the haystack's last byte.
    fin_reseed: u32,
    dead: u32,
    empty_match: bool,
    /// NFA-state visits charged — the same meter `dfa/subset.zig` bills, so the
    /// two determinizations are directly comparable.
    visits: u64,

    pub fn deinit(a: *Automaton) void {
        a.gpa.free(a.trans_in);
        a.gpa.free(a.trans_fin);
        a.gpa.free(a.is_match);
    }
};

/// The determinizer's mutable half — subset map, closure scratch, growing tables.
const Det = struct {
    gpa: std.mem.Allocator,
    prog: *const program.Program,
    anchored: bool,
    words: usize,
    nmt: u16,

    map: SetMap,
    sets: std.ArrayList([]u64) = .empty,
    is_match: std.ArrayList(bool) = .empty,
    trans_in: std.ArrayList(u32) = .empty,
    trans_fin: std.ArrayList(u32) = .empty,
    nstates: u32 = 0,
    dead: u32 = std.math.maxInt(u32),

    visited: []u64,
    out: []u64,
    stack: []u32,
    key: []u64,
    sp: usize = 0,
    visits: u64 = 0,

    /// The unanchored re-seed, precomputed — `seeds[at_end]` is the start's
    /// closure at that gap, `seed_match[at_end]` whether it accepts. Null when
    /// anchored. The byte determinizer's `dfa/subset.zig::seeds` with one
    /// dimension instead of three: this program has no word context, and
    /// `at_start` is false in every step, so a step can present only two gaps.
    seeds: ?[]u64 = null, // 2 x words
    seed_match: [2]bool = @splat(false),

    fn deinit(d: *Det) void {
        if (d.seeds) |sd| d.gpa.free(sd);
        d.map.deinit();
        for (d.sets.items) |k| d.gpa.free(k);
        d.sets.deinit(d.gpa);
        d.is_match.deinit(d.gpa);
        d.trans_in.deinit(d.gpa);
        d.trans_fin.deinit(d.gpa);
        d.gpa.free(d.visited);
        d.gpa.free(d.out);
        d.gpa.free(d.stack);
        d.gpa.free(d.key);
    }

    fn pushIf(d: *Det, st: u32) void {
        d.visits += 1;
        if (B64.get(d.visited, st)) return;
        B64.set(d.visited, st);
        d.stack[d.sp] = st;
        d.sp += 1;
    }

    fn reset(d: *Det) void {
        @memset(d.visited, 0);
        @memset(d.out, 0);
        d.sp = 0;
    }

    /// Epsilon-close the stack into `d.out`, resolving `^`/`$` against the
    /// position flags exactly as `dfa/subset.zig::close` does.
    fn close(d: *Det, at_start: bool, at_end: bool) bool {
        var matched = false;
        while (d.sp > 0) {
            d.sp -= 1;
            const st = d.stack[d.sp];
            switch (d.prog.states[st]) {
                .consume => B64.set(d.out, st),
                .split => |sp| {
                    d.pushIf(sp.a);
                    d.pushIf(sp.b);
                },
                .assert_start => |o| if (at_start) d.pushIf(o),
                .assert_end => |o| if (at_end) d.pushIf(o),
                .match => matched = true,
            }
        }
        return matched;
    }

    fn closeSeed(d: *Det, at_start: bool, at_end: bool) bool {
        d.reset();
        d.pushIf(d.prog.start);
        return d.close(at_start, at_end);
    }

    /// Close the start once per step-reachable gap and keep it, so `step` folds
    /// the re-seed in with a bitset OR instead of re-walking it `nstates x nmt`
    /// times. Sound because epsilon-closure distributes over union: the walk
    /// from `from` and the walk from the start reach each other only through
    /// states both would visit anyway.
    fn primeSeeds(d: *Det) Error!void {
        const buf = try d.gpa.alloc(u64, 2 * d.words);
        d.seeds = buf;
        for ([_]bool{ false, true }, 0..) |at_end, g| {
            d.seed_match[g] = d.closeSeed(false, at_end);
            @memcpy(buf[g * d.words ..][0..d.words], d.out);
        }
    }

    /// Transition out of consume-set `from` on minterm `m`: a consume state
    /// fires iff its predicate accepts the minterm — one bitmask read where the
    /// byte engine walks a trie. Re-seeds when unanchored, then closes.
    fn step(d: *Det, from: []const u64, m: u16, at_end: bool) bool {
        d.reset();
        const alpha = &d.prog.alpha;
        var it = B64.ones(from);
        while (it.next()) |st| {
            d.visits += 1;
            const cn = d.prog.states[st].consume;
            if (alpha.contains(cn.pred, m)) d.pushIf(cn.out);
        }
        var matched = d.close(false, at_end);
        if (d.seeds) |sd| {
            const g = @intFromBool(at_end);
            for (d.out, sd[g * d.words ..][0..d.words]) |*o, v| o.* |= v;
            matched = matched or d.seed_match[g];
            d.visits += d.words; // the fold is real work; the budget must see it
        }
        return matched;
    }

    fn intern(d: *Det, matched: bool) Error!struct { id: u32, is_new: bool } {
        @memcpy(d.key[0..d.words], d.out);
        d.key[d.words] = @intFromBool(matched);
        if (d.map.get(d.key)) |id| return .{ .id = id, .is_new = false };
        if (d.nstates >= max_states) return Decline.TooLarge;
        const key = try d.gpa.dupe(u64, d.key);
        errdefer d.gpa.free(key);
        const id = d.nstates;
        d.nstates += 1;
        try d.map.put(key, id);
        try d.sets.append(d.gpa, key);
        try d.is_match.append(d.gpa, matched);
        try d.trans_in.appendNTimes(d.gpa, 0, d.nmt);
        try d.trans_fin.appendNTimes(d.gpa, 0, d.nmt);
        if (!matched and B64.none(d.out)) d.dead = id;
        return .{ .id = id, .is_new = true };
    }

    fn setOf(d: *const Det, id: u32) []const u64 {
        return d.sets.items[id][0..d.words];
    }

    /// Intern the empty, non-matching sink so `reseed` has somewhere to point
    /// for an anchored program even when no transition ever reaches it.
    fn internDead(d: *Det) Error!u32 {
        d.reset();
        return (try d.intern(false)).id;
    }
};

/// Determinize `prog` over its minterm alphabet to fixpoint.
pub fn build(gpa: std.mem.Allocator, prog: *const program.Program, anchored: bool) Error!Automaton {
    const nmt = prog.alpha.count;
    const words = B64.words(prog.states.len);
    var d = Det{
        .gpa = gpa,
        .prog = prog,
        .anchored = anchored,
        .words = words,
        .nmt = nmt,
        .map = SetMap.init(gpa),
        .visited = try gpa.alloc(u64, words),
        .out = try gpa.alloc(u64, words),
        .stack = try gpa.alloc(u32, prog.states.len),
        .key = try gpa.alloc(u64, words + 1),
    };
    defer d.deinit();

    const empty_match = d.closeSeed(true, true);
    const start = (try d.intern(d.closeSeed(true, false))).id;
    // The two resync landings, interned before the walk so the product can name
    // them unconditionally: mid-line and at end-of-line, both without `^`.
    const reseed = if (anchored) try d.internDead() else (try d.intern(d.closeSeed(false, false))).id;
    const fin_reseed = if (anchored) try d.internDead() else (try d.intern(d.closeSeed(false, true))).id;

    // After the two resync landings are interned (they read `d.out`, which this
    // clobbers) and before any stepping, which is the only reader.
    if (!anchored) try d.primeSeeds();

    var queued: std.ArrayList(bool) = .empty;
    defer queued.deinit(gpa);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(gpa);

    const push = struct {
        fn f(q: *std.ArrayList(bool), w: *std.ArrayList(u32), g: std.mem.Allocator, n: u32, id: u32) std.mem.Allocator.Error!void {
            while (q.items.len < n) try q.append(g, false);
            if (q.items[id]) return;
            q.items[id] = true;
            try w.append(g, id);
        }
    }.f;

    try push(&queued, &work, gpa, d.nstates, start);
    try push(&queued, &work, gpa, d.nstates, reseed);
    var cur: usize = 0;
    while (cur < work.items.len) : (cur += 1) {
        const id = work.items[cur];
        var m: u16 = 0;
        while (m < nmt) : (m += 1) {
            const in = try d.intern(d.step(d.setOf(id), m, false));
            d.trans_in.items[@as(usize, id) * nmt + m] = in.id;
            const fin = try d.intern(d.step(d.setOf(id), m, true));
            d.trans_fin.items[@as(usize, id) * nmt + m] = fin.id;
            try push(&queued, &work, gpa, d.nstates, in.id);
        }
    }

    return .{
        .gpa = gpa,
        .nmt = nmt,
        .nstates = d.nstates,
        .trans_in = try d.trans_in.toOwnedSlice(gpa),
        .trans_fin = try d.trans_fin.toOwnedSlice(gpa),
        .is_match = try d.is_match.toOwnedSlice(gpa),
        .start = start,
        .reseed = reseed,
        .fin_reseed = fin_reseed,
        .dead = d.dead,
        .empty_match = empty_match,
        .visits = d.visits,
    };
}

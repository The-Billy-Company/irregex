//! gist — determinization that remembers which thread was preferred.
//!
//! `dfa/subset.zig` interns a state as a *set* of NFA states, which is all a
//! boolean answer needs: does anything match. A span needs more. `a|ab` must
//! report `a` and `a+` must report the whole run, so the engine has to know
//! which surviving thread OUTRANKS which — and a bitset has thrown that away.
//!
//! So a state here is an **ordered list** in priority order, and the closure is
//! a strict priority DFS: `split{a,b}` explores `a` to exhaustion before `b`,
//! and dedup happens on POP rather than on push, so a state shared by two
//! threads settles at the rank of the better one. On top of that sits the one
//! rule that makes leftmost-first fall out (RE2 / rust-`regex`'s match
//! dominance): reaching `match` **abandons the rest of the worklist**, because
//! every thread still on it is worse than a match already in hand. The
//! unanchored re-seed is pushed under everything else, so once a match is live
//! no new start can displace it — which is exactly "leftmost".
//!
//! One `Machine` runs forwards with dominance to find where a match ends;
//! another runs backwards, anchored and without dominance, to find where it
//! began. Same closure, same interning, same memo — the direction lives only in
//! the caller's loop (`caliper.zig`), and `subset.passes` resolves `^ $ \b \B
//! \< \>` for both, so no second transcription of the assertions exists.
//!
//! **Quitting is a first-class answer**, as it is for the lazy boolean DFA: a
//! pattern whose determinization outgrows the budget sets `quit`, and the
//! caller runs the Pike VM instead. Declining costs throughput, never
//! correctness.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const subset = @import("../dfa/subset.zig");
const bits = @import("../../../../primitives/bits.zig");

const State = syn.State;
const B64 = bits.Field(u64);
const unknown = subset.unknown;

/// Program-proportional memo ceiling, bounded against tiny and Unicode NFAs —
/// the same shape as the lazy boolean DFA's, and for the same reason: a large
/// class can describe a small automaton, so the cap is on bytes spent, not
/// states discovered.
const min_budget: usize = 128 * 1024;
const max_budget: usize = 2 * 1024 * 1024;

/// A gap's identity as far as the memo is concerned: the position predicates a
/// transition's closure can consult. Four bits, so an assertion-free program
/// uses four rows per state and only a word-bearing one pays sixteen.
fn kindOf(g: subset.Gap) u4 {
    return @as(u4, @intFromBool(g.at_start)) |
        (@as(u4, @intFromBool(g.at_end)) << 1) |
        (@as(u4, @intFromBool(g.word_before)) << 2) |
        (@as(u4, @intFromBool(g.word_after)) << 3);
}

/// One direction's immutable configuration. Shared across threads; every
/// mutable byte lives in a `Cache`.
pub const Machine = struct {
    states: []const State,
    start_nfa: u32,
    cls: *const subset.Classes,
    /// Leftmost-first match dominance — the forward pass only. The backward
    /// pass asks "how far left can a match reach", which is a question about
    /// the set, not its order.
    dominate: bool,
    /// Program carries `\b`/`\B`/`\<`/`\>`, so a gap's word context selects the
    /// transition and the memo needs all sixteen gap shapes.
    word_ctx: bool,

    /// Memo rows per state: one per gap shape, doubled because whether the
    /// transition re-seeds the start is part of the question being memoized.
    fn rows(m: *const Machine) usize {
        return @as(usize, if (m.word_ctx) 16 else 4) * 2;
    }
    fn stride(m: *const Machine) usize {
        return m.rows() * m.cls.ncls;
    }
};

const KeyCtx = struct {
    pub fn hash(_: KeyCtx, k: []const u32) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(k));
    }
    pub fn eql(_: KeyCtx, a: []const u32, b: []const u32) bool {
        return std.mem.eql(u32, a, b);
    }
};
const KeyMap = std.HashMap([]const u32, u32, KeyCtx, std.hash_map.default_max_load_percentage);

/// Per-thread mutable half: the states discovered so far, their transitions,
/// and the closure scratch. Caller-owned, exactly like the Pike VM's `Sim` and
/// the lazy DFA's `Cache`, so the compiled pattern stays immutable and shared.
pub const Cache = struct {
    gpa: std.mem.Allocator,
    m: *const Machine,

    map: KeyMap,
    keys: std.ArrayList([]u32) = .empty, // keys[id] = priority order ++ [match flag]
    trans: std.ArrayList(u32) = .empty,
    nstates: u32 = 0,

    /// The entry state per gap shape. `enter` is paid once per span — 1.5M
    /// times over a match-dense corpus — and its closure answer depends on
    /// nothing but the gap's four predicates, so it is memoized like any other
    /// transition rather than recomputed per match.
    entry: [16]u32 = @splat(unknown),

    visited: []u64,
    stack: []u32,
    order: []u32,
    key_scratch: []u32,
    sp: usize = 0,
    norder: usize = 0,

    budget: usize,
    /// Set once the memo outgrew its budget. Sticky — the caller falls back to
    /// the Pike VM for the rest of this pattern's life on this thread.
    quit: bool = false,

    pub fn init(gpa: std.mem.Allocator, m: *const Machine) std.mem.Allocator.Error!Cache {
        const n = m.states.len;
        var c: Cache = .{
            .gpa = gpa,
            .m = m,
            .map = KeyMap.init(gpa),
            // Dedup on pop means a state can sit on the worklist once per
            // in-edge: two per split, one per everything else, plus one seed
            // per member of the set being stepped.
            .visited = try gpa.alloc(u64, B64.words(n)),
            .stack = try gpa.alloc(u32, 3 * n + 2),
            .order = try gpa.alloc(u32, n),
            .key_scratch = try gpa.alloc(u32, n + 1),
            .budget = std.math.clamp(n * 64, min_budget, max_budget),
        };
        errdefer c.deinit();
        return c;
    }

    pub fn deinit(c: *Cache) void {
        c.map.deinit();
        for (c.keys.items) |k| c.gpa.free(k);
        c.keys.deinit(c.gpa);
        c.trans.deinit(c.gpa);
        c.gpa.free(c.visited);
        c.gpa.free(c.stack);
        c.gpa.free(c.order);
        c.gpa.free(c.key_scratch);
        c.* = undefined;
    }

    /// A state with no surviving thread — the sink both search loops stop on.
    /// Emptiness is the whole test, and it must not be conditioned on the match
    /// flag: match dominance's ordinary outcome is a set truncated to nothing
    /// (`a+?` after one `a`, or any pattern whose match outranks every thread
    /// still running). Treating that as live would step from an empty set,
    /// which for an unanchored machine re-seeds the start — silently restarting
    /// the search and reporting some later match as if it were the leftmost.
    pub fn isDead(c: *const Cache, id: u32) bool {
        return c.keys.items[id].len == 1; // the match flag, and nothing else
    }

    pub fn matched(c: *const Cache, id: u32) bool {
        const k = c.keys.items[id];
        return k[k.len - 1] != 0;
    }

    fn push(c: *Cache, st: u32) void {
        c.stack[c.sp] = st;
        c.sp += 1;
    }

    fn reset(c: *Cache) void {
        @memset(c.visited, 0);
        c.sp = 0;
        c.norder = 0;
    }

    /// Drain the worklist in priority order into `c.order`, resolving zero-width
    /// assertions through the shared predicate. Returns whether `match` was
    /// reached; under `dominate` that return ABANDONS the remaining worklist,
    /// which is the whole of leftmost-first.
    fn close(c: *Cache, g: subset.Gap) bool {
        var hit = false;
        while (c.sp > 0) {
            c.sp -= 1;
            const st = c.stack[c.sp];
            if (B64.get(c.visited, st)) continue;
            B64.set(c.visited, st);
            switch (c.m.states[st]) {
                .consume => {
                    c.order[c.norder] = st;
                    c.norder += 1;
                },
                // Push the worse branch first so the better one pops first.
                .split => |sp| {
                    c.push(sp.b);
                    c.push(sp.a);
                },
                .match => {
                    hit = true;
                    if (c.m.dominate) return true;
                },
                else => if (subset.passes(c.m.states[st], g)) |o| c.push(o),
            }
        }
        return hit;
    }

    /// Intern `c.order[0..norder] ++ [hit]` as a DFA state.
    fn intern(c: *Cache, hit: bool) std.mem.Allocator.Error!u32 {
        const n = c.norder;
        @memcpy(c.key_scratch[0..n], c.order[0..n]);
        c.key_scratch[n] = @intFromBool(hit);
        const probe = c.key_scratch[0 .. n + 1];
        if (c.map.get(probe)) |id| return id;

        const key = try c.gpa.dupe(u32, probe);
        errdefer c.gpa.free(key);
        const id = c.nstates;
        try c.map.put(key, id);
        try c.keys.append(c.gpa, key);
        try c.trans.appendNTimes(c.gpa, unknown, c.m.stride());
        c.nstates += 1;
        return id;
    }

    /// Seed the start state and close it at this gap — the entry point of a
    /// search, and (unanchored) of nothing else.
    pub fn enter(c: *Cache, g: subset.Gap) ?u32 {
        if (c.quit) return null;
        const kind = kindOf(g);
        if (c.entry[kind] != unknown) return c.entry[kind];
        c.reset();
        c.push(c.m.start_nfa);
        const hit = c.close(g);
        const id = c.settle(hit) orelse return null;
        c.entry[kind] = id;
        return id;
    }

    fn settle(c: *Cache, hit: bool) ?u32 {
        if (c.trans.items.len * @sizeOf(u32) > c.budget) {
            c.quit = true;
            return null;
        }
        return c.intern(hit) catch {
            c.quit = true;
            return null;
        };
    }

    /// The state reached from `id` by consuming a byte of class `k` and landing
    /// at a gap of shape `g`, optionally starting a fresh match there. Memoized
    /// per (state, gap shape, seeding, class); a miss determinizes exactly the
    /// one transition the haystack asked for.
    ///
    /// `seed` is the unanchored search's re-start, and the caller turns it OFF
    /// the moment a match is in hand. It has to live here rather than as a
    /// low-priority thread inside the set, and that placement puts it outside
    /// dominance's reach — so without the caller's switch an unanchored machine
    /// would keep opening new matches after one had already been found, and
    /// report whichever finished last as though it were the leftmost.
    pub fn step(c: *Cache, id: u32, k: u16, g: subset.Gap, seed: bool) ?u32 {
        if (c.quit) return null;
        const row = @as(usize, kindOf(g)) * 2 + @intFromBool(seed);
        const slot = (@as(usize, id) * c.m.rows() + row) * c.m.cls.ncls + k;
        const memo = c.trans.items[slot];
        if (memo != unknown) return memo;

        const from = c.keys.items[id];
        const rep = c.m.cls.rep[k];
        c.reset();
        // Lowest priority goes on first: a re-seed sits beneath every thread
        // already in flight, so an older thread always outranks a younger start.
        if (seed) c.push(c.m.start_nfa);
        var i = from.len - 1; // trailing match flag is not a state
        while (i > 0) {
            i -= 1;
            const st = from[i];
            if (c.m.states[st].consume.set.has(rep)) c.push(c.m.states[st].consume.out);
        }
        const hit = c.close(g);
        const id2 = c.settle(hit) orelse return null;
        c.trans.items[slot] = id2;
        return id2;
    }
};

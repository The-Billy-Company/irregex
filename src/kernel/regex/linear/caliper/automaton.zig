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
const mix = @import("../../../math/mix.zig");
const syn = @import("../../syntax/syntax.zig");
const subset = @import("../dfa/subset.zig");
const bits = @import("../../../math/bits.zig");

const State = syn.State;
const B64 = bits.Field(u64);

/// **The currency of the search loop**, and the reason its inner loop has no
/// multiply in it.
///
/// A cell names a state by its OFFSET INTO THE MEMO (`id * stride`) rather than
/// by its id, and carries that state's `Mark` in bits above the offset rather
/// than in a second array. Both choices exist to empty `glide`'s dependency
/// chain, which used to hold two things it does not need: the `imul` that
/// re-derives a row from an id every byte, and a dependent load into `marks` to
/// ask whether to stop. Now the recurrence is a bare `off = cell` and the
/// stopping question is answered by the value already in the register — the
/// same chain a premultiplied lazy DFA walk has, which is the walk this engine
/// has to keep up with.
///
/// ```text
///   [0, 24)   the state's memo offset
///   [24, 26)  its `Mark` — matched, dead, or neither
///   all ones  `unknown`: this transition has not been determinized
/// ```
///
/// The split is what makes one compare separate the fast path from BOTH exits:
/// a plain live state is numerically below every marked one and below
/// `unknown`, so `raw < plain` is the whole test. Twenty-four bits is ~32x the
/// memo's own ceiling (`max_budget / 4` entries), and `settle` refuses to mint
/// a state that would reach it, so the fields cannot collide.
pub const Cell = enum(u32) {
    unknown = subset.unknown,
    _,

    const off_bits = 24;
    const off_mask: u32 = (1 << off_bits) - 1;
    /// Everything at or above this is marked or undetermined — never a state
    /// the walk may simply continue from.
    const plain: u32 = 1 << off_bits;

    fn make(off: u32, m: u8) Cell {
        return @enumFromInt(off | (@as(u32, m) << off_bits));
    }

    /// Where this state's transitions begin. Undefined for `unknown`, which is
    /// never a state one stands on.
    pub fn offset(c: Cell) u32 {
        return @intFromEnum(c) & off_mask;
    }

    fn mark(c: Cell) u8 {
        return @truncate(@intFromEnum(c) >> off_bits);
    }

    pub fn matched(c: Cell) bool {
        return c.mark() & Mark.matched != 0;
    }

    pub fn dead(c: Cell) bool {
        return c.mark() & Mark.dead != 0;
    }
};

/// What the search loop needs to know about a state it just landed on, in the
/// two bits it takes to say it. Rides inside a `Cell`, so asking costs no load.
const Mark = struct {
    const matched: u8 = 1;
    /// No surviving thread — the sink both search loops stop on. Emptiness is
    /// the whole test, and it must not be conditioned on the match flag: match
    /// dominance's ordinary outcome is a set truncated to nothing (`a+?` after
    /// one `a`, or any pattern whose match outranks every thread still
    /// running). Treating that as live would step from an empty set, which for
    /// an unanchored machine re-seeds the start — silently restarting the
    /// search and reporting some later match as if it were the leftmost.
    const dead: u8 = 2;

    fn of(hit: bool, norder: usize) u8 {
        return (if (hit) Mark.matched else 0) | (if (norder == 0) Mark.dead else 0);
    }
};

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

/// `kindOf`'s inverse — the gap a memo row stands for. Only `zeroWidth` needs
/// it: to ask a question about *every* gap shape you have to be able to name one
/// without a haystack position to read it off.
fn gapOf(kind: u4) subset.Gap {
    return .{
        .at_start = kind & 1 != 0,
        .at_end = kind & 2 != 0,
        .word_before = kind & 4 != 0,
        .word_after = kind & 8 != 0,
    };
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

const KeyCtx = mix.SliceCtx(u32);
const KeyMap = std.HashMap([]const u32, u32, KeyCtx, std.hash_map.default_max_load_percentage);

/// Per-thread mutable half: the states discovered so far, their transitions,
/// and the closure scratch. Caller-owned, exactly like the Pike VM's `Sim` and
/// the lazy DFA's `Cache`, so the compiled pattern stays immutable and shared.
pub const Cache = struct {
    gpa: std.mem.Allocator,
    m: *const Machine,

    map: KeyMap,
    keys: std.ArrayList([]u32) = .empty, // keys[id] = priority order ++ [match flag]
    trans: std.ArrayList(Cell) = .empty,
    nstates: u32 = 0,

    /// The entry state per gap shape. `enter` is paid once per span — 1.5M
    /// times over a match-dense corpus — and its closure answer depends on
    /// nothing but the gap's four predicates, so it is memoized like any other
    /// transition rather than recomputed per match.
    entry: [16]Cell = @splat(.unknown),

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
    /// Memo for `zeroWidth` — one answer per machine, decided on first ask.
    zero_width: ?bool = null,

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

    /// Intern `c.order[0..norder] ++ [hit]` as a DFA state, and hand back the
    /// cell that names it. The `Mark` is a pure function of that key — `hit` is
    /// part of it and `norder` is its length — so re-deriving it here for a
    /// state already interned is exact, which is what lets the memo carry the
    /// mark inline and keep no `marks` array at all.
    fn intern(c: *Cache, hit: bool) std.mem.Allocator.Error!Cell {
        const n = c.norder;
        @memcpy(c.key_scratch[0..n], c.order[0..n]);
        c.key_scratch[n] = @intFromBool(hit);
        const probe = c.key_scratch[0 .. n + 1];
        const mark = Mark.of(hit, n);
        if (c.map.get(probe)) |id| return Cell.make(@intCast(id * c.m.stride()), mark);

        const key = try c.gpa.dupe(u32, probe);
        errdefer c.gpa.free(key);
        const id = c.nstates;
        const off: u32 = @intCast(c.trans.items.len); // == id * stride, by construction
        try c.map.put(key, id);
        try c.keys.append(c.gpa, key);
        try c.trans.appendNTimes(c.gpa, .unknown, c.m.stride());
        c.nstates += 1;
        return Cell.make(off, mark);
    }

    /// Seed the start state and close it at this gap — the entry point of a
    /// search, and (unanchored) of nothing else.
    pub fn enter(c: *Cache, g: subset.Gap) ?Cell {
        if (c.quit) return null;
        const kind = kindOf(g);
        if (c.entry[kind] != .unknown) return c.entry[kind];
        c.reset();
        c.push(c.m.start_nfa);
        const hit = c.close(g);
        const cell = c.settle(hit) orelse return null;
        c.entry[kind] = cell;
        return cell;
    }

    /// Can a match be **zero-width** — does the start closure reach `match` at
    /// any gap shape at all? This is the licence for a caller to skip bytes: a
    /// search that jumps to the next position a byte could be *consumed* from
    /// can only lose a match that consumes nothing, so a machine that answers
    /// `false` here can be driven by a first-byte prefilter, and one that
    /// answers `true` must be walked gap by gap.
    ///
    /// Asked of the automaton rather than read off the pattern's flags on
    /// purpose. `eol_empty` (`\d*$`) and `nullable` (`x|\b$`) are two separately
    /// derived views of this same fact, and either could drift from what the
    /// determinizer actually does; the start closure cannot. `enter` is memoized
    /// per shape, so the survey costs at most sixteen closures once, and a
    /// budget quit answers `true` — declining an optimization, never a match.
    pub fn zeroWidth(c: *Cache) bool {
        if (c.zero_width) |v| return v;
        const shapes: u5 = if (c.m.word_ctx) 16 else 4; // word-free ⇒ bits 2,3 are never set
        var kind: u5 = 0;
        const answer = while (kind < shapes) : (kind += 1) {
            const cell = c.enter(gapOf(@intCast(kind))) orelse break true;
            if (cell.matched()) break true;
        } else false;
        c.zero_width = answer;
        return answer;
    }

    fn settle(c: *Cache, hit: bool) ?Cell {
        // The second ceiling is what keeps a `Cell`'s offset field from
        // reaching its mark bits. The budget already forbids it ~32x over, so
        // this only has to be true, not tight.
        if (c.trans.items.len * @sizeOf(u32) > c.budget or c.trans.items.len > Cell.off_mask) {
            c.quit = true;
            return null;
        }
        return c.intern(hit) catch {
            c.quit = true;
            return null;
        };
    }

    /// Which end of a run of bytes the search is walking from. Only the byte
    /// order differs; the memo, the row, and the stopping rule are one
    /// transcription for both jaws.
    pub const Dir = enum { forward, backward };

    /// How far a memo-only run got. `len` bytes were consumed and `cell` is the
    /// state after them; the run stopped *before* the byte it could not decide,
    /// so a caller resumes at exactly that byte.
    pub const Run = struct { cell: Cell, len: usize };

    /// Consume bytes through the memo **and nothing else**, for a run the caller
    /// has proven keeps one row: the same gap shape at every landing, and one
    /// seeding decision throughout.
    ///
    /// That premise is what makes this worth having. `step` must recompute the
    /// row and reload the memo's base pointer on every byte, because it is a
    /// call that might determinize and reallocate. Here the row is computed once
    /// and the tables are borrowed once, so the loop reduces to a class lookup
    /// and one dependent load per byte — the same shape a premultiplied lazy DFA
    /// walk has, which is the walk this engine has to keep up with.
    ///
    /// It stops before the first byte whose transition is not determinized yet,
    /// and after any byte whose target is marked. Both are decisions only the
    /// caller can make — a miss needs the closure, a mark ends or extends a
    /// match — and keeping them out of the loop is precisely what keeps the loop
    /// free of anything that could leave it.
    ///
    /// Both stopping conditions are read off the loaded `Cell` and nothing
    /// else, by the single `raw < plain` compare: a plain cell IS the next
    /// offset, so the recurrence is `off = raw` with no multiply to re-derive a
    /// row and no second load to ask whether this state is interesting. That is
    /// worth ~2.1x per byte on a saturated line, measured against a transcript
    /// of the loop it replaces — see `Cell`.
    pub fn glide(c: *const Cache, from: Cell, g: subset.Gap, seed: bool, bytes: []const u8, comptime dir: Dir) Run {
        const base = (@as(usize, kindOf(g)) * 2 + @intFromBool(seed)) * @as(usize, c.m.cls.ncls);
        const trans = c.trans.items;
        const class = &c.m.cls.class;
        var off = from.offset();
        var landed = from;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = if (dir == .backward) bytes[bytes.len - 1 - i] else bytes[i];
            const next = trans[@as(usize, off) + base + class[b]];
            const raw = @intFromEnum(next);
            if (raw >= Cell.plain) { // marked, or not determinized yet
                if (next == .unknown) break;
                landed = next;
                i += 1;
                break;
            }
            off = raw;
            landed = next;
            i += 1;
        }
        return .{ .cell = landed, .len = i };
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
    pub fn step(c: *Cache, cell: Cell, k: u16, g: subset.Gap, seed: bool) ?Cell {
        if (c.quit) return null;
        const off = cell.offset();
        const row = @as(usize, kindOf(g)) * 2 + @intFromBool(seed);
        // `off` already IS `id * rows * ncls`, so the row lands by addition —
        // the two multiplies this address used to need are gone with the id.
        const slot = @as(usize, off) + row * c.m.cls.ncls + k;
        const memo = c.trans.items[slot];
        if (memo != .unknown) return memo;

        // Only a miss needs the state back by name, and a miss is about to run
        // a whole closure, so the one division lands where nothing can feel it.
        const from = c.keys.items[@divExact(off, @as(u32, @intCast(c.m.stride())))];
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
        const to = c.settle(hit) orelse return null; // may have grown `trans`
        c.trans.items[slot] = to;
        return to;
    }
};

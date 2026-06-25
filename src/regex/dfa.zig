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
//! Determinization (powerset) over the Thompson NFA in `syntax.zig`:
//!   * **Byte classes** — bytes that no consuming state distinguishes collapse to
//!     one equivalence class, shrinking the alphabet (and the transition table)
//!     from 256 to a handful of columns. (RE2/rust-`regex` `ByteClasses`.)
//!   * **Line anchors** — `lineMatch` runs on a single line, so the only
//!     boundaries are BOL (before byte 0) and EOL (after the last byte). `^` is
//!     resolved once in the start state (`at_start=true`); `$` is resolved by a
//!     separate **final** transition table closed with `at_end=true` — the
//!     single-line analogue of RE2's one-byte match delay / EOI sentinel. So we
//!     keep two tables: `trans_in` (interior bytes) and `trans_fin` (last byte).
//!   * **Unanchored search** re-seeds the NFA start into every transition (the
//!     standard `.*`-prefix trick); `^`-anchored programs (`startsAnchored`) do
//!     not, and dead-state to `false` the instant their thread set drains.
//!
//! Built **eagerly** at compile (these patterns are tiny) into an immutable,
//! scratch-free automaton freely shared across threads — exactly like the bit
//! engine it supersedes. Powerset blow-up is bounded: past `max_states` the build
//! bails to null and the caller keeps the Pike VM, which stays the correctness
//! reference (the differential-fuzz oracle). Counted repetition (`a{1000}`) yields
//! a linear, not exponential, DFA, so the cap only ever trips on genuinely
//! pathological alternations.

const std = @import("std");
const syn = @import("syntax.zig");
const State = syn.State;

/// Powerset state cap. Beyond this the eager build bails to null (Pike fallback).
/// Sized so a linear `{n}`-expanded program (DFA ≈ n states) always fits while a
/// pathological exponential alternation can't blow compile time or memory.
pub const max_states: u32 = 4096;

const unknown: u32 = std.math.maxInt(u32); // unfilled transition slot sentinel

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
        var i: usize = 0;
        while (i < last) : (i += 1) {
            s = self.trans_in[@as(usize, s) * ncls + self.class[line[i]]];
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
                    // …but only abandon the line if content remains: the LAST content
                    // byte still gets `trans_fin` below, whose `$`-resolving (at_end)
                    // closure can match where the interior (at_end=false) one died.
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

const SetCtx = struct {
    pub fn hash(_: SetCtx, k: []const u64) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(k));
    }
    pub fn eql(_: SetCtx, a: []const u64, b: []const u64) bool {
        return std.mem.eql(u64, a, b);
    }
};
const SetMap = std.HashMap([]const u64, u32, SetCtx, std.hash_map.default_max_load_percentage);

fn setBit(bits: []u64, i: u32) void {
    bits[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
}
fn hasBit(bits: []const u64, i: u32) bool {
    return (bits[i >> 6] >> @intCast(i & 63)) & 1 != 0;
}
fn isZero(bits: []const u64) bool {
    for (bits) |w| if (w != 0) return false;
    return true;
}

/// Builder scratch — the powerset machinery (subset map, NFA-closure stack,
/// reusable bitsets) that produces the immutable `Dfa`. Discarded after `build`.
/// Each DFA state's key is one heap `[]u64` of length `words+1`: the consume-set
/// bits followed by the match flag (which joins the identity). `map` and `sets`
/// share that buffer; `sets` owns it (freed once on teardown).
const Builder = struct {
    gpa: std.mem.Allocator,
    states: []const State, // the Thompson NFA program
    start_nfa: u32,
    anchored: bool,
    words: usize, // u64s per NFA-state bitset = ceil(states.len / 64)
    ncls: u16,
    rep: *const [256]u8, // representative byte per class (for `set.has`)

    map: SetMap,
    sets: std.ArrayList([]u64), // sets[id] = consume bits ++ [match flag]
    is_match: std.ArrayList(bool),
    trans_in: std.ArrayList(u32),
    trans_fin: std.ArrayList(u32),
    queued: std.ArrayList(bool),
    worklist: std.ArrayList(u32),
    nstates: u32 = 0,
    dead: u32 = unknown,

    visited: []u64, // closure dedup (one pass)
    out: []u64, // consume-set accumulated by one closure
    stack: []u32, // closure worklist
    sp: usize = 0,

    fn pushIf(b: *Builder, s: u32) void {
        if (!hasBit(b.visited, s)) {
            setBit(b.visited, s);
            b.stack[b.sp] = s;
            b.sp += 1;
        }
    }

    /// Epsilon-close everything currently on the stack into `b.out`, resolving
    /// `^`/`$` against the boundary flags. Returns whether `match` was reached.
    /// Iterative so a `{1000}`-deep program can't overflow the call stack.
    fn close(b: *Builder, at_start: bool, at_end: bool) bool {
        var matched = false;
        while (b.sp > 0) {
            b.sp -= 1;
            const s = b.stack[b.sp];
            switch (b.states[s]) {
                .consume => setBit(b.out, s),
                .split => |sp| {
                    b.pushIf(sp.a);
                    b.pushIf(sp.b);
                },
                .assert_start => |o| if (at_start) b.pushIf(o),
                .assert_end => |o| if (at_end) b.pushIf(o),
                .match => matched = true,
            }
        }
        return matched;
    }

    /// Seed the start NFA state and epsilon-close it at the given boundary flags;
    /// result in `b.out`. Used for the start state (BOL) and empty-line verdict.
    fn closeStart(b: *Builder, at_start: bool, at_end: bool) bool {
        @memset(b.visited, 0);
        @memset(b.out, 0);
        b.sp = 0;
        b.pushIf(b.start_nfa);
        return b.close(at_start, at_end);
    }

    /// The transition out of consume-set `from` on a byte of class `k`: gather the
    /// `out` of every member accepting the class's representative byte, re-seed the
    /// NFA start when unanchored, then epsilon-close (at_start always false — only
    /// the start state sits at BOL). Result lands in `b.out`; returns matched.
    fn step(b: *Builder, from: []const u64, k: u16, at_end: bool) bool {
        @memset(b.visited, 0);
        @memset(b.out, 0);
        b.sp = 0;
        const rep = b.rep[k];
        var wi: usize = 0;
        while (wi < b.words) : (wi += 1) {
            var w = from[wi];
            while (w != 0) : (w &= w - 1) {
                const s: u32 = @intCast(wi * 64 + @ctz(w));
                if (b.states[s].consume.set.has(rep)) b.pushIf(b.states[s].consume.out);
            }
        }
        if (!b.anchored) b.pushIf(b.start_nfa);
        return b.close(false, at_end);
    }

    /// Intern `b.out` + `matched` as a DFA state: id + whether freshly created (so
    /// the caller enqueues interior targets for expansion). The match flag joins
    /// the identity — an empty consume-set that reached `match` (e.g. via `$`) is a
    /// distinct state from a dead one.
    fn intern(b: *Builder, matched: bool) std.mem.Allocator.Error!struct { id: u32, is_new: bool } {
        const key = try b.gpa.alloc(u64, b.words + 1);
        errdefer b.gpa.free(key);
        @memcpy(key[0..b.words], b.out);
        key[b.words] = @intFromBool(matched);
        if (b.map.get(key)) |id| {
            b.gpa.free(key);
            return .{ .id = id, .is_new = false };
        }
        const id = b.nstates;
        b.nstates += 1;
        try b.map.put(key, id);
        try b.sets.append(b.gpa, key);
        try b.is_match.append(b.gpa, matched);
        try b.queued.append(b.gpa, false);
        try b.trans_in.appendNTimes(b.gpa, unknown, b.ncls);
        try b.trans_fin.appendNTimes(b.gpa, unknown, b.ncls);
        if (!matched and isZero(b.out)) b.dead = id;
        return .{ .id = id, .is_new = true };
    }

    fn enqueue(b: *Builder, id: u32) std.mem.Allocator.Error!void {
        if (!b.queued.items[id]) {
            b.queued.items[id] = true;
            try b.worklist.append(b.gpa, id);
        }
    }
};

/// Partition 0..255 into equivalence classes — two bytes share a class iff no
/// consuming state's set distinguishes them — and record a representative byte
/// per class. Returns the class count (≤ 256). Refines the partition once per
/// consuming `set`: the textbook `ByteClassSet` build (RE2/rust-`regex`).
fn buildClasses(states: []const State, class: *[256]u8, rep: *[256]u8) u16 {
    for (class) |*c| c.* = 0;
    var ncls: u16 = 1;
    for (states) |st| switch (st) {
        .consume => |cn| {
            var seen = [_]i16{-1} ** 512; // key = old_class*2 + member ∈ [0,511]
            var newn: u16 = 0;
            for (0..256) |bi| {
                const b: u8 = @intCast(bi);
                const member: usize = @intFromBool(cn.set.has(b));
                const k = @as(usize, class[b]) * 2 + member;
                if (seen[k] < 0) {
                    seen[k] = @intCast(newn);
                    newn += 1;
                }
                class[b] = @intCast(seen[k]);
            }
            ncls = newn;
            if (ncls == 256) break; // maximally refined — no set can split further
        },
        else => {},
    };
    var done = [_]bool{false} ** 256;
    for (0..256) |bi| {
        const c = class[@intCast(bi)];
        if (!done[c]) {
            rep[c] = @intCast(bi);
            done[c] = true;
        }
    }
    return ncls;
}

/// Determinize the Thompson NFA (`states`, entry `start`) into an immutable
/// byte-class DFA, or null when it isn't worth it (powerset exceeds `max_states`)
/// — in which case the caller keeps the Pike VM. `anchored` mirrors
/// `syn.startsAnchored`: every match begins at line start, so we never re-seed.
pub fn build(gpa: std.mem.Allocator, states: []const State, start: u32, anchored: bool) std.mem.Allocator.Error!?*Dfa {
    var class: [256]u8 = undefined;
    var rep: [256]u8 = undefined;
    const ncls = buildClasses(states, &class, &rep);
    const words = (states.len + 63) >> 6;

    var b = Builder{
        .gpa = gpa,
        .states = states,
        .start_nfa = start,
        .anchored = anchored,
        .words = words,
        .ncls = ncls,
        .rep = &rep,
        .map = SetMap.init(gpa),
        .sets = .empty,
        .is_match = .empty,
        .trans_in = .empty,
        .trans_fin = .empty,
        .queued = .empty,
        .worklist = .empty,
        .visited = try gpa.alloc(u64, words),
        .out = try gpa.alloc(u64, words),
        .stack = try gpa.alloc(u32, states.len),
    };
    // Builder scratch + the subset map/sets are discarded once the immutable
    // tables are sliced out (or on a bail). `sets` owns every state key.
    defer {
        b.map.deinit();
        for (b.sets.items) |s| gpa.free(s);
        b.sets.deinit(gpa);
        b.queued.deinit(gpa);
        b.worklist.deinit(gpa);
        gpa.free(b.visited);
        gpa.free(b.out);
        gpa.free(b.stack);
    }
    errdefer {
        b.is_match.deinit(gpa);
        b.trans_in.deinit(gpa);
        b.trans_fin.deinit(gpa);
    }

    const empty_match = b.closeStart(true, true); // empty line: BOL ∧ EOL
    const start_matched = b.closeStart(true, false); // start: BOL only (`$` at EOL)
    const start_id = (try b.intern(start_matched)).id; // interns `b.out` from above
    try b.enqueue(start_id);

    var wcur: usize = 0;
    while (wcur < b.worklist.items.len) : (wcur += 1) {
        const id = b.worklist.items[wcur];
        // The state key buffer is stable (independently heap-allocated); only the
        // `sets` pointer array can move under interning, so re-read it per class.
        var k: u16 = 0;
        while (k < ncls) : (k += 1) {
            const m_in = b.step(b.sets.items[id][0..b.words], k, false);
            const r_in = try b.intern(m_in);
            b.trans_in.items[@as(usize, id) * ncls + k] = r_in.id;
            try b.enqueue(r_in.id);
            // Last byte (at_end=true) resolves `$`. Targets are terminal — the
            // line ends right after — so interned for `is_match` but not enqueued.
            const m_fin = b.step(b.sets.items[id][0..b.words], k, true);
            const r_fin = try b.intern(m_fin);
            b.trans_fin.items[@as(usize, id) * ncls + k] = r_fin.id;
            if (b.nstates > max_states) { // powerset blow-up ⇒ keep the Pike VM
                b.is_match.deinit(gpa); // (not held by `defer`/`errdefer` on this path)
                b.trans_in.deinit(gpa);
                b.trans_fin.deinit(gpa);
                return null;
            }
        }
    }

    const dfa = try gpa.create(Dfa);
    errdefer gpa.destroy(dfa);
    dfa.* = .{
        .class = class,
        .ncls = ncls,
        .nstates = b.nstates,
        .trans_in = try b.trans_in.toOwnedSlice(gpa),
        .trans_fin = try b.trans_fin.toOwnedSlice(gpa),
        .is_match = try b.is_match.toOwnedSlice(gpa),
        .start = start_id,
        .empty_match = empty_match,
        .anchored = anchored,
        .dead = b.dead,
        .allocator = gpa,
    };
    return dfa;
}

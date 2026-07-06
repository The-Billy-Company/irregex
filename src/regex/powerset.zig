//! gist — powerset (subset) construction: determinizes the Thompson NFA in
//! `syntax.zig` into the immutable byte-class `Dfa` (`dfa.zig`). Built **eagerly**
//! at compile (these patterns are tiny); the result is scratch-free and freely
//! shared across threads, exactly like the bit engine it supersedes.
//!
//! Determinization (powerset) over the Thompson NFA:
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
//! Powerset blow-up is bounded: past `max_states` the build bails to null and the
//! caller keeps the Pike VM, which stays the correctness reference (the
//! differential-fuzz oracle). Counted repetition (`a{1000}`) yields a linear, not
//! exponential, DFA, so the cap only ever trips on genuinely pathological
//! alternations.

const std = @import("std");
const syn = @import("syntax.zig");
const prefilter = @import("prefilter.zig");
const State = syn.State;
const Dfa = @import("dfa.zig").Dfa;

/// Start-state acceleration eligibility (mirrors rust-regex `accel.rs`): only
/// accelerate when the start state's escape set is ≤ this many bytes, past which
/// the SIMD skip stops being selective (e.g. `\w`'s 63 bytes) and a plain dense
/// scan wins. memchr/range-skip earns its keep at 1–3 exit bytes.
const max_accel_bytes: usize = 3;

/// Powerset state cap. Beyond this the eager build bails to null (Pike fallback).
/// Sized so a linear `{n}`-expanded program (DFA ≈ n states) always fits while a
/// pathological exponential alternation can't blow compile time or memory.
pub const max_states: u32 = 4096;

const unknown: u32 = std.math.maxInt(u32); // unfilled transition slot sentinel

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
    return std.mem.allEqual(u64, bits, 0);
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
    key_scratch: []u64, // reusable interning-probe key (`out` ++ match flag)
    sp: usize = 0,

    fn pushIf(b: *Builder, s: u32) void {
        if (!hasBit(b.visited, s)) {
            setBit(b.visited, s);
            b.stack[b.sp] = s;
            b.sp += 1;
        }
    }

    /// Clear the closure scratch (dedup bitset, accumulator, stack) for a fresh pass.
    fn reset(b: *Builder) void {
        @memset(b.visited, 0);
        @memset(b.out, 0);
        b.sp = 0;
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
                // `build` bails to the Pike VM (returns null above) before any
                // state is interned, so the determinizer never sees a word
                // boundary (two-sided or one-sided) or a buffer anchor.
                .assert_word_b, .assert_not_word_b, .assert_word_start, .assert_word_end, .assert_buf_start, .assert_buf_end => unreachable,
                .match => matched = true,
            }
        }
        return matched;
    }

    /// Seed the start NFA state and epsilon-close it at the given boundary flags;
    /// result in `b.out`. Used for the start state (BOL) and empty-line verdict.
    fn closeStart(b: *Builder, at_start: bool, at_end: bool) bool {
        b.reset();
        b.pushIf(b.start_nfa);
        return b.close(at_start, at_end);
    }

    /// The transition out of consume-set `from` on a byte of class `k`: gather the
    /// `out` of every member accepting the class's representative byte, re-seed the
    /// NFA start when unanchored, then epsilon-close (at_start always false — only
    /// the start state sits at BOL). Result lands in `b.out`; returns matched.
    fn step(b: *Builder, from: []const u64, k: u16, at_end: bool) bool {
        b.reset();
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
        // Probe with the reusable scratch key first — in any real determinization
        // most transitions land on an already-interned state, so allocating a
        // fresh key per call (only to free it on the dup path) is pure churn. Copy
        // into a permanent key only once the state proves genuinely new.
        @memcpy(b.key_scratch[0..b.words], b.out);
        b.key_scratch[b.words] = @intFromBool(matched);
        if (b.map.get(b.key_scratch)) |id| return .{ .id = id, .is_new = false };
        const key = try b.gpa.alloc(u64, b.words + 1);
        errdefer b.gpa.free(key);
        @memcpy(key, b.key_scratch);
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
    @memset(class, 0);
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
    // Any byte in a class is a valid representative (all members behave identically under every set), so last-write-wins needs no "seen" tracking.
    for (0..256) |bi| rep[class[bi]] = @intCast(bi);
    return ncls;
}

/// Determinize the Thompson NFA (`states`, entry `start`) into an immutable
/// byte-class DFA, or null when it isn't worth it (powerset exceeds `max_states`)
/// — in which case the caller keeps the Pike VM. `anchored` mirrors
/// `analysis.startsAnchored`: every match begins at line start, so we never re-seed.
pub fn build(gpa: std.mem.Allocator, states: []const State, start: u32, anchored: bool) std.mem.Allocator.Error!?*Dfa {
    // A `\b`/`\B` (or one-sided `\<`/`\>`) assertion gates on the word-ness of
    // the bytes straddling a position, which a byte-class DFA can't resolve
    // without folding "previous byte was a word char" into every state (a second
    // determinization axis). Keep the Pike VM (the correctness reference) for
    // these — exactly the powerset-blow-up fallback — while the trigram
    // prefilter still selects on the bounded literal. Recorded next rung: a
    // word-context-aware DFA. The buffer anchors (`\A`/`\z`) exist only under
    // multiline, where no DFA is built at all — bail defensively anyway.
    for (states) |st| switch (st) {
        .assert_word_b, .assert_not_word_b, .assert_word_start, .assert_word_end, .assert_buf_start, .assert_buf_end => return null,
        else => {},
    };

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
        .key_scratch = try gpa.alloc(u64, words + 1),
    };
    // Builder scratch + the subset map/sets are discarded once the immutable tables are sliced out (or on a bail). `sets` owns every state key.
    defer {
        b.map.deinit();
        for (b.sets.items) |s| gpa.free(s);
        b.sets.deinit(gpa);
        b.queued.deinit(gpa);
        b.worklist.deinit(gpa);
        gpa.free(b.visited);
        gpa.free(b.out);
        gpa.free(b.stack);
        gpa.free(b.key_scratch);
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
        // The state key buffer is stable (independently heap-allocated); only the `sets` pointer array can move under interning, so re-read it per class.
        var k: u16 = 0;
        while (k < ncls) : (k += 1) {
            const m_in = b.step(b.sets.items[id][0..b.words], k, false);
            const r_in = try b.intern(m_in);
            b.trans_in.items[@as(usize, id) * ncls + k] = r_in.id;
            try b.enqueue(r_in.id);
            // Last byte (at_end=true) resolves `$`. Targets are terminal — the line ends right after — so interned for `is_match` but not enqueued.
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

    // Start-state acceleration: the "relevant" bytes from the unanchored start
    // state are the only ones that can contribute to a match; when there are few,
    // the scanner SIMD-skips to them. Anchored programs never re-seed (ineligible).
    // Computed on the id-based tables BEFORE premultiplication below (it reasons
    // about state identity, not the flattened offset).
    const accel = computeAccel(anchored, empty_match, b.trans_in.items, b.trans_fin.items, b.is_match.items, &class, ncls, start_id);

    // Premultiply (rust-regex / RE2 dense-DFA trick): rewrite every state value to
    // its row offset `id*ncls`, so the hot loop's per-byte index collapses from a
    // loop-carried `madd(s, ncls, class)` to a fold-into-addressing `s + class[b]`
    // — one fewer instruction on the latency-bound transition recurrence. Targets
    // never reached by an interior byte keep their `unknown` sentinel (their row is
    // never indexed), so skip those to avoid overflowing the multiply.
    const nc: u32 = ncls;
    for (b.trans_in.items) |*t| if (t.* != unknown) {
        t.* *= nc;
    };
    for (b.trans_fin.items) |*t| if (t.* != unknown) {
        t.* *= nc;
    };
    // `is_match` re-laid-out by offset: `is_match_pm[id*ncls] = is_match[id]`, so the
    // hot loop reads `is_match[s]` with the premultiplied `s` and never divides. The
    // inter-row slots are never indexed (every live `s` is a multiple of `ncls`).
    const im_pm = try gpa.alloc(bool, @as(usize, b.nstates) * ncls);
    errdefer gpa.free(im_pm);
    @memset(im_pm, false);
    for (b.is_match.items, 0..) |m, id| im_pm[id * ncls] = m;
    const dead_pm = if (b.dead == unknown) unknown else b.dead * nc;

    const dfa = try gpa.create(Dfa);
    errdefer gpa.destroy(dfa);
    dfa.* = .{
        .class = class,
        .ncls = ncls,
        .nstates = b.nstates,
        .trans_in = try b.trans_in.toOwnedSlice(gpa),
        .trans_fin = try b.trans_fin.toOwnedSlice(gpa),
        .is_match = im_pm,
        .start = start_id * nc,
        .empty_match = empty_match,
        .anchored = anchored,
        .dead = dead_pm,
        .accel = accel,
        .allocator = gpa,
    };
    b.is_match.deinit(gpa); // replaced by the offset-indexed `im_pm`
    return dfa;
}

/// Derive start-state acceleration from the finished transition tables. A byte is
/// "relevant" — must stop the SIMD skip — when, from the unanchored start state,
/// it either (a) moves to a *different* interior state (`trans_in` ≠ start, the
/// match-beginning case) or (b) produces a match at end-of-line (`trans_fin` is a
/// match state, the `$`-anchored-literal case like `;$`, where the byte keeps
/// `trans_in` in start yet matches as the line's last byte). Every other byte both
/// keeps start in itself AND can't match under `$`, so it is provably skippable.
/// Returns a `Prefilter` over the relevant set iff it is non-empty and
/// ≤ `max_accel_bytes`; else null (dense scan).
///
/// `\n` is added to the needle **only when the skip can't safely cross a line** —
/// i.e. when an empty line can match (`empty_match`) or `\n` is itself relevant.
/// Otherwise crossing `\n` in the start state is a pure no-op, so we omit it: the
/// scanner then `memchr`s straight across newlines (rg's exact `;$` strategy) and,
/// for a single relevant byte, the prefilter collapses to a one-byte `memchr`
/// instead of a two-range scan. The byte-at-a-time inner loop still stops at `\n`,
/// so `$`/line-end resolution stays correct.
fn computeAccel(anchored: bool, empty_match: bool, trans_in: []const u32, trans_fin: []const u32, is_match: []const bool, class: *const [256]u8, ncls: u16, start_id: u32) ?prefilter.Prefilter {
    if (anchored) return null;
    const base = @as(usize, start_id) * ncls;
    const relevantByte = struct {
        fn f(ti: []const u32, tf: []const u32, im: []const bool, off: usize, sid: u32) bool {
            return ti[off] != sid or im[tf[off]];
        }
    }.f;
    var relevant: syn.ByteSet = .{};
    var n: usize = 0;
    var bi: usize = 0;
    while (bi < 256) : (bi += 1) {
        const b: u8 = @intCast(bi);
        if (b == '\n') continue; // line-boundary stop, decided separately below
        if (relevantByte(trans_in, trans_fin, is_match, base + class[b], start_id)) {
            relevant.set(b);
            n += 1;
        }
    }
    if (n == 0 or n > max_accel_bytes) return null;
    // Keep the skip inside one line only when it must: an empty line can match, or
    // `\n` itself is relevant. Otherwise let the skip `memchr` across newlines.
    const nl_relevant = relevantByte(trans_in, trans_fin, is_match, base + class['\n'], start_id);
    if (empty_match or nl_relevant) relevant.set('\n');
    return prefilter.Prefilter.init(relevant);
}

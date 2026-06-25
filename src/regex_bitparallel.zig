//! gist — T2 bit-parallel NFA: a Glushkov *position automaton* simulated with
//! bitwise ops, the dense-small-program fast path the Pike VM (`regex.zig`) loses
//! to ripgrep's lazy DFA on. Lineage: Baeza-Yates–Gonnet Shift-And (1992) →
//! Navarro–Raffinot NR-grep → Hyperscan's small-engine path. ADR-pending.
//!
//! The Pike simulation is O(active-threads)/byte; on a dense match like `\w{3,8}`
//! (no literal prefilter, `\w` covers most bytes so the first-byte skip never
//! engages) that's per-byte work proportional to the live thread set. This engine
//! instead keeps the active-position set as ONE machine word and advances it with
//! a handful of bit ops per byte — O(popcount)/byte with no allocation, no
//! per-byte epsilon-closure recompute, no thread list, no gen/seen bookkeeping.
//!
//! Scope (a *fast path*, not a replacement): built only for **anchor-free**
//! programs (`^`/`$` are zero-width and position-dependent — left on the Pike
//! path, which already has the anchored fast path) whose position count fits one
//! `Word`. Anything else ⇒ `build` returns null and the caller falls back to the
//! Pike VM, which stays the correctness reference (the differential-fuzz oracle).
//!
//! Construction is the textbook Glushkov First/Last/Follow/nullable recurrence
//! over the AST. The AST is a DAG (`{n,m}` shares the atom pointer across copies),
//! so the walk is deliberately *un-memoized*: each structural visit mints a fresh
//! position, exactly as the Thompson compiler mints a fresh state per visit — the
//! `{n,m}` repetition is thereby expanded into distinct positions, sound by
//! construction. Past `max_positions` positions the build bails to Pike.

const std = @import("std");
const syn = @import("regex_syntax.zig");
const ByteSet = syn.ByteSet;
const Node = syn.Node;

/// The active-position set lives in one of these. u64 ⇒ programs up to 64
/// consuming positions take the bit-parallel path; larger ⇒ Pike fallback.
pub const Word = u64;
pub const max_positions: u8 = @bitSizeOf(Word);
const PosIdx = std.math.Log2Int(Word); // u6 for u64 — a valid shift amount

inline fn bit(p: PosIdx) Word {
    return @as(Word, 1) << p;
}

/// A compiled Glushkov position automaton. `charmask[b]` is the set of positions
/// whose class accepts byte `b`; `follow[p]` the positions enterable right after
/// consuming at `p`; `initial` the positions a match can begin at; `accept` the
/// positions whose consumption *completes* a match (Glushkov `Last`). All fields
/// are immutable after `build` — the simulation needs no scratch, so one `BitNfa`
/// is freely shared across threads (each call to `match` is read-only).
pub const BitNfa = struct {
    charmask: [256]Word,
    follow: [max_positions]Word,
    initial: Word,
    accept: Word,
    init_match: bool, // the empty string matches (root is nullable)
    npos: u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BitNfa) void {
        const a = self.allocator;
        a.destroy(self);
    }

    /// Does the pattern match any substring of `line`? Linear in `line.len`,
    /// branch-light. Unanchored: `initial` is OR'd in at every position so a
    /// match may begin anywhere (the standard Shift-And start-state trick — it
    /// subsumes the Pike VM's re-seed-every-byte loop for free).
    pub fn match(self: *const BitNfa, line: []const u8) bool {
        if (self.init_match) return true; // empty match ⇒ matches every line
        var cur: Word = 0;
        for (line) |c| {
            cur |= self.initial;
            const fired = cur & self.charmask[c];
            if (fired & self.accept != 0) return true;
            var next: Word = 0;
            var bits = fired;
            while (bits != 0) {
                const p: PosIdx = @intCast(@ctz(bits));
                next |= self.follow[p];
                bits &= bits - 1; // clear lowest set bit
            }
            cur = next;
        }
        return false;
    }
};

/// Result of one Glushkov walk: the node's nullability and its First/Last
/// position sets (the per-position Follow edges and char masks are accumulated
/// into the `BitNfa` as a side effect).
const Frag = struct { nullable: bool, first: Word, last: Word };
const empty_frag: Frag = .{ .nullable = true, .first = 0, .last = 0 };

const Builder = struct {
    nfa: *BitNfa,
    npos: u8 = 0,
    ok: bool = true, // cleared by an anchor or a position-count overflow ⇒ bail

    /// Mint a fresh position for a consuming class, recording its accepted bytes
    /// into `charmask`. Returns null (and trips `ok`) once the word is full.
    fn newPos(b: *Builder, set: ByteSet) ?PosIdx {
        if (b.npos >= max_positions) {
            b.ok = false;
            return null;
        }
        const p: PosIdx = @intCast(b.npos);
        b.npos += 1;
        const m = bit(p);
        for (0..256) |c| if (set.has(@intCast(c))) {
            b.nfa.charmask[c] |= m;
        };
        return p;
    }

    /// Add `to ⊆ Follow(p)` for every position `p` in the `from` set.
    fn addFollow(b: *Builder, from: Word, to: Word) void {
        var bits = from;
        while (bits != 0) {
            const p: PosIdx = @intCast(@ctz(bits));
            b.nfa.follow[p] |= to;
            bits &= bits - 1;
        }
    }

    fn walk(b: *Builder, node: *Node) Frag {
        if (!b.ok) return empty_frag; // short-circuit once we've decided to bail
        switch (node.*) {
            .empty => return empty_frag,
            // Anchors are zero-width and position-dependent — out of scope; bail
            // to the Pike path (which resolves them in its epsilon-closure).
            .anchor_start, .anchor_end => {
                b.ok = false;
                return empty_frag;
            },
            .class => |set| {
                const p = b.newPos(set) orelse return empty_frag;
                return .{ .nullable = false, .first = bit(p), .last = bit(p) };
            },
            .concat => |ab| {
                const x = b.walk(ab[0]);
                const y = b.walk(ab[1]);
                b.addFollow(x.last, y.first); // x's tail flows into y's head
                return .{
                    .nullable = x.nullable and y.nullable,
                    .first = x.first | (if (x.nullable) y.first else 0),
                    .last = y.last | (if (y.nullable) x.last else 0),
                };
            },
            .alt => |ab| {
                const x = b.walk(ab[0]);
                const y = b.walk(ab[1]);
                return .{
                    .nullable = x.nullable or y.nullable,
                    .first = x.first | y.first,
                    .last = x.last | y.last,
                };
            },
            .star => |x| {
                const r = b.walk(x);
                b.addFollow(r.last, r.first); // loop back
                return .{ .nullable = true, .first = r.first, .last = r.last };
            },
            .plus => |x| {
                const r = b.walk(x);
                b.addFollow(r.last, r.first); // loop back, but ≥1 iteration
                return .{ .nullable = r.nullable, .first = r.first, .last = r.last };
            },
            .quest => |x| {
                const r = b.walk(x);
                return .{ .nullable = true, .first = r.first, .last = r.last };
            },
        }
    }
};

/// Compile `ast` into a bit-parallel automaton, or null when it isn't
/// representable here (contains an anchor, or exceeds `max_positions` positions)
/// — in which case the caller keeps the Pike VM. Allocation is one `BitNfa`.
pub fn build(allocator: std.mem.Allocator, ast: *Node) std.mem.Allocator.Error!?*BitNfa {
    const nfa = try allocator.create(BitNfa);
    errdefer allocator.destroy(nfa);
    @memset(&nfa.charmask, 0);
    @memset(&nfa.follow, 0);

    var b = Builder{ .nfa = nfa };
    const root = b.walk(ast);
    if (!b.ok) {
        allocator.destroy(nfa);
        return null;
    }
    nfa.initial = root.first;
    nfa.accept = root.last;
    nfa.init_match = root.nullable;
    nfa.npos = b.npos;
    nfa.allocator = allocator;
    return nfa;
}

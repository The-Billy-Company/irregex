//! gist — the predicate alphabet: scalar interval sets, and the **minterm
//! partition** they induce.
//!
//! A codepoint class (`\w`, `\p{L}`, `.`, `é`) is a predicate over Unicode
//! scalars. The byte engine answers "does this class hold?" by walking a UTF-8
//! trie — hundreds of NFA states per occurrence, re-walked by every closure the
//! determinizer runs. Symbolically the same question needs no automaton at all:
//! partition the scalar space into the coarsest blocks no predicate splits
//! (its **minterms**), and every class becomes a bitmask over a handful of
//! symbols. `\w+X` has three: `{X}`, `\w∖{X}`, and everything else.
//!
//! This is the alphabet half of the symbolic-automata literature (van Noord &
//! Gerdemann; Veanes' `MinTerm` generation for symbolic finite automata) — the
//! only part of it this lane adopts. The partition is computed by one boundary
//! sweep over every predicate's ranges, so it costs `O(B log B)` in the number
//! of interval endpoints rather than the `O(2^n)` of pairwise intersection.

const std = @import("std");
const mix = @import("../../../math/mix.zig");
const syn = @import("../../syntax/syntax.zig");

/// An inclusive scalar range `[lo, hi]` — the same shape `Node.uclass` carries.
pub const Range = [2]u21;

/// Largest Unicode scalar value. Surrogates are *inside* the partitioned space:
/// `utf8seq` drops them when the decoder is lowered, which is exactly how the
/// byte engine treats them (no well-formed encoding ⇒ unmatchable).
pub const max_scalar: u21 = 0x10FFFF;

/// Ceiling on distinct predicates. Every consuming AST leaf contributes one
/// (deduplicated by content, so `\w{3,8}`'s eight copies are a single
/// predicate). Past this the signature bitset stops being cheap and the pattern
/// is pathological; the caller falls back to the byte path.
pub const max_predicates: u32 = 512;

// File-private control flow (ADR-373): converted to `.declined` at the
// symbolic module boundary — not a declared fault-taxonomy member.
const Err = error{TooManyPredicates};

const sig_words: usize = max_predicates / 64;

/// One predicate's identity while the partition is being built: its ranges plus
/// the slot it occupies in every atom's signature.
const Event = struct { pos: u32, pred: u16, open: bool };

fn lessEvent(_: void, a: Event, b: Event) bool {
    if (a.pos != b.pos) return a.pos < b.pos;
    return @intFromBool(a.open) > @intFromBool(b.open); // opens before closes at a shared endpoint
}

const SigCtx = mix.SliceCtx(u64);
const SigMap = std.HashMap([]const u64, u16, SigCtx, std.hash_map.default_max_load_percentage);

/// Content key for a predicate's range set. `[2]u21` has undefined padding bits
/// in its 4-byte ABI slot, so the set is flattened to `u32` pairs before it is
/// hashed — deduplication must not depend on bits nobody wrote.
const KeyCtx = mix.SliceCtx(u32);
const KeyMap = std.HashMap([]const u32, u16, KeyCtx, std.hash_map.default_max_load_percentage);

/// The finished alphabet: a partition of `[0, max_scalar]` into minterms, plus
/// which minterms each predicate accepts.
///
/// `atoms` is the partition as a sorted, gapless, disjoint cover; `owner[i]` is
/// the minterm atom `i` belongs to (several atoms may share one — `\w` is 748
/// disjoint ranges yet a single minterm when it is the only predicate).
/// `accepts(p, m)` is the whole interface the determinizer needs: a pattern
/// transition is then a bitmask test, never a byte walk.
pub const Alphabet = struct {
    gpa: std.mem.Allocator,
    atoms: []Range,
    owner: []u16,
    count: u16, // number of minterms
    npred: u16,
    membership: []bool, // [pred * count + minterm]

    pub fn deinit(a: *Alphabet) void {
        a.gpa.free(a.atoms);
        a.gpa.free(a.owner);
        a.gpa.free(a.membership);
    }

    pub fn accepts(a: *const Alphabet, pred: u16, mint: u16) bool {
        return a.membership[@as(usize, pred) * a.count + mint];
    }

    /// The scalar ranges belonging to minterm `m`, ascending and coalesced.
    /// Caller owns the returned slice. Used only by the decoder builder.
    pub fn rangesOf(a: *const Alphabet, gpa: std.mem.Allocator, m: u16) std.mem.Allocator.Error![]Range {
        var out: std.ArrayList(Range) = .empty;
        errdefer out.deinit(gpa);
        for (a.atoms, a.owner) |r, o| {
            if (o != m) continue;
            // Atoms are ascending, so a run of this minterm's atoms that happens
            // to be contiguous fuses instead of paying a second decomposition.
            if (out.items.len > 0 and @as(u32, out.items[out.items.len - 1][1]) + 1 == r[0]) {
                out.items[out.items.len - 1][1] = r[1];
            } else try out.append(gpa, r);
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Accumulates the pattern's distinct predicates, deduplicating by content, and
/// hands out the slot each one occupies in the minterm signature. One instance
/// per compile; `finish` turns it into the `Alphabet`.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    ranges: std.ArrayList([]Range) = .empty, // owned; ranges[p] = predicate p's set
    index: KeyMap, // content key → slot; owns its keys
    scratch: std.ArrayList(Range) = .empty,
    key_scratch: std.ArrayList(u32) = .empty,

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa, .index = KeyMap.init(gpa) };
    }

    pub fn deinit(b: *Builder) void {
        for (b.ranges.items) |r| b.gpa.free(r);
        b.ranges.deinit(b.gpa);
        b.scratch.deinit(b.gpa);
        b.key_scratch.deinit(b.gpa);
        var it = b.index.keyIterator();
        while (it.next()) |k| b.gpa.free(k.*);
        b.index.deinit();
    }

    /// Intern a predicate given as sorted, disjoint scalar ranges; returns its
    /// slot. Identical sets collapse — the whole reason `\w{3,8}` costs one
    /// predicate rather than eight.
    pub fn intern(b: *Builder, ranges: []const Range) (Err || std.mem.Allocator.Error)!u16 {
        b.key_scratch.clearRetainingCapacity();
        for (ranges) |r| try b.key_scratch.appendSlice(b.gpa, &[_]u32{ r[0], r[1] });
        if (b.index.get(b.key_scratch.items)) |p| return p;
        if (b.ranges.items.len >= max_predicates) return error.TooManyPredicates;
        const key = try b.gpa.dupe(u32, b.key_scratch.items);
        errdefer b.gpa.free(key);
        const owned = try b.gpa.dupe(Range, ranges);
        errdefer b.gpa.free(owned);
        const slot: u16 = @intCast(b.ranges.items.len);
        try b.ranges.append(b.gpa, owned);
        try b.index.put(key, slot);
        return slot;
    }

    /// Intern an ASCII `ByteSet` (a `class` node) as a scalar predicate. Callers
    /// guarantee no member is ≥ 0x80 — a high byte is not a codepoint and the
    /// symbolic path declines such programs up front.
    pub fn internByteSet(b: *Builder, set: *const syn.ByteSet) (Err || std.mem.Allocator.Error)!u16 {
        b.scratch.clearRetainingCapacity();
        var i: u16 = 0;
        while (i <= 0x7F) {
            if (!set.has(@intCast(i))) {
                i += 1;
                continue;
            }
            const lo = i;
            while (i <= 0x7F and set.has(@intCast(i))) i += 1;
            try b.scratch.append(b.gpa, .{ @intCast(lo), @intCast(i - 1) });
        }
        return b.intern(b.scratch.items);
    }

    /// Sweep every interned predicate's endpoints once, cut the scalar line at
    /// each, and label every resulting atom by the set of predicates covering
    /// it. Atoms sharing a label are the same minterm — that label *is* the
    /// minterm's identity, so the partition is minimal by construction.
    pub fn finish(b: *Builder) std.mem.Allocator.Error!Alphabet {
        const gpa = b.gpa;
        const npred: u16 = @intCast(b.ranges.items.len);

        var events: std.ArrayList(Event) = .empty;
        defer events.deinit(gpa);
        for (b.ranges.items, 0..) |set, p| for (set) |r| {
            try events.append(gpa, .{ .pos = r[0], .pred = @intCast(p), .open = true });
            try events.append(gpa, .{ .pos = @as(u32, r[1]) + 1, .pred = @intCast(p), .open = false });
        };
        std.mem.sort(Event, events.items, {}, lessEvent);

        var atoms: std.ArrayList(Range) = .empty;
        errdefer atoms.deinit(gpa);
        var owner: std.ArrayList(u16) = .empty;
        errdefer owner.deinit(gpa);

        var map = SigMap.init(gpa);
        defer {
            var it = map.keyIterator();
            while (it.next()) |k| gpa.free(k.*);
            map.deinit();
        }
        var sigs: std.ArrayList([]const u64) = .empty; // borrowed from `map`'s keys
        defer sigs.deinit(gpa);

        var active = [_]u64{0} ** sig_words;
        var cursor: u32 = 0;
        var i: usize = 0;
        while (cursor <= max_scalar) {
            // Everything strictly before the next endpoint shares one label.
            const next: u32 = if (i < events.items.len) events.items[i].pos else @as(u32, max_scalar) + 1;
            if (next > cursor) {
                const hi: u32 = @min(next - 1, max_scalar);
                const id = try label(gpa, &map, &sigs, &active);
                try atoms.append(gpa, .{ @intCast(cursor), @intCast(hi) });
                try owner.append(gpa, id);
                cursor = hi + 1;
                if (cursor > max_scalar) break;
            }
            while (i < events.items.len and events.items[i].pos == next) : (i += 1) {
                const e = events.items[i];
                const w = e.pred / 64;
                const bit = @as(u64, 1) << @intCast(e.pred % 64);
                if (e.open) active[w] |= bit else active[w] &= ~bit;
            }
        }

        const count: u16 = @intCast(sigs.items.len);
        const membership = try gpa.alloc(bool, @as(usize, npred) * count);
        errdefer gpa.free(membership);
        @memset(membership, false);
        for (sigs.items, 0..) |sig, m| {
            var p: u16 = 0;
            while (p < npred) : (p += 1) {
                if (sig[p / 64] & (@as(u64, 1) << @intCast(p % 64)) != 0) membership[@as(usize, p) * count + m] = true;
            }
        }
        return .{
            .gpa = gpa,
            .atoms = try atoms.toOwnedSlice(gpa),
            .owner = try owner.toOwnedSlice(gpa),
            .count = count,
            .npred = npred,
            .membership = membership,
        };
    }
};

/// Intern one atom's predicate-membership signature, returning its minterm id.
fn label(gpa: std.mem.Allocator, map: *SigMap, sigs: *std.ArrayList([]const u64), active: *const [sig_words]u64) std.mem.Allocator.Error!u16 {
    if (map.get(active)) |id| return id;
    const key = try gpa.dupe(u64, active);
    errdefer gpa.free(key);
    const id: u16 = @intCast(sigs.items.len);
    try map.put(key, id);
    try sigs.append(gpa, key);
    return id;
}

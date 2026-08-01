//! gist — the UTF-8 → minterm decoder.
//!
//! One deterministic byte automaton for the WHOLE alphabet, built once per
//! pattern: read bytes, and the moment a codepoint completes, announce which
//! minterm it fell in. This is the piece that lets the symbolic path hand back
//! an ordinary byte DFA — `transcribe.zig` crosses this with the pattern
//! automaton and the reachable pairs are the table.
//!
//! It is also where the byte path's central inefficiency is paid off. `lowerUtf8`
//! builds a fresh trie per class OCCURRENCE and the determinizer then re-walks it
//! once per closure; here the trie exists once, is shared by every occurrence,
//! and is walked once — at build time, by a construction that never revisits it.
//!
//! Two structural choices carry their weight:
//!   * **Hash-consing on the edge list.** Every three-byte tail `[80-BF][80-BF]`
//!     in the alphabet is the same node, and there are hundreds of them. Nodes
//!     are interned by content, so shared suffixes collapse before the product
//!     ever multiplies them.
//!   * **Rejected minterms are not decoded at all.** A minterm the pattern
//!     refuses from every state behaves exactly like a lost sync, and resync
//!     already handles arbitrary bytes correctly, so its sequences never enter
//!     the weave. Without this the decoder carries a full trie for the
//!     COMPLEMENT of the class the pattern asked about.

const std = @import("std");
const mix = @import("../../../math/mix.zig");
const u8seq = @import("../../unicode/utf8seq.zig");
const subset = @import("../dfa/subset.zig");
const alphabet = @import("alphabet.zig");
const determinize = @import("determinize.zig");

/// Ceiling on decoder nodes. A pattern whose alphabet cannot be decoded inside
/// this declines to the byte path rather than growing without bound.
pub const max_nodes: u32 = 4096;

// File-private control flow (the fault-channel taxonomy): converted to `.declined` at the
// symbolic module boundary — not members of the declared fault taxonomy.
const Decline = error{ TooLarge, Malformed };
const Error = Decline || std.mem.Allocator.Error;

/// Edge target: a decoder node id, or — with `leaf` set — "a codepoint just
/// completed, and it belongs to this minterm".
pub const leaf: u32 = 0x8000_0000;

/// `row`'s "no edge covers this byte here" — what the edge scan reported as
/// `null`. Unambiguous against both inhabitants of an edge target: a node id is
/// under `max_nodes`, and a leaf carries a `u16` minterm, so no real target ever
/// sets every bit.
pub const no_edge: u32 = std.math.maxInt(u32);

const Edge = struct { lo: u8, hi: u8, target: u32 };
const NodeSpan = struct { first: u32, len: u32 };

/// Hash-consing key for a node's edge list: one `u64` per edge. Packed by hand
/// rather than reinterpreting the `Edge` struct's bytes, whose alignment padding
/// is undefined — interning must not turn on bits nobody wrote.
fn packEdge(e: Edge) u64 {
    return @as(u64, e.lo) | (@as(u64, e.hi) << 8) | (@as(u64, e.target) << 32);
}

const WordsCtx = mix.SliceCtx(u64);
const ConsMap = std.HashMap([]const u64, u32, WordsCtx, std.hash_map.default_max_load_percentage);

/// One decomposed UTF-8 byte-range sequence, tagged with the minterm whose
/// codepoints it encodes.
const Tagged = struct { seq: u8seq.Sequence, mint: u16 };

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    edges: std.ArrayList(Edge) = .empty,
    nodes: std.ArrayList(NodeSpan) = .empty,
    seqs: std.ArrayList(Tagged) = .empty,
    cons: ConsMap,
    key: std.ArrayList(u64) = .empty,
    root: u32 = 0,
    /// `follow` as a table: `row[node * 256 + b]`, materialized once by `spread`
    /// when the weave is finished. The edge list stays the authority (it is what
    /// interning and the byte-class partition read); this is the same answer laid
    /// out for the one caller that asks 10⁶ times.
    row: std.ArrayList(u32) = .empty,

    pub fn deinit(d: *Decoder) void {
        d.edges.deinit(d.gpa);
        d.nodes.deinit(d.gpa);
        d.seqs.deinit(d.gpa);
        d.key.deinit(d.gpa);
        d.row.deinit(d.gpa);
        var it = d.cons.keyIterator();
        while (it.next()) |k| d.gpa.free(k.*);
        d.cons.deinit();
    }

    pub fn count(d: *const Decoder) u32 {
        return @intCast(d.nodes.items.len);
    }

    fn edgesOf(d: *const Decoder, node: u32) []const Edge {
        const s = d.nodes.items[node];
        return d.edges.items[s.first..][0..s.len];
    }

    /// Lay every node's edge list out as a dense byte row, so `follow` is one
    /// load instead of a scan. The product in `transcribe.zig` asks this
    /// question once per (product state × byte class) and the answer depends only
    /// on `(node, b)` — on `func\s+\w+\(` that was 21.5M edge comparisons to
    /// resolve 1.4M distinct lookups, and it was the single largest line item in
    /// compiling a literal-plus-Unicode-class pattern.
    ///
    /// Edges are written back-to-front so that, exactly as in the scan it
    /// replaces, the FIRST edge covering a byte is the one that answers. The
    /// weave emits disjoint ascending ranges, so the two orders agree today; the
    /// reversal makes the equivalence hold without depending on that.
    fn spread(d: *Decoder) std.mem.Allocator.Error!void {
        try d.row.resize(d.gpa, d.nodes.items.len * 256);
        @memset(d.row.items, no_edge);
        for (d.nodes.items, 0..) |span, n| {
            const dst = d.row.items[n * 256 ..][0..256];
            var i = span.len;
            while (i > 0) {
                i -= 1;
                const e = d.edges.items[span.first + i];
                @memset(dst[e.lo .. @as(usize, e.hi) + 1], e.target);
            }
        }
    }

    /// The edge target covering `b`, or null when the byte cannot continue here.
    pub fn follow(d: *const Decoder, node: u32, b: u8) ?u32 {
        std.debug.assert(d.row.items.len == d.nodes.items.len * 256); // `spread` ran
        const t = d.row.items[(@as(usize, node) << 8) | b];
        return if (t == no_edge) null else t;
    }

    /// Intern a node by its edge list so shared tails — every three-byte
    /// `[80-BF][80-BF]` chain, and there are many — collapse to one node.
    fn intern(d: *Decoder, list: []const Edge) Error!u32 {
        d.key.clearRetainingCapacity();
        for (list) |e| try d.key.append(d.gpa, packEdge(e));
        if (d.cons.get(d.key.items)) |id| return id;
        if (d.nodes.items.len >= max_nodes) return Decline.TooLarge;
        const owned = try d.gpa.dupe(u64, d.key.items);
        errdefer d.gpa.free(owned);
        const id: u32 = @intCast(d.nodes.items.len);
        const first: u32 = @intCast(d.edges.items.len);
        try d.edges.appendSlice(d.gpa, list);
        try d.nodes.append(d.gpa, .{ .first = first, .len = @intCast(list.len) });
        try d.cons.put(owned, id);
        return id;
    }

    /// Build the decoder level for `idx` (indices into `seqs`) at byte position
    /// `depth`: cut the byte line at every range endpoint present, then per
    /// resulting atomic byte range either announce a minterm (all members end
    /// here) or recurse. Members of one atom always agree — they encode disjoint
    /// codepoint sets, so two of them ending at the same byte with different
    /// minterms would put one codepoint in two blocks of a partition.
    fn weave(d: *Decoder, idx: []const u32, depth: usize) Error!u32 {
        const gpa = d.gpa;
        var cuts: std.ArrayList(u16) = .empty;
        defer cuts.deinit(gpa);
        for (idx) |i| {
            const r = d.seqs.items[i].seq.ranges[depth];
            try cuts.append(gpa, r.start);
            try cuts.append(gpa, @as(u16, r.end) + 1);
        }
        std.mem.sort(u16, cuts.items, {}, std.sort.asc(u16));

        var list: std.ArrayList(Edge) = .empty;
        defer list.deinit(gpa);
        var members: std.ArrayList(u32) = .empty;
        defer members.deinit(gpa);

        var c: usize = 0;
        while (c + 1 < cuts.items.len) : (c += 1) {
            if (cuts.items[c] == cuts.items[c + 1]) continue;
            const lo: u8 = @intCast(cuts.items[c]);
            const hi: u8 = @intCast(cuts.items[c + 1] - 1);
            members.clearRetainingCapacity();
            var ends = false;
            var conts = false;
            for (idx) |i| {
                const t = d.seqs.items[i];
                const r = t.seq.ranges[depth];
                if (r.start > lo or lo > r.end) continue;
                try members.append(gpa, i);
                if (depth + 1 == t.seq.len) ends = true else conts = true;
            }
            if (members.items.len == 0) continue;
            if (ends and conts) return Decline.Malformed; // a lead byte fixes the length
            const target = if (ends) blk: {
                const m = d.seqs.items[members.items[0]].mint;
                for (members.items) |i| if (d.seqs.items[i].mint != m) return Decline.Malformed;
                break :blk leaf | @as(u32, m);
            } else try d.weave(members.items, depth + 1);
            // Fuse with the previous edge when it is adjacent and identical: the
            // byte-class partition is derived from these boundaries, so leaving
            // a split unfused would cost a whole table column.
            if (list.items.len > 0) {
                const last = &list.items[list.items.len - 1];
                if (last.target == target and @as(u16, last.hi) + 1 == lo) {
                    last.hi = hi;
                    continue;
                }
            }
            try list.append(gpa, .{ .lo = lo, .hi = hi, .target = target });
        }
        return d.intern(list.items);
    }
};

/// A minterm the pattern rejects from EVERY state — reading it always lands on
/// the same re-seed a lost sync does. Such a codepoint need not be decoded at
/// all: dropping it lets resync consume its bytes one at a time, which is sound
/// because no continuation byte can begin a match. On `\w+X` this is the
/// difference between carrying the whole non-word trie and not.
fn rejected(aut: *const determinize.Automaton, m: u16) bool {
    var q: u32 = 0;
    while (q < aut.nstates) : (q += 1) {
        const i = @as(usize, q) * aut.nmt + m;
        if (aut.trans_in[i] != aut.reseed or aut.trans_fin[i] != aut.fin_reseed) return false;
    }
    return true;
}

/// Decompose every minterm the pattern can distinguish into UTF-8 byte-range
/// sequences and weave them into one deterministic decoder. `pruned` reports how
/// many minterms were skipped as uniformly rejected.
pub fn build(
    gpa: std.mem.Allocator,
    alpha: *const alphabet.Alphabet,
    aut: *const determinize.Automaton,
    pruned: *u16,
) Error!Decoder {
    var d = Decoder{ .gpa = gpa, .cons = ConsMap.init(gpa) };
    errdefer d.deinit();
    var m: u16 = 0;
    while (m < alpha.count) : (m += 1) {
        if (rejected(aut, m)) {
            pruned.* += 1;
            continue;
        }
        const ranges = try alpha.rangesOf(gpa, m);
        defer gpa.free(ranges);
        for (ranges) |r| {
            var it = u8seq.Sequences.init(r[0], r[1]);
            while (it.next()) |s| try d.seqs.append(gpa, .{ .seq = s, .mint = m });
        }
    }
    // Every minterm rejected ⇒ nothing to decode. The empty-edge root still
    // answers: every byte resyncs to the re-seed, which is the truth.
    if (d.seqs.items.len == 0) {
        d.root = try d.intern(&.{});
        try d.spread();
        return d;
    }
    const all = try gpa.alloc(u32, d.seqs.items.len);
    defer gpa.free(all);
    for (all, 0..) |*slot, i| slot.* = @intCast(i);
    d.root = try d.weave(all, 0);
    try d.spread();
    return d;
}

/// Byte equivalence classes for the product: two bytes share a class iff no
/// decoder edge separates them, so every node resolves them identically (both
/// inside the same edge, or both outside every edge and resyncing). Deliberately
/// over-refined — `transcribe.zig` recovers the coarse partition once the
/// columns exist and can be compared.
pub fn classes(d: *const Decoder) subset.Classes {
    var c: subset.Classes = .{ .class = undefined, .rep = undefined, .ncls = 1 };
    @memset(&c.class, 0);
    for (d.edges.items) |e| {
        c.ncls = refine(&c.class, e.lo, e.hi);
        if (c.ncls == 256) break;
    }
    for (0..256) |bi| c.rep[c.class[bi]] = @intCast(bi);
    return c;
}

/// Split `class` by one byte-range membership predicate; returns the new count.
/// The `refineBySet` of `dfa/subset.zig`, over a range instead of a bit set.
fn refine(class: *[256]u8, lo: u8, hi: u8) u16 {
    var seen = [_]i16{-1} ** 512;
    var newn: u16 = 0;
    for (0..256) |bi| {
        const inside: usize = @intFromBool(lo <= bi and bi <= hi);
        const k = @as(usize, class[bi]) * 2 + inside;
        if (seen[k] < 0) {
            seen[k] = @intCast(newn);
            newn += 1;
        }
        class[bi] = @intCast(seen[k]);
    }
    return newn;
}

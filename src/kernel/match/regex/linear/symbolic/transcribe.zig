//! gist — transcribing a codepoint automaton back into a byte one.
//!
//! Determinizing over minterms buys the compile-time collapse, but the scan
//! loop must not change: `s = trans[s + class[b]]`, one dependent load per byte,
//! is the hardware floor the whole engine is built on and no codepoint-at-a-time
//! matcher can touch it. So the last step is a **product**: a UTF-8 → minterm
//! decoder (built once over the alphabet, not once per class occurrence) is
//! crossed with the pattern automaton, and the reachable pairs *are* the byte
//! DFA. Same `Dfa` struct, same premultiplied tables, same `match`.
//!
//! Three things make the product exact rather than merely plausible:
//!   * A continuation byte (`80–BF`) is never a lead byte, so at any position
//!     the decoder's phase is fixed by the byte history — the byte engine can
//!     never be mid-sequence in two different ways at once, which is what lets
//!     one decoder node stand for its whole trie frontier.
//!   * Malformed input **resyncs**: the decoder restarts at the offending byte
//!     and the pattern drops to `reseed`. For an unanchored program that is the
//!     start closure (a match may begin anywhere); for an anchored one it is the
//!     dead state — which is why `^é` cannot match `\xC3\xC3\xA9` here any more
//!     than it does in the byte engine.
//!   * A surrogate encoding has no minterm edge at all (`utf8seq` refuses to
//!     emit one), so it resyncs like any other malformed sequence — exactly what
//!     the byte trie does by having no path for it.

const std = @import("std");
const subset = @import("../dfa/subset.zig");
const Dfa = @import("../dfa/dfa.zig").Dfa;
const alphabet = @import("alphabet.zig");
const decoder_mod = @import("decoder.zig");
const determinize = @import("determinize.zig");
const minimize = @import("minimize.zig");

/// Ceiling on reachable product states. Deliberately equal to
/// `dfa/powerset.zig`'s `max_states`, so this path can never hand back a table
/// the byte path would have refused to hold.
pub const max_states: u32 = 4096;

// File-private control flow (ADR-373): same names as decoder's set so Zig
// unifies them; converted to `.declined` at the symbolic module boundary.
const Decline = error{ TooLarge, Malformed };
const Error = Decline || std.mem.Allocator.Error;
const Decoder = decoder_mod.Decoder;
const leaf = decoder_mod.leaf;
const unknown = subset.unknown;

// ─────────────────────────── the product automaton ───────────────────────────

/// Where a byte lands: the decoder's next node and the pattern's next state.
const Landing = struct { node: u32, pat: u32 };

const Product = struct {
    gpa: std.mem.Allocator,
    dec: *const Decoder,
    aut: *const determinize.Automaton,
    ncls: u16,
    map: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    keys: std.ArrayList(u64) = .empty,
    trans_in: std.ArrayList(u32) = .empty,
    trans_fin: std.ArrayList(u32) = .empty,
    is_match: std.ArrayList(bool) = .empty,

    fn deinit(p: *Product) void {
        p.map.deinit(p.gpa);
        p.keys.deinit(p.gpa);
        p.trans_in.deinit(p.gpa);
        p.trans_fin.deinit(p.gpa);
        p.is_match.deinit(p.gpa);
    }

    /// A pattern state that can never match again makes the decoder's phase
    /// irrelevant, so every `(node, dead)` pair collapses to one absorbing
    /// state. That is what gives `Dfa.match` its anchored early-exit — and it
    /// only ever fires for anchored programs, whose `reseed` IS `dead`.
    fn canon(p: *const Product, l: Landing) u64 {
        const node = if (p.aut.reseed == p.aut.dead and l.pat == p.aut.dead) p.dec.root else l.node;
        return (@as(u64, node) << 32) | l.pat;
    }

    fn intern(p: *Product, l: Landing) Error!struct { id: u32, is_new: bool } {
        const key = p.canon(l);
        if (p.map.get(key)) |id| return .{ .id = id, .is_new = false };
        if (p.keys.items.len >= max_states) return Decline.TooLarge;
        const id: u32 = @intCast(p.keys.items.len);
        try p.map.put(p.gpa, key, id);
        try p.keys.append(p.gpa, key);
        // A match ends on a codepoint boundary, never between the bytes of one.
        // Mid-sequence the pattern half still carries the verdict from BEFORE
        // this partial codepoint — a verdict the scan loop already read and
        // returned at that earlier byte — so repeating it here would only split
        // every decoder node in two: matched-twin and unmatched-twin, which is
        // precisely the factor of 2 that made this table twice the byte path's.
        const at_boundary = @as(u32, @intCast(key >> 32)) == p.dec.root;
        try p.is_match.append(p.gpa, at_boundary and p.aut.is_match[@as(u32, @truncate(key))]);
        try p.trans_in.appendNTimes(p.gpa, unknown, p.ncls);
        try p.trans_fin.appendNTimes(p.gpa, unknown, p.ncls);
        return .{ .id = id, .is_new = true };
    }

    /// Read one byte. `at_end` selects the pattern's final table, where `$`
    /// resolves; an incomplete or malformed codepoint there leaves nothing but
    /// the re-seed's own end-of-line closure.
    fn stepByte(p: *const Product, from: Landing, b: u8, at_end: bool) Landing {
        const a = p.aut;
        const tbl = if (at_end) a.trans_fin else a.trans_in;
        // At end of line nothing follows, so a half-read codepoint's decoder
        // phase is unobservable: every incomplete landing there is the SAME
        // state. Interning it as one keeps the decoder from minting a terminal
        // twin per node — the difference between a table the size of the byte
        // path's and one twice it.
        const half: Landing = .{ .node = p.dec.root, .pat = a.fin_reseed };
        if (p.dec.follow(from.node, b)) |t| {
            if (t & leaf == 0) return if (at_end) half else .{ .node = t, .pat = from.pat };
            return .{ .node = p.dec.root, .pat = tbl[@as(usize, from.pat) * a.nmt + (t & ~leaf)] };
        }
        // Lost sync. The byte cannot continue the sequence in flight, so that
        // sequence is malformed and every thread inside it dies; re-read the
        // byte as a fresh start. A continuation byte is never a lead, so this
        // can never double-count a codepoint.
        if (from.node != p.dec.root) {
            if (p.dec.follow(p.dec.root, b)) |t| {
                if (t & leaf == 0) return if (at_end) half else .{ .node = t, .pat = a.reseed };
                return .{ .node = p.dec.root, .pat = tbl[@as(usize, a.reseed) * a.nmt + (t & ~leaf)] };
            }
        }
        return if (at_end) half else .{ .node = p.dec.root, .pat = a.reseed };
    }
};

/// The expansion frontier, `dfa/powerset.zig`'s `Worklist` over product ids:
/// dense ids handed out in order, so one bool per interned state replaces a map.
const Frontier = struct {
    gpa: std.mem.Allocator,
    queued: std.ArrayList(bool) = .empty,
    items: std.ArrayList(u32) = .empty,

    fn deinit(f: *Frontier) void {
        f.queued.deinit(f.gpa);
        f.items.deinit(f.gpa);
    }

    fn push(f: *Frontier, p: *const Product, id: u32) std.mem.Allocator.Error!void {
        while (f.queued.items.len < p.keys.items.len) try f.queued.append(f.gpa, false);
        if (f.queued.items[id]) return;
        f.queued.items[id] = true;
        try f.items.append(f.gpa, id);
    }
};

/// Merge byte classes whose table columns are identical — the over-refinement
/// `buildClasses` accepts for soundness, paid back once the columns exist.
/// Returns the new class count; rewrites `class`, `trans_in` and `trans_fin`.
fn mergeClasses(gpa: std.mem.Allocator, cls: *subset.Classes, ns: u32, tin: []u32, tfin: []u32) std.mem.Allocator.Error!u16 {
    const ncls = cls.ncls;
    var col = try gpa.alloc(u64, ncls);
    defer gpa.free(col);
    for (0..ncls) |k| {
        var h = std.hash.Wyhash.init(0);
        for (0..ns) |s| {
            h.update(std.mem.asBytes(&tin[s * ncls + k]));
            h.update(std.mem.asBytes(&tfin[s * ncls + k]));
        }
        col[k] = h.final();
    }
    var remap = try gpa.alloc(u16, ncls);
    defer gpa.free(remap);
    var newn: u16 = 0;
    for (0..ncls) |k| {
        remap[k] = newn;
        for (0..k) |j| if (col[j] == col[k] and sameColumn(ncls, ns, tin, tfin, @intCast(j), @intCast(k))) {
            remap[k] = remap[j];
            break;
        };
        if (remap[k] == newn) newn += 1;
    }
    if (newn == ncls) return ncls;
    for (0..ns) |s| for (0..ncls) |k| {
        tin[s * newn + remap[k]] = tin[s * ncls + k];
        tfin[s * newn + remap[k]] = tfin[s * ncls + k];
    };
    for (0..256) |bi| cls.class[bi] = @intCast(remap[cls.class[bi]]);
    for (0..256) |bi| cls.rep[cls.class[bi]] = @intCast(bi);
    cls.ncls = newn;
    return newn;
}

fn sameColumn(ncls: u16, ns: u32, tin: []const u32, tfin: []const u32, j: u16, k: u16) bool {
    for (0..ns) |s| {
        if (tin[s * ncls + j] != tin[s * ncls + k]) return false;
        if (tfin[s * ncls + j] != tfin[s * ncls + k]) return false;
    }
    return true;
}

/// Statistics the measurement harnesses read: how much the two determinizations
/// actually cost on the same pattern.
pub const Stats = struct { visits: u64 = 0, minterms: u16 = 0, pruned: u16 = 0, nodes: u32 = 0, pat_states: u32 = 0, product_states: u32 = 0 };

/// Cross the decoder with the determinized codepoint automaton and freeze the
/// reachable pairs into the byte `Dfa` the ladder already runs.
pub fn transcribe(
    gpa: std.mem.Allocator,
    aut: *const determinize.Automaton,
    alpha: *const alphabet.Alphabet,
    anchored: bool,
    stats: *Stats,
) Error!*Dfa {
    var dec = try decoder_mod.build(gpa, alpha, aut, &stats.pruned);
    defer dec.deinit();
    var cls = decoder_mod.classes(&dec);
    stats.nodes = dec.count();

    var p = Product{ .gpa = gpa, .dec = &dec, .aut = aut, .ncls = cls.ncls };
    defer p.deinit();

    // The frontier is keyed on "has an interior byte ever landed here", NOT on
    // "was freshly interned": a state first seen as a `trans_fin` target is
    // already interned when the interior later reaches it, and skipping it then
    // would ship a row of `unknown` the scan loop can index.
    var work = Frontier{ .gpa = gpa };
    defer work.deinit();

    const start_id = (try p.intern(.{ .node = dec.root, .pat = aut.start })).id;
    try work.push(&p, start_id);

    var cur: usize = 0;
    while (cur < work.items.items.len) : (cur += 1) {
        const id = work.items.items[cur];
        const from = Landing{ .node = @intCast(p.keys.items[id] >> 32), .pat = @truncate(p.keys.items[id]) };
        var k: u16 = 0;
        while (k < cls.ncls) : (k += 1) {
            const rep = cls.rep[k];
            const in = try p.intern(p.stepByte(from, rep, false));
            p.trans_in.items[@as(usize, id) * cls.ncls + k] = in.id;
            try work.push(&p, in.id);
            // The final table's targets are terminal — the line ends right
            // after — so they are interned for `is_match` but never expanded.
            const fin = try p.intern(p.stepByte(from, rep, true));
            p.trans_fin.items[@as(usize, id) * cls.ncls + k] = fin.id;
        }
    }

    // An anchored program's absorbing sink, if the walk ever reached it: the one
    // state whose pattern half is dead (all decoder phases collapsed into it).
    var dead: u32 = unknown;
    if (aut.reseed == aut.dead and aut.dead != std.math.maxInt(u32)) {
        if (p.map.get((@as(u64, dec.root) << 32) | aut.dead)) |id| dead = id;
    }

    // Quotient out the decoder phase the pattern can't observe, THEN drop the
    // byte classes the quotient no longer separates. Rows first: merging states
    // is what makes whole columns coincide, so the other order leaves both
    // dimensions over-refined.
    const raw: u32 = @intCast(p.keys.items.len);
    stats.product_states = raw;
    const map = try gpa.alloc(u32, raw);
    defer gpa.free(map);
    const ns = try minimize.run(gpa, raw, cls.ncls, p.trans_in.items, p.trans_fin.items, p.is_match.items, map);
    const start = map[start_id];
    if (dead != unknown) dead = map[dead];
    p.trans_in.shrinkRetainingCapacity(@as(usize, ns) * cls.ncls);
    p.trans_fin.shrinkRetainingCapacity(@as(usize, ns) * cls.ncls);
    p.is_match.shrinkRetainingCapacity(ns);

    const ncls = try mergeClasses(gpa, &cls, ns, p.trans_in.items, p.trans_fin.items);
    p.trans_in.shrinkRetainingCapacity(@as(usize, ns) * ncls);
    p.trans_fin.shrinkRetainingCapacity(@as(usize, ns) * ncls);
    stats.pat_states = aut.nstates;
    stats.minterms = alpha.count;

    const accel = subset.startAccel(anchored, aut.empty_match, p.trans_in.items, p.trans_fin.items, p.is_match.items, &cls.class, ncls, start);

    const nc: u32 = ncls;
    for (p.trans_in.items) |*t| if (t.* != unknown) {
        t.* *= nc;
    };
    for (p.trans_fin.items) |*t| if (t.* != unknown) {
        t.* *= nc;
    };
    const im = try gpa.alloc(bool, @as(usize, ns) * ncls);
    errdefer gpa.free(im);
    @memset(im, false);
    for (p.is_match.items, 0..) |m, id| im[id * ncls] = m;

    const dfa = try gpa.create(Dfa);
    errdefer gpa.destroy(dfa);
    dfa.* = .{
        .class = cls.class,
        .ncls = ncls,
        .nstates = ns,
        .trans_in = try p.trans_in.toOwnedSlice(gpa),
        .trans_fin = try p.trans_fin.toOwnedSlice(gpa),
        .is_match = im,
        .start = start * nc,
        .empty_match = aut.empty_match,
        .anchored = anchored,
        .dead = if (dead == unknown) unknown else dead * nc,
        .accel = accel,
        .word_ctx = false,
        .unicode_word = false,
        .trans_in_w = &.{},
        .start_w = start * nc,
        .allocator = gpa,
    };
    return dfa;
}

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
const freeze = @import("../automata/freeze.zig");
const Dfa = @import("../dfa/dfa.zig").Dfa;
const alphabet = @import("alphabet.zig");
const decoder_mod = @import("decoder.zig");
const determinize = @import("determinize.zig");
const reduce = @import("../automata/reduce.zig");

/// Ceiling on reachable product states. Deliberately equal to
/// `dfa/powerset.zig`'s `max_states`, so this path can never hand back a table
/// the byte path would have refused to hold.
pub const max_states: u32 = 4096;

// File-private control flow (the fault-channel taxonomy): same names as decoder's set so Zig
// unifies them; converted to `.declined` at the symbolic module boundary.
const Decline = error{ TooLarge, Malformed };
const Error = Decline || std.mem.Allocator.Error;
const Decoder = decoder_mod.Decoder;
const leaf = decoder_mod.leaf;
const unknown = subset.unknown;

// ─────────────────────────── the product automaton ───────────────────────────

/// An upper bound on the product's reachable states, read off the two factors
/// before a single pair is interned. Sound by construction — every interned key
/// is a `canon`ed `(node, pattern state)` and nothing else — and in practice
/// EXACT, because the two factors are independent: a mid-sequence byte carries
/// the pattern state through untouched (`stepByte`), so every node the decoder
/// can reach pairs with every state the pattern can reach. Measured against the
/// finished walk over 33 codepoint-class patterns, the bound was hit exactly in
/// all of them.
///
/// The anchored refinement is the one place `canon` takes a column out of the
/// space: there `reseed == dead`, so every `(node, dead)` collapses onto the
/// single absorbing pair. `^func\s` reaches 49 = 8 × (7−1) + 1, not 8 × 7.
fn pairBound(nodes: u32, aut: *const determinize.Automaton) u64 {
    const n: u64 = nodes;
    const pats: u64 = aut.nstates;
    if (aut.reseed == aut.dead and aut.dead != std.math.maxInt(u32) and pats > 0) return n * (pats - 1) + 1;
    return n * pats;
}

/// Where a byte lands: the decoder's next node and the pattern's next state.
const Landing = struct { node: u32, pat: u32 };

/// `seen`'s "no pair has been interned in this slot yet".
const none: u32 = std.math.maxInt(u32);

const Product = struct {
    gpa: std.mem.Allocator,
    dec: *const Decoder,
    aut: *const determinize.Automaton,
    ncls: u16,
    /// `(node, pattern state) -> product id`, dense: `seen[node * nstates + pat]`.
    /// The pair space is what `pairBound` measured before the walk was allowed to
    /// start, so this array is bounded by that same figure — under 8 K slots, 32
    /// KiB — and a hash map buys nothing over an index that small. It is the
    /// interning that dominated the walk once `Decoder.follow` stopped: 872 K
    /// probes on `func\s+\w+\(`, all but 3792 of them hits.
    seen: []u32,
    keys: std.ArrayList(u64) = .empty,
    trans_in: std.ArrayList(u32) = .empty,
    trans_fin: std.ArrayList(u32) = .empty,
    is_match: std.ArrayList(bool) = .empty,

    fn deinit(p: *Product) void {
        p.gpa.free(p.seen);
        p.keys.deinit(p.gpa);
        p.trans_in.deinit(p.gpa);
        p.trans_fin.deinit(p.gpa);
        p.is_match.deinit(p.gpa);
    }

    /// A pattern state that can never match again makes the decoder's phase
    /// irrelevant, so every `(node, dead)` pair collapses to one absorbing
    /// state. That is what gives `Dfa.match` its anchored early-exit — and it
    /// only ever fires for anchored programs, whose `reseed` IS `dead`.
    fn canonNode(p: *const Product, l: Landing) u32 {
        return if (p.aut.reseed == p.aut.dead and l.pat == p.aut.dead) p.dec.root else l.node;
    }

    fn intern(p: *Product, l: Landing) Error!struct { id: u32, is_new: bool } {
        const node = p.canonNode(l);
        // Both halves are interned ids — a decoder node and a codepoint-automaton
        // state — so the slot is in range. `aut.dead` is the one id that can be
        // `maxInt` (no dead state was ever interned), and it is only ever COMPARED
        // against in `canonNode`, never landed on.
        std.debug.assert(node < p.dec.count() and l.pat < p.aut.nstates);
        const slot = @as(usize, node) * p.aut.nstates + l.pat;
        if (p.seen[slot] != none) return .{ .id = p.seen[slot], .is_new = false };
        // Unreachable while `pairBound` gates the walk — kept because it, not the
        // bound, is what the returned table's size actually rests on.
        if (p.keys.items.len >= max_states) return Decline.TooLarge;
        const id: u32 = @intCast(p.keys.items.len);
        p.seen[slot] = id;
        const key = (@as(u64, node) << 32) | l.pat;
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
    stats.nodes = dec.count();
    stats.pat_states = aut.nstates;
    stats.minterms = alpha.count;

    // Start the walk only when it can finish. `intern` enforces `max_states` a
    // pair at a time, which is the right guard but the wrong moment: a product
    // whose pair space is already past the cap spends the whole walk to learn
    // that, and every one of those pairs is thrown away. `pgxpool\.\w+` paid
    // 5.3 ms interning 5372 pairs against a 4096 ceiling. The bound above is
    // free and, on the patterns that hit this, exact.
    //
    // No semantic content: declining hands the pattern to `dfa/powerset.zig` and
    // then to `dfa/lazy.zig`, which is where every pair-space this size already
    // ended up — the only change is the bill for finding out.
    if (pairBound(dec.count(), aut) >= max_states) return Decline.TooLarge;

    var cls = decoder_mod.classes(&dec);

    const seen = try gpa.alloc(u32, @as(usize, dec.count()) * aut.nstates);
    @memset(seen, none);
    var p = Product{ .gpa = gpa, .dec = &dec, .aut = aut, .ncls = cls.ncls, .seen = seen };
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
        const slot = @as(usize, dec.root) * aut.nstates + aut.dead;
        if (p.seen[slot] != none) dead = p.seen[slot];
    }

    // Quotient out the decoder phase the pattern can't observe, in both
    // dimensions — `reduce` owns the rows-then-columns order this needs, and
    // owns it for the byte road too.
    const raw: u32 = @intCast(p.keys.items.len);
    stats.product_states = raw;
    const map = try gpa.alloc(u32, raw);
    defer gpa.free(map);
    // The product is never word-context — that road declines before it gets
    // here — so the reduction cannot decline either.
    const ext = (try reduce.run(gpa, &cls, .{
        .interior = &p.trans_in,
        .final = &p.trans_fin,
        .is_match = p.is_match.items,
    }, raw, map, .both)).?;
    const start = map[start_id];
    if (dead != unknown) dead = map[dead];
    p.is_match.shrinkRetainingCapacity(ext.nstates);

    // Same freeze the byte path takes: match-first renumbering, start
    // acceleration off the finished start row, then premultiplication.
    return freeze.freeze(gpa, &cls, .{
        .interior = &p.trans_in,
        .final = &p.trans_fin,
        .is_match = p.is_match.items,
    }, .{
        .nstates = ext.nstates,
        .start = start,
        .start_word = start,
        .dead = dead,
        .empty_match = aut.empty_match,
        .anchored = anchored,
    });
}

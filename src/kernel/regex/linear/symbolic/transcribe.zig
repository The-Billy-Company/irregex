//! irregex — transcribing a codepoint automaton back into a byte one.
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
const horizon_mod = @import("horizon.zig");
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
/// is a `canon`ed `(node, pattern state)` and nothing else.
///
/// It used to be exact, and the reason it no longer is, is the point of
/// `horizon.zig`: the two factors looked independent because a mid-sequence byte
/// carries the pattern state through untouched, so every decoder node appeared to
/// pair with every pattern state. It does — but most of those pairs are the same
/// state, because a node deep in a class's trie can only ever hand `q` to the
/// transition table for the minterms still reachable below it. `\w+X` bounds at
/// 316 × 3 = 948 and walks 318.
///
/// So the gate reads **both** this and the horizon's own `pairs`, and takes the
/// tighter. Neither dominates: `pairs` is a per-node class count and is far
/// smaller on anything with a Unicode class, while this one carries the anchored
/// refinement `pairs` cannot — the one place `canon` takes a whole column out of
/// the space, because `reseed == dead` there collapses every `(node, dead)` onto
/// the single absorbing pair. `^func\s` bounds at 49 = 8 × (7−1) + 1, not 8 × 7.
/// Both are upper bounds on what the walk can intern, so the minimum is one too.
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
    /// Which pattern states a given node can still tell apart. Substituting a
    /// state's representative before interning is what keeps the walk from
    /// building the mid-codepoint twins `reduce` would only merge again.
    hor: *const horizon_mod.Horizon,
    ncls: u16,
    /// `(node, pattern state) -> product id`, addressed by `horizon.slot`: one
    /// block per decoder node, each sized to the classes that node can still tell
    /// apart rather than to every state the automaton has. Exactly `hor.pairs`
    /// long — 658 slots on `func\s+\w+\(` where the rectangle wanted 3792 — which
    /// matters less for the memory than for the `@memset` that has to precede
    /// every walk. A hash map buys nothing over an index this small, and it is the
    /// interning that dominated the walk once `Decoder.follow` stopped: 872 K
    /// probes on that pattern, all but 3792 of them hits.
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
        //
        // THE ASSERT IS THE ONLY GUARD, AND IT IS DEBUG-ONLY. Release builds are
        // ReleaseFast, where this compiles to `unreachable` — so in the build that
        // matters the two bounds below are an ASSUMPTION handed to the optimizer,
        // not a check. What it is protecting is the `p.seen[slot] = id` store four
        // lines down: a `Landing` carrying `pat == aut.dead == maxInt(u32)` would
        // compute a slot of ~2³² × `nstates` and write there. That is an
        // out-of-bounds WRITE into the heap, not a read and not a panic — it would
        // surface as corruption somewhere unrelated, long after this frame is gone.
        //
        // So the load-bearing fact is the one stated above: nothing may LAND on
        // `aut.dead`. `canonNode` compares against it and maps the pair onto
        // `dec.root`, which keeps `node` in range, but it deliberately leaves
        // `l.pat` alone — the dead id still reaches the slot arithmetic. If a
        // future change lets a dead pattern state flow into `intern` as a landing
        // (rather than only as a comparand), or gives `dead` a real interned id
        // without re-checking this, that is the specific way to turn a compile-time
        // cost optimization into heap corruption. `horizon.slot` is the single
        // addressing rule: it is used here, in the `dead` lookup after the walk,
        // and it is what `hor.pairs` sizes `seen` to, and those three must agree.
        std.debug.assert(node < p.dec.count() and l.pat < p.aut.nstates);
        // Mid-codepoint the pattern is not running, so `node` may not be able to
        // tell `l.pat` from a lower-numbered state; intern that one instead. The
        // horizon is read at the CANONED node, and it is the identity at the root
        // — which is both where `is_match` is read and where the anchored
        // collapse above lands, so neither is disturbed.
        const pat = p.hor.canon(node, l.pat);
        const slot = p.hor.slot(node, pat);
        if (p.seen[slot] != none) return .{ .id = p.seen[slot], .is_new = false };
        // Unreachable while the pair gate precedes the walk — kept because it, not
        // either bound, is what the returned table's size actually rests on.
        if (p.keys.items.len >= max_states) return Decline.TooLarge;
        const id: u32 = @intCast(p.keys.items.len);
        p.seen[slot] = id;
        const key = (@as(u64, node) << 32) | pat;
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

    /// `stepByte`'s lost-sync tail, on its own. Reachable only from a non-root
    /// node — the root consumes a byte that starts nothing rather than re-reading
    /// it — and, crucially, **it never reads `from.pat`**. So every non-root node
    /// resyncs to the same landing on the same byte, and that landing can be
    /// interned once for the whole walk instead of once per state.
    fn resyncByte(p: *const Product, b: u8, at_end: bool) Landing {
        const a = p.aut;
        const tbl = if (at_end) a.trans_fin else a.trans_in;
        const half: Landing = .{ .node = p.dec.root, .pat = a.fin_reseed };
        if (p.dec.follow(p.dec.root, b)) |t| {
            if (t & leaf == 0) return if (at_end) half else .{ .node = t, .pat = a.reseed };
            return .{ .node = p.dec.root, .pat = tbl[@as(usize, a.reseed) * a.nmt + (t & ~leaf)] };
        }
        return if (at_end) half else .{ .node = p.dec.root, .pat = a.reseed };
    }
};

/// Which byte classes a decoder node actually has an edge for.
///
/// A product row is `ncls` wide — 102 columns on `func\s+\w+\(` — but a decoder
/// node has a handful of live edges and resyncs on everything else, and
/// `resyncByte` shows the resync landing to be independent of the pattern state.
/// So the resync half of every row is **one row, computed once and copied**, and
/// the walk's per-state work drops to the live edges: 6 columns instead of 102,
/// with the other 96 becoming a `memcpy` the table had to pay for anyway.
///
/// `read` is what keeps that from inventing states. A resync column is interned
/// only if some non-root node actually resyncs on that class, and every decoder
/// node is reachable in the product (it sits on a byte path from the root, and a
/// mid-sequence landing carries the pattern state through, so nothing can strand
/// it — the one exception, an unsatisfiable program whose start IS its dead
/// state, is held off by the caller). The interned set is therefore exactly the
/// set the old column-at-a-time walk reached, which is why the product's state
/// count is unchanged and not merely similar.
const Edges = struct {
    gpa: std.mem.Allocator,
    /// Class ids with an edge, laid out per node. `ncls ≤ 256`, so a class id is
    /// a byte.
    live: []u8,
    /// `live[at[n]..at[n + 1]]` — node `n`'s live classes.
    at: []u32,
    /// Classes some non-root node resyncs on: the resync columns a walk can read.
    read: []bool,
    /// Whether the root has a class with no edge at all. Its resync row is a
    /// single target, so one bit answers for all `ncls` columns.
    root_reads: bool,

    fn deinit(e: *Edges) void {
        e.gpa.free(e.live);
        e.gpa.free(e.at);
        e.gpa.free(e.read);
    }
};

/// One pass over `nodes × ncls` of the decoder's byte row, replacing the same
/// question asked once per *product state* — a factor of `states / nodes`, and
/// then only for the columns that survive it.
fn scanEdges(
    gpa: std.mem.Allocator,
    dec: *const Decoder,
    cls: *const subset.Classes,
) std.mem.Allocator.Error!Edges {
    const nodes = dec.count();
    var live: std.ArrayList(u8) = .empty;
    errdefer live.deinit(gpa);
    const at = try gpa.alloc(u32, @as(usize, nodes) + 1);
    errdefer gpa.free(at);
    const read = try gpa.alloc(bool, cls.ncls);
    errdefer gpa.free(read);
    @memset(read, false);

    var root_reads = false;
    for (0..nodes) |n| {
        at[n] = @intCast(live.items.len);
        var k: u16 = 0;
        while (k < cls.ncls) : (k += 1) {
            if (dec.follow(@intCast(n), cls.rep[k]) != null) {
                try live.append(gpa, @intCast(k));
            } else if (@as(u32, @intCast(n)) == dec.root) {
                root_reads = true;
            } else {
                read[k] = true;
            }
        }
    }
    at[nodes] = @intCast(live.items.len);
    return .{
        .gpa = gpa,
        .live = try live.toOwnedSlice(gpa),
        .at = at,
        .read = read,
        .root_reads = root_reads,
    };
}

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
/// actually cost on the same pattern, and — since the gate below is the reason
/// some patterns get an eager table and some do not — what the two readings of
/// the pair space said. `bound` is the free upper bound, `pairs` the horizon's
/// exact count; both are filled even on the path that declines, so a decline is
/// attributable to a number rather than to a shrug.
pub const Stats = struct {
    visits: u64 = 0,
    minterms: u16 = 0,
    pruned: u16 = 0,
    nodes: u32 = 0,
    pat_states: u32 = 0,
    product_states: u32 = 0,
    bound: u64 = 0,
    pairs: u64 = 0,
    kinds: u32 = 0,
};

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

    var cls = decoder_mod.classes(&dec);

    // The quotient the walk interns against, and — because it counts each node's
    // classes rather than assuming every state survives at every node — the exact
    // size of the table that walk needs.
    var hor = try horizon_mod.build(gpa, &dec, aut);
    defer hor.deinit();
    stats.bound = pairBound(dec.count(), aut);
    stats.pairs = hor.pairs;
    stats.kinds = hor.kinds;

    // Start the walk only when it can finish. `intern` enforces `max_states` a
    // pair at a time, which is the right guard but the wrong moment: a product
    // whose pair space is already past the cap spends the whole walk to learn
    // that, and every one of those pairs is thrown away. `pgxpool\.\w+` paid
    // 5.3 ms interning 5372 pairs against a 4096 ceiling.
    //
    // Reading `pairs` here rather than the rectangle is the whole reason the
    // horizon is built BEFORE the gate instead of after it: `pgxpool\.\w+`'s
    // rectangle is 316 × 17 = 5372 and its real pair space is 332, so a pattern
    // that used to buy the byte powerset and then the lazy DFA now holds an eager
    // table. That is a change of tier, not of answer — and it is why this path
    // owes the differentials it now has.
    //
    // Declining still has no semantic content: it hands the pattern to
    // `dfa/powerset.zig` and then to `dfa/lazy.zig`, which is where every
    // pair-space genuinely this size already ended up.
    if (@min(stats.bound, stats.pairs) >= max_states) return Decline.TooLarge;

    // Sized by the gate above and not by hope: a node contributes at most `pats`
    // classes, so `pairs ≤ nodes × pats`, which is `bound` plus at most
    // `nodes − 1` under the anchored refinement. Past a gate on the minimum both
    // are therefore under `max_states + max_nodes` — 32 KiB, worst case.
    const seen = try gpa.alloc(u32, @intCast(hor.pairs));
    @memset(seen, none);
    var p = Product{ .gpa = gpa, .dec = &dec, .aut = aut, .hor = &hor, .ncls = cls.ncls, .seen = seen };
    defer p.deinit();

    // The frontier is keyed on "has an interior byte ever landed here", NOT on
    // "was freshly interned": a state first seen as a `trans_fin` target is
    // already interned when the interior later reaches it, and skipping it then
    // would ship a row of `unknown` the scan loop can index.
    var work = Frontier{ .gpa = gpa };
    defer work.deinit();

    const start_id = (try p.intern(.{ .node = dec.root, .pat = aut.start })).id;
    try work.push(&p, start_id);

    // The resync rows, interned before the walk so the walk can copy them. Two
    // of them: a non-root node re-reads the byte from the root, the root consumes
    // it in place — and neither reads the pattern state it came from.
    //
    // An unsatisfiable anchored program is the one shape where a node can go
    // unreached (`canonNode` folds every landing onto the root), so it keeps the
    // column-at-a-time path; there is nothing to save on a one-state product.
    const reachable = aut.start != aut.dead;
    var resync_in: []u32 = &.{};
    var resync_fin: []u32 = &.{};
    var root_in: u32 = unknown;
    var root_fin: u32 = unknown;
    var span: ?Edges = if (reachable) try scanEdges(gpa, &dec, &cls) else null;
    defer if (span) |*e| e.deinit();
    if (span) |e| {
        resync_in = try gpa.alloc(u32, cls.ncls);
        resync_fin = try gpa.alloc(u32, cls.ncls);
        @memset(resync_in, unknown);
        @memset(resync_fin, unknown);
        for (e.read, 0..) |wanted, k| {
            if (!wanted) continue;
            const b = cls.rep[k];
            const in = try p.intern(p.resyncByte(b, false));
            resync_in[k] = in.id;
            try work.push(&p, in.id);
            resync_fin[k] = (try p.intern(p.resyncByte(b, true))).id;
        }
        if (e.root_reads) {
            const in = try p.intern(.{ .node = dec.root, .pat = aut.reseed });
            root_in = in.id;
            try work.push(&p, in.id);
            root_fin = (try p.intern(.{ .node = dec.root, .pat = aut.fin_reseed })).id;
        }
    }
    defer gpa.free(resync_in);
    defer gpa.free(resync_fin);

    var cur: usize = 0;
    while (cur < work.items.items.len) : (cur += 1) {
        const id = work.items.items[cur];
        const from = Landing{ .node = @intCast(p.keys.items[id] >> 32), .pat = @truncate(p.keys.items[id]) };
        const row = @as(usize, id) * cls.ncls;
        if (span) |e| {
            // Lay the resync row down first, then overwrite the live columns.
            // A column left `unknown` here is one no node resyncs on, so the
            // loop below is about to write it.
            if (from.node == dec.root) {
                @memset(p.trans_in.items[row..][0..cls.ncls], root_in);
                @memset(p.trans_fin.items[row..][0..cls.ncls], root_fin);
            } else {
                @memcpy(p.trans_in.items[row..][0..cls.ncls], resync_in);
                @memcpy(p.trans_fin.items[row..][0..cls.ncls], resync_fin);
            }
            for (e.live[e.at[from.node]..e.at[from.node + 1]]) |k| {
                const rep = cls.rep[k];
                const in = try p.intern(p.stepByte(from, rep, false));
                p.trans_in.items[row + k] = in.id;
                try work.push(&p, in.id);
                // The final table's targets are terminal — the line ends right
                // after — so they are interned for `is_match` but never expanded.
                const fin = try p.intern(p.stepByte(from, rep, true));
                p.trans_fin.items[row + k] = fin.id;
            }
            continue;
        }
        var k: u16 = 0;
        while (k < cls.ncls) : (k += 1) {
            const rep = cls.rep[k];
            const in = try p.intern(p.stepByte(from, rep, false));
            p.trans_in.items[row + k] = in.id;
            try work.push(&p, in.id);
            const fin = try p.intern(p.stepByte(from, rep, true));
            p.trans_fin.items[row + k] = fin.id;
        }
    }

    // An anchored program's absorbing sink, if the walk ever reached it: the one
    // state whose pattern half is dead (all decoder phases collapsed into it).
    var dead: u32 = unknown;
    if (aut.reseed == aut.dead and aut.dead != std.math.maxInt(u32)) {
        // The root's quotient is the identity, so this reaches the same slot
        // `canonNode` sent every `(node, dead)` pair to.
        const slot = hor.slot(dec.root, aut.dead);
        if (p.seen[slot] != none) dead = p.seen[slot];
    }

    // Quotient out the decoder phase the pattern can't observe, in both
    // dimensions — `reduce` owns the rows-then-columns order this needs, and
    // owns it for the byte road too.
    const raw: u32 = @intCast(p.keys.items.len);
    stats.product_states = raw;
    const map = try gpa.alloc(u32, raw);
    defer gpa.free(map);
    const ext = try reduce.run(gpa, &cls, .{
        .interior = &p.trans_in,
        .final = &p.trans_fin,
        .is_match = p.is_match.items,
    }, raw, map, .both);
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

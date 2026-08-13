//! irregex — the trawl: one automaton for a slate too wide to net.
//!
//! The dragnet (`muster.zig`) is a bucketed SIMD sieve, and it wins decisively
//! while the buckets stay sparse. Past ~32 literals it cannot: the group count
//! is capped at four (32 buckets) precisely because per-block vector cost
//! otherwise grows with the size of the question, so a wider slate can only
//! share buckets harder. A bucket holding `k` literals sets `k` bits in each of
//! its nibble tables, and at `k = 32` the tables approach all-ones — nearly
//! every position becomes a candidate, and the verify list behind it is 32
//! literals long. The sieve degrades into a memcmp storm. Measured: the dragnet
//! peaks near N=8 and falls off a cliff past N=64, which is the regime
//! Vectorscan was still winning by 3–4×.
//!
//! Aho–Corasick removes that growth by construction (Aho & Corasick, *Efficient
//! String Matching: An Aid to Bibliographic Search*, CACM 1975): one automaton
//! holds every needle, one table lookup advances one byte, and the per-byte cost
//! is independent of how many needles there are. It gives up SIMD — no eight
//! lanes at a time — so it can never beat a sparse dragnet on a narrow slate.
//! That is exactly why this is a TIER and not a replacement: the two mechanisms
//! own opposite ends of N, and `muster.build` dispatches on the pool size it can
//! see at compile time.
//!
//! Two things make this fast enough to be worth the tier, and both are about
//! memory rather than arithmetic — an automaton this size lives or dies on the
//! cache:
//!
//!   • **A compacted alphabet.** A dense 256-way row costs 1 KiB per state, so a
//!     1024-literal slate would want ~8 MiB of transition table and miss cache
//!     on nearly every byte. But a slate of identifiers touches only ~40
//!     distinct bytes. Every byte no literal contains is behaviorally
//!     identical — it can only ever return the automaton toward the root — so
//!     they all fold into ONE column. The row shrinks ~6×, which is the
//!     difference between a table that fits in L2 and one that does not.
//!   • **No verify step.** The dragnet's candidate must be confirmed with a
//!     `memcmp`, because a nibble table admits byte combinations no literal
//!     spells. An Aho–Corasick output is exact: reaching an output state means
//!     the full needle just ended there. The false-positive tax is zero.
//!
//! Soundness runs the same single direction the muster's does: the trawl may
//! only ever ADD a pattern to the play set (it reports occurrences, never
//! absences), a slate it declines to build leaves those patterns on the
//! dragnet/`stubs` path, and every non-settled survivor is still confirmed by
//! the engine a single-pattern search runs. `patterns_test.zig` proves the
//! set's answer stays bit-identical to N independent searches with the
//! accelerator armed and stripped, and the sweep in the kinship package's
//! `bench/rungs/multipattern/` re-proves it at corpus scale at every N.
//!
//! Kernel profile: immutable after `build`, no I/O, no per-scan allocation.

const std = @import("std");
const bits = @import("../math/bits.zig");

const B64 = bits.Field(u64);

/// No such state / no such literal. `0` is the root, so it cannot be a sentinel.
///
/// Published because it TERMINATES two chains a caller may legitimately walk —
/// `out_next` (the literals ending at a state) and `link` (the dictionary-suffix
/// chain) — so anyone reporting every occurrence rather than the first has to
/// know where those chains stop. The `needles` FFI plane respelled it locally
/// before this was `pub`, which is a duplicated constant that no test can catch
/// until the day the two disagree.
pub const none = std.math.maxInt(u32);

/// Transition rows are the whole memory cost, so the tier declines rather than
/// build a table that would evict everything else from cache. 1<<15 states over
/// a ~48-column alphabet is ~6 MiB — past that the automaton is losing to the
/// thing it was meant to beat, and the dragnet's degraded curve is still an
/// answer where an OOM is not.
pub const max_states = 1 << 15;

/// Interleaved scan streams — the single largest constant in this file, and the
/// reason the trawl is throughput-bound instead of latency-bound.
///
/// Measured on the 67 MB packed corpus (GB/s at 64 / 512 literals):
///   2 streams → 0.87 / 0.82    4 → 1.64 / 1.47
///   6 streams → 2.13 / 1.88    8 → 1.95 / 1.79
/// Six is the peak. Below it the transition chain's load latency is exposed —
/// each next state is a load whose ADDRESS is the previous load's result, so one
/// stream stalls at cache latency per byte no matter how idle the core is. Above
/// it the six live state registers plus six cursors exceed what the allocator
/// keeps in registers, and the spills cost more than the extra stream buys.
pub const stripes = 6;

/// The Aho–Corasick trawl over a pooled literal set. `next` is a dense
/// `nstates × ncols` transition table in DFA form (every cell resolved through
/// failure links at build time, so the sweep never follows one).
pub const Trawl = struct {
    next: []u32,
    /// Head of the list of literals ending at this state (`none` if it is not an
    /// output state). Distinct patterns can own byte-identical literals, so an
    /// output state carries a LIST, not one index.
    out_head: []u32,
    /// Next literal ending at the same state.
    out_next: []u32,
    /// Nearest proper suffix of this state that is an output state — the
    /// dictionary-suffix link, so `she` also reports `he`.
    link: []u32,
    /// Does this state report anything at all (itself or via `link`)? One byte
    /// per state keeps the hot check a single load off a small array instead of
    /// two loads into the big ones.
    reports: []bool,
    xlat: [256]u8,
    ncols: u32,
    nstates: u32,
    /// Longest pooled literal — the stripe overlap that makes the split exact.
    longest: usize,

    pub fn deinit(self: *Trawl, gpa: std.mem.Allocator) void {
        gpa.free(self.next);
        gpa.free(self.out_head);
        gpa.free(self.out_next);
        gpa.free(self.link);
        gpa.free(self.reports);
    }

    /// One pass over `hay`, setting `play` for every pattern one of whose
    /// literals occurs. Returns the number of patterns still unaccounted for, so
    /// a caller can stop the moment the whole slate is in play.
    ///
    /// Swept as `stripes` INTERLEAVED streams, which is the difference between a
    /// latency-bound automaton and a throughput-bound one. A single stream's next
    /// state is a load whose ADDRESS depends on the previous load's result, so
    /// the chain is serialized at cache-latency per byte no matter how idle the
    /// rest of the core is — the classic pointer-chase, and the reason a textbook
    /// Aho–Corasick lands near 0.5 GB/s. Independent streams over disjoint
    /// regions have no such dependency between them, so `stripes` of them issue
    /// concurrently and the loop becomes bound by load THROUGHPUT instead.
    ///
    /// Correctness of the split is the overlap: each stripe restarts at the root
    /// rather than inheriting the true state from the bytes before it, which can
    /// only ever LOSE a match that began earlier — never invent one. Extending
    /// every stripe by `longest - 1` bytes past its end guarantees any needle
    /// wholly inside `hay` lies wholly inside some stripe, so no occurrence can
    /// fall between two of them. Reporting the same occurrence from two
    /// overlapping stripes is harmless: setting a play bit is idempotent.
    pub fn sweep(
        self: *const Trawl,
        hay: []const u8,
        owner: []const u32,
        play: []u64,
        left_in: usize,
    ) usize {
        var left = left_in;
        const cols = self.ncols;
        const overlap = self.longest - 1;
        // Below this a stripe is mostly overlap and the split is pure loss.
        const span = (hay.len + stripes - 1) / stripes;
        if (hay.len < stripes * (overlap + 64)) return self.crawl(hay, owner, play, left);

        var s = [_]u32{0} ** stripes;
        var at = [_]usize{0} ** stripes;
        var end = [_]usize{0} ** stripes;
        inline for (0..stripes) |w| {
            at[w] = w * span;
            end[w] = @min(w * span + span + overlap, hay.len);
        }
        // Every stripe runs the same number of steps; the shortest one bounds the
        // fused loop and the remainder of the others is finished serially below.
        var steps = end[0] - at[0];
        inline for (1..stripes) |w| steps = @min(steps, end[w] - at[w]);

        for (0..steps) |_| {
            inline for (0..stripes) |w| {
                s[w] = self.next[s[w] * cols + self.xlat[hay[at[w]]]];
                at[w] += 1;
            }
            // Hoisted out of the transition group so the loads above stay
            // back-to-back; on real code this is false for almost every byte.
            inline for (0..stripes) |w| {
                if (self.reports[s[w]]) {
                    left = self.report(s[w], owner, play, left);
                    if (left == 0) return 0;
                }
            }
        }
        inline for (0..stripes) |w| {
            left = self.crawlFrom(hay[at[w]..end[w]], s[w], owner, play, left);
            if (left == 0) return 0;
        }
        return left;
    }

    /// The single-stream sweep — used for a haystack too short to stripe, and for
    /// each stripe's ragged tail. Public because it is also the REFERENCE the
    /// striped path is held to: `trawl_test.zig` runs both over one document and
    /// demands identical play sets, which is the only thing that makes the split
    /// a performance change rather than a semantic one.
    pub fn crawl(self: *const Trawl, hay: []const u8, owner: []const u32, play: []u64, left_in: usize) usize {
        return self.crawlFrom(hay, 0, owner, play, left_in);
    }

    fn crawlFrom(self: *const Trawl, hay: []const u8, from: u32, owner: []const u32, play: []u64, left_in: usize) usize {
        var left = left_in;
        const cols = self.ncols;
        var s = from;
        for (hay) |c| {
            s = self.next[s * cols + self.xlat[c]];
            if (!self.reports[s]) continue;
            left = self.report(s, owner, play, left);
            if (left == 0) return 0;
        }
        return left;
    }

    /// Mark every pattern owning a literal that ends at `s` (or at any proper
    /// suffix of `s`, via the dictionary link).
    fn report(self: *const Trawl, s: u32, owner: []const u32, play: []u64, left_in: usize) usize {
        var left = left_in;
        var at = s;
        while (at != none) : (at = self.link[at]) {
            var k = self.out_head[at];
            while (k != none) : (k = self.out_next[k]) {
                const p = owner[k];
                if (B64.get(play, p)) continue;
                B64.set(play, p);
                left -= 1;
                if (left == 0) return 0;
            }
        }
        return left;
    }
};

/// Build the trawl over `pool` (indices into `lits`), or `null` when it would
/// not pay for itself or would not fit `max_states`. A `null` return is always a
/// performance decision — the caller keeps the mechanism it already had.
pub fn build(
    gpa: std.mem.Allocator,
    lits: []const []const u8,
    pool: []const u32,
) error{OutOfMemory}!?Trawl {
    if (pool.len == 0) return null;

    // The alphabet every literal actually spells. Column 0 is "some byte no
    // literal contains", which every state answers identically, so folding all
    // of them into one column is exact and shrinks the row ~6× on real slates.
    var xlat = [_]u8{0} ** 256;
    var ncols: u32 = 1;
    for (pool) |k| for (lits[k]) |c| {
        if (xlat[c] == 0) {
            xlat[c] = @intCast(ncols);
            ncols += 1;
        }
    };

    // Upper bound on states: the root plus one per literal byte. Sharing makes
    // the real count smaller; allocating the bound once avoids a growable
    // transition table (whose reallocs would dominate build time).
    var cap: usize = 1;
    var longest: usize = 0;
    for (pool) |k| {
        cap += lits[k].len;
        longest = @max(longest, lits[k].len);
    }
    if (cap > max_states) return null;

    const next = try gpa.alloc(u32, cap * ncols);
    errdefer gpa.free(next);
    @memset(next, none);
    const out_head = try gpa.alloc(u32, cap);
    errdefer gpa.free(out_head);
    @memset(out_head, none);
    const out_next = try gpa.alloc(u32, lits.len);
    errdefer gpa.free(out_next);
    @memset(out_next, none);
    const link = try gpa.alloc(u32, cap);
    errdefer gpa.free(link);
    @memset(link, none);
    const reports = try gpa.alloc(bool, cap);
    errdefer gpa.free(reports);
    @memset(reports, false);

    // ── Trie. `next` holds raw child edges for now; the BFS below resolves the
    // missing ones into failure transitions, turning it into a DFA in place.
    var nstates: u32 = 1;
    for (pool) |k| {
        var s: u32 = 0;
        for (lits[k]) |c| {
            const col = xlat[c];
            const cell = &next[s * ncols + col];
            if (cell.* == none) {
                cell.* = nstates;
                nstates += 1;
            }
            s = cell.*;
        }
        // Prepend: order within one state's output list never reaches the
        // caller, which only asks whether a pattern is in play.
        out_next[k] = out_head[s];
        out_head[s] = k;
        reports[s] = true;
    }

    // ── Failure links, breadth-first, resolving `next` to full DFA form.
    // `fail` is scratch: the sweep follows `link` (outputs only), never this.
    const fail = try gpa.alloc(u32, nstates);
    defer gpa.free(fail);
    @memset(fail, 0);
    var queue = try gpa.alloc(u32, nstates);
    defer gpa.free(queue);
    var head: usize = 0;
    var tail: usize = 0;

    for (0..ncols) |col| {
        const cell = &next[col]; // root row
        if (cell.* == none) {
            cell.* = 0; // an unspelled byte keeps the root at the root
        } else {
            fail[cell.*] = 0;
            queue[tail] = cell.*;
            tail += 1;
        }
    }
    while (head < tail) : (head += 1) {
        const s = queue[head];
        // A state reports if it is an output state, or if any proper suffix of
        // it is. Both facts are known by the time `s` is dequeued, because
        // `fail[s]` is strictly shallower and was processed earlier.
        link[s] = if (reports[fail[s]]) fail[s] else link[fail[s]];
        if (link[s] != none) reports[s] = true;
        for (0..ncols) |col| {
            const cell = &next[s * ncols + col];
            const via_fail = next[fail[s] * ncols + col];
            if (cell.* == none) {
                cell.* = via_fail;
            } else {
                fail[cell.*] = via_fail;
                queue[tail] = cell.*;
                tail += 1;
            }
        }
    }

    return .{
        .next = next,
        .out_head = out_head,
        .out_next = out_next,
        .link = link,
        .reports = reports,
        .xlat = xlat,
        .ncols = ncols,
        .nstates = nstates,
        .longest = longest,
    };
}

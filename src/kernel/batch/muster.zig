//! irregex — the muster: one SIMD pass that calls the roll on N patterns.
//!
//! A `PatternSet` answers "which of these N patterns match this document?".
//! Answered naively that is N whole-document scans, and the cost of the answer
//! grows with the size of the question — which is precisely the growth
//! Hyperscan was built to remove (Wang et al., *Hyperscan: A Fast Multi-pattern
//! Regex Matcher for Modern CPUs*, NSDI 2019). Hyperscan's move is to split the
//! problem: a SIMD **string matcher** over the literals every expression is
//! forced to contain (FDR / Teddy) decides which expressions are even in play,
//! and only those reach a finite automaton.
//!
//! This is that split, with gist's own parts. Every compiled query already
//! publishes a SOUND necessary condition — the literals `kernel/match/query`
//! derives for the trigram index, which the index is already trusted to elide
//! whole file reads with (`prefilter.zig`: a required literal present in EVERY
//! match, else a per-branch alternation cover). The muster pools those literals
//! across the whole set, scans the bytes ONCE through the shipped Teddy kernel
//! (`kernel/match/scan/teddy.zig`), and reports which patterns survived. Two
//! consequences follow, and they are the whole point:
//!
//!   • A pattern whose every literal is absent CANNOT match. It is excluded
//!     without the engine ever running — the confirm count drops from N to the
//!     number of patterns actually in play, which on real code is nearly always
//!     zero or one.
//!   • A pattern that IS a plain literal (`-F`, no fold, no `-w`) is *decided*
//!     by the roll: presence of the needle is match. Those patterns are marked
//!     `settled` and never reach a confirm at all.
//!
//! Soundness is the only thing that matters here, and it runs one way: the
//! muster may only ever say "this pattern cannot match". A pattern with no
//! derivable literal is permanently in play (`unbounded`), a chunk that fails
//! to build is dropped by making its patterns unbounded, and every non-settled
//! survivor is still confirmed by the same engine a single-pattern search runs.
//! So the set's answer stays bit-identical to N independent searches, which is
//! the invariant `patterns_test.zig` proves against a live oracle with the
//! muster both ON and OFF.
//!
//! Kernel profile: immutable after `build`, no I/O, no per-scan allocation —
//! `roll` writes into a caller-owned word array, so a walk worker's scan is
//! allocation-free.

const std = @import("std");
const assay = @import("../../assay/assay.zig");
const bits = @import("../primitives/bits.zig");
const simd = @import("../match/scan/simd.zig");
const lanes = @import("../match/regex/regex.zig").compose.lanes;
const query = @import("../match/query/query.zig");
const trawl_mod = @import("trawl.zig");

const B64 = bits.Field(u64);
const V16 = lanes.Vec;
const Lane = u16; // one bit per 16-byte-block lane
const per_group = 8; // bucket bits in one nibble table — a byte's width
const max_groups = 4; // ⇒ 32 buckets; past this the shuffles stop paying
const stem = 3; // leading bytes each bucket bit is keyed on
const floor = 2; // shortest literal the sieve will carry (shorter ⇒ `stubs`)
/// Pooled-literal count at which the dragnet hands over to the Aho–Corasick
/// trawl (`trawl.zig`). Measured crossover, not a guess: below it the sieve's
/// SIMD lanes win; above it its buckets are saturated and shared-bucket
/// verification grows, while the trawl's per-byte cost is flat in the slate's
/// width. The two curves cross tightly — best-of-3 over the 67 MB packed corpus,
/// each column a real slate mined by `bench/multipattern/slate.py` (GB/s):
///
///   literals   14     16     18     20     24     28     32
///   dragnet    2.87   2.55   2.14   2.03   1.84   1.53   1.45
///   trawl      2.23   2.24   2.17   2.21   2.20   2.20   2.19
///
/// The trawl is flat to within 3% across the whole band — that is the O(1)-in-N
/// property, visible. The dragnet falls ~10% per two literals as its four bucket
/// groups saturate. They cross at 18: at 16 the sieve is still 14% ahead, at 18
/// the trawl takes it by 2%. So the handover sits at 18 — the last width where
/// the sieve is genuinely the better mechanism, not a round number near it.
/// `bench/races/multipattern.sh` re-derives the crossing, and
/// `GIST_MUSTER_TIER` forces either side of it.
const trawl_from = 18;

/// Force a tier, ignoring `trawl_from`. This is the parity/measurement lever the
/// same way `GIST_NO_PARALLEL_LOAD` is one: the differential tests use it to
/// prove BOTH mechanisms answer identically at a given N (not merely that
/// whichever one the threshold picked does), and `bench/multipattern/sweep.py`
/// uses it to measure the crossover the threshold is set from. An unset or
/// unrecognized value means "decide by size" — it can never select a third
/// behavior, so a typo degrades to the default rather than to something silent.
fn tierOverride() ?enum { dragnet, trawl } {
    const v = assay.envSpan("GIST_MUSTER_TIER") orelse return null;
    if (std.mem.eql(u8, v, "dragnet")) return .dragnet;
    if (std.mem.eql(u8, v, "trawl")) return .trawl;
    return null;
}
const window = 16 + stem - 1; // bytes one vector iteration must be able to read

/// The dragnet: a bucketed nibble-table sieve over the leading THREE bytes of
/// every pooled literal, swept once. It is `scan/teddy.zig`'s idea with the two
/// parameters Hyperscan actually tunes, and both of them were measured here
/// rather than assumed.
///
/// **Bucket sharing, capped.** `Teddy` spends one bucket bit per needle, so a
/// 64-literal set needs eight table groups and pays eight shuffle quartets per
/// block — per-block cost linear in set size, which is the exact growth a
/// multi-pattern matcher exists to remove (measured through `Teddy`: 4.1 GB/s at
/// N=8 decaying to 0.46 GB/s at N=62, in step with `ceil(N/8)`). Hyperscan packs
/// several literals into one bucket and lets the confirm separate them. But
/// sharing is not free either: a bucket holding `k` literals admits `k²` byte
/// combinations its members never spell, and an 8-per-bucket 2-byte sieve
/// measured *worse* than `Teddy` at N=64 (0.15 GB/s) — the vector work went
/// constant and the false-positive verify ate the winnings. So the group count
/// is capped, not fixed: ≤32 buckets, which keeps sharing at ~2 literals per
/// bucket even on a 64-literal slate.
///
/// **Four bytes, not two.** That is what makes the sharing affordable, and the
/// depth was measured, not guessed. Each extra nibble pair costs one load and
/// two shuffles per block; what it buys is discrimination, and on real code it
/// buys much less than the uniform-random 16× per nibble. Identifiers are ASCII
/// letters, so a *high* nibble is 6 or 7 almost always and that half of every
/// lookup is nearly free to a false candidate — a 3-byte stem left ~2.4% of
/// positions candidate at N=64 (measured 0.86 GB/s, behind Vectorscan's 2.56),
/// where the fourth byte cuts it ~13× for +33% vector work. Two bytes is not on
/// the table at all: with 8 literals to a bucket a nibble table saturates at
/// ~½ of all positions, and that shape measured 0.15 GB/s — worse than `Teddy`.
///
/// A literal shorter than the stem does not lose the sieve, and does not force
/// everyone else shallow: the missing byte's tables get that ONE bucket's bit in
/// all 32 entries, so its bucket discriminates on the bytes it has while its
/// neighbors keep all four. Below `floor` bytes even that is too little signal
/// and the literal rides `stubs` instead.
///
/// At N ≤ 32 there is one literal per bucket and the sieve has *strictly fewer*
/// candidate lanes than `Teddy` at the same N; at N = 64 it pays 32 shuffles a
/// block, the same as `Teddy`, while keeping 32 buckets where `Teddy` has 8
/// groups of exclusive bits. Better or equal on both axes at both ends, which is
/// why it replaces `Teddy` here rather than fronting it.
///
/// It also asks a strictly cheaper question than `Teddy.find`. `find` returns
/// the LEFTMOST occurrence, so a caller collecting every needle must re-enter it
/// after each hit and rescan the block it just left. The muster only needs
/// *presence*, which is order-free — so this sweeps once, accumulating into the
/// caller's `play` bitmask, and skips verifying any literal whose pattern is
/// already in play. A hot literal is confirmed once per document and free
/// thereafter, and the sweep abandons the document the moment every pattern is
/// accounted for.
const Dragnet = struct {
    /// Per group, the `stem` nibble-table pairs: `tab[g][2*s]` keyed on byte
    /// `s`'s low nibble, `tab[g][2*s+1]` on its high nibble.
    tab: [max_groups][2 * stem]V16,
    groups: usize,
    /// Literal indices grouped by bucket: bucket `b` owns `slots[at[b]..at[b+1]]`.
    slots: []u32,
    at: [max_groups * per_group + 1]u32,

    /// Nibble tables over `pool` (indices into `lits`, every literal ≥ `floor`
    /// bytes). `pool` is consumed as `slots` — the caller hands over ownership.
    fn arm(pool: []u32, lits: []const []const u8) Dragnet {
        // Order by leading stem first: literals sharing a prefix then land in
        // ONE bucket, so the lane hit they cannot avoid sharing costs a single
        // bucket's verify list instead of several buckets'.
        std.mem.sort(u32, pool, lits, struct {
            fn lt(ls: []const []const u8, a: u32, b: u32) bool {
                const n = @min(ls[a].len, ls[b].len, stem);
                return std.mem.order(u8, ls[a][0..n], ls[b][0..n]) == .lt;
            }
        }.lt);

        // Annotated: `@min` against a comptime bound narrows its result type, and
        // a `u3` cannot hold the bucket count it is about to be multiplied into.
        const groups: usize = @min(max_groups, (pool.len - 1) / per_group + 1);
        const n_buckets = groups * per_group;
        // Buckets are CONTIGUOUS RANGES of the sorted pool, not a round-robin
        // stride: a bucket's verify list is then a plain slice, and prefix
        // neighbors stay together.
        var at: [max_groups * per_group + 1]u32 = undefined;
        for (at[0 .. n_buckets + 1], 0..) |*a, b| a.* = @intCast(b * pool.len / n_buckets);
        at[n_buckets] = @intCast(pool.len);

        // Build as byte arrays — a `V16` element index must be comptime, so the
        // runtime nibble keys land in `[16]u8` and only then promote to vectors
        // for the shuffle path (same posture as `scan/teddy.zig`).
        var raw = [_][2 * stem][16]u8{[_][16]u8{[_]u8{0} ** 16} ** (2 * stem)} ** max_groups;
        for (0..n_buckets) |b| {
            const bit = @as(u8, 1) << @intCast(b % per_group);
            for (pool[at[b]..at[b + 1]]) |k| {
                const n = lits[k];
                inline for (0..stem) |s| {
                    if (s < n.len) {
                        raw[b / per_group][2 * s][n[s] & 0x0F] |= bit;
                        raw[b / per_group][2 * s + 1][n[s] >> 4] |= bit;
                    } else {
                        // Past this needle's end: wildcard byte `s` for THIS
                        // bucket only, so a short literal spends its own
                        // discrimination and none of its neighbors'.
                        for (&raw[b / per_group][2 * s]) |*e| e.* |= bit;
                        for (&raw[b / per_group][2 * s + 1]) |*e| e.* |= bit;
                    }
                }
            }
        }
        var tab: [max_groups][2 * stem]V16 = undefined;
        for (0..groups) |g| {
            inline for (0..2 * stem) |i| tab[g][i] = raw[g][i];
        }
        return .{ .tab = tab, .groups = groups, .slots = pool, .at = at };
    }

    /// One pass over `hay`, setting `play` for every pattern whose literal
    /// occurs. Returns the number of patterns still unaccounted for.
    fn sweep(
        self: *const Dragnet,
        hay: []const u8,
        lits: []const []const u8,
        owner: []const u32,
        play: []u64,
        left_in: usize,
    ) usize {
        var left = left_in;
        const zero: V16 = @splat(0);
        const low: V16 = @splat(0x0F);
        const four: V16 = @splat(4);
        // Copy the tables into a LOCAL, and index it only at comptime below. A
        // runtime `g` made every one of the `2 * stem * groups` tables a fresh
        // load through `self` on every 16-byte block — 24 loads a block at four
        // groups, which measured as the wall the sieve was actually hitting.
        // Local + comptime index is promotable to vector registers, so the
        // tables are loaded once per document instead of once per block.
        const tab = self.tab;
        var i: usize = 0;
        while (i + window <= hay.len) : (i += 16) {
            var b: [stem]V16 = undefined;
            inline for (&b, 0..) |*v, s| v.* = hay[i + s ..][0..16].*;
            // Groups are swept INSIDE the block loop, on one pass over the
            // bytes. Hoisting them out — a separate pass per group, six tables
            // live instead of twenty-four — reads like the fix for register
            // pressure and measured 2.4× WORSE at every N (2.9 GB/s where
            // nested gets 7.1 at N=4): four unrolled copies of the byte loop
            // cost more in code footprint than the spills they avoid.
            inline for (0..max_groups) |g| {
                if (g < self.groups) {
                    // The shift-or/`pshufb` step: AND of all `2 * stem` nibble
                    // lookups is the bucket bits any literal in this group
                    // could start on, for each of the block's 16 lanes.
                    var cand: V16 = @splat(0xFF);
                    inline for (0..stem) |s| {
                        cand &= lanes.shuffle(tab[g][2 * s], b[s] & low) &
                            lanes.shuffle(tab[g][2 * s + 1], b[s] >> four);
                    }
                    const occupied: @Vector(16, bool) = cand != zero;
                    var hits = bits.ones(@as(Lane, @bitCast(occupied)));
                    if (hits.rest != 0) {
                        const cells: [16]u8 = cand;
                        while (hits.next()) |j| {
                            const pos = i + j;
                            var bucket = bits.ones(cells[j]);
                            while (bucket.next()) |narrow| {
                                // Widen before the `+ 1`: `ones` yields a `u3`,
                                // in which the range end overflows on the
                                // eighth bucket.
                                const bk: usize = g * per_group + @as(usize, narrow);
                                // Retiring a bucket here — clearing its bit from
                                // the tables once all its literals are in play,
                                // so a common needle costs nothing for the rest
                                // of the document — is sound and measured 2.9×
                                // WORSE (2.4 GB/s where const gets 6.8 at N=4).
                                // A mutable table cannot live in registers, and
                                // that promotion is worth more than every
                                // candidate the retire would have removed.
                                for (self.slots[self.at[bk]..self.at[bk + 1]]) |k| {
                                    const p = owner[k];
                                    if (B64.get(play, p)) continue; // already accounted for
                                    const lit = lits[k];
                                    if (pos + lit.len > hay.len or !std.mem.eql(u8, hay[pos..][0..lit.len], lit)) continue;
                                    B64.set(play, p);
                                    left -= 1;
                                    if (left == 0) return 0;
                                }
                            }
                        }
                    }
                }
            }
        }
        // Tail: the < `window` positions no full vector iteration covered.
        for (self.slots) |k| {
            const p = owner[k];
            if (B64.get(play, p)) continue;
            if (std.mem.indexOfPos(u8, hay, i, lits[k]) == null) continue;
            B64.set(play, p);
            left -= 1;
            if (left == 0) return 0;
        }
        return left;
    }
};

/// The compiled roll call. `lits[k]` belongs to pattern `owner[k]`; a pattern is
/// in play when any of its literals is present, always in play when it has none
/// (`unbounded`), and DECIDED by presence when it is a bare literal (`settled`).
pub const Muster = struct {
    lits: [][]const u8,
    owner: []u32,
    /// The SIMD sieve — armed for a narrow slate, where its lanes win.
    net: ?Dragnet,
    /// The Aho–Corasick tier — armed instead for a wide slate, where the sieve's
    /// capped buckets saturate. Exactly one of these two is ever non-null.
    trawl: ?trawl_mod.Trawl,
    /// Literals under the dragnet's `floor`, which ride a plain SIMD substring
    /// scan instead. Indices into `lits`. Nearly always empty: a derived
    /// prefilter literal is trigram-sized or longer by construction, so only a
    /// bare one- or two-byte `-F` pattern lands here.
    stubs: []u32,
    /// Patterns with no derivable literal — permanently in play.
    unbounded: []u64,
    /// Patterns whose literal presence IS their match decision.
    settled: []u64,
    npatterns: usize,
    /// Patterns the roll can actually rule out — `npatterns` minus the
    /// unbounded ones. The sweep's early-exit budget.
    boundable: usize,

    pub fn deinit(self: *Muster, gpa: std.mem.Allocator) void {
        gpa.free(self.lits);
        gpa.free(self.owner);
        if (self.net) |n| gpa.free(n.slots);
        if (self.trawl) |*tr| tr.deinit(gpa);
        gpa.free(self.stubs);
        gpa.free(self.unbounded);
        gpa.free(self.settled);
    }

    /// Is pattern `i` decided by the roll alone (no engine confirm needed)?
    pub fn isSettled(self: *const Muster, i: usize) bool {
        return B64.get(self.settled, i);
    }

    /// Which mechanism the roll is actually carrying. Reportable because the tier
    /// choice is a measured claim (`trawl_from`), and a benchmark row that does not
    /// say which side of the crossing produced it cannot support that claim —
    /// `bench/races/multipattern.sh` records this per row.
    pub fn tier(self: *const Muster) []const u8 {
        if (self.trawl != null) return "trawl";
        if (self.net != null) return "dragnet";
        return "none"; // every pattern unbounded or stub-only: no sieve armed
    }

    /// Call the roll over `hay`: clear `play` and set bit `i` for every pattern
    /// that could match. `play` is caller-owned and `words(npatterns)` long.
    /// Returns whether any bit is set — so an all-miss document is answered by
    /// this one pass, with no engine run at all.
    pub fn roll(self: *const Muster, hay: []const u8, play: []u64) bool {
        @memcpy(play, self.unbounded);
        var left = self.boundable;
        if (self.net) |*net| left = net.sweep(hay, self.lits, self.owner, play, left);
        if (self.trawl) |*tr| if (left != 0) {
            left = tr.sweep(hay, self.owner, play, left);
        };
        if (left != 0) for (self.stubs) |k| {
            const p = self.owner[k];
            if (B64.get(play, p)) continue;
            if (!simd.contains(hay, self.lits[k])) continue;
            B64.set(play, p);
            left -= 1;
            if (left == 0) break;
        };
        return !B64.none(play);
    }
};

/// Compile the roll call for `queries`/`specs` (index-aligned), or `null` when
/// it could not pay for itself: fewer than two patterns, or every pattern
/// unbounded (nothing to exclude). A `null` muster leaves the set on its
/// pre-existing gate-then-confirm-all path, which is why every decline here is
/// a performance choice and never a correctness one.
pub fn build(
    gpa: std.mem.Allocator,
    queries: []const query.CompiledQuery,
    specs: []const query.Spec,
) error{OutOfMemory}!?Muster {
    if (queries.len < 2) return null;

    var lits: std.ArrayList([]const u8) = .empty;
    errdefer lits.deinit(gpa);
    var owner: std.ArrayList(u32) = .empty;
    errdefer owner.deinit(gpa);
    var stubs: std.ArrayList(u32) = .empty;
    errdefer stubs.deinit(gpa);
    var pooled: std.ArrayList(u32) = .empty;
    errdefer pooled.deinit(gpa);

    const words = B64.words(queries.len);
    const unbounded = try gpa.alloc(u64, words);
    errdefer gpa.free(unbounded);
    @memset(unbounded, 0);
    const settled = try gpa.alloc(u64, words);
    errdefer gpa.free(settled);
    @memset(settled, 0);

    var covered: usize = 0;
    for (queries, specs, 0..) |*q, spec, i| {
        var one: [1][]const u8 = undefined;
        const cover = coverOf(q, &one);
        if (cover.len == 0) {
            B64.set(unbounded, i);
            continue;
        }
        covered += 1;
        if (decides(q, spec)) B64.set(settled, i);
        for (cover) |lit| {
            try lits.append(gpa, lit);
            try owner.append(gpa, @intCast(i));
            const k: u32 = @intCast(owner.items.len - 1);
            try (if (lit.len < floor) stubs.append(gpa, k) else pooled.append(gpa, k));
        }
    }
    if (covered == 0) {
        gpa.free(unbounded);
        gpa.free(settled);
        lits.deinit(gpa);
        owner.deinit(gpa);
        stubs.deinit(gpa);
        pooled.deinit(gpa);
        return null;
    }

    const lit_slice = try lits.toOwnedSlice(gpa);
    errdefer gpa.free(lit_slice);
    const owner_slice = try owner.toOwnedSlice(gpa);
    errdefer gpa.free(owner_slice);
    const stub_slice = try stubs.toOwnedSlice(gpa);
    errdefer gpa.free(stub_slice);
    const pool = try pooled.toOwnedSlice(gpa);
    errdefer gpa.free(pool);

    // Tier choice. The dragnet's SIMD lanes win decisively while its buckets stay
    // sparse; past `trawl_from` literals they cannot (32 buckets is a hard cap,
    // so a wider slate only shares harder until the nibble tables saturate and
    // every position is a candidate). There the trawl's per-byte cost, constant
    // in N and free of any verify, takes over. The crossover is measured — see
    // `bench/multipattern/` — not assumed, and a trawl that declines to build
    // (too large for its table) falls back to the dragnet rather than to nothing.
    var net: ?Dragnet = null;
    var trawl: ?trawl_mod.Trawl = null;
    if (pool.len == 0) {
        gpa.free(pool);
    } else {
        const want_trawl = if (tierOverride()) |forced| forced == .trawl else pool.len >= trawl_from;
        if (want_trawl) trawl = try trawl_mod.build(gpa, lit_slice, pool);
        // A declined trawl (slate too wide for its table) falls back to the
        // sieve's degraded curve, which is still an answer.
        if (trawl == null) net = Dragnet.arm(pool, lit_slice) else gpa.free(pool);
    }

    return .{
        .lits = lit_slice,
        .owner = owner_slice,
        .net = net,
        .trawl = trawl,
        .stubs = stub_slice,
        .unbounded = unbounded,
        .settled = settled,
        .npatterns = queries.len,
        .boundable = queries.len - B64.count(unbounded),
    };
}

/// The literals a match of `q` is FORCED to contain at least one of. This is
/// `CompiledQuery.prefilter` — the index's own soundness derivation — widened
/// by one case it declines for a reason that does not apply here: a bare
/// literal body under three bytes is useless to a TRIGRAM index but is a
/// perfectly sound needle for a byte scanner.
fn coverOf(q: *const query.CompiledQuery, one: *[1][]const u8) []const []const u8 {
    if (!q.caseless and q.body == .literal) {
        const needle = q.body.literal;
        if (needle.len == 0) return &.{};
        one[0] = needle;
        return one[0..1];
    }
    return q.prefilter(one);
}

/// Does literal presence DECIDE `q`? Only for the bare-literal body: the whole
/// pattern is the needle, so `contains ⇔ docMatches`. `-w` narrows the match
/// set after the fact, so a word query is nominated, never decided.
fn decides(q: *const query.CompiledQuery, spec: query.Spec) bool {
    return !q.caseless and !q.word and !spec.pcre and q.body == .literal;
}

// ── tests ──────────────────────────────────────────────────────────────────
//
// The muster's contract is negative — "these patterns CANNOT match" — so every
// test here checks the same thing from a different angle: a pattern the roll
// excludes must be one the real engine also rejects. The set-level equality
// proof (roll on vs off, against N independent searches) lives in
// `patterns_test.zig`, where the oracle is the production single-pattern path.

const testing = std.testing;

const Built = struct {
    queries: []query.CompiledQuery,
    muster: ?Muster,

    fn deinit(self: *Built) void {
        if (self.muster) |*m| m.deinit(testing.allocator);
        for (self.queries) |*q| q.deinit(testing.allocator);
        testing.allocator.free(self.queries);
    }
};

fn compileAll(specs: []const query.Spec) !Built {
    const qs = try testing.allocator.alloc(query.CompiledQuery, specs.len);
    for (specs, qs) |s, *q| q.* = try query.CompiledQuery.compile(testing.allocator, s);
    return .{ .queries = qs, .muster = try build(testing.allocator, qs, specs) };
}

/// The load-bearing assertion: for every pattern the roll leaves OUT, the real
/// engine must agree there is no match.
fn expectSoundOver(specs: []const query.Spec, doc: []const u8) !void {
    var built = try compileAll(specs);
    defer built.deinit();
    const m = built.muster orelse return;
    const play = try testing.allocator.alloc(u64, B64.words(specs.len));
    defer testing.allocator.free(play);
    _ = m.roll(doc, play);
    for (built.queries, 0..) |*q, i| {
        var sc = try q.scratch(testing.allocator);
        defer sc.deinit();
        const truth = q.docMatches(doc, &sc);
        if (!B64.get(play, i)) try testing.expect(!truth); // excluded ⇒ really absent
        if (m.isSettled(i)) try testing.expectEqual(truth, B64.get(play, i)); // settled ⇒ decided
    }
}

test "roll excludes only patterns the engine also rejects" {
    const specs = [_]query.Spec{
        .{ .pattern = "WalletService", .fixed = true },
        .{ .pattern = "refund\\(", .fixed = false },
        .{ .pattern = "nonexistent_needle_zzz", .fixed = true },
        .{ .pattern = "handle[A-Z]\\w+", .fixed = false },
        .{ .pattern = "alpha|beta|gamma", .fixed = false },
    };
    try expectSoundOver(&specs, "pub fn handleRefund(w: *WalletService) !void { return w.refund(amount); }");
    try expectSoundOver(&specs, "nothing of interest lives in this line");
    try expectSoundOver(&specs, "gamma rays only");
}

test "a literal body is settled; a caseless or regex body never is" {
    const specs = [_]query.Spec{
        .{ .pattern = "settled_literal", .fixed = true },
        .{ .pattern = "CASELESS", .fixed = true, .ignore_case = true },
        .{ .pattern = "re[gG]ex", .fixed = false },
        .{ .pattern = "worded", .fixed = true, .word = true },
    };
    var built = try compileAll(&specs);
    defer built.deinit();
    const m = built.muster.?;
    try testing.expect(m.isSettled(0));
    try testing.expect(!m.isSettled(1));
    try testing.expect(!m.isSettled(2));
    try testing.expect(!m.isSettled(3));
}

test "a pattern with no derivable literal stays permanently in play" {
    // `.` forces nothing, so its bit must be set even on a document that
    // cannot possibly hold the other needle.
    const specs = [_]query.Spec{
        .{ .pattern = ".", .fixed = false },
        .{ .pattern = "concrete", .fixed = true },
    };
    var built = try compileAll(&specs);
    defer built.deinit();
    const m = built.muster.?;
    const play = try testing.allocator.alloc(u64, B64.words(specs.len));
    defer testing.allocator.free(play);
    try testing.expect(m.roll("", play));
    try testing.expect(B64.get(play, 0));
    try testing.expect(!B64.get(play, 1));
}

test "needles under the dragnet's stem still ride the roll soundly" {
    const specs = [_]query.Spec{
        .{ .pattern = "x", .fixed = true },
        .{ .pattern = "ab", .fixed = true },
        .{ .pattern = "zzz", .fixed = true },
    };
    try expectSoundOver(&specs, "ab");
    try expectSoundOver(&specs, "x marks it");
    try expectSoundOver(&specs, "qqq");
}

test "differential fuzz: the roll never excludes a real match" {
    const specs = [_]query.Spec{
        .{ .pattern = "ab", .fixed = true },
        .{ .pattern = "c+d", .fixed = false },
        .{ .pattern = "e.g", .fixed = false },
        .{ .pattern = "hh", .fixed = true },
        .{ .pattern = "f|gg", .fixed = false },
    };
    var prng = std.Random.DefaultPrng.init(0x0117e);
    const r = prng.random();
    var buf: [128]u8 = undefined;
    for (0..300) |_| {
        const n = r.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*b| b.* = 'a' + r.uintLessThan(u8, 8);
        try expectSoundOver(&specs, buf[0..n]);
    }
}

test "a slate wider than the bucket count still attributes every pattern" {
    // 70 literals over 8 buckets ⇒ ~9 literals share each bucket bit, and they
    // all share a two-byte prefix, so every candidate lane lights the same
    // bucket. Attribution must still name exactly one pattern — the case a
    // one-bucket-per-literal filter gets for free and a bucketed one must earn.
    const many = comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: [70]query.Spec = undefined;
        for (&out, 0..) |*s, i| s.* = .{ .pattern = std.fmt.comptimePrint("needle{d:0>3}", .{i}), .fixed = true };
        break :blk out;
    };
    var built = try compileAll(&many);
    defer built.deinit();
    const m = built.muster.?;
    const play = try testing.allocator.alloc(u64, B64.words(many.len));
    defer testing.allocator.free(play);
    // Past the 16-byte vector stride AND in the scalar tail — both scan halves.
    try testing.expect(m.roll("filler filler filler filler needle069 filler", play));
    try testing.expect(B64.get(play, 69));
    try testing.expect(B64.count(play) == 1);
    try testing.expect(m.roll("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa needle007", play));
    try testing.expect(B64.get(play, 7));
    try testing.expect(B64.count(play) == 1);
    try testing.expect(!m.roll("nothing here at all", play));
}

test "the sweep's early exit does not lose a pattern" {
    // Every pattern present ⇒ the sweep hits `left == 0` and abandons the rest
    // of the document. Every bit must already be set when it does.
    const specs = [_]query.Spec{
        .{ .pattern = "alpha", .fixed = true },
        .{ .pattern = "bravo", .fixed = true },
        .{ .pattern = "charlie", .fixed = true },
    };
    var built = try compileAll(&specs);
    defer built.deinit();
    const m = built.muster.?;
    const play = try testing.allocator.alloc(u64, B64.words(specs.len));
    defer testing.allocator.free(play);
    try testing.expect(m.roll("alpha bravo charlie ..... trailing bytes never scanned .....", play));
    try testing.expectEqual(@as(usize, 3), B64.count(play));
}

//! parens — balanced parentheses with a range min-max tree.
//!
//! The third leg of `succinct/`. RRR answers "how many ones before here" and
//! the wavelet tree answers "which symbol is here"; neither can answer "where
//! does this one close", which is the only question a tree shape is made of.
//!
//! An ordinal forest of N nodes serializes depth-first as a word over `(` and
//! `)` — 2N bits, against the dozens of bytes plus a refcount a pointered node
//! costs. Every navigation question is then a question about the *excess*
//!
//!     E(k) = (opens in B[0,k)) − (closes in B[0,k)) = 2·rank₁(k) − k
//!
//! which is a ±1 walk. Two facts do all the work here. First, the measure
//! μ(w) = (total, min, max) is a monoid homomorphism —
//! μ(uv) = (tᵤ+t_v, min(mᵤ, tᵤ+m_v), max(Mᵤ, tᵤ+M_v)) — so it can be kept over
//! a tree of blocks and repaired locally. Second, because the walk steps by
//! ±1, the excess values a range attains are EXACTLY the integer interval
//! [min, max]; so "does this subtree hold my target" is a containment test with
//! no false positives, and a search descends without ever backtracking.
//!
//! That pair is Sadakane & Navarro's range min-max tree
//! ([Fully-Functional Succinct Trees](https://dl.acm.org/doi/10.5555/1873601.1873614),
//! SODA 2010), which collapsed the whole navigation zoo — `findClose`,
//! `enclose`, `lca`, `subtreeSize` — onto two primitives: forward and backward
//! search for an excess value over one annotated tree. The 2n+o(n) floor
//! itself is [Jacobson (1989)](https://doi.org/10.1109/SFCS.1989.63533) and its
//! constant-time word-RAM realization
//! [Munro & Raman (2001)](https://doi.org/10.1137/S0097539799364092).
//!
//! **Static, by construction.** Every query reads immutable storage; an edit
//! rebuilds. SN also give a dynamic variant, and in this family that is a
//! finger tree over this same measure — a different file's job, because it
//! needs the bit string itself to become a tree of blocks and so cannot ride
//! `rrr.Plain`. `Span` below documents which half of the measure this file
//! stores and what the dynamic one would have to store instead.
//!
//! **Complexity, honestly.** SN reach O(1) with a Θ(log²n) block, a
//! Θ(log n)-degree tree, and precomputed universal tables. This is the
//! practical shape implementations actually ship instead: a 512-bit block
//! scanned a byte at a time through a 256-entry table, under a perfect binary
//! tree of absolute (min, max). So the two searches — and everything built on
//! them — are **O(b/8 + log(n/b)) = O(log n)** word operations with a small
//! constant, not O(1). `excess`, `depth`, `preorder`, `firstChild` and
//! `isOpen` are O(1); `select` is O(log n).

const std = @import("std");
const bitsmod = @import("../bits.zig");
const rrr = @import("rrr.zig");

const B64 = bitsmod.Field(u64);

/// Bits per leaf block. 512 bounds an in-block scan at 64 table steps and
/// prices the leaf level at 8 bytes per 512 parentheses. Public because it is
/// the one geometry number a caller sizing an artifact — or a test building a
/// deliberately boundary-straddling shape — has to agree with.
pub const block_bits: usize = 512;

/// Per-byte excess folds, bits read LSB-first to match `bits.Field(u64)`'s
/// packing. `min`/`max` range over the eight forward prefixes, `bmin`/`bmax`
/// over the eight backward ones (negated, since a backward step subtracts).
/// A whole byte is therefore one table lookup in a scan, and the ±1 interval
/// property makes the containment test on it exact.
const Byte = struct { sum: i32, min: i32, max: i32, bmin: i32, bmax: i32 };

const byte_tab: [256]Byte = blk: {
    @setEvalBranchQuota(20_000);
    var t: [256]Byte = undefined;
    for (0..256) |b| {
        var e: i32 = 0;
        var mn: i32 = std.math.maxInt(i32);
        var mx: i32 = std.math.minInt(i32);
        for (0..8) |j| {
            e += if ((b >> j) & 1 == 1) 1 else -1;
            mn = @min(mn, e);
            mx = @max(mx, e);
        }
        var r: i32 = 0;
        var bmn: i32 = std.math.maxInt(i32);
        var bmx: i32 = std.math.minInt(i32);
        for (0..8) |j| {
            r -= if ((b >> (7 - j)) & 1 == 1) 1 else -1;
            bmn = @min(bmn, r);
            bmx = @max(bmx, r);
        }
        t[b] = .{ .sum = e, .min = mn, .max = mx, .bmin = bmn, .bmax = bmx };
    }
    break :blk t;
};

/// The excess interval a range attains — the (min, max) half of μ, in ABSOLUTE
/// excess rather than relative to the range's own start. The total is not
/// stored at all: it is `excess(hi) − excess(lo−1)`, already O(1) from rank, so
/// keeping it would be a second copy of a derived fact.
///
/// Absolute is the right call for a static string and the wrong one for a
/// dynamic one, so it is worth naming. A search compares a target against
/// `[min, max]` directly, with no per-step addition and no need to know where
/// the node begins — which is why the descent below is as tight as it is. The
/// price is that a Span is bound to its position: splice bits in front of it
/// and every Span after the splice is stale, where the relative form
/// μ(uv) = (tᵤ+t_v, min(mᵤ, tᵤ+m_v), max(Mᵤ, tᵤ+M_v)) would still compose. A
/// dynamic sibling built over a monoid-measured tree wants the relative form;
/// this one, which rebuilds on edit, does not pay for it.
pub const Span = struct {
    min: i32,
    max: i32,

    const empty: Span = .{ .min = std.math.maxInt(i32), .max = std.math.minInt(i32) };

    fn join(a: Span, b: Span) Span {
        return .{ .min = @min(a.min, b.min), .max = @max(a.max, b.max) };
    }

    /// Exact, not conservative: a ±1 walk attains every value between its
    /// extremes, so a subtree that reports containment always holds the answer.
    fn holds(self: Span, e: i32) bool {
        return e >= self.min and e <= self.max;
    }
};

/// A balanced-parenthesis sequence and its range min-max tree.
///
/// A **node is the bit position of its own open paren** — that is the handle
/// every operation below takes and returns. The sequence encodes an ordinal
/// *forest*: several roots are legal (`lca` then returns null for nodes in
/// different trees), and a single-rooted tree is the ordinary case.
pub const Parens = struct {
    /// Bit storage plus O(1) rank, borrowed whole from `rrr.Plain` rather than
    /// re-rolled: `1` is `(`, `0` is `)`.
    bits: rrr.Plain,
    /// Perfect binary tree over blocks, 1-indexed; leaves live at
    /// `[leaves, 2·leaves)` and the pad leaves past `nblocks` are `Span.empty`,
    /// so a search can never select one.
    tip: []Span,
    leaves: usize,
    nblocks: usize,
    nbits: usize,

    /// The bit sequence is not a balanced one, so it does not denote a forest.
    /// `NonCanonical` is the taxonomy's declared name for input that is not in the
    /// form a reader requires — the same fact whether the bits arrived from a
    /// caller's builder or off a persisted page, so it gets the same spelling.
    pub const Error = error{NonCanonical};

    /// Depth-first emission of a forest: `open` on the way down, `close` on the
    /// way up. `capacity_bits` is an upper bound the writes may not exceed —
    /// twice the node count if that is known, a guess otherwise; `seal` trims
    /// to what was written. The bound is asserted, not grown, because a
    /// serializer that miscounted its own tree should say so here.
    pub const Builder = struct {
        plain: rrr.Plain,
        n: usize = 0,
        cap: usize,
        open_depth: i32 = 0,

        pub fn init(gpa: std.mem.Allocator, capacity_bits: usize) !Builder {
            std.debug.assert(capacity_bits <= std.math.maxInt(i32));
            return .{ .plain = try rrr.Plain.initEmpty(gpa, capacity_bits), .cap = capacity_bits };
        }

        pub fn open(self: *Builder) void {
            std.debug.assert(self.n < self.cap);
            self.plain.set(self.n);
            self.n += 1;
            self.open_depth += 1;
        }

        pub fn close(self: *Builder) Error!void {
            std.debug.assert(self.n < self.cap);
            if (self.open_depth == 0) return error.NonCanonical;
            self.n += 1;
            self.open_depth -= 1;
        }

        /// Consume the builder and index it. The builder is spent afterwards;
        /// `deinit` is only for abandoning one before this call.
        ///
        /// The capacity was a reservation, not a promise: a caller who guessed
        /// high seals at the length it actually wrote, and the slack is handed
        /// back. Only an unclosed parenthesis is a refusal.
        pub fn seal(self: *Builder, gpa: std.mem.Allocator) !Parens {
            if (self.open_depth != 0) return error.NonCanonical;
            var plain = self.plain;
            self.plain = .{ .words = &.{}, .supers = &.{}, .nbits = 0 };
            errdefer plain.deinit(gpa);
            plain.nbits = self.n;
            const want = @max((self.n + 63) / 64, 1) + 1; // +1: rrr's straddle pad
            if (want < plain.words.len) plain.words = gpa.realloc(plain.words, want) catch plain.words;
            try plain.finalize(gpa);
            return index(gpa, plain);
        }

        pub fn deinit(self: *Builder, gpa: std.mem.Allocator) void {
            self.plain.deinit(gpa);
        }
    };

    /// Build from a literal shape over `(` and `)` — the readable door, and
    /// what a test or a fixture wants.
    pub fn fromShape(gpa: std.mem.Allocator, shape: []const u8) !Parens {
        var b = try Builder.init(gpa, shape.len);
        errdefer b.deinit(gpa);
        for (shape) |c| switch (c) {
            '(' => b.open(),
            ')' => try b.close(),
            else => return error.NonCanonical,
        };
        return b.seal(gpa);
    }

    fn index(gpa: std.mem.Allocator, plain: rrr.Plain) !Parens {
        const nblocks = @max(1, (plain.nbits + block_bits - 1) / block_bits);
        const leaves = std.math.ceilPowerOfTwo(usize, nblocks) catch unreachable;
        const tip = try gpa.alloc(Span, 2 * leaves);
        @memset(tip, Span.empty);
        var self = Parens{
            .bits = plain,
            .tip = tip,
            .leaves = leaves,
            .nblocks = nblocks,
            .nbits = plain.nbits,
        };
        for (0..nblocks) |b| {
            const s = b * block_bits;
            tip[leaves + b] = self.scanSpan(s, @min(s + block_bits, self.nbits));
        }
        var i = leaves;
        while (i > 1) : (i -= 1) tip[i - 1] = tip[2 * (i - 1)].join(tip[2 * (i - 1) + 1]);
        return self;
    }

    pub fn deinit(self: *Parens, gpa: std.mem.Allocator) void {
        self.bits.deinit(gpa);
        gpa.free(self.tip);
    }

    pub fn sizeBytes(self: *const Parens) usize {
        return self.bits.sizeBytes() + self.tip.len * @sizeOf(Span);
    }

    pub fn bitLen(self: *const Parens) usize {
        return self.nbits;
    }

    pub fn nodeCount(self: *const Parens) usize {
        return self.nbits / 2;
    }

    // ── the bit sequence ────────────────────────────────────────────────────

    pub fn isOpen(self: *const Parens, i: usize) bool {
        return B64.get(self.bits.words, i);
    }

    /// Opens in `B[0, i)`. Also the 0-based preorder index of the node at `i`.
    pub fn rank1(self: *const Parens, i: usize) usize {
        return self.bits.rank1(i);
    }

    /// Closes in `B[0, i)`.
    pub fn rank0(self: *const Parens, i: usize) usize {
        return i - self.bits.rank1(i);
    }

    /// Position of the `k`-th open (0-based), or null past the last.
    pub fn select1(self: *const Parens, k: usize) ?usize {
        if (k >= self.nodeCount()) return null;
        return self.select(k, true);
    }

    /// Position of the `k`-th close (0-based), or null past the last.
    pub fn select0(self: *const Parens, k: usize) ?usize {
        if (k >= self.nodeCount()) return null;
        return self.select(k, false);
    }

    /// Unmatched opens after reading `B[0, i]` — excess INCLUSIVE of `i`.
    /// For an open paren this is its depth.
    pub fn excess(self: *const Parens, i: usize) i32 {
        return self.eAt(i + 1);
    }

    /// The interval of `excess(i)` over `i ∈ [lo, hi]` — the range min-max
    /// tree's own query, answered in O(b/8 + log(n/b)).
    pub fn measure(self: *const Parens, lo: usize, hi: usize) Span {
        return self.spanE(lo + 1, hi + 1);
    }

    // ── the tree ────────────────────────────────────────────────────────────

    /// The `)` matching the `(` at `i`. Always exists on a sealed sequence.
    pub fn findClose(self: *const Parens, i: usize) usize {
        std.debug.assert(self.isOpen(i));
        return self.fwdsearch(i + 1, self.eAt(i)).? - 1;
    }

    /// The `(` matching the `)` at `i`.
    pub fn findOpen(self: *const Parens, i: usize) usize {
        std.debug.assert(!self.isOpen(i));
        return self.bwdsearch(i, self.eAt(i + 1)).?;
    }

    /// The nearest enclosing open — i.e. the PARENT of the node at `i`, or
    /// null when it is a root.
    pub fn enclose(self: *const Parens, i: usize) ?usize {
        std.debug.assert(self.isOpen(i));
        const e = self.eAt(i);
        if (e == 0) return null;
        return self.bwdsearch(i, e - 1);
    }

    /// Depth of the node at `i`; roots are at depth 1.
    pub fn depth(self: *const Parens, i: usize) usize {
        std.debug.assert(self.isOpen(i));
        return @intCast(self.excess(i));
    }

    /// Nodes in the subtree rooted at `i`, counting `i`.
    pub fn subtreeSize(self: *const Parens, i: usize) usize {
        return (self.findClose(i) - i + 1) / 2;
    }

    pub fn firstChild(self: *const Parens, i: usize) ?usize {
        std.debug.assert(self.isOpen(i));
        return if (self.isOpen(i + 1)) i + 1 else null;
    }

    pub fn lastChild(self: *const Parens, i: usize) ?usize {
        const c = self.findClose(i);
        return if (c == i + 1) null else self.findOpen(c - 1);
    }

    pub fn nextSibling(self: *const Parens, i: usize) ?usize {
        const c = self.findClose(i) + 1;
        return if (c < self.nbits and self.isOpen(c)) c else null;
    }

    pub fn prevSibling(self: *const Parens, i: usize) ?usize {
        std.debug.assert(self.isOpen(i));
        if (i == 0 or self.isOpen(i - 1)) return null;
        return self.findOpen(i - 1);
    }

    /// 0-based preorder index of the node at `i`, and its inverse.
    pub fn preorder(self: *const Parens, i: usize) usize {
        std.debug.assert(self.isOpen(i));
        return self.bits.rank1(i);
    }

    pub fn nodeAt(self: *const Parens, preorder_index: usize) ?usize {
        return self.select1(preorder_index);
    }

    pub fn isAncestor(self: *const Parens, a: usize, b: usize) bool {
        return a <= b and b <= self.findClose(a);
    }

    /// Deepest node enclosing both, or null when they sit in different trees
    /// of the forest. `a` and `b` may be equal or in ancestor relation.
    pub fn lca(self: *const Parens, a: usize, b: usize) ?usize {
        if (a == b) return a;
        const x = @min(a, b);
        const y = @max(a, b);
        return self.bwdsearch(x, self.measure(x, y).min - 1);
    }

    // ── the two search primitives everything above is expressed in ──────────

    /// E(k) — excess EXCLUSIVE of position k, defined on `[0, nbits]`.
    fn eAt(self: *const Parens, k: usize) i32 {
        return @as(i32, @intCast(2 * self.bits.rank1(k))) - @as(i32, @intCast(k));
    }

    fn byteAt(self: *const Parens, bi: usize) u8 {
        return @truncate(self.bits.words[bi >> 3] >> @intCast((bi & 7) * 8));
    }

    fn blockOf(self: *const Parens, k: usize) usize {
        return @min(k / block_bits, self.nblocks - 1);
    }

    /// Smallest `k ≥ from` with `E(k) = target`.
    fn fwdsearch(self: *const Parens, from: usize, target: i32) ?usize {
        const b = self.blockOf(from);
        if (self.scanFwd(from, @min((b + 1) * block_bits, self.nbits), target)) |k| return k;
        var node = self.leaves + b;
        while (node > 1) : (node >>= 1) {
            if (node & 1 == 0 and self.tip[node + 1].holds(target)) {
                var n = node + 1;
                while (n < self.leaves) n = if (self.tip[2 * n].holds(target)) 2 * n else 2 * n + 1;
                const s = (n - self.leaves) * block_bits;
                return self.scanFwd(s, @min(s + block_bits, self.nbits), target).?;
            }
        }
        return null;
    }

    /// Largest `k ≤ to` with `E(k) = target`.
    fn bwdsearch(self: *const Parens, to: usize, target: i32) ?usize {
        const b = self.blockOf(to);
        if (self.scanBwd(to, b * block_bits, target)) |k| return k;
        var node = self.leaves + b;
        while (node > 1) : (node >>= 1) {
            if (node & 1 == 1 and self.tip[node - 1].holds(target)) {
                var n = node - 1;
                while (n < self.leaves) n = if (self.tip[2 * n + 1].holds(target)) 2 * n + 1 else 2 * n;
                const s = (n - self.leaves) * block_bits;
                return self.scanBwd(@min(s + block_bits, self.nbits), s, target).?;
            }
        }
        return null;
    }

    /// Min/max of E over `[klo, khi]`, both inclusive.
    fn spanE(self: *const Parens, klo: usize, khi: usize) Span {
        const blo = self.blockOf(klo);
        const bhi = self.blockOf(khi);
        if (blo == bhi) return self.scanSpan(klo, khi);
        var acc = self.scanSpan(klo, (blo + 1) * block_bits);
        acc = acc.join(self.scanSpan(bhi * block_bits, khi));
        if (bhi > blo + 1) {
            var l = self.leaves + blo + 1;
            var r = self.leaves + bhi; // exclusive
            while (l < r) : ({
                l >>= 1;
                r >>= 1;
            }) {
                if (l & 1 == 1) {
                    acc = acc.join(self.tip[l]);
                    l += 1;
                }
                if (r & 1 == 1) {
                    r -= 1;
                    acc = acc.join(self.tip[r]);
                }
            }
        }
        return acc;
    }

    // ── in-block walks: one table lookup per byte, bits only at the edges ───

    fn scanFwd(self: *const Parens, from: usize, to: usize, target: i32) ?usize {
        var e = self.eAt(from);
        if (e == target) return from;
        var k = from;
        while (k < to) {
            if (k & 7 == 0 and to - k >= 8) {
                const byte = self.byteAt(k >> 3);
                const tab = byte_tab[byte];
                const d = target - e;
                if (d >= tab.min and d <= tab.max) {
                    for (0..8) |j| {
                        e += if ((byte >> @intCast(j)) & 1 == 1) @as(i32, 1) else -1;
                        if (e == target) return k + j + 1;
                    }
                    unreachable; // the ±1 interval property makes `d` attained
                }
                e += tab.sum;
                k += 8;
            } else {
                e += if (self.isOpen(k)) @as(i32, 1) else -1;
                k += 1;
                if (e == target) return k;
            }
        }
        return null;
    }

    fn scanBwd(self: *const Parens, from: usize, downto: usize, target: i32) ?usize {
        var e = self.eAt(from);
        if (e == target) return from;
        var k = from;
        while (k > downto) {
            if (k & 7 == 0 and k - downto >= 8) {
                const byte = self.byteAt((k >> 3) - 1);
                const tab = byte_tab[byte];
                const d = target - e;
                if (d >= tab.bmin and d <= tab.bmax) {
                    for (0..8) |r| {
                        e -= if ((byte >> @intCast(7 - r)) & 1 == 1) @as(i32, 1) else -1;
                        if (e == target) return k - r - 1;
                    }
                    unreachable;
                }
                e -= tab.sum;
                k -= 8;
            } else {
                e -= if (self.isOpen(k - 1)) @as(i32, 1) else -1;
                k -= 1;
                if (e == target) return k;
            }
        }
        return null;
    }

    fn scanSpan(self: *const Parens, klo: usize, khi: usize) Span {
        var e = self.eAt(klo);
        var acc = Span{ .min = e, .max = e };
        var k = klo;
        while (k < khi) {
            if (k & 7 == 0 and khi - k >= 8) {
                const tab = byte_tab[self.byteAt(k >> 3)];
                acc.min = @min(acc.min, e + tab.min);
                acc.max = @max(acc.max, e + tab.max);
                e += tab.sum;
                k += 8;
            } else {
                e += if (self.isOpen(k)) @as(i32, 1) else -1;
                k += 1;
                acc = acc.join(.{ .min = e, .max = e });
            }
        }
        return acc;
    }

    /// Position of the `k`-th one (or zero) — binary search over `Plain`'s
    /// 512-bit rank samples, then a word walk, then a byte walk. O(log n).
    fn select(self: *const Parens, k: usize, comptime want_one: bool) usize {
        const Prefix = struct {
            fn at(p: *const Parens, g: usize) usize {
                const ones: usize = p.bits.supers[g];
                return if (want_one) ones else g * 512 - ones;
            }
        };
        var lo: usize = 0;
        var hi: usize = self.bits.supers.len; // first group whose prefix count exceeds k
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (Prefix.at(self, mid) <= k) lo = mid else hi = mid;
        }
        var rest = k - Prefix.at(self, lo);
        var w = lo * 8;
        while (true) : (w += 1) {
            const word = if (want_one) self.bits.words[w] else ~self.bits.words[w];
            const c = @popCount(word);
            if (rest < c) {
                var v = word;
                var shift: usize = 0;
                while (true) : (shift += 8) {
                    const cb = @popCount(@as(u8, @truncate(v)));
                    if (rest < cb) break;
                    rest -= cb;
                    v >>= 8;
                }
                var byte: u8 = @truncate(v);
                while (rest > 0) : (rest -= 1) byte &= byte - 1;
                return w * 64 + shift + @ctz(byte);
            }
            rest -= c;
        }
    }
};

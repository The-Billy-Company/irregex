//! rrr — entropy-compressed bitvectors with O(1) rank.
//!
//! Two representations behind one seam, chosen per vector by measured size:
//!
//!   Plain  raw 64-bit words + a rank sample every 512 bits (6.6% overhead,
//!          ~10ns rank). Wins on incompressible bits — e.g. the root level of
//!          a wavelet tree, where the Huffman split is near-balanced.
//!   Rrr    Raman–Raman–Rao (SODA 2002) block coding: each 63-bit block is
//!          stored as (class = popcount, offset = combinadic rank within the
//!          C(63,class) patterns of that class) — Σ ⌈log₂ C(63,cᵢ)⌉ bits is
//!          ≤ nH₀ + o(n), the zeroth-order entropy OF THE BITVECTOR. Inside a
//!          wavelet tree over a BWT this is what buys k-th order compression:
//!          the BWT makes bits run-heavy, runs make blocks extreme-class, and
//!          extreme classes cost ~0 bits (implicit compression boosting —
//!          Mäkinen & Navarro, SPIRE 2007).
//!
//! `Bits.adopt` takes a finished Plain vector and keeps whichever encoding is
//! smaller, so a caller can never lose space to the choice. Rank never decodes
//! more than one block (≤63 combinadic steps, early-exit on exhausted class)
//! after a ≤15-block class walk from the nearest superblock sample.

const std = @import("std");
const bitsmod = @import("../bits.zig");

const B64 = bitsmod.Field(u64);

/// Pascal's triangle through C(63,k) — max C(63,31) ≈ 9.16e17 < 2⁶⁴.
const binomial: [64][64]u64 = blk: {
    @setEvalBranchQuota(20_000);
    var c: [64][64]u64 = .{.{0} ** 64} ** 64;
    for (0..64) |i| {
        c[i][0] = 1;
        for (1..i + 1) |j| c[i][j] = c[i - 1][j - 1] + c[i - 1][j];
    }
    break :blk c;
};

/// The same table transposed: `binom_t[k][n]` = C(n,k). Block decode walks
/// positions with k nearly constant, so this layout turns its inner loop into
/// a sequential descent of one 512-byte row instead of a 512-byte-strided
/// column walk through `binomial`.
const binom_t: [64][64]u64 = blk: {
    @setEvalBranchQuota(20_000);
    var t: [64][64]u64 = undefined;
    for (0..64) |n| {
        for (0..64) |k| t[k][n] = binomial[n][k];
    }
    break :blk t;
};

/// Offset field width per class: ⌈log₂ C(63,k)⌉ (0 for the two extreme classes).
const offset_width: [64]u7 = blk: {
    var w: [64]u7 = undefined;
    for (0..64) |k| {
        const c = binomial[63][k];
        w[k] = if (c <= 1) 0 else @intCast(64 - @clz(c - 1));
    }
    break :blk w;
};

/// Class-PAIR projections for the superblock walk: one 12-bit gulp of two
/// packed classes keys both the summed offset width and the summed rank, so
/// the walk retires two blocks per loop step. Byte-sized entries keep the
/// pair tables at 4KB each. PROFILING-DERIVED (2026-07-18, macOS `sample`
/// over `codex-scale` 16MB, ReleaseFast): `Rrr.seek` was ~41% of the count()
/// query phase (1501/3600 samples), nearly all of it this class walk —
/// don't fold these back into per-class `offset_width` lookups without
/// re-measuring `bench/codex`.
const pair_width: [4096]u8 = blk: {
    @setEvalBranchQuota(20_000);
    var t: [4096]u8 = undefined;
    for (0..4096) |p| t[p] = offset_width[p & 63] + offset_width[p >> 6];
    break :blk t;
};
const pair_rank: [4096]u8 = blk: {
    @setEvalBranchQuota(20_000);
    var t: [4096]u8 = undefined;
    for (0..4096) |p| t[p] = (p & 63) + (p >> 6);
    break :blk t;
};

const BLOCK: usize = 63;
const SUPER: usize = 16; // blocks per superblock sample

fn readBits(words: []const u64, bitpos: usize, nbits: u7) u64 {
    if (nbits == 0) return 0;
    const w = bitpos >> 6;
    const sh: u6 = @intCast(bitpos & 63);
    var v = words[w] >> sh;
    if (@as(usize, sh) + nbits > 64) v |= words[w + 1] << @intCast(64 - @as(usize, sh));
    return v & bitsmod.prefixMask(u64, nbits);
}

fn writeBits(words: []u64, bitpos: usize, nbits: u7, v: u64) void {
    if (nbits == 0) return;
    const w = bitpos >> 6;
    const sh: u6 = @intCast(bitpos & 63);
    words[w] |= v << sh;
    if (@as(usize, sh) + nbits > 64) words[w + 1] |= v >> @intCast(64 - @as(usize, sh));
}

/// Raman–Raman–Rao combinadic offset: rank of this 63-bit pattern among the
/// C(63,popcount) same-class patterns (bit-0-first, 0 before 1).
///
/// Only the set bits contribute a term, so the walk visits them directly
/// (`@ctz`, then clear the low one) rather than scanning every position up to
/// the last one. Same sum, same table, `class` iterations instead of
/// `last_set_pos + 1` — measured 1.42× over the real root-level blocks of a
/// 32MB corpus, which is ~⅙ of the RRR transcode.
fn encodeBlock(bits: u64) u64 {
    var off: u64 = 0;
    var k: u32 = @popCount(bits);
    var rest = bits;
    while (rest != 0) : (rest &= rest - 1) {
        off += binom_t[k][62 - @ctz(rest)];
        k -= 1;
    }
    return off;
}

/// Walk a coded block: ones among the first `upto` positions, plus (when
/// `want_bit`) the bit at position `upto` itself. Two early exits keep the
/// BWT's run-heavy blocks ~free: class exhausted ⇒ the rest are zeros; class
/// equal to the remaining width ⇒ the rest are ones.
fn scanBlock(class: u32, offset: u64, upto: u32, want_bit: bool) struct { ones: u32, bit: u1 } {
    // Offset 0 is the rank-0 pattern of its class: zeros as early as
    // possible, i.e. the k ones packed at the tail [63-k, 63). That is
    // exactly the shape of a BWT run block (0^a 1^b — and all-ones, whose
    // offset field is 0 wide), so it answers in O(1) instead of walking up
    // to 62 binomial-table steps. PROFILING NOTE (2026-07-18, `sample` over
    // `codex-scale` 16MB ReleaseFast): the occ→rank1 chain under
    // `Codex.range` is the top count() cost, but this shortcut alone
    // measured within run-to-run noise there (the seek class walk
    // dominates) — kept for the O(1) bound on run-heavy blocks, verified by
    // the density/boundary sweep in codex_test.
    if (offset == 0) {
        const first_one = 63 - class;
        return .{
            .ones = if (upto > first_one) upto - first_one else 0,
            .bit = @intFromBool(want_bit and upto >= first_one),
        };
    }
    var k = class;
    var off = offset;
    var ones: u32 = 0;
    var bit: u1 = 0;
    const limit = if (want_bit) upto + 1 else upto;
    var pos: u32 = 0;
    while (pos < limit and k > 0) : (pos += 1) {
        if (k == 63 - pos) { // all remaining positions are forced ones
            if (upto > pos) ones += upto - pos;
            if (want_bit) bit = 1;
            return .{ .ones = ones, .bit = bit };
        }
        const c = binom_t[k][62 - pos];
        if (off >= c) {
            off -= c;
            k -= 1;
            if (pos < upto) ones += 1 else bit = 1;
        }
    }
    return .{ .ones = ones, .bit = bit };
}

/// Raw bitvector with sampled rank. Also the construction surface: callers
/// build a Plain (set + finalize), then `Bits.adopt` may transcode it.
pub const Plain = struct {
    words: []u64,
    supers: []u32, // rank1 before each 8-word (512-bit) group
    nbits: usize,

    pub fn initEmpty(gpa: std.mem.Allocator, nbits: usize) !Plain {
        const words = try gpa.alloc(u64, @max((nbits + 63) / 64, 1) + 1); // +1: straddle-free block reads
        @memset(words, 0);
        return .{ .words = words, .supers = &.{}, .nbits = nbits };
    }

    pub fn set(self: *Plain, i: usize) void {
        B64.set(self.words, i);
    }

    pub fn finalize(self: *Plain, gpa: std.mem.Allocator) !void {
        const nsupers = (self.words.len >> 3) + 1;
        const supers = try gpa.alloc(u32, nsupers);
        var acc: u32 = 0;
        for (0..nsupers) |sb| {
            supers[sb] = acc;
            const lo = sb << 3;
            for (self.words[lo..@min(lo + 8, self.words.len)]) |w| acc += @popCount(w);
        }
        self.supers = supers;
    }

    /// Reconstitute from persisted words (takes ownership; the slice must
    /// carry `initEmpty`'s +1 straddle pad). Rank samples are rebuilt, not
    /// trusted from disk.
    pub fn fromWords(gpa: std.mem.Allocator, words: []u64, nbits: usize) !Plain {
        if (words.len != @max((nbits + 63) / 64, 1) + 1) return error.Corrupt;
        var self = Plain{ .words = words, .supers = &.{}, .nbits = nbits };
        try self.finalize(gpa);
        return self;
    }

    pub fn deinit(self: *Plain, gpa: std.mem.Allocator) void {
        gpa.free(self.words);
        gpa.free(self.supers);
    }

    pub fn rank1(self: *const Plain, pos: usize) usize {
        const w = pos >> 6;
        var r: usize = self.supers[w >> 3];
        var i = (w >> 3) << 3;
        while (i < w) : (i += 1) r += @popCount(self.words[i]);
        return r + bitsmod.rank(self.words[w], pos & 63);
    }

    pub fn get(self: *const Plain, pos: usize) u1 {
        return @intFromBool(B64.get(self.words, pos));
    }

    pub fn sizeBytes(self: *const Plain) usize {
        return self.words.len * 8 + self.supers.len * 4;
    }
};

/// The RRR encoding of a Plain vector.
pub const Rrr = struct {
    classes: []u64, // 6-bit packed class per block
    offsets: []u64, // variable-width combinadic offsets, densely packed
    super_rank: []u32, // rank1 before each superblock
    super_off: []u32, // offset-stream bit position at each superblock
    nbits: usize,

    pub fn fromPlain(gpa: std.mem.Allocator, plain: *const Plain) !Rrr {
        const nblocks = (plain.nbits + BLOCK - 1) / BLOCK;
        const nsupers = nblocks / SUPER + 1;
        const classes = try gpa.alloc(u64, (nblocks * 6 + 63) / 64 + 1);
        errdefer gpa.free(classes);
        const super_rank = try gpa.alloc(u32, nsupers);
        errdefer gpa.free(super_rank);
        const super_off = try gpa.alloc(u32, nsupers);
        errdefer gpa.free(super_off);
        var self = Rrr{
            .classes = classes,
            .offsets = undefined,
            .super_rank = super_rank,
            .super_off = super_off,
            .nbits = plain.nbits,
        };
        @memset(self.classes, 0);
        // pass 1: classes + stream geometry; pass 2: offsets
        var total_off_bits: usize = 0;
        var rank_acc: u32 = 0;
        for (0..nblocks) |b| {
            if (b % SUPER == 0) {
                self.super_rank[b / SUPER] = rank_acc;
                self.super_off[b / SUPER] = @intCast(total_off_bits);
            }
            const nb: u7 = @intCast(@min(BLOCK, plain.nbits - b * BLOCK));
            const block = readBits(plain.words, b * BLOCK, nb);
            const class: u32 = @popCount(block);
            writeBits(self.classes, b * 6, 6, class);
            rank_acc += class;
            total_off_bits += offset_width[class];
        }
        // trailing sample: rank1(nbits) on an exact-multiple block count lands
        // on superblock nblocks/SUPER, which the loop above never reaches
        if (nblocks % SUPER == 0) {
            self.super_rank[nblocks / SUPER] = rank_acc;
            self.super_off[nblocks / SUPER] = @intCast(total_off_bits);
        }
        self.offsets = try gpa.alloc(u64, (total_off_bits + 63) / 64 + 1);
        @memset(self.offsets, 0);
        var opos: usize = 0;
        for (0..nblocks) |b| {
            const nb: u7 = @intCast(@min(BLOCK, plain.nbits - b * BLOCK));
            const block = readBits(plain.words, b * BLOCK, nb);
            const class: u32 = @popCount(block);
            writeBits(self.offsets, opos, offset_width[class], encodeBlock(block));
            opos += offset_width[class];
        }
        return self;
    }

    /// Reconstitute from persisted class + offset streams (takes ownership).
    /// The superblock samples are rebuilt from the classes — derived data is
    /// never trusted from disk — and the stream geometry is validated.
    pub fn fromParts(gpa: std.mem.Allocator, classes: []u64, offsets: []u64, nbits: usize) !Rrr {
        const nblocks = (nbits + BLOCK - 1) / BLOCK;
        if (classes.len != (nblocks * 6 + 63) / 64 + 1) return error.Corrupt;
        const nsupers = nblocks / SUPER + 1;
        var self = Rrr{
            .classes = classes,
            .offsets = offsets,
            .super_rank = try gpa.alloc(u32, nsupers),
            .super_off = try gpa.alloc(u32, nsupers),
            .nbits = nbits,
        };
        errdefer gpa.free(self.super_rank);
        errdefer gpa.free(self.super_off);
        var rank_acc: u32 = 0;
        var opos: usize = 0;
        for (0..nblocks) |b| {
            if (b % SUPER == 0) {
                self.super_rank[b / SUPER] = rank_acc;
                self.super_off[b / SUPER] = @intCast(opos);
            }
            const class = self.classAt(b);
            const width: u7 = @intCast(@min(BLOCK, nbits - b * BLOCK));
            if (class > width) return error.Corrupt; // popcount can't exceed block width
            rank_acc += class;
            opos += offset_width[class];
        }
        if (nblocks % SUPER == 0) {
            self.super_rank[nblocks / SUPER] = rank_acc;
            self.super_off[nblocks / SUPER] = @intCast(opos);
        }
        if (offsets.len != (opos + 63) / 64 + 1) return error.Corrupt;
        return self;
    }

    pub fn deinit(self: *Rrr, gpa: std.mem.Allocator) void {
        gpa.free(self.classes);
        gpa.free(self.offsets);
        gpa.free(self.super_rank);
        gpa.free(self.super_off);
    }

    fn classAt(self: *const Rrr, b: usize) u32 {
        return @intCast(readBits(self.classes, b * 6, 6));
    }

    /// Locate block `b`'s class and offset by walking from its superblock.
    /// The walk streams the packed classes through a `bits.Stream` cursor —
    /// one positioned load at the superblock, then a shift+mask per gulp —
    /// and retires blocks TWO at a time: a 12-bit take keys the `pair_*`
    /// tables for the summed rank and offset width. PROFILING-DERIVED
    /// (2026-07-18, see `pair_width`): this walk dominated `count()`, and
    /// the cursor+pair shape measured ~5% median / ~14% best count-latency
    /// improvement on the 16MB `codex-scale` slice; keep it load-light and
    /// re-measure `bench/codex` before restructuring.
    fn seek(self: *const Rrr, b: usize) struct { class: u32, offset: u64, rank_before: usize } {
        const sb = b / SUPER;
        var rank: usize = self.super_rank[sb];
        var opos: usize = self.super_off[sb];
        var classes = bitsmod.Stream.init(self.classes, sb * SUPER * 6);
        var n = b - sb * SUPER;
        while (n >= 2) : (n -= 2) {
            // A 12-bit take is ≤ 4095 — the `pair_*` tables' exact extent — so
            // narrowing the bit-stream's u64 to the index type is exact anywhere.
            const p: usize = @intCast(classes.take(12));
            rank += pair_rank[p];
            opos += pair_width[p];
        }
        if (n == 1) {
            const c: usize = @intCast(classes.take(6)); // a 6-bit take is ≤ 63
            rank += c;
            opos += offset_width[c];
        }
        const class: u32 = @intCast(classes.take(6));
        return .{ .class = class, .offset = readBits(self.offsets, opos, offset_width[class]), .rank_before = rank };
    }

    pub fn rank1(self: *const Rrr, pos: usize) usize {
        if (pos == 0) return 0;
        const b = pos / BLOCK;
        const rem: u32 = @intCast(pos % BLOCK);
        if (rem == 0) { // block boundary: classes alone suffice
            const sb = b / SUPER;
            var rank: usize = self.super_rank[sb];
            var classes = bitsmod.Stream.init(self.classes, sb * SUPER * 6);
            var n = b - sb * SUPER;
            while (n >= 2) : (n -= 2) rank += pair_rank[@intCast(classes.take(12))];
            if (n == 1) rank += @intCast(classes.take(6));
            return rank;
        }
        const s = self.seek(b);
        return s.rank_before + scanBlock(s.class, s.offset, rem, false).ones;
    }

    pub fn get(self: *const Rrr, pos: usize) u1 {
        const s = self.seek(pos / BLOCK);
        return scanBlock(s.class, s.offset, @intCast(pos % BLOCK), true).bit;
    }

    pub fn sizeBytes(self: *const Rrr) usize {
        return (self.classes.len + self.offsets.len) * 8 + (self.super_rank.len + self.super_off.len) * 4;
    }
};

/// The seam the wavelet tree stores: whichever encoding measured smaller.
pub const Bits = union(enum) {
    plain: Plain,
    rrr: Rrr,

    /// Take ownership of a finalized Plain vector; transcode to RRR when that
    /// is strictly smaller (never worse than the raw representation).
    pub fn adopt(gpa: std.mem.Allocator, plain: Plain) !Bits {
        var p = plain;
        var r = try Rrr.fromPlain(gpa, &p);
        if (r.sizeBytes() < p.sizeBytes()) {
            p.deinit(gpa);
            return .{ .rrr = r };
        }
        r.deinit(gpa);
        return .{ .plain = p };
    }

    pub fn deinit(self: *Bits, gpa: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*v| v.deinit(gpa),
        }
    }

    pub fn rank1(self: *const Bits, pos: usize) usize {
        return switch (self.*) {
            inline else => |*v| v.rank1(pos),
        };
    }

    pub fn get(self: *const Bits, pos: usize) u1 {
        return switch (self.*) {
            inline else => |*v| v.get(pos),
        };
    }

    pub fn nbits(self: *const Bits) usize {
        return switch (self.*) {
            inline else => |*v| v.nbits,
        };
    }

    pub fn sizeBytes(self: *const Bits) usize {
        return switch (self.*) {
            inline else => |*v| v.sizeBytes(),
        };
    }
};

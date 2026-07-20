//! bits — the shared two's-complement identity floor.
//!
//! Hardware encodes negatives in two's complement (flip all bits, add one),
//! so `x - 1` borrows through the trailing zeros of `x` and flips exactly its
//! lowest set bit. That one fact is this module's whole engine (Warren,
//! *Hacker's Delight* §2-1):
//!
//!   x & (x - 1)   retires the lowest set bit
//!   @ctz(x)       names its index
//!
//! Together they walk a word's set bits in popcount steps — never the word
//! width — which is `ones` below. `Field(Word)` layers the word-packed bit
//! set on top: the `bits[i>>6] |= 1 << (i&63)` shape that powerset, patterns,
//! syntax's ByteSet, sais, and rrr each hand-rolled (at u64 AND u8 widths),
//! now one floor. Packing is also the memory story: 1 bit per flag versus the
//! byte a `[]bool` spends.
//!
//! Deliberately identities-over-PLAIN-SLICES, not `std.bit_set`'s owning
//! containers: these masks live as hash-map keys (powerset interning),
//! caller-owned attribution masks (`patterns.docMask`), and struct fields
//! (sais' u8 suffix-type map) — the storage belongs to the caller; only the
//! identities are shared.

const std = @import("std");

/// Iterator over the set-bit indices of ONE machine word, ascending. Each
/// step is `@ctz` to name the lowest set bit and `x & (x - 1)` to retire it,
/// so a k-bit word costs exactly k steps.
pub fn Ones(comptime Word: type) type {
    return struct {
        rest: Word,

        pub fn next(self: *@This()) ?std.math.Log2Int(Word) {
            if (self.rest == 0) return null;
            const i: std.math.Log2Int(Word) = @intCast(@ctz(self.rest));
            self.rest &= self.rest - 1; // two's-complement borrow clears the lowest set bit
            return i;
        }
    };
}

/// The set bits of one word, lowest first.
pub fn ones(x: anytype) Ones(@TypeOf(x)) {
    return .{ .rest = x };
}

/// Mask of the low `k` bits of `Word`, correct at BOTH edges (k = 0 and
/// k = width). The naive `(1 << k) - 1` is UB at k = width (the shift
/// overflows before the two's-complement borrow can wrap it); shifting
/// all-ones DOWN from the top runs out of that trap: `~0 >> (width - k)`.
pub fn prefixMask(comptime Word: type, k: usize) Word {
    comptime std.debug.assert(@typeInfo(Word).int.signedness == .unsigned);
    if (k == 0) return 0;
    return @as(Word, std.math.maxInt(Word)) >> @intCast(@bitSizeOf(Word) - k);
}

/// rank1 within one word: set bits among the low `k` of `w` (k ≤ width).
/// One mask + one popcount — the per-word step of every sampled-rank scheme.
pub fn rank(w: anytype, k: usize) usize {
    return @popCount(w & prefixMask(@TypeOf(w), k));
}

/// Cursor over bit fields packed densely in a little-endian u64 stream.
/// Holds a 128-bit shift window refilled a whole word at a time, so after
/// the first positioned load each `take` costs one shift + one mask — versus
/// a fresh positioned read (index math, two loads, straddle test) per field.
/// `take`'s width is per-call, so a walk can gulp fields in fused groups
/// (e.g. two 6-bit codes as one 12-bit table key) and still finish with a
/// single field. This is the decode half of the `writeBits`-style dense
/// packing that sampled-rank structures walk in their hot path.
///
/// PROFILING-DERIVED (2026-07-18, macOS `sample` over `codex-scale` 16MB,
/// ReleaseFast): the positioned-read class walk in `codex/rrr.zig`'s `seek`
/// was ~41% of FM-index `count()` samples (1501/3600); this cursor plus
/// paired takes measured ~5% median / up to ~14% (m=32) faster count
/// ns/query, best-of-3 × 400 queries. Don't swap it back to per-field
/// positioned reads without re-running `bench/codex`.
///
/// The caller guarantees one readable word past the last field consumed (the
/// usual `+1` pad word on packed streams).
pub const Stream = struct {
    words: []const u64,
    wi: usize, // next word to refill from
    win: u128,
    have: u8, // valid low bits of `win`

    pub fn init(words: []const u64, bitpos: usize) Stream {
        const sh: u6 = @intCast(bitpos % 64);
        return .{
            .words = words,
            .wi = bitpos / 64 + 1,
            .win = words[bitpos / 64] >> sh,
            .have = 64 - @as(u8, sh),
        };
    }

    pub fn take(self: *Stream, comptime n: u7) u64 {
        if (self.have < n) {
            self.win |= @as(u128, self.words[self.wi]) << @intCast(self.have);
            self.wi += 1;
            self.have += 64;
        }
        const v = @as(u64, @truncate(self.win)) & prefixMask(u64, n);
        self.win >>= n;
        self.have -= n;
        return v;
    }
};

/// Word-packed bit set over a caller-owned `[]Word` — one namespace per word
/// width (`Field(u64)` for the engine masks, `Field(u8)` for sais' 1-bit
/// suffix-type map). All operations are branch-light and O(1) except the
/// whole-set queries (`none`/`count`/`first`), which are one linear pass.
pub fn Field(comptime Word: type) type {
    comptime std.debug.assert(@typeInfo(Word).int.signedness == .unsigned);
    const width = @bitSizeOf(Word);
    return struct {
        /// Words needed to hold `nbits` flags.
        pub fn words(nbits: usize) usize {
            return (nbits + (width - 1)) / width;
        }

        inline fn one(i: usize) Word {
            return @as(Word, 1) << @intCast(i % width);
        }

        pub fn set(bits: []Word, i: usize) void {
            bits[i / width] |= one(i);
        }

        pub fn clear(bits: []Word, i: usize) void {
            bits[i / width] &= ~one(i);
        }

        /// Set every bit in [lo, hi] (inclusive) with word-wide masks: the
        /// partial edge words get a `prefixMask` intersection, the interior
        /// words a single all-ones store — O(words touched), not O(bits),
        /// where the naive per-bit loop pays hi−lo iterations (256 for a
        /// full byte-class fill).
        pub fn setRange(bits: []Word, lo: usize, hi: usize) void {
            std.debug.assert(lo <= hi);
            const wlo = lo / width;
            const whi = hi / width;
            const mlo = ~prefixMask(Word, lo % width); // bits ≥ lo within its word
            const mhi = prefixMask(Word, hi % width + 1); // bits ≤ hi within its word
            if (wlo == whi) {
                bits[wlo] |= mlo & mhi;
                return;
            }
            bits[wlo] |= mlo;
            @memset(bits[wlo + 1 .. whi], std.math.maxInt(Word));
            bits[whi] |= mhi;
        }

        pub fn get(bits: []const Word, i: usize) bool {
            return bits[i / width] & one(i) != 0;
        }

        /// No bit set anywhere.
        pub fn none(bits: []const Word) bool {
            return std.mem.allEqual(Word, bits, 0);
        }

        /// Total set bits (popcount over the words).
        pub fn count(bits: []const Word) usize {
            var n: usize = 0;
            for (bits) |w| n += @popCount(w);
            return n;
        }

        /// Index of the lowest set bit, or null when the set is empty.
        pub fn first(bits: []const Word) ?usize {
            for (bits, 0..) |w, wi| if (w != 0) return wi * width + @ctz(w);
            return null;
        }

        /// Ascending indices of every set bit — popcount steps, not nbits.
        pub fn ones(bits: []const Word) Iter {
            return .{ .bits = bits, .cur = if (bits.len == 0) 0 else bits[0] };
        }

        pub const Iter = struct {
            bits: []const Word,
            wi: usize = 0,
            cur: Word,

            pub fn next(self: *Iter) ?usize {
                while (self.cur == 0) {
                    self.wi += 1;
                    if (self.wi >= self.bits.len) return null;
                    self.cur = self.bits[self.wi];
                }
                const i = self.wi * width + @ctz(self.cur);
                self.cur &= self.cur - 1; // retire the lowest set bit
                return i;
            }
        };
    };
}

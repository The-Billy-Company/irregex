//! gist — first-byte scan acceleration: given the set of bytes that can BEGIN a
//! match (computed by `analysis.analyzeFirst`), find the next candidate position
//! in a line so the Pike scanner skips dead spans instead of re-seeding a closure
//! at every byte (the literal-prefilter trick rg uses). Pure byte hunting — no
//! NFA/`Regex` dependency, only `ByteSet`. Three tiers by set shape: SIMD
//! `indexOfScalar` for a singleton (`;$`), a SIMD range scan for a few contiguous
//! ranges (`[0-9]{4}`, `[a-f0-9]{2,}`), and a scalar byteset probe for anything
//! wider (a negated class). All accelerators are derived once at compile time;
//! `nextStart` is the verify-hot entry the scanner calls per skip.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const rarity = @import("../../scan/rarity.zig");
const bitsmod = @import("../../../primitives/bits.zig");
const ByteSet = syn.ByteSet;

const vlen: usize = std.simd.suggestVectorLength(u8) orelse 16;
const probability_scale: u32 = 32768;

/// A contiguous byte range `[lo, hi]`. The first-byte set decomposes into a
/// handful of these (`[0-9]`, `[a-f0-9]`, `\w`, the `{p,0}` of `panic|0x`), tested
/// by the scanner's skip loop with one SIMD compare per range, not a scalar
/// byteset probe per byte.
const Range = struct { lo: u8, hi: u8 };
const max_ranges = 8; // rare 4–8 byte sets still earn a vector equality/range scan

/// Shared, corpus-priced economics for every machine considering a byte-set
/// prefilter. `mass` is a fixed-point probability over `probability_scale`;
/// `stride` is the expected distance between candidates. The density source is
/// the same checked-in Billy-corpus prior used by the substring kernel.
pub const Economics = struct {
    mass: u16,
    stride: u16,

    /// A full-byte machine should stand down only when the prefilter is expected
    /// to skip at least `minimum_stride` bytes per candidate. This is deliberately
    /// one fact shared by DFA acceleration, Compose, Parabix, and Sieve.
    pub fn beatsDense(self: Economics, minimum_stride: u16) bool {
        return self.stride >= minimum_stride;
    }
};

/// The set of bytes that can begin a match, plus the precomputed accelerators
/// that pick the cheapest sound skip strategy for its shape. Built once per
/// `Regex` from the first-byte `ByteSet`; immutable thereafter.
pub const Prefilter = struct {
    set: ByteSet,
    byte: ?u8, // sole member when singleton ⇒ SIMD `indexOfScalar`
    ranges: [max_ranges]Range,
    nranges: u8, // 0 ⇒ singleton (memchr) or too-many-ranges (scalar probe)
    economics: Economics,

    /// Derive the accelerators from the first-byte `set`. The SIMD range scan
    /// earns its keep only without a singleton memchr; null (`>max_ranges`) falls
    /// back to the scalar byteset probe.
    pub fn init(set: ByteSet) Prefilter {
        const single = set.only();
        var ranges: [max_ranges]Range = undefined;
        const nranges: u8 = if (single != null) 0 else firstRanges(set, &ranges) orelse 0;
        return .{
            .set = set,
            .byte = single,
            .ranges = ranges,
            .nranges = nranges,
            .economics = estimate(set),
        };
    }

    pub fn count(self: *const Prefilter) usize {
        return self.set.count();
    }

    pub fn has(self: *const Prefilter, b: u8) bool {
        return self.set.has(b);
    }

    /// Next index ≥ `from` whose byte can begin a match. Three tiers: SIMD
    /// `indexOfScalar` for a singleton set (`;$`), a SIMD range scan for a few
    /// contiguous ranges (`[0-9]{4}`, `[a-f0-9]{2,}`), and a scalar byteset probe
    /// for anything wider (a negated class).
    pub fn nextStart(self: *const Prefilter, line: []const u8, from: usize) ?usize {
        if (self.byte) |b| return std.mem.indexOfScalarPos(u8, line, from, b);
        if (self.nranges > 0) return self.nextStartRange(line, from);
        return self.scalarFirst(line, from);
    }

    /// Scalar fallback: first index ≥ `from` whose byte is in `set` (wide sets,
    /// e.g. a negated class, where neither memchr nor the range scan applies).
    fn scalarFirst(self: *const Prefilter, line: []const u8, from: usize) ?usize {
        var i = from;
        while (i < line.len) : (i += 1) if (self.set.has(line[i])) return i;
        return null;
    }

    /// Vectorized hunt for the first byte falling in any of `ranges`: one
    /// `lo ≤ b ≤ hi` compare per range across a `vlen`-wide window, OR the lane
    /// masks, take the lowest set lane. The scalar tail handles the remainder.
    fn nextStartRange(self: *const Prefilter, line: []const u8, from: usize) ?usize {
        const Vec = @Vector(vlen, u8);
        const Mask = std.meta.Int(.unsigned, vlen);
        const ranges = self.ranges[0..self.nranges];
        var i = from;
        while (i + vlen <= line.len) : (i += vlen) {
            const blk: Vec = line[i..][0..vlen].*;
            var hit: @Vector(vlen, bool) = @splat(false);
            for (ranges) |rg| {
                const lo: Vec = @splat(rg.lo);
                const hi: Vec = @splat(rg.hi);
                hit |= (blk >= lo) & (blk <= hi);
            }
            const bits: Mask = bitsmod.laneMask(Mask, hit);
            if (bits != 0) return i + @ctz(bits);
        }
        return self.scalarFirst(line, i);
    }

    /// Decompose a byte set into contiguous `[lo,hi]` ranges; null past
    /// `max_ranges` (the scalar probe then beats that many SIMD compares/chunk).
    fn firstRanges(set: ByteSet, out: *[max_ranges]Range) ?u8 {
        var n: u8 = 0;
        var c: usize = 0;
        while (c < 256) {
            if (!set.has(@intCast(c))) {
                c += 1;
                continue;
            }
            const lo: u8 = @intCast(c);
            while (c < 256 and set.has(@intCast(c))) c += 1;
            if (n == max_ranges) return null;
            out[n] = .{ .lo = lo, .hi = @intCast(c - 1) };
            n += 1;
        }
        return n;
    }
};

/// Price a candidate-byte set against the checked-in corpus prior. Saturated
/// `density` cells are intentionally expanded: 255 means "at least this common",
/// not 255/32768 exactly, and treating it as the latter is what made two common
/// letters look selective. Zero cells retain one unit so unseen bytes have a
/// finite, conservative stride rather than infinity.
pub fn estimate(set: ByteSet) Economics {
    var mass: u32 = 0;
    for (0..256) |i| if (set.has(@intCast(i))) {
        const d = rarity.density[i];
        mass += if (d == 255) 2048 else @max(@as(u32, d), 1);
    };
    mass = @min(mass, probability_scale);
    const stride: u32 = if (mass == 0) probability_scale else @max(1, probability_scale / mass);
    return .{ .mass = @intCast(mass), .stride = @intCast(@min(stride, std.math.maxInt(u16))) };
}

test "economics distinguishes a common byte from a rare set" {
    var common: ByteSet = .{};
    common.set(' '); // saturated in the corpus prior ⇒ dense, no skip earned
    var rare: ByteSet = .{};
    // Genuinely rare in the checked-in density table (J=9, Q=12, Z=7). NOT `_`,
    // which is saturated-common in code identifiers — a rare set of common bytes
    // is exactly the trap `estimate` exists to price out.
    for ("JQZ") |b| rare.set(b);
    try std.testing.expect(!estimate(common).beatsDense(32));
    try std.testing.expect(estimate(rare).beatsDense(32));
}

//! gist — Teddy SIMD multi-literal prefilter (Hyperscan's algorithm, as in
//! ripgrep's `aho-corasick`).
//!
//! Why this exists (proven, not assumed — see the load-count arithmetic below):
//! the fused first+last gate in `simd.zig` (`containsAny`/`indexOfAnyPos`) does
//! ONE shared first-byte load plus ONE last-byte load *per needle* per block —
//! `1 + N` loads. Those scans are load-port bound (the same fact that makes the
//! single-load byte kernels widen well), so the per-block cost grows linearly
//! in the alternation size: an 8-way `func|const|return|…` union pays 9 loads a
//! block. Teddy collapses that to a **constant 2 loads per block regardless of
//! N** by pre-baking every needle's leading bytes into nibble→bucket lookup
//! tables and resolving all N with one `tbl`/`pshufb` shuffle each.
//!
//! The scheme (slim Teddy, one bucket per needle, ≤ 8 needles): assign needle
//! `b` the bucket bit `1 << b`. For byte position `p ∈ {0,1}` build two 16-entry
//! tables keyed by a byte's low / high nibble, each cell the OR of the buckets
//! whose needle has that nibble at position `p`. Per 16-byte block: shuffle the
//! block's low- and high-nibble vectors through the position-0 tables and AND —
//! each lane now holds the buckets whose needle's *first* byte equals that lane.
//! Repeat for the block shifted by one byte against the position-1 tables and
//! AND in — surviving lanes have needles whose first TWO bytes match. Nonzero
//! lanes are candidates; each pays one `eql` verify. Two leading bytes give the
//! same selectivity class as the fused first+last gate, so the verify rate is
//! comparable while the load count stops growing with N.
//!
//! Fixed 16-wide (NEON `tbl` / SSSE3 `pshufb` are 16-byte; the win is the
//! load-count collapse, not vector width). Byte-exact leftmost with
//! `std.mem.indexOf` — proven by the differential fuzz in `simd_test.zig`.

const std = @import("std");
const builtin = @import("builtin");
const bitsmod = @import("../../primitives/bits.zig");

const V16 = @Vector(16, u8);
const Lane = u16; // one bit per 16-byte-block lane

/// Max needles: one bucket bit per needle in a `u8` bucket mask.
pub const max_buckets: usize = 8;

/// 16-wide runtime byte shuffle: `out[i] = table[idx[i]]` for `idx[i] ∈ 0..15`
/// (all callers mask/shift indices into range, so the arch high-bit lane-zeroing
/// never fires). One NEON `tbl` / SSSE3 `pshufb`; a scalar gather elsewhere.
inline fn shuffle(table: V16, idx: V16) V16 {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => asm ("tbl %[o].16b, {%[t].16b}, %[i].16b"
            : [o] "=w" (-> V16),
            : [t] "w" (table),
              [i] "w" (idx),
        ),
        .x86_64 => asm ("pshufb %[i], %[o]"
            : [o] "=x" (-> V16),
            : [t] "0" (table),
              [i] "x" (idx),
        ),
        else => blk: {
            var out: [16]u8 = undefined;
            const t: [16]u8 = table;
            const ix: [16]u8 = idx;
            for (0..16) |k| out[k] = t[ix[k] & 0x0F];
            break :blk out;
        },
    };
}

/// A prepared multi-literal prefilter over the first two bytes of ≤ 8 needles.
/// Borrows `needles` for the survivor verify; valid for the scan call's extent.
pub const Teddy = struct {
    lo0: V16,
    hi0: V16,
    lo1: V16,
    hi1: V16,
    needles: []const []const u8,

    /// Prepare Teddy for `needles`, or `null` if the set is ineligible
    /// (fewer than 2, more than `max_buckets`, or any needle under 2 bytes) —
    /// exactly the fused gate's eligibility, so the caller keeps its path.
    pub fn init(needles: []const []const u8) ?Teddy {
        if (needles.len < 2 or needles.len > max_buckets) return null;
        for (needles) |n| if (n.len < 2) return null;

        var lo0 = [_]u8{0} ** 16;
        var hi0 = [_]u8{0} ** 16;
        var lo1 = [_]u8{0} ** 16;
        var hi1 = [_]u8{0} ** 16;
        for (needles, 0..) |n, b| {
            const bit = @as(u8, 1) << @intCast(b);
            lo0[n[0] & 0x0F] |= bit;
            hi0[n[0] >> 4] |= bit;
            lo1[n[1] & 0x0F] |= bit;
            hi1[n[1] >> 4] |= bit;
        }
        return .{ .lo0 = lo0, .hi0 = hi0, .lo1 = lo1, .hi1 = hi1, .needles = needles };
    }

    /// Leftmost occurrence of any needle at or after `from`, byte-exact with the
    /// minimum of `std.mem.indexOfPos` across the set. `null` when none occur.
    pub fn find(self: Teddy, hay: []const u8, from: usize) ?usize {
        const low: V16 = @splat(0x0F);
        const four: V16 = @splat(4);
        const zero: V16 = @splat(0);
        var i: usize = from;
        // Windows [i, i+16) and [i+1, i+17) both stay in bounds.
        while (i + 17 <= hay.len) : (i += 16) {
            const b0: V16 = hay[i..][0..16].*;
            const b1: V16 = hay[i + 1 ..][0..16].*;
            const c = shuffle(self.lo0, b0 & low) & shuffle(self.hi0, b0 >> four) &
                shuffle(self.lo1, b1 & low) & shuffle(self.hi1, b1 >> four);
            const cb: [16]u8 = c;
            var lanes = bitsmod.ones(@as(Lane, @bitCast(c != zero)));
            while (lanes.next()) |j| {
                const pos = i + j;
                var buckets = bitsmod.ones(cb[j]);
                while (buckets.next()) |b| {
                    const n = self.needles[b];
                    if (pos + n.len <= hay.len and std.mem.eql(u8, hay[pos..][0..n.len], n)) return pos;
                }
            }
        }
        // Scalar tail: leftmost start in [i, hay.len) the vector loop never saw.
        var best: ?usize = null;
        for (self.needles) |n| if (std.mem.indexOfPos(u8, hay, i, n)) |p| {
            if (best == null or p < best.?) best = p;
        };
        return best;
    }

    /// Presence — the bool `find` twin for whole-file gating.
    pub fn contains(self: Teddy, hay: []const u8) bool {
        return self.find(hay, 0) != null;
    }
};

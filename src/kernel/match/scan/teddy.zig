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
//! The scheme (slim Teddy, eight buckets per group, ≤ 64 needles): within each
//! group assign needle `b` the bucket bit `1 << b`. For byte position
//! `p ∈ {0,1}` build two 16-entry tables keyed by a byte's low / high nibble,
//! each cell the OR of matching buckets. Per 16-byte block, every group reuses
//! the same two haystack loads; nibble shuffles recover the needles whose first
//! two bytes match, then only survivors pay `eql`. Additional groups therefore
//! add register-table work, never another pass or another haystack load.
//!
//! Fixed 16-wide (NEON `tbl` / SSSE3 `pshufb` are 16-byte; the win is the
//! load-count collapse, not vector width). Byte-exact leftmost with
//! `std.mem.indexOf` — proven by the differential fuzz in `simd_test.zig`.

const std = @import("std");
const bitsmod = @import("../../primitives/bits.zig");
const lanes = @import("../regex/linear/compose/lanes.zig");

const V16 = lanes.Vec;
const Lane = u16; // one bit per 16-byte-block lane

/// Eight bucket bits per nibble table, with up to eight independent groups.
pub const buckets_per_group: usize = 8;
pub const max_buckets: usize = 64;
const max_groups = max_buckets / buckets_per_group;

const Group = struct {
    lo0: V16,
    hi0: V16,
    lo1: V16,
    hi1: V16,

    inline fn candidates(self: Group, b0: V16, b1: V16, low: V16, four: V16) V16 {
        return lanes.shuffle(self.lo0, b0 & low) & lanes.shuffle(self.hi0, b0 >> four) &
            lanes.shuffle(self.lo1, b1 & low) & lanes.shuffle(self.hi1, b1 >> four);
    }
};

/// A prepared multi-literal prefilter over the first two bytes of 2–64 needles.
/// Borrows `needles` for the survivor verify; valid for the scan call's extent.
pub const Teddy = struct {
    groups: [max_groups]Group,
    group_count: u8,
    needles: []const []const u8,

    /// Prepare Teddy for `needles`, or `null` if the set is ineligible
    /// (fewer than 2, more than `max_buckets`, or any needle under 2 bytes) —
    /// short sets stay on the caller's byte-exact fallback.
    pub fn init(needles: []const []const u8) ?Teddy {
        if (needles.len < 2 or needles.len > max_buckets) return null;
        for (needles) |n| if (n.len < 2) return null;

        var groups: [max_groups]Group = undefined;
        // `buckets_per_group` (8) is a fixed nonzero comptime divisor and
        // `needles.len` is already bounded to `[2, max_buckets]` above, so this
        // is plain ceiling division — no fallible `std.math.divCeil` needed.
        const group_count = (needles.len - 1) / buckets_per_group + 1;
        for (0..group_count) |g| {
            var lo0 = [_]u8{0} ** 16;
            var hi0 = [_]u8{0} ** 16;
            var lo1 = [_]u8{0} ** 16;
            var hi1 = [_]u8{0} ** 16;
            const base = g * buckets_per_group;
            for (needles[base..@min(base + buckets_per_group, needles.len)], 0..) |n, b| {
                const bit = @as(u8, 1) << @intCast(b);
                lo0[n[0] & 0x0F] |= bit;
                hi0[n[0] >> 4] |= bit;
                lo1[n[1] & 0x0F] |= bit;
                hi1[n[1] >> 4] |= bit;
            }
            groups[g] = .{ .lo0 = lo0, .hi0 = hi0, .lo1 = lo1, .hi1 = hi1 };
        }
        return .{ .groups = groups, .group_count = @intCast(group_count), .needles = needles };
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
            var candidates: [max_groups][16]u8 = undefined;
            var occupied: @Vector(16, bool) = @splat(false);
            for (self.groups[0..self.group_count], 0..) |group, g| {
                const group_candidates = group.candidates(b0, b1, low, four);
                candidates[g] = group_candidates;
                occupied |= group_candidates != zero;
            }
            var hit_lanes = bitsmod.ones(@as(Lane, @bitCast(occupied)));
            while (hit_lanes.next()) |j| {
                const pos = i + j;
                for (candidates[0..self.group_count], 0..) |group_candidates, g| {
                    var buckets = bitsmod.ones(group_candidates[j]);
                    while (buckets.next()) |b| {
                        const n = self.needles[g * buckets_per_group + b];
                        if (pos + n.len <= hay.len and std.mem.eql(u8, hay[pos..][0..n.len], n)) return pos;
                    }
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

test "grouped Teddy holds block seams and 8/64 boundaries" {
    const needles8 = [_][]const u8{ "aa0", "aa1", "aa2", "aa3", "aa4", "aa5", "aa6", "target" };
    const needles64 = comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: [64][]const u8 = undefined;
        for (&out, 0..) |*n, i| n.* = std.fmt.comptimePrint("needle-{d:0>2}", .{i});
        break :blk out;
    };
    var hay = [_]u8{'x'} ** 96;
    @memcpy(hay[15..21], "target");
    try std.testing.expectEqual(@as(?usize, 15), Teddy.init(&needles8).?.find(&hay, 0));
    @memcpy(hay[47..56], "needle-63");
    try std.testing.expectEqual(@as(?usize, 47), Teddy.init(&needles64).?.find(&hay, 16));
}

test "grouped Teddy rejects short and over-cap sets" {
    const short = [_][]const u8{ "ab", "x" };
    const over = [_][]const u8{"ab"} ** 65;
    try std.testing.expect(Teddy.init(&short) == null);
    try std.testing.expect(Teddy.init(&over) == null);
}

test "grouped Teddy differential survives dense candidates" {
    const needles = comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: [64][]const u8 = undefined;
        for (&out, 0..) |*n, i| n.* = std.fmt.comptimePrint("aa{d:0>4}", .{i});
        break :blk out;
    };
    const teddy = Teddy.init(&needles).?;
    var prng = std.Random.DefaultPrng.init(0x7eddd1ff);
    const random = prng.random();
    var hay: [257]u8 = undefined;
    for (0..128) |_| {
        @memset(&hay, 'a');
        const chosen = random.uintLessThan(usize, needles.len);
        if (random.boolean()) {
            const at = random.uintLessThan(usize, hay.len - needles[chosen].len + 1);
            @memcpy(hay[at..][0..needles[chosen].len], needles[chosen]);
        }
        const from = random.uintLessThan(usize, hay.len + 1);
        var expected: ?usize = null;
        for (needles) |needle| if (std.mem.indexOfPos(u8, &hay, from, needle)) |position| {
            if (expected == null or position < expected.?) expected = position;
        };
        try std.testing.expectEqual(expected, teddy.find(&hay, from));
    }
}

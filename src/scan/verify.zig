//! gist bench — data-parallel verify (the half of the head-to-head that has to
//! out-throughput ripgrep's multi-core scan). The trigram filter is cheap and
//! single-threaded; the *bytes* are in the candidate verify (and the <3-byte
//! full-scan fallback), so that is what fans out across cores. Split from
//! `bench.zig` to keep each file under the shape cap; the corpus-aware
//! `gistMatches` wrapper stays in `bench.zig` and calls in here.

const std = @import("std");
const simd = @import("simd.zig");

pub const par_threshold = 512; // below this candidate count, threading isn't worth it

/// SIMD first+last-byte scan — ~18x std's naive 2–4 byte path (see `simd.zig`).
pub inline fn contains(hay: []const u8, needle: []const u8) bool {
    return simd.contains(hay, needle);
}

const VerifyShard = struct {
    docs: []const []const u8,
    ids: []const u32,
    needle: []const u8,
    out: []u32, // private region (≤ ids.len), no contention
    n: usize = 0,
};

fn verifyShard(sh: *VerifyShard) void {
    var w: usize = 0;
    for (sh.ids) |d| if (contains(sh.docs[d], sh.needle)) {
        sh.out[w] = d;
        w += 1;
    };
    sh.n = w;
}

/// Verify `ids` against `needle`, fanning out across cores when the candidate
/// set is large. Sharding is **byte-balanced** (each thread gets ~equal total
/// bytes, not equal file count) so a few large files can't stall one thread
/// while the rest idle — the load-imbalance that capped the earlier speedup.
/// Thread count scales with total bytes (~one per 512 KiB). Results are
/// appended unordered (callers that need a set sort afterward).
pub fn parallelVerify(gpa: std.mem.Allocator, docs: []const []const u8, ids: []const u32, needle: []const u8, out: *std.ArrayList(u32)) !void {
    var total: usize = 0;
    for (ids) |d| total += docs[d].len;

    const ncpu = std.Thread.getCpuCount() catch 1;
    var nthr = @max(@as(usize, 1), total / (512 * 1024));
    nthr = @min(nthr, ncpu);
    if (ids.len < par_threshold or nthr <= 1) {
        for (ids) |d| if (contains(docs[d], needle)) try out.append(gpa, d);
        return;
    }

    // Byte-greedy boundaries over the (arbitrary-order) candidate list.
    const bounds = try gpa.alloc(usize, nthr + 1);
    defer gpa.free(bounds);
    const target = total / nthr;
    bounds[0] = 0;
    var b: usize = 1;
    var acc: usize = 0;
    for (ids, 0..) |d, i| {
        acc += docs[d].len;
        if (b < nthr and acc >= target * b) {
            bounds[b] = i + 1;
            b += 1;
        }
    }
    while (b <= nthr) : (b += 1) bounds[b] = ids.len;

    const shards = try gpa.alloc(VerifyShard, nthr);
    defer gpa.free(shards);
    const threads = try gpa.alloc(std.Thread, nthr);
    defer gpa.free(threads);
    const outbuf = try gpa.alloc(u32, ids.len);
    defer gpa.free(outbuf);

    for (0..nthr) |t| {
        const lo = bounds[t];
        const hi = bounds[t + 1];
        shards[t] = .{ .docs = docs, .ids = ids[lo..hi], .needle = needle, .out = outbuf[lo..hi] };
        threads[t] = try std.Thread.spawn(.{}, verifyShard, .{&shards[t]});
    }
    for (0..nthr) |t| threads[t].join();
    for (0..nthr) |t| try out.appendSlice(gpa, shards[t].out[0..shards[t].n]);
}

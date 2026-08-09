//! rrr — `Plain`, `Rrr`, and the `Bits` seam between them, proved three ways:
//!
//!   1. Every encoding's `rank1`/`get` differential-tested against a naive
//!      prefix-popcount oracle, swept across a battery of bit patterns
//!      (all-zero, all-one, alternating, uniform random, BWT-shaped runs,
//!      near-extreme-class scatter) and across the BLOCK(63)/SUPER(1008-bit)
//!      boundary sweep — including the `nblocks % SUPER == 0` trailing
//!      superblock sample `fromPlain`/`fromParts` only take on some lengths.
//!   2. Persistence round-trips: `Plain.fromWords` and `Rrr.fromParts`
//!      rebuild byte-identical answers from a duplicated copy of what
//!      `finalize`/`fromPlain` produced — the exact shape a caller reloading
//!      a mmap'd or on-disk index exercises.
//!   3. Fails closed: `fromWords`/`fromParts` reject a truncated or padded
//!      stream, and `fromParts` rejects a block whose stored popcount
//!      exceeds its own bit width — before rank/get can read past the data
//!      that's actually there.
//!
//! `Rrr` vs `Plain` agreement here is the standalone proof of what
//! `codex_test.zig` otherwise only exercises indirectly through a live
//! FM-index; `Bits.adopt` is checked to answer correctly regardless of which
//! of the two encodings it picked.

const std = @import("std");
const rrr = @import("rrr.zig");

const t = std.testing;

// ── shared fixtures ──

fn patternLens() []const usize {
    return &.{ 0, 1, 5, 63, 64, 65, 126, 127, 128, 1000, 1008, 1009, 2016, 5000 };
}

fn allZero(gpa: std.mem.Allocator, n: usize) ![]u1 {
    const b = try gpa.alloc(u1, n);
    @memset(b, 0);
    return b;
}

fn allOne(gpa: std.mem.Allocator, n: usize) ![]u1 {
    const b = try gpa.alloc(u1, n);
    @memset(b, 1);
    return b;
}

fn alternating(gpa: std.mem.Allocator, n: usize) ![]u1 {
    const b = try gpa.alloc(u1, n);
    for (b, 0..) |*v, i| v.* = @intCast(i & 1);
    return b;
}

fn randomBits(gpa: std.mem.Allocator, n: usize, seed: u64) ![]u1 {
    const b = try gpa.alloc(u1, n);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    for (b) |*v| v.* = @intFromBool(rand.boolean());
    return b;
}

/// BWT-shaped: long runs of one value, the shape the module doc names as
/// what RRR is measured against (runs make blocks extreme-class).
fn skewedRuns(gpa: std.mem.Allocator, n: usize, seed: u64) ![]u1 {
    const b = try gpa.alloc(u1, n);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var i: usize = 0;
    var v: u1 = 0;
    while (i < n) {
        const run = @min(n - i, rand.intRangeAtMost(usize, 1, 200));
        @memset(b[i .. i + run], v);
        i += run;
        v ^= 1;
    }
    return b;
}

/// Mostly-ones with a handful of scattered zero flips per 63-bit block —
/// biases classes toward the high end (61-63) with varied, non-canonical
/// offsets, which `scanBlock`'s "k == 63-pos, forced ones" early exit and its
/// general combinadic walk both need to agree with a plain scan on (a purely
/// canonical offset-0 block, as `allOne` produces, can never reach that walk).
fn nearExtreme(gpa: std.mem.Allocator, n: usize, seed: u64) ![]u1 {
    const b = try gpa.alloc(u1, n);
    @memset(b, 1);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var block_start: usize = 0;
    while (block_start < n) {
        const block_end = @min(block_start + 63, n);
        const width = block_end - block_start;
        const flips = rand.intRangeAtMost(usize, 0, 3);
        for (0..flips) |_| b[block_start + rand.uintLessThan(usize, width)] = 0;
        block_start = block_end;
    }
    return b;
}

fn buildPlain(gpa: std.mem.Allocator, nbits: usize, pattern: []const u1) !rrr.Plain {
    var p = try rrr.Plain.initEmpty(gpa, nbits);
    for (pattern, 0..) |b, i| {
        if (b == 1) p.set(i);
    }
    try p.finalize(gpa);
    return p;
}

/// Differential check against the ground truth: a running prefix-popcount
/// scan. Works against `Plain`, `Rrr`, or `Bits` — all three share the same
/// `rank1(pos)`/`get(pos)` shape.
fn checkAgainstOracle(v: anytype, pattern: []const u1) !void {
    var running: usize = 0;
    for (pattern, 0..) |b, pos| {
        try t.expectEqual(running, v.rank1(pos));
        try t.expectEqual(@as(u1, b), v.get(pos));
        running += b;
    }
    try t.expectEqual(running, v.rank1(pattern.len));
}

fn allPatterns(gpa: std.mem.Allocator, n: usize) ![5][]u1 {
    return .{
        try allZero(gpa, n),
        try allOne(gpa, n),
        try alternating(gpa, n),
        try randomBits(gpa, n, 0x1234 +% n),
        try skewedRuns(gpa, n, 0x5678 +% n),
    };
}

// ── Plain ──

test "Plain: agrees with the oracle across the word/superblock boundary sweep" {
    const gpa = t.allocator;
    for (patternLens()) |n| {
        const patterns = try allPatterns(gpa, n);
        defer for (patterns) |p| gpa.free(p);
        for (patterns) |pattern| {
            var plain = try buildPlain(gpa, n, pattern);
            defer plain.deinit(gpa);
            try checkAgainstOracle(&plain, pattern);
        }
    }
}

test "Plain.fromWords: reloads byte-identically from a duplicated words buffer" {
    const gpa = t.allocator;
    for (patternLens()) |n| {
        const pattern = try skewedRuns(gpa, n, 0x9001 +% n);
        defer gpa.free(pattern);
        var original = try buildPlain(gpa, n, pattern);
        const words_copy = try gpa.dupe(u64, original.words);
        original.deinit(gpa);

        var reloaded = try rrr.Plain.fromWords(gpa, words_copy, n);
        defer reloaded.deinit(gpa);
        try checkAgainstOracle(&reloaded, pattern);
    }
}

test "Plain.fromWords: rejects a words buffer whose length doesn't match nbits" {
    const gpa = t.allocator;
    const nbits: usize = 200; // expects (200+63)/64+1 = 5 words
    {
        const too_short = try gpa.alloc(u64, 4);
        defer gpa.free(too_short);
        @memset(too_short, 0);
        try t.expectError(error.Corrupt, rrr.Plain.fromWords(gpa, too_short, nbits));
    }
    {
        const too_long = try gpa.alloc(u64, 6);
        defer gpa.free(too_long);
        @memset(too_long, 0);
        try t.expectError(error.Corrupt, rrr.Plain.fromWords(gpa, too_long, nbits));
    }
}

// ── Rrr ──

test "Rrr.fromPlain: agrees with Plain at every position, across the block/superblock sweep" {
    const gpa = t.allocator;
    for (patternLens()) |n| {
        const fixed = try allPatterns(gpa, n);
        defer for (fixed) |p| gpa.free(p);
        const extreme = try nearExtreme(gpa, n, 0xABCD +% n);
        defer gpa.free(extreme);

        for (fixed ++ .{extreme}) |pattern| {
            var plain = try buildPlain(gpa, n, pattern);
            defer plain.deinit(gpa);
            var coded = try rrr.Rrr.fromPlain(gpa, &plain);
            defer coded.deinit(gpa);
            try checkAgainstOracle(&coded, pattern);
        }
    }
}

test "Rrr.fromParts: reloads byte-identically from duplicated class/offset streams" {
    const gpa = t.allocator;
    for (patternLens()) |n| {
        const pattern = try skewedRuns(gpa, n, 0xC0DE +% n);
        defer gpa.free(pattern);
        var plain = try buildPlain(gpa, n, pattern);
        defer plain.deinit(gpa);
        var original = try rrr.Rrr.fromPlain(gpa, &plain);
        const classes_copy = try gpa.dupe(u64, original.classes);
        const offsets_copy = try gpa.dupe(u64, original.offsets);
        original.deinit(gpa);

        var reloaded = try rrr.Rrr.fromParts(gpa, classes_copy, offsets_copy, n);
        defer reloaded.deinit(gpa);
        try checkAgainstOracle(&reloaded, pattern);
    }
}

/// Overwrite one block's packed 6-bit class field in place (LSB-first, the
/// layout `Rrr.fromPlain`/`classAt` use). Only ever called with a low block
/// index in this file, so it never needs to straddle a word boundary.
fn writeClass(classes: []u64, block: usize, class: u6) void {
    const bitpos = block * 6;
    const w = bitpos / 64;
    const sh: u6 = @intCast(bitpos % 64);
    std.debug.assert(sh <= 58);
    const mask: u64 = @as(u64, 0x3f) << sh;
    classes[w] = (classes[w] & ~mask) | (@as(u64, class) << sh);
}

test "Rrr.fromParts: fails closed on truncated streams and an out-of-range class" {
    const gpa = t.allocator;
    const n: usize = 100; // nblocks=2, last block width = 100-63 = 37
    const pattern = try skewedRuns(gpa, n, 0xBEEF);
    defer gpa.free(pattern);
    var plain = try buildPlain(gpa, n, pattern);
    defer plain.deinit(gpa);
    var baseline = try rrr.Rrr.fromPlain(gpa, &plain);
    defer baseline.deinit(gpa);

    // truncated classes stream: caught by the structural length check alone
    {
        const classes = try gpa.dupe(u64, baseline.classes[0 .. baseline.classes.len - 1]);
        const offsets = try gpa.dupe(u64, baseline.offsets);
        try t.expectError(error.Corrupt, rrr.Rrr.fromParts(gpa, classes, offsets, n));
        gpa.free(classes);
        gpa.free(offsets);
    }
    // padded (too-long) classes stream: same check, other direction
    {
        const classes = try gpa.alloc(u64, baseline.classes.len + 1);
        @memcpy(classes[0..baseline.classes.len], baseline.classes);
        classes[baseline.classes.len] = 0;
        const offsets = try gpa.dupe(u64, baseline.offsets);
        try t.expectError(error.Corrupt, rrr.Rrr.fromParts(gpa, classes, offsets, n));
        gpa.free(classes);
        gpa.free(offsets);
    }
    // truncated offsets stream: caught after the class walk recomputes the
    // expected offset-stream length from (unmodified, valid) classes
    {
        const classes = try gpa.dupe(u64, baseline.classes);
        const offsets = try gpa.dupe(u64, baseline.offsets[0 .. baseline.offsets.len - 1]);
        try t.expectError(error.Corrupt, rrr.Rrr.fromParts(gpa, classes, offsets, n));
        gpa.free(classes);
        gpa.free(offsets);
    }
    // an impossible class on the trailing partial block: popcount can't
    // exceed the block's own bit width (37), even though 40 is a
    // perfectly legal 6-bit field value
    {
        const classes = try gpa.dupe(u64, baseline.classes);
        writeClass(classes, 1, 40);
        const offsets = try gpa.dupe(u64, baseline.offsets);
        try t.expectError(error.Corrupt, rrr.Rrr.fromParts(gpa, classes, offsets, n));
        gpa.free(classes);
        gpa.free(offsets);
    }
}

// ── Bits (Plain/Rrr union) ──

test "Bits.adopt: rank1/get/nbits agree with the oracle regardless of which encoding won" {
    const gpa = t.allocator;
    for (patternLens()) |n| {
        const fixed = try allPatterns(gpa, n);
        defer for (fixed) |p| gpa.free(p);
        const extreme = try nearExtreme(gpa, n, 0x2222 +% n);
        defer gpa.free(extreme);

        for (fixed ++ .{extreme}) |pattern| {
            const plain = try buildPlain(gpa, n, pattern);
            var bits_ = try rrr.Bits.adopt(gpa, plain); // takes ownership of `plain`
            defer bits_.deinit(gpa);
            try t.expectEqual(n, bits_.nbits());
            try checkAgainstOracle(&bits_, pattern);
        }
    }
}

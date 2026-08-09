//! mix — proved against its own contract, since there is no second correct
//! hash to diff against.
//!
//! `finalize` is checked for the two properties every caller actually leans
//! on: determinism, and bijectivity over distinct u64 inputs (each of the
//! three xor-shift/odd-multiply passes is invertible mod 2^64, so the whole
//! composition can never force two distinct keys into the same slot — the
//! failure that would silently corrupt bottom-k selection), plus the
//! avalanche spread the docstring claims (a run of sequential, FNV-clustered
//! inputs still lands spread across the output space). `SliceCtx` is checked
//! against a naive linear-scan lookup oracle, at the widths it is actually
//! deployed at (`u32`, `u64` — `refine`, `dafsa`, `minterm`, the DFA/symbolic
//! determinizers) plus `u8` for generality, including the case it exists
//! for: two distinct allocations holding identical content must resolve to
//! the same entry.

const std = @import("std");
const mix = @import("mix.zig");

const t = std.testing;

// ── finalize ──

test "finalize: deterministic across repeated calls" {
    var prng = std.Random.DefaultPrng.init(0x51de);
    const rand = prng.random();
    for (0..500) |_| {
        const x = rand.int(u64);
        try t.expectEqual(mix.finalize(x), mix.finalize(x));
    }
}

test "finalize: bijective — sequential and random distinct inputs never collide" {
    // Each pass is (xor-shift, then multiply by an odd constant mod 2^64),
    // and multiplication by an odd constant is a bijection on Z/2^64Z (the
    // odd residues are exactly its units) — so the three-step composition is
    // a bijection with no way for two distinct u64s to land on one output.
    // Sequential inputs are the adversarial case named in the docstring:
    // FNV alone clusters short phrases in their low bits, which is exactly
    // what a naive seed-by-index probe would look like.
    var seen = std.AutoHashMap(u64, void).init(t.allocator);
    defer seen.deinit();
    for (0..20_000) |i| {
        const prev = try seen.fetchPut(mix.finalize(@intCast(i)), {});
        try t.expect(prev == null);
    }

    var seen_random = std.AutoHashMap(u64, void).init(t.allocator);
    defer seen_random.deinit();
    var seen_inputs = std.AutoHashMap(u64, void).init(t.allocator);
    defer seen_inputs.deinit();
    var prng = std.Random.DefaultPrng.init(0xf00d);
    const rand = prng.random();
    for (0..20_000) |_| {
        const x = rand.int(u64);
        if ((try seen_inputs.fetchPut(x, {})) != null) continue; // only distinct inputs prove bijectivity
        const prev = try seen_random.fetchPut(mix.finalize(x), {});
        try t.expect(prev == null);
    }
}

test "finalize: adversarial fixed points — zero, all-ones, single bits, alternating patterns" {
    var seen_x = std.AutoHashMap(u64, void).init(t.allocator);
    defer seen_x.deinit();
    var seen_out = std.AutoHashMap(u64, void).init(t.allocator);
    defer seen_out.deinit();

    // `1 << 0` below duplicates `fixed[1]` — checked for distinctness once,
    // via `seen_x`, rather than double-counting one input as two.
    const fixed = [_]u64{ 0, 1, std.math.maxInt(u64), 0xAAAA_AAAA_AAAA_AAAA, 0x5555_5555_5555_5555 };
    for (fixed) |x| {
        if ((try seen_x.fetchPut(x, {})) != null) continue;
        try t.expect((try seen_out.fetchPut(mix.finalize(x), {})) == null);
    }
    for (0..64) |bit| {
        const x = @as(u64, 1) << @intCast(bit);
        if ((try seen_x.fetchPut(x, {})) != null) continue;
        try t.expect((try seen_out.fetchPut(mix.finalize(x), {})) == null);
    }
    // never the identity, and never a trivial no-op on any of the above
    for (fixed) |x| try t.expect(mix.finalize(x) != x);
}

test "finalize: single input-bit flip changes roughly half the output bits (avalanche)" {
    var prng = std.Random.DefaultPrng.init(0xa7a1);
    const rand = prng.random();
    var total_diff: u64 = 0;
    var trials: u64 = 0;
    for (0..300) |_| {
        const x = rand.int(u64);
        const base = mix.finalize(x);
        for (0..64) |bit| {
            const flipped = mix.finalize(x ^ (@as(u64, 1) << @intCast(bit)));
            total_diff += @popCount(base ^ flipped);
            trials += 1;
        }
    }
    const avg = @as(f64, @floatFromInt(total_diff)) / @as(f64, @floatFromInt(trials));
    // A random oracle averages exactly 32 of 64; this is not one, so the band
    // is wide, but a band this wide is still incompatible with a mixer that
    // merely shuffles bits without truly spreading them (which would cluster
    // near a handful of fixed diff counts instead).
    try t.expect(avg > 24.0 and avg < 40.0);
}

test "finalize: sequential low-entropy input still spreads across the high byte of the output" {
    // The exact motivating scenario: short phrases hashed by FNV alone
    // cluster in the low bits, and `finalize` exists so bottom-k selection
    // still sees uniform keys. Proxy the claim directly — sequential input
    // (maximally clustered) must still spread across the OUTPUT's high byte,
    // which a mixer that only touched low bits would fail.
    var high_byte_seen = std.AutoHashMap(u8, void).init(t.allocator);
    defer high_byte_seen.deinit();
    for (0..4000) |i| {
        const h = mix.finalize(@intCast(i));
        try high_byte_seen.put(@intCast(h >> 56), {});
    }
    try t.expect(high_byte_seen.count() > 200); // of 256 possible values
}

// ── SliceCtx ──

test "SliceCtx: hash agrees with eql at every deployed width, and differs on real content changes" {
    inline for ([_]type{ u8, u32, u64 }) |T| {
        const Ctx = mix.SliceCtx(T);
        const ctx = Ctx{};
        var prng = std.Random.DefaultPrng.init(0x5117);
        const rand = prng.random();
        for (0..300) |_| {
            const len = rand.intRangeAtMost(usize, 0, 8);
            const a = try t.allocator.alloc(T, len);
            defer t.allocator.free(a);
            for (a) |*v| v.* = @intCast(rand.intRangeAtMost(u16, 0, 255));
            const b = try t.allocator.dupe(T, a); // same content, distinct allocation
            defer t.allocator.free(b);
            try t.expect(ctx.eql(a, b));
            try t.expectEqual(ctx.hash(a), ctx.hash(b));

            if (len > 0) {
                const c = try t.allocator.dupe(T, a);
                defer t.allocator.free(c);
                c[0] +%= 1; // guaranteed to differ in content
                try t.expect(!ctx.eql(a, c));
            }
        }
        // two independently-allocated empty slices are equal regardless of pointer
        const e1: []const T = &.{};
        const e2 = try t.allocator.alloc(T, 0);
        defer t.allocator.free(e2);
        try t.expect(ctx.eql(e1, e2));
        try t.expectEqual(ctx.hash(e1), ctx.hash(e2));
    }
}

/// Differential vs a naive linear-scan (content, id) oracle — the reference
/// definition of "same key" a slice-keyed map must reproduce, at whichever
/// width is under test.
fn sliceCtxDifferential(comptime T: type, gpa: std.mem.Allocator, seed: u64) !void {
    const Ctx = mix.SliceCtx(T);
    const Map = std.HashMap([]const T, u32, Ctx, std.hash_map.default_max_load_percentage);
    var map = Map.init(gpa);
    defer map.deinit();

    var owned: std.ArrayList([]T) = .empty;
    defer {
        for (owned.items) |s| gpa.free(s);
        owned.deinit(gpa);
    }
    const Entry = struct { key: []const T, id: u32 };
    var oracle: std.ArrayList(Entry) = .empty;
    defer oracle.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    for (0..600) |_| {
        const len = rand.intRangeAtMost(usize, 0, 5);
        const buf = try gpa.alloc(T, len);
        try owned.append(gpa, buf);
        // A tiny alphabet forces genuine content collisions ACROSS distinct
        // allocations — the exact interner scenario `SliceCtx` exists for.
        for (buf) |*v| v.* = @intCast(rand.intRangeAtMost(u16, 0, 3));

        var existing: ?u32 = null;
        for (oracle.items) |o| if (std.mem.eql(T, o.key, buf)) {
            existing = o.id;
            break;
        };

        if (existing) |id| {
            try t.expectEqual(id, map.get(buf).?);
        } else {
            const id: u32 = @intCast(oracle.items.len);
            try t.expect(map.get(buf) == null);
            try map.put(buf, id);
            try oracle.append(gpa, .{ .key = buf, .id = id });
        }
    }

    // A lookup with the SAME bytes in a brand-new allocation still resolves —
    // the whole reason `std` cannot be handed slice keys directly.
    for (oracle.items) |o| {
        const probe = try gpa.dupe(T, o.key);
        defer gpa.free(probe);
        try t.expectEqual(o.id, map.get(probe).?);
    }

    // Content that was never inserted is absent.
    const absent = [_]T{ 9, 9, 9, 9, 9, 9, 9 };
    try t.expect(map.get(absent[0..]) == null);
}

test "SliceCtx: interning differential at u8, u32, and u64" {
    try sliceCtxDifferential(u8, t.allocator, 0xA1);
    try sliceCtxDifferential(u32, t.allocator, 0xB2); // `refine`, `dafsa`
    try sliceCtxDifferential(u64, t.allocator, 0xC3); // `minterm`, the DFA/symbolic determinizers
}

//! irregex T0 index-loader LONG fuzz target — the nightly companion to the
//! CI-safe fuzz-lite in `trigram_load_test.zig`. It drives many more iterations
//! over a seed corpus (valid + malformed blobs + real built indexes) plus
//! aggressive mutations (bit flips, byte overwrites, truncation), asserting
//! three things on every input — matching the crate's deterministic-PRNG fuzz
//! convention (`simd_test.zig`, `regex/adversarial_test.zig`) rather than
//! `std.testing.fuzz`:
//!
//!   1. no panic / OOB / silent accept  — `fromBytes` either rejects with
//!      `Corrupt` or returns an index that queryLiteral can walk without
//!      tripping ReleaseSafe/Debug memory safety;
//!   2. accepted ⇒ canonical            — an INDEPENDENT re-walk (`safeCanonical`,
//!      not the loader's own `validateStructure`) must also accept it, so a bug
//!      that let the loader accept a noncanonical blob is caught;
//!   3. the two loaders agree           — `fromBytes` and `fromMappedBytes` accept
//!      or reject the same bytes.
//!
//! `fuzz_iters` below is the mutation budget — a CI-safe default that keeps
//! `zig build test` fast; bump it for a nightly/pre-release soak and run with
//! memory-safety on: `zig build test -Doptimize=ReleaseSafe`.

const std = @import("std");
const tri = @import("trigram.zig");
const vi = @import("../postings/varint.zig");

/// Mutation iterations per `zig build test`. Nightly soak: raise to millions.
pub const fuzz_iters: usize = 10_000;

fn serialize(a: std.mem.Allocator, idx: *const tri.Index) ![]u8 {
    const buf = try a.alloc(u8, idx.serializedSize());
    _ = idx.writeInto(buf);
    return buf;
}

/// Serialize an arbitrary (possibly malformed) blob — header little-endian, the
/// directory arrays native-endian `u32` (matches `writeInto`).
fn makeBlob(
    a: std.mem.Allocator,
    doc_count: u32,
    posting_count: u64,
    dir_tri: []const u32,
    dir_off: []const u32,
    dir_count: []const u32,
    body: []const u8,
) ![]u8 {
    const n = dir_tri.len;
    const buf = try a.alloc(u8, tri.header_len + n * 12 + body.len);
    @memcpy(buf[0..8], "GISTIDX\x01");
    std.mem.writeInt(u32, buf[8..][0..4], tri.format_version, .little);
    std.mem.writeInt(u32, buf[12..][0..4], doc_count, .little);
    std.mem.writeInt(u64, buf[16..][0..8], @intCast(n), .little);
    std.mem.writeInt(u64, buf[24..][0..8], posting_count, .little);
    var off: usize = tri.header_len;
    for (dir_tri) |v| {
        std.mem.writeInt(u32, buf[off..][0..4], v, .native);
        off += 4;
    }
    for (dir_off) |v| {
        std.mem.writeInt(u32, buf[off..][0..4], v, .native);
        off += 4;
    }
    for (dir_count) |v| {
        std.mem.writeInt(u32, buf[off..][0..4], v, .native);
        off += 4;
    }
    @memcpy(buf[off..][0..body.len], body);
    return buf;
}

/// Independent canonical re-walk of an ACCEPTED index (deliberately NOT the
/// loader's `validateStructure`, so a loader bug that accepts a noncanonical blob
/// is caught here). Uses only the index's public fields + the bounded decoder.
fn safeCanonical(idx: *const tri.Index) bool {
    const n = idx.dir_tri.len;
    if (idx.dir_off.len != n or idx.dir_count.len != n) return false;
    if (n == 0) return idx.body.len == 0 and idx.posting_count == 0;
    if (idx.dir_off[0] != 0) return false;
    var sum: u64 = 0;
    for (0..n) |i| {
        if (i > 0 and idx.dir_tri[i] <= idx.dir_tri[i - 1]) return false;
        if (idx.dir_count[i] == 0) return false;
        if (idx.dir_off[i] > idx.body.len) return false;
        const end = if (i + 1 < n) idx.dir_off[i + 1] else idx.body.len;
        if (end < idx.dir_off[i] or end > idx.body.len) return false;
        var pos: usize = idx.dir_off[i];
        var prev: u32 = 0;
        for (0..idx.dir_count[i]) |k| {
            const d = vi.decodeBoundedCanonical(idx.body[pos..end], vi.max_len) catch return false;
            pos += d.len;
            const doc: u32 = if (k == 0) d.value else blk: {
                if (d.value == 0) return false;
                break :blk std.math.add(u32, prev, d.value) catch return false;
            };
            if (doc >= idx.doc_count) return false;
            prev = doc;
        }
        if (pos != end) return false;
        sum += idx.dir_count[i];
    }
    return sum == idx.posting_count;
}

fn checkOne(a: std.mem.Allocator, bytes: []const u8) !void {
    const copy_ok = blk: {
        if (tri.Index.fromBytes(a, bytes)) |idx0| {
            var idx = idx0;
            defer idx.deinit();
            if (!safeCanonical(&idx)) return error.LoaderAcceptedNoncanonical;
            if (idx.queryLiteral(a, "abc") catch null) |got| a.free(got); // crash surface only
            break :blk true;
        } else |_| break :blk false;
    };
    const aligned = try a.alignedAlloc(u8, .fromByteUnits(@alignOf(u32)), bytes.len);
    defer a.free(aligned);
    @memcpy(aligned, bytes);
    const map_ok = blk: {
        if (tri.Index.fromMappedBytes(aligned)) |idx0| {
            var idx = idx0;
            defer idx.deinit();
            if (!safeCanonical(&idx)) return error.LoaderAcceptedNoncanonical;
            break :blk true;
        } else |_| break :blk false;
    };
    if (copy_ok != map_ok) return error.LoadersDisagree;
}

fn addBuilt(a: std.mem.Allocator, seeds: *std.ArrayList([]const u8), docs: []const []const u8) !void {
    var idx = try tri.Index.build(a, docs);
    defer idx.deinit();
    try seeds.append(a, try serialize(a, &idx));
}

test "fuzz: index loader survives seeds + mutations (long soak via fuzz_iters)" {
    const a = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(a);
    defer arena_inst.deinit();
    const ar = arena_inst.allocator();

    var seeds: std.ArrayList([]const u8) = .empty;
    // real built indexes: empty · one trigram/one doc · one trigram/many docs ·
    // many trigrams/sparse · zero-trigram with doc_count > 0 · a realistic corpus.
    try addBuilt(ar, &seeds, &.{});
    try addBuilt(ar, &seeds, &.{"abc"});
    try addBuilt(ar, &seeds, &.{ "abc", "abc", "abc", "xabc", "abcx" });
    try addBuilt(ar, &seeds, &.{ "the quick brown fox", "lazy dog", "quick brown" });
    try addBuilt(ar, &seeds, &.{ "a", "bb", "" }); // all < 3 bytes → zero trigrams, doc_count 3
    try addBuilt(ar, &seeds, &.{ "func main()", "return err", "for range xs" });
    // hand-built valid: a max-width (5-byte varint) doc id, in range.
    {
        var b: [8]u8 = undefined;
        const nb = vi.encode(b[0..], std.math.maxInt(u32) - 1);
        try seeds.append(ar, try makeBlob(ar, std.math.maxInt(u32), 1, &.{7}, &.{0}, &.{1}, b[0..nb]));
    }
    // deterministic malformed seeds (must be rejected; mutated around the boundary).
    try seeds.append(ar, try makeBlob(ar, 4, 1, &.{7}, &.{0}, &.{1}, &[_]u8{0x80})); // truncated varint
    try seeds.append(ar, try makeBlob(ar, 4, 1, &.{7}, &.{0}, &.{1}, &[_]u8{ 0x80, 0x00 })); // overlong
    try seeds.append(ar, try makeBlob(ar, 1, 1, &.{7}, &.{0}, &.{1}, &[_]u8{0x01})); // doc id >= doc_count
    try seeds.append(ar, try makeBlob(ar, 3, 2, &.{7}, &.{0}, &.{2}, &[_]u8{ 0x00, 0x00 })); // delta 0
    try seeds.append(ar, try makeBlob(ar, 1, 5, &.{7}, &.{0}, &.{1}, &[_]u8{0x00})); // sum != posting_count
    try seeds.append(ar, &[_]u8{0} ** 8); // sub-header garbage

    // 1. corpus replay (deterministic regression on every `zig build test`).
    for (seeds.items) |s| try checkOne(a, s);

    // 2. mutation fuzz — pick a seed, truncate + flip/overwrite bytes.
    var prng = std.Random.DefaultPrng.init(0x9151_F00D);
    const rng = prng.random();
    const iters = fuzz_iters;
    var it: usize = 0;
    while (it < iters) : (it += 1) {
        const seed = seeds.items[rng.uintLessThan(usize, seeds.items.len)];
        const keep = if (seed.len == 0) 0 else rng.uintLessThan(usize, seed.len) + 1; // truncation
        const m = try a.dupe(u8, seed[0..keep]);
        defer a.free(m);
        var k: u32 = 0;
        const nmut = rng.uintLessThan(u32, 4);
        while (k < nmut and m.len > 0) : (k += 1) {
            const pos = rng.uintLessThan(usize, m.len);
            if (rng.boolean()) {
                m[pos] ^= @as(u8, 1) << @intCast(rng.uintLessThan(u32, 8));
            } else {
                m[pos] = rng.int(u8);
            }
        }
        try checkOne(a, m);
    }
}

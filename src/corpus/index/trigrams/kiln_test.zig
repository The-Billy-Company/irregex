//! kiln's proof: the block builder's four CSR regions, judged against the FORMAT
//! rather than against another run of the code under test.
//!
//! The oracle here is written from `trigram.zig`'s header — "three parallel
//! arrays over the distinct trigrams present, plus a body whose groups hold the
//! first doc id raw and each successor as a delta, varint-packed" — by the
//! shortest route that obviously obeys it: collect every `(trigram, doc)` pair,
//! sort, group, emit. It is quadratic-ish and allocates freely, which is exactly
//! why it is trustworthy as a spec statement and useless as a builder.
//!
//! That distinction matters because kiln's whole reason to exist is the machinery
//! the oracle refuses to have — a bounded window, blocks fired to compressed
//! runs, a lockstep sweep. Comparing it against a builder that shares any of that
//! machinery would only prove the two agree about a shared mistake.
//!
//! Every corpus below is sized to force the paths that machinery adds: more
//! postings than one block holds (so the sweep merges), doc ranges split across
//! workers (so the concatenation's ordering invariant is load-bearing), and
//! documents whose trigrams straddle a block boundary.

const std = @import("std");
const kiln = @import("kiln.zig");
const ngram = @import("ngram.zig");
const varint = @import("../postings/varint.zig");

const Pair = struct {
    tri: u32,
    doc: u32,

    fn less(_: void, a: Pair, b: Pair) bool {
        return if (a.tri != b.tri) a.tri < b.tri else a.doc < b.doc;
    }
};

/// The format, spelled out. Returns the same four regions `kiln.fire` does.
fn oracle(gpa: std.mem.Allocator, docs: []const []const u8) !kiln.Fired {
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(gpa);
    for (docs, 0..) |d, i| {
        // Distinct trigrams of this doc, by the plainest means available: a set
        // keyed on the 24-bit gram. Dedup is part of the contract ("a doc's own
        // trigram set is deduped"), so the oracle has to do it too.
        var seen = std.AutoHashMap(u32, void).init(gpa);
        defer seen.deinit();
        if (d.len >= 3) for (0..d.len - 2) |p| {
            const t = (@as(u32, d[p]) << 16) | (@as(u32, d[p + 1]) << 8) | @as(u32, d[p + 2]);
            if ((try seen.getOrPut(t)).found_existing) continue;
            try pairs.append(gpa, .{ .tri = t, .doc = @intCast(i) });
        };
    }
    std.mem.sort(Pair, pairs.items, {}, Pair.less);

    var tris: std.ArrayList(u32) = .empty;
    errdefer tris.deinit(gpa);
    var offs: std.ArrayList(u32) = .empty;
    errdefer offs.deinit(gpa);
    var counts: std.ArrayList(u32) = .empty;
    errdefer counts.deinit(gpa);
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);

    var i: usize = 0;
    while (i < pairs.items.len) {
        const tri = pairs.items[i].tri;
        var j = i;
        while (j < pairs.items.len and pairs.items[j].tri == tri) j += 1;
        try tris.append(gpa, tri);
        try offs.append(gpa, @intCast(body.items.len));
        try counts.append(gpa, @intCast(j - i));
        var prev: u32 = 0;
        for (pairs.items[i..j], 0..) |p, k| {
            var scratch: [varint.max_len]u8 = undefined;
            const n = varint.encode(&scratch, if (k == 0) p.doc else p.doc - prev);
            try body.appendSlice(gpa, scratch[0..n]);
            prev = p.doc;
        }
        i = j;
    }
    return .{
        .dir_tri = try tris.toOwnedSlice(gpa),
        .dir_off = try offs.toOwnedSlice(gpa),
        .dir_count = try counts.toOwnedSlice(gpa),
        .body = try body.toOwnedSlice(gpa),
        .posting_count = @intCast(pairs.items.len),
    };
}

fn free(gpa: std.mem.Allocator, f: kiln.Fired) void {
    gpa.free(f.dir_tri);
    gpa.free(f.dir_off);
    gpa.free(f.dir_count);
    gpa.free(f.body);
}

/// Fire `docs` and assert every region matches the format oracle exactly. The
/// body is compared byte-for-byte, not merely decoded to the same doc sets: the
/// persisted index IS these bytes, so a builder that reached the same postings
/// through different varints would silently change every artifact digest.
fn agrees(gpa: std.mem.Allocator, docs: []const []const u8) !void {
    const want = try oracle(gpa, docs);
    defer free(gpa, want);
    const got = try kiln.fire(gpa, docs);
    defer free(gpa, got);

    try std.testing.expectEqual(want.posting_count, got.posting_count);
    try std.testing.expectEqualSlices(u32, want.dir_tri, got.dir_tri);
    try std.testing.expectEqualSlices(u32, want.dir_count, got.dir_count);
    try std.testing.expectEqualSlices(u32, want.dir_off, got.dir_off);
    try std.testing.expectEqualSlices(u8, want.body, got.body);
}

/// Deterministic pseudo-text with a small alphabet, so trigrams recur densely
/// across documents (the case where a group spans many runs) rather than each
/// doc owning a private trigram space (where the sweep would never merge).
fn scribble(gpa: std.mem.Allocator, seed: u64, len: usize) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const buf = try gpa.alloc(u8, len);
    for (buf) |*b| b.* = "abcdefgh \n"[r.uintLessThan(usize, 10)];
    return buf;
}

/// `[]const u8` elements so the result feeds `fire`/`oracle` as-is — the corpus
/// type IS the doc-slice type, and a cast between them would only be hiding that.
fn corpus(gpa: std.mem.Allocator, ndocs: usize, each: usize) ![][]const u8 {
    const docs = try gpa.alloc([]const u8, ndocs);
    for (docs, 0..) |*d, i| d.* = try scribble(gpa, @intCast(i + 1), each);
    return docs;
}

fn release(gpa: std.mem.Allocator, docs: [][]const u8) void {
    for (docs) |d| gpa.free(d);
    gpa.free(docs);
}

test "a corpus spanning many blocks merges to the format's exact bytes" {
    const gpa = std.testing.allocator;
    // ~4 MiB over a 10-symbol alphabet: far more postings than one block holds,
    // so the sweep is doing real k-way work rather than passing a single run
    // through.
    const docs = try corpus(gpa, 512, 8192);
    defer release(gpa, docs);
    try agrees(gpa, docs);
}

test "one document larger than a block still lands each trigram exactly once" {
    const gpa = std.testing.allocator;
    // The straddle case the header calls out: a doc whose trigrams overflow the
    // block it started in. Its remainder opens the next block with a new base,
    // and no trigram may see this doc twice.
    const solo = try scribble(gpa, 99, 6 << 20);
    defer gpa.free(solo);
    const filler = try scribble(gpa, 7, 4096);
    defer gpa.free(filler);
    try agrees(gpa, &.{ filler, solo, filler });
}

test "highly repetitive docs collapse to few trigrams across every run" {
    const gpa = std.testing.allocator;
    // The degenerate distribution: a handful of distinct trigrams, each present
    // in every doc, so a single group is concatenated out of all runs at once
    // and the ascending-doc invariant is the only thing keeping it sound.
    const docs = try gpa.alloc([]const u8, 4096);
    defer gpa.free(docs);
    for (docs, 0..) |*d, i| d.* = if (i % 2 == 0) "aaaabbbbaaaa" ** 128 else "abababab" ** 192;
    try agrees(gpa, docs);
}

test "empty and sub-trigram documents hold their doc ids without postings" {
    const gpa = std.testing.allocator;
    // Doc ids are indices, so a doc too short to carry a trigram must still
    // consume its id — otherwise every later doc's postings point one file off.
    const big = try scribble(gpa, 3, 5 << 20);
    defer gpa.free(big);
    try agrees(gpa, &.{ "", "ab", big, "", "xy", big, "" });
}

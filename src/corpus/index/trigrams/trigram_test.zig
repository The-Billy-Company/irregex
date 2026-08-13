//! irregex T0 trigram-index tests — split from `trigram.zig` to keep the index
//! file under the shape cap. Pulled into `zig build test` via `root.zig`'s test
//! block. Covers the candidate-set query semantics (sound superset / no false
//! negatives), the on-disk serialize round-trip incl. the zero-copy
//! `fromMappedBytes` aliasing the postings without a copy, and the >4 MiB
//! parallel build path's byte-parity with an independent serial reference.
//! (Extraction primitives are tested in `ngram_test.zig`.)

const std = @import("std");
const tri = @import("trigram.zig");
const ngram = @import("ngram.zig");
const Trigram = tri.Trigram;
const Posting = tri.Posting;
const Index = tri.Index;
const QueryError = tri.QueryError;
const LoadError = tri.LoadError;

test "query: literal hits exactly the containing docs" {
    const docs = [_][]const u8{ "the cat sat", "the dog ran", "concatenate" };
    var idx = try Index.build(std.testing.allocator, &docs);
    defer idx.deinit();

    const got = try idx.queryLiteral(std.testing.allocator, "cat");
    defer std.testing.allocator.free(got);
    // doc0 "the cat sat" and doc2 "concatenate" both contain "cat"; doc1 does not.
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 2 }, got);
}

test "query: true negative returns empty candidate set" {
    const docs = [_][]const u8{ "the cat sat", "the dog ran" };
    var idx = try Index.build(std.testing.allocator, &docs);
    defer idx.deinit();
    const got = try idx.queryLiteral(std.testing.allocator, "car");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "query: filter semantics — present-but-not-contiguous is a candidate" {
    // "bcaabc" contains trigrams "bca" and "abc" but NOT the literal "abca".
    // The trigram filter must keep it as a candidate (sound superset); the
    // caller's exact verify is what ultimately rejects it.
    const docs = [_][]const u8{"bcaabc"};
    var idx = try Index.build(std.testing.allocator, &docs);
    defer idx.deinit();
    const got = try idx.queryLiteral(std.testing.allocator, "abca");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
}

test "query: needle under 3 bytes is reported, not silently wrong" {
    const docs = [_][]const u8{"hello"};
    var idx = try Index.build(std.testing.allocator, &docs);
    defer idx.deinit();
    try std.testing.expectError(QueryError.NeedleTooShort, idx.queryLiteral(std.testing.allocator, "he"));
}

test "serialize: round-trip preserves postings and query results" {
    const a = std.testing.allocator;
    const docs = [_][]const u8{ "the cat sat", "the dog ran", "concatenate" };
    var idx = try Index.build(a, &docs);
    defer idx.deinit();

    const buf = try a.alloc(u8, idx.serializedSize());
    defer a.free(buf);
    const n = idx.writeInto(buf);
    try std.testing.expectEqual(idx.serializedSize(), n);

    var loaded = try Index.fromBytes(a, buf);
    defer loaded.deinit();
    try std.testing.expectEqual(idx.doc_count, loaded.doc_count);

    const want = try idx.debugAllPostings(a);
    defer a.free(want);
    const got_all = try loaded.debugAllPostings(a);
    defer a.free(got_all);
    try std.testing.expectEqualSlices(Posting, want, got_all);

    const got = try loaded.queryLiteral(a, "cat");
    defer a.free(got);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 2 }, got);
}

test "serialize: garbage / truncated blob is rejected, not misread" {
    const a = std.testing.allocator;
    try std.testing.expectError(LoadError.Corrupt, Index.fromBytes(a, "not a gist index"));
    try std.testing.expectError(LoadError.Corrupt, Index.fromBytes(a, "GISTIDX\x01")); // valid magic, header truncated
    try std.testing.expectError(LoadError.Corrupt, Index.fromMappedBytes("not a gist index"));
}

test "serialize: zero-copy fromMappedBytes aliases the directory, no copy" {
    const a = std.testing.allocator;
    const docs = [_][]const u8{ "the cat sat", "concatenate" };
    var idx = try Index.build(a, &docs);
    defer idx.deinit();

    // mmap is page-aligned; mirror that here so the `@alignCast` in
    // `fromMappedBytes` holds (the header keeps the u32 directory 4-aligned).
    const buf = try a.alignedAlloc(u8, comptime .fromByteUnits(@alignOf(u32)), idx.serializedSize());
    defer a.free(buf);
    _ = idx.writeInto(buf);

    var mapped = try Index.fromMappedBytes(buf);
    defer mapped.deinit(); // borrowed ⇒ a no-op; `buf` is freed above
    try std.testing.expect(mapped.borrowed);
    try std.testing.expectEqual(idx.doc_count, mapped.doc_count);

    const want = try idx.debugAllPostings(a);
    defer a.free(want);
    const got_all = try mapped.debugAllPostings(a);
    defer a.free(got_all);
    try std.testing.expectEqualSlices(Posting, want, got_all);
    // The decisive property: the directory points INTO `buf`, not a copy.
    try std.testing.expectEqual(@intFromPtr(buf.ptr) + tri.header_len, @intFromPtr(mapped.dir_tri.ptr));

    const got = try mapped.queryLiteral(a, "cat"); // both docs contain "cat"
    defer a.free(got);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 1 }, got);
}

const Ref = struct { tri: Trigram, doc: u32 };
fn refLess(_: void, x: Ref, y: Ref) bool {
    return if (x.tri != y.tri) x.tri < y.tri else x.doc < y.doc;
}

test "build: >4MiB parallel path byte-matches an independent serial reference" {
    const a = std.testing.allocator;
    const ndocs = 8;
    const per = (5 << 20) / ndocs; // ~5 MiB total, > 4 MiB threshold ⇒ parallel path

    var bufs: [ndocs][]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    for (0..ndocs) |i| {
        bufs[i] = try a.alloc(u8, per);
        for (bufs[i]) |*c| c.* = rnd.intRangeAtMost(u8, 'a', 'd'); // dense small alphabet ⇒ dupes
    }
    defer for (bufs) |b| a.free(b);

    var docs: [ndocs][]const u8 = undefined;
    for (0..ndocs) |i| docs[i] = bufs[i];

    var idx = try Index.build(a, &docs);
    defer idx.deinit();

    // Independent reference: extract per doc, concat, sort by (tri, doc).
    const scratch = try a.alloc(Trigram, per);
    defer a.free(scratch);
    const ref = try a.alloc(Ref, ndocs * per); // upper bound
    defer a.free(ref);
    var n: usize = 0;
    for (docs, 0..) |d, di| {
        const k = ngram.extractSortedUnique(d, scratch);
        for (scratch[0..k]) |t| {
            ref[n] = .{ .tri = t, .doc = @intCast(di) };
            n += 1;
        }
    }
    std.mem.sort(Ref, ref[0..n], {}, refLess);

    const got = try idx.debugAllPostings(a);
    defer a.free(got);
    try std.testing.expectEqual(n, got.len);
    for (got, ref[0..n]) |p, r| {
        try std.testing.expectEqual(r.tri, p.tri);
        try std.testing.expectEqual(r.doc, p.doc);
    }
}

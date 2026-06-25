const std = @import("std");
const tri = @import("src/trigram.zig");

const Ref = struct { tri: u32, doc: u32 };
fn refLess(_: void, x: Ref, y: Ref) bool {
    return if (x.tri != y.tri) x.tri < y.tri else x.doc < y.doc;
}

test "parallel build (>4MiB) == independent serial reference" {
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

    var idx = try tri.Index.build(a, &docs);
    defer idx.deinit();

    // Independent reference: extract per doc, concat, sort by (tri, doc).
    const scratch = try a.alloc(u32, per);
    defer a.free(scratch);
    const ref = try a.alloc(Ref, ndocs * per); // upper bound
    defer a.free(ref);
    var n: usize = 0;
    for (docs, 0..) |d, di| {
        const k = tri.extractSortedUnique(d, scratch);
        for (scratch[0..k]) |t| {
            ref[n] = .{ .tri = t, .doc = @intCast(di) };
            n += 1;
        }
    }
    std.mem.sort(Ref, ref[0..n], {}, refLess);

    try std.testing.expectEqual(n, idx.postings.len);
    for (idx.postings, ref[0..n]) |p, r| {
        try std.testing.expectEqual(r.tri, p.tri);
        try std.testing.expectEqual(r.doc, p.doc);
    }
    std.debug.print("parallel path verified: {d} postings byte-match serial ref\n", .{idx.postings.len});
}

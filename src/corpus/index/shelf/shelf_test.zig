//! The codex shelf, held to its persisted contract: corpus-wide counts and
//! per-document tallies must match a per-document oracle straight through a
//! save/load round-trip, every corpus position must map back to its document,
//! and a corrupt or truncated blob must fail closed rather than half-load.

const std = @import("std");
const testing = std.testing;
const shelf_mod = @import("shelf.zig");

/// Ground truth by scan: overlapping occurrences of `pattern` in `text`.
fn oracleCount(text: []const u8, pattern: []const u8) usize {
    if (pattern.len == 0) return 0;
    var c: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, pattern)) |p| {
        c += 1;
        i = p + 1;
    }
    return c;
}

test "shelf: count and tally match per-document oracles, through save/load" {
    const gpa = testing.allocator;
    const docs = [_][]const u8{
        "the quick brown fox",
        "fox fox fox",
        "no relation at all",
        "quick quick",
        "", // empty document is legal
    };
    const paths = [_][]const u8{ "a/one.txt", "b/two.txt", "c/three.txt", "d/four.txt", "e/empty.txt" };
    var built = try shelf_mod.Shelf.build(gpa, &docs, &paths, 42, .{ .sample_rate = 4 });
    defer built.deinit(gpa);
    const blob = try built.save(gpa);
    defer gpa.free(blob);
    var shelf = try shelf_mod.Shelf.load(gpa, blob);
    defer shelf.deinit(gpa);

    try testing.expectEqual(@as(i64, 42), shelf.built_ns);
    try testing.expectEqual(paths.len, shelf.paths.len);
    for (paths, shelf.paths) |want, got| try testing.expectEqualStrings(want, got);

    for ([_][]const u8{ "fox", "quick", "o", "zebra", " " }) |pat| {
        // corpus-wide count == Σ per-doc oracle counts (patterns carry no '\n',
        // so the sentinel guarantees no cross-document match)
        var want_total: usize = 0;
        for (&docs) |d| want_total += oracleCount(d, pat);
        try testing.expectEqual(want_total, shelf.count(pat));

        const t = (try shelf.tally(gpa, pat)).got;
        defer gpa.free(t);
        var tallied: usize = 0;
        for (t, 0..) |dc, i| {
            try testing.expectEqual(oracleCount(docs[dc.doc], pat), dc.count);
            try testing.expect(dc.count > 0); // only matching docs appear
            if (i > 0) try testing.expect(t[i - 1].count >= dc.count); // heaviest first
            tallied += dc.count;
        }
        try testing.expectEqual(want_total, tallied);
    }
}

test "shelf: docOf maps every corpus position to its document" {
    const gpa = testing.allocator;
    const docs = [_][]const u8{ "aa", "b", "cccc" };
    const paths = [_][]const u8{ "one", "two", "three" };
    var shelf = try shelf_mod.Shelf.build(gpa, &docs, &paths, 0, .{ .sample_rate = 1 });
    defer shelf.deinit(gpa);
    // layout: aa\n b\n cccc\n → doc starts 0, 3, 5
    var pos: u64 = 0;
    for (&docs, 0..) |d, i| {
        for (0..d.len + 1) |_| { // body + its sentinel both belong to doc i
            try testing.expectEqual(@as(u32, @intCast(i)), shelf.docOf(pos));
            pos += 1;
        }
    }
}

test "shelf: load fails closed on framing corruption" {
    const gpa = testing.allocator;
    const docs = [_][]const u8{ "alpha", "beta" };
    const paths = [_][]const u8{ "a", "b" };
    var built = try shelf_mod.Shelf.build(gpa, &docs, &paths, 7, .{});
    defer built.deinit(gpa);
    const blob = try built.save(gpa);
    defer gpa.free(blob);

    var bad = try gpa.dupe(u8, blob);
    defer gpa.free(bad);
    bad[0] = 'X'; // magic
    try testing.expectError(error.Corrupt, shelf_mod.Shelf.load(gpa, bad));
    var cut: usize = 0;
    while (cut < blob.len) : (cut += @max(blob.len / 23, 1)) {
        try testing.expectError(error.Corrupt, shelf_mod.Shelf.load(gpa, blob[0..cut]));
    }
    // bit rot inside the embedded codex blob trips its checksum
    bad[0] = blob[0];
    bad[bad.len - 20] ^= 0x40;
    try testing.expectError(error.Corrupt, shelf_mod.Shelf.load(gpa, bad));
}

// ── cento (cross-parse) ──

//! gist T4 RRF-ranking tests — split from `rank.zig` to keep each tier file lean
//! and tests in a sibling. Pulled into `zig build test` via `root.zig`'s test
//! block. Asserts the editorial fusion calls: a definition beats a far hotter
//! call site (symbol weight), density-then-shallowness orders the rest, the
//! optional external graph signal fuses in and is weight-controlled, and the
//! trivial 0/1-doc sizes are well-defined.

const std = @import("std");
const rank_mod = @import("rank.zig");
const Doc = rank_mod.Doc;
const rank = rank_mod.rank;

test "rrf: definition beats a higher-frequency call site" {
    const docs = [_]Doc{
        .{ .id = 10, .matches = 50, .is_def = false, .best_line = 5, .depth = 3 }, // hot usage
        .{ .id = 20, .matches = 2, .is_def = true, .best_line = 1, .depth = 3 }, // the def
    };
    const order = try rank(std.testing.allocator, &docs, .{}, null);
    defer std.testing.allocator.free(order);
    // The symbol signal (weight 2) lifts the definition above the 25×-hotter usage.
    try std.testing.expectEqual(@as(u32, 1), order[0]); // docs[1] == the def
    try std.testing.expectEqual(@as(u32, 0), order[1]);
}

test "rrf: among non-defs, density then shallowness win" {
    const docs = [_]Doc{
        .{ .id = 1, .matches = 1, .is_def = false, .best_line = 9, .depth = 6 },
        .{ .id = 2, .matches = 9, .is_def = false, .best_line = 2, .depth = 2 },
        .{ .id = 3, .matches = 9, .is_def = false, .best_line = 2, .depth = 5 },
    };
    const order = try rank(std.testing.allocator, &docs, .{}, null);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqual(@as(u32, 1), order[0]); // most matches AND shallowest
    try std.testing.expectEqual(@as(u32, 2), order[1]); // same matches, deeper
    try std.testing.expectEqual(@as(u32, 0), order[2]); // fewest matches
}

test "rrf: external graph ranking fuses in and drives the order" {
    const docs = [_]Doc{
        .{ .id = 100, .matches = 5, .is_def = false, .best_line = 3, .depth = 4 },
        .{ .id = 200, .matches = 5, .is_def = false, .best_line = 3, .depth = 4 },
    };
    // A dominant graph signal puts whichever id it ranks first on top, and flipping the order flips the result —
    // proving the optional signal fuses in and is weight-controlled.
    const graph_a = [_]u32{ 200, 100 };
    const a = try rank(std.testing.allocator, &docs, .{ .graph = 100 }, &graph_a);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqual(@as(u32, 1), a[0]); // docs[1].id == 200

    const graph_b = [_]u32{ 100, 200 };
    const b = try rank(std.testing.allocator, &docs, .{ .graph = 100 }, &graph_b);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u32, 0), b[0]); // docs[0].id == 100
}

test "rank: trivial sizes are well-defined" {
    const empty = try rank(std.testing.allocator, &[_]Doc{}, .{}, null);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const one = [_]Doc{.{ .id = 7, .matches = 1, .is_def = false, .best_line = 1, .depth = 1 }};
    const got = try rank(std.testing.allocator, &one, .{}, null);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(u32, 0), got[0]);
}

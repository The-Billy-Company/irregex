//! gist T3 freshness-overlay test — split from `fresh.zig`. Pulled into
//! `zig build test` via `bench.zig`'s test block. Exercises `widen`'s set
//! algebra in isolation (no filesystem): an existing-but-trigram-skipped file is
//! forced into the candidate ids by its existing id, a brand-new file is
//! appended to `paths` and id'd once, and duplicates collapse — each doc exactly
//! once.

const std = @import("std");
const fresh = @import("fresh.zig");

test "widen: new file is appended + id'd; existing fresh file is forced once" {
    const gpa = std.testing.allocator;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    try paths.appendSlice(gpa, &.{ "a/x.zig", "a/y.zig" }); // ids 0,1

    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    try ids.append(gpa, 0); // base candidate: only doc 0

    // y.zig (existing, trigram-skipped) + z.zig (brand new) both changed.
    try fresh.widen(gpa, &paths, &ids, &.{ "a/y.zig", "a/z.zig", "a/y.zig" });

    try std.testing.expectEqual(@as(usize, 3), paths.items.len); // z.zig appended once
    try std.testing.expectEqualStrings("a/z.zig", paths.items[2]);
    // ids: 0 (base) + 1 (y forced) + 2 (z new), each exactly once.
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, ids.items);
}

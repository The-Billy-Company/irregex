//! gist T0 persisted index/path-table tests — split per the shape cap, wired via
//! `root.zig`'s test block. Exercises the doc→path integrity invariant
//! (`validatePersistedPair`) and the NUL-split (`parsePathTable`) WITHOUT touching
//! the filesystem; the mmap `load` path is covered end-to-end by the CLI races.

const std = @import("std");
const persist = @import("persist.zig");

test "parsePathTable: splits NUL-separated paths in doc-id order, dropping a trailing NUL" {
    const a = std.testing.allocator;
    var p = try persist.parsePathTable(a, "a\x00bb\x00ccc\x00");
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), p.items.len);
    try std.testing.expectEqualStrings("a", p.items[0]);
    try std.testing.expectEqualStrings("bb", p.items[1]);
    try std.testing.expectEqualStrings("ccc", p.items[2]);
}

test "parsePathTable: a coalesced double-NUL drops the empty (a count mismatch then catches it)" {
    const a = std.testing.allocator;
    var p = try persist.parsePathTable(a, "a\x00\x00b");
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), p.items.len);
    try std.testing.expectEqualStrings("a", p.items[0]);
    try std.testing.expectEqualStrings("b", p.items[1]);
}

test "validatePersistedPair: accepts exactly doc_count paths" {
    const paths = [_][]const u8{ "a", "b", "c" };
    try persist.validatePersistedPair(3, &paths);
}

test "validatePersistedPair: rejects a shorter or longer path table (the doc-id OOB guard)" {
    const paths = [_][]const u8{ "a", "b", "c" };
    try std.testing.expectError(persist.PairError.PathTableMismatch, persist.validatePersistedPair(4, &paths));
    try std.testing.expectError(persist.PairError.PathTableMismatch, persist.validatePersistedPair(2, &paths));
}

test "validatePersistedPair: an empty table matches only doc_count 0" {
    try persist.validatePersistedPair(0, &.{});
    try std.testing.expectError(persist.PairError.PathTableMismatch, persist.validatePersistedPair(1, &.{}));
}

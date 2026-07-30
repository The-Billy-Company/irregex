//! irregex loom — tests for the closed shaping op set.
//!
//! Contract under test: every plan is total and deterministic (same plan +
//! rows ⇒ same answer, ties never swap), filter uses the rg glob semantics
//! the scope layer already certifies, and group counts equal a hand-derived
//! tally — never the module's own output fed back to itself.

const std = @import("std");
const loom = @import("loom.zig");

const gpa = std.testing.allocator;
const Row = loom.Row;

const rows = [_]Row{
    .{ .pattern = 0, .path = "services/backend/api/wallet.go", .line = 10 },
    .{ .pattern = 1, .path = "services/backend/api/wallet.go", .line = 12 },
    .{ .pattern = 0, .path = "clients/web/app/pay.ts", .line = 3 },
    .{ .pattern = 0, .path = "services/ai/tools/pay.py", .line = 7 },
    .{ .pattern = 2, .path = "clients/web/app/pay.ts", .line = 9 },
    .{ .pattern = 0, .path = "services/backend/api/wallet.go", .line = 2 },
};
const pattern_labels = [_][]const u8{ "wallet", "refund", "charge" };

test "rows: filter by glob, total path order, limit" {
    var res = try loom.execute(gpa, .{ .filter_glob = "services/**", .limit = 3 }, &rows, &.{});
    defer res.deinit(gpa);
    const got = res.rows;
    try std.testing.expectEqual(@as(usize, 3), got.len);
    // Total order: path asc, then line asc — wallet.go line 2 precedes line 10.
    try std.testing.expectEqualStrings("services/ai/tools/pay.py", got[0].path);
    try std.testing.expectEqualStrings("services/backend/api/wallet.go", got[1].path);
    try std.testing.expectEqual(@as(u32, 2), got[1].line);
    try std.testing.expectEqual(@as(u32, 10), got[2].line);
}

test "basename glob applies at any depth (rg semantics)" {
    var res = try loom.execute(gpa, .{ .filter_glob = "*.ts" }, &rows, &.{});
    defer res.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
    for (res.rows) |r| try std.testing.expect(std.mem.endsWith(u8, r.path, ".ts"));
}

test "group by pattern: counts match a hand tally, labels resolve" {
    var res = try loom.execute(gpa, .{ .group = .pattern, .sort = .count_desc }, &rows, &pattern_labels);
    defer res.deinit(gpa);
    const g = res.groups;
    try std.testing.expectEqual(@as(usize, 3), g.len);
    // Hand tally: wallet=4, refund=1, charge=1. Ties break on label asc.
    try std.testing.expectEqualStrings("wallet", g[0].label);
    try std.testing.expectEqual(@as(u64, 4), g[0].count);
    try std.testing.expectEqualStrings("charge", g[1].label);
    try std.testing.expectEqualStrings("refund", g[2].label);
}

test "group by file with filter and limit composes" {
    var res = try loom.execute(gpa, .{
        .filter_glob = "services/**",
        .group = .file,
        .sort = .count_desc,
        .limit = 1,
    }, &rows, &.{});
    defer res.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), res.groups.len);
    try std.testing.expectEqualStrings("services/backend/api/wallet.go", res.groups[0].label);
    try std.testing.expectEqual(@as(u64, 3), res.groups[0].count);
}

test "determinism: equal counts never swap run to run" {
    // pay.ts and pay.py each hold one pattern-0 row; label order must decide.
    var a = try loom.execute(gpa, .{ .group = .file, .sort = .count_desc }, &rows, &.{});
    defer a.deinit(gpa);
    var b = try loom.execute(gpa, .{ .group = .file, .sort = .count_desc }, &rows, &.{});
    defer b.deinit(gpa);
    for (a.groups, b.groups) |x, y| {
        try std.testing.expectEqualStrings(x.label, y.label);
        try std.testing.expectEqual(x.count, y.count);
    }
}

test "empty rows and empty plan are total" {
    var res = try loom.execute(gpa, .{}, &.{}, &.{});
    defer res.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), res.rows.len);
    var res2 = try loom.execute(gpa, .{ .group = .pattern }, &.{}, &.{});
    defer res2.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), res2.groups.len);
}

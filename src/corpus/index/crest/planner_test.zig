const std = @import("std");
const planner = @import("planner.zig");

test "planner admits only an honestly cheaper sieve" {
    const costs: planner.Coefficients = .{
        .fixed = 100,
        .column_document = 1,
        .verify_document = 100,
    };
    const profitable = planner.decide(.{
        .touched_columns = 2,
        .candidate_docs = 100,
        .scanned_docs = 100,
        .expected_candidates = 20,
    }, costs);
    try std.testing.expect(profitable.run);
    try std.testing.expectEqual(planner.Reason.profitable, profitable.reason);

    const expensive = planner.decide(.{
        .touched_columns = 60,
        .candidate_docs = 100,
        .scanned_docs = 100,
        .expected_candidates = 90,
    }, costs);
    try std.testing.expect(!expensive.run);
    try std.testing.expectEqual(planner.Reason.unprofitable, expensive.reason);
}

test "planner margins and invalid estimates fail closed" {
    const costs: planner.Coefficients = .{
        .fixed = 0,
        .column_document = 1,
        .verify_document = 100,
        .minimum_savings = 5_000,
        .minimum_savings_bps = 2_500,
    };
    try std.testing.expectEqual(
        planner.Reason.invalid_estimate,
        planner.decide(.{
            .touched_columns = 1,
            .candidate_docs = 10,
            .scanned_docs = 10,
            .expected_candidates = 11,
        }, costs).reason,
    );
    try std.testing.expectEqual(
        planner.Reason.invalid_estimate,
        planner.decide(.{
            .touched_columns = 1,
            .candidate_docs = 10,
            .scanned_docs = 9,
            .expected_candidates = 1,
        }, costs).reason,
    );
    try std.testing.expectEqual(
        planner.Reason.below_absolute_margin,
        planner.decide(.{
            .touched_columns = 1,
            .candidate_docs = 10,
            .scanned_docs = 10,
            .expected_candidates = 9,
        }, costs).reason,
    );
    var invalid = costs;
    invalid.minimum_savings_bps = planner.basis_points + 1;
    try std.testing.expectEqual(
        planner.Reason.invalid_coefficients,
        planner.decide(.{
            .touched_columns = 1,
            .candidate_docs = 10,
            .scanned_docs = 10,
            .expected_candidates = 1,
        }, invalid).reason,
    );
}

test "planner prices the sparse and dense columnar boundary honestly" {
    const costs: planner.Coefficients = .{
        .fixed = 0,
        .column_document = 1,
        .verify_document = 4,
    };
    const sparse = planner.decide(.{
        .touched_columns = 1,
        .candidate_docs = 25,
        .scanned_docs = planner.scannedDocs(25, 100),
        .expected_candidates = 1,
    }, costs);
    try std.testing.expect(sparse.run);
    try std.testing.expectEqual(@as(u64, 25), sparse.scanned_docs);
    try std.testing.expectEqual(@as(u128, 25), sparse.column_cost);

    const dense = planner.decide(.{
        .touched_columns = 1,
        .candidate_docs = 26,
        .scanned_docs = planner.scannedDocs(26, 100),
        .expected_candidates = 1,
    }, costs);
    try std.testing.expect(!dense.run);
    try std.testing.expectEqual(planner.Reason.unprofitable, dense.reason);
    try std.testing.expectEqual(@as(u64, 100), dense.scanned_docs);
    try std.testing.expectEqual(@as(u128, 104), dense.direct_cost);
    try std.testing.expectEqual(@as(u128, 100), dense.column_cost);
}

test "planner overflow cannot accidentally authorize execution" {
    const decision = planner.decide(.{
        .touched_columns = std.math.maxInt(u16),
        .candidate_docs = std.math.maxInt(u64),
        .scanned_docs = std.math.maxInt(u64),
        .expected_candidates = 1,
    }, .{
        .fixed = std.math.maxInt(u64),
        .column_document = std.math.maxInt(u64),
        .verify_document = std.math.maxInt(u64),
    });
    try std.testing.expect(!decision.run);
    try std.testing.expectEqual(planner.Reason.arithmetic_overflow, decision.reason);
}

const std = @import("std");
const image = @import("munch_image_types.zig");
const t = std.testing;

fn context(allocation: u64, work: u64, live: u64, budget: *image.Budget) !image.Context {
    var limits = image.Limits.trial();
    limits.live_owned_bytes = live;
    budget.* = image.Budget.trial();
    budget.allocation_left = allocation;
    budget.work_left = work;
    return image.Context.init(t.allocator, limits, budget, 0);
}

test "munch-image: live ceiling precedes allocation debit and allocator failure" {
    var budget: image.Budget = undefined;
    var ctx = try context(0, 0, 7, &budget);
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    ctx.base = failing.allocator();
    try t.expectError(error.Oversized, ctx.alloc(u64, 1, .validation));
    try t.expectEqual(@as(u64, 0), budget.allocation_left);
    try t.expectEqual(@as(u64, 0), ctx.live);
    try t.expect(!failing.has_induced_failure);
    ctx.limits.live_owned_bytes = 8;
    try t.expectError(error.BudgetExceeded, ctx.alloc(u64, 1, .validation));
    try t.expect(!failing.has_induced_failure);
    budget.allocation_left = 8;
    try t.expectError(error.OutOfMemory, ctx.alloc(u64, 1, .validation));
    try t.expect(failing.has_induced_failure);
    try t.expectEqual(@as(u64, 0), budget.allocation_left);
    try t.expectEqual(@as(u64, 0), ctx.live);
    try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "munch-image: frees release live occupancy without refunding cumulative allocation" {
    var budget: image.Budget = undefined;
    var ctx = try context(16, 0, 8, &budget);
    const first = try ctx.alloc(u64, 1, .validation);
    var first_live = true;
    defer if (first_live) ctx.free(first);
    try t.expectEqual(@as(u64, 8), ctx.live);
    try t.expectEqual(@as(u64, 8), budget.allocation_left);
    try t.expectError(error.Oversized, ctx.alloc(u64, 1, .validation));
    try t.expectEqual(@as(u64, 8), budget.allocation_left);
    ctx.free(first);
    first_live = false;
    try t.expectEqual(@as(u64, 0), ctx.live);
    try t.expectEqual(@as(u64, 8), budget.allocation_left);
    const second = try ctx.alloc(u64, 1, .validation);
    ctx.free(second);
    try t.expectEqual(@as(u64, 0), ctx.live);
    try t.expectEqual(@as(u64, 0), budget.allocation_left);
    try t.expectError(error.BudgetExceeded, ctx.alloc(u64, 1, .validation));
}

test "munch-image: rejected work debit leaves its exact remaining allowance" {
    var budget: image.Budget = undefined;
    var ctx = try context(0, 175, 0, &budget);
    try t.expectError(error.BudgetExceeded, ctx.work(176));
    try t.expectEqual(@as(u64, 175), budget.work_left);
    try ctx.work(175);
    try t.expectEqual(@as(u64, 0), budget.work_left);
    try t.expectError(error.BudgetExceeded, ctx.work(1));
    try t.expectEqual(@as(u64, 0), budget.work_left);
    try ctx.work(0);
}

test "munch-image: retained pending storage consumes current live ceiling without redebit" {
    const pending = try t.allocator.alloc(u8, 16);
    defer t.allocator.free(pending);
    var limits = image.Limits.trial();
    limits.live_owned_bytes = 15;
    var budget = image.Budget.trial();
    budget.allocation_left = 8;
    try t.expectError(error.Oversized, image.Context.init(t.allocator, limits, &budget, pending.len));
    try t.expectEqual(@as(u64, 8), budget.allocation_left);
    limits.live_owned_bytes = 16;
    var ctx = try image.Context.init(t.allocator, limits, &budget, pending.len);
    try t.expectEqual(@as(u64, 16), ctx.live);
    try t.expectEqual(@as(u64, 8), budget.allocation_left);
    try t.expectError(error.Oversized, ctx.alloc(u8, 1, .validation));
    try t.expectEqual(@as(u64, 8), budget.allocation_left);
}

test "munch-image: zero-length storage needs no allocation or live allowance" {
    var budget: image.Budget = undefined;
    var ctx = try context(0, 0, 0, &budget);
    const empty = try ctx.alloc(u64, 0, .validation);
    defer ctx.free(empty);
    try t.expectEqual(@as(usize, 0), empty.len);
    try t.expectEqual(@as(u64, 0), ctx.live);
    try t.expectEqual(@as(u64, 0), budget.allocation_left);
    try t.expectEqual(@as(u64, 0), budget.work_left);
}

test "munch-image: allocation arithmetic refuses overflow before allocator or budget" {
    try t.expectError(error.Oversized, image.add(std.math.maxInt(u64), 1));
    try t.expectError(error.Oversized, image.mul(std.math.maxInt(u64), 2));
    try t.expectEqual(@as(usize, 8), try image.size(8));
    var budget: image.Budget = undefined;
    var ctx = try context(std.math.maxInt(u64), 0, std.math.maxInt(u64), &budget);
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    ctx.base = failing.allocator();
    if (@bitSizeOf(usize) == 64) {
        try t.expectError(error.Oversized, ctx.alloc(u64, std.math.maxInt(usize), .validation));
        try t.expectEqual(std.math.maxInt(u64), budget.allocation_left);
        try t.expect(!failing.has_induced_failure);
    }
}

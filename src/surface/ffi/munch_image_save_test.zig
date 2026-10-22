const std = @import("std");
const ffi = @import("munch.zig");
const contract = @import("contract.zig");
const fault = @import("../../fault.zig");
const image = @import("../../kernel/regex/linear/program/munch_image.zig");
const data = @import("../../kernel/regex/linear/program/munch_image_vectors.zig");
const t = std.testing;
const Status = contract.Status;

fn fixture(name: []const u8) *const data.Fixture {
    for (&data.fixtures) |*f| if (std.mem.eql(u8, name, f.name)) return f;
    @panic("missing authored fixture");
}

fn load(f: *const data.Fixture) !*ffi.Munch {
    const limits = image.Limits.trial();
    var budget = image.Budget.trial();
    var patterns: [64]ffi.Pattern = undefined;
    for (f.patterns, patterns[0..f.patterns.len]) |bytes, *p| p.* = .{ .pattern = bytes.ptr, .len = bytes.len };
    var worker: *ffi.Munch = undefined;
    try t.expectEqual(Status.ok, ffi.load(&patterns, f.patterns.len, f.expected_flags, f.bytes.ptr, f.bytes.len, &limits, &budget, &worker));
    return worker;
}

fn stage(worker: *ffi.Munch, limits: *const ffi.ImageLimits, budget: *ffi.ImageBudget) !usize {
    var written: usize = 0;
    try t.expectEqual(Status.match, ffi.save(worker, limits, budget, null, 0, &written));
    try t.expect(written >= 208);
    try t.expect(worker.pending != null);
    try t.expect(fault.last() == null);
    return written;
}

fn scanUsable(worker: *ffi.Munch) !void {
    var token: ffi.Token = undefined;
    var winners: [1]u32 = undefined;
    try t.expectEqual(Status.match, ffi.scan(worker, "a", 1, 0, null, 0, ffi.pick_longest, &token, &winners, 1));
    try t.expectEqual(@as(usize, 1), token.len);
    try t.expectEqual(@as(usize, 1), token.count);
    try t.expectEqual(@as(u32, 0), winners[0]);
}

test "munch-image: loaded canonical goldens save exactly through sizing short and full copy" {
    var tested: usize = 0;
    for (&data.fixtures) |*f| {
        if (f.expected_fault != null) continue;
        const worker = try load(f);
        defer ffi.free(worker);
        const limits = image.Limits.trial();
        var budget = image.Budget.trial();
        const needed = try stage(worker, &limits, &budget);
        try t.expectEqual(f.bytes.len, needed);
        const allocation_after_sizing = budget.allocation_left;
        var short: [8]u8 = @splat(0xa7);
        var written: usize = 0;
        try t.expectEqual(Status.match, ffi.save(worker, &limits, &budget, &short, short.len, &written));
        try t.expectEqual(needed, written);
        try t.expect(worker.pending != null);
        for (short) |byte| try t.expectEqual(@as(u8, 0xa7), byte);
        try t.expectEqual(allocation_after_sizing, budget.allocation_left);
        var copy: *ffi.Munch = undefined;
        try t.expectEqual(Status.ok, ffi.cloneWorker(worker, &copy));
        defer ffi.free(copy);
        try t.expect(copy.pending == null);
        try t.expect(worker.pending != null);
        var output: [1024]u8 = @splat(0xa7);
        try t.expect(needed <= output.len);
        try t.expectEqual(Status.match, ffi.save(worker, &limits, &budget, &output, needed, &written));
        try t.expectEqual(needed, written);
        try t.expectEqualSlices(u8, f.bytes, output[0..written]);
        for (output[written..]) |byte| try t.expectEqual(@as(u8, 0xa7), byte);
        try t.expect(worker.pending == null);
        try t.expectEqual(allocation_after_sizing, budget.allocation_left);
        tested += 1;
    }
    try t.expectEqual(@as(usize, 7), tested);
}

const BadArgument = enum { none, output, written };

fn rejected(worker: *ffi.Munch, limits: ?*const ffi.ImageLimits, budget: ?*ffi.ImageBudget, argument: BadArgument, expected: ?anyerror) !void {
    var output: [1024]u8 = @splat(0xa7);
    var written: usize = 999;
    const before = if (budget) |b| b.* else image.Budget.trial();
    const status = ffi.save(worker, limits, budget, if (argument == .output) null else &output, if (argument == .output) 1 else output.len, if (argument == .written) null else &written);
    if (expected) |e| {
        try t.expectEqual(if (e == error.BudgetExceeded) Status.out_of_memory else Status.open_failed, status);
        const detail = fault.last() orelse return error.TestExpectedFault;
        try t.expectEqualStrings(@errorName(e), @errorName(detail.code));
    } else {
        try t.expectEqual(Status.invalid, status);
        try t.expect(fault.last() == null);
        if (budget) |b| try t.expect(std.meta.eql(before, b.*));
    }
    try t.expect(worker.pending == null);
    for (output) |byte| try t.expectEqual(@as(u8, 0xa7), byte);
    try scanUsable(worker);
}

test "munch-image: every invalid save record clears previously retained pending bytes" {
    inline for (.{ .{ "struct_size", 0 }, .{ "struct_size", 76 }, .{ "struct_size", 84 }, .{ "version", 0 }, .{ "version", 2 }, .{ "reserved0", 1 }, .{ "reserved1", 1 } }) |change| {
        const worker = try load(fixture("singleton"));
        defer ffi.free(worker);
        var limits = image.Limits.trial();
        var budget = image.Budget.trial();
        _ = try stage(worker, &limits, &budget);
        @field(limits, change[0]) = change[1];
        try rejected(worker, &limits, &budget, .none, null);
    }
    inline for (.{ .{ "struct_size", 0 }, .{ "struct_size", 28 }, .{ "struct_size", 36 }, .{ "version", 0 }, .{ "version", 2 }, .{ "reserved0", 1 }, .{ "reserved1", 1 } }) |change| {
        const worker = try load(fixture("singleton"));
        defer ffi.free(worker);
        const limits = image.Limits.trial();
        var budget = image.Budget.trial();
        _ = try stage(worker, &limits, &budget);
        @field(budget, change[0]) = change[1];
        try rejected(worker, &limits, &budget, .none, null);
    }
}

test "munch-image: invalid save pointers clear pending without touching output or budgets" {
    inline for (.{ "limits", "budget", "output", "written" }) |which| {
        const worker = try load(fixture("singleton"));
        defer ffi.free(worker);
        const limits = image.Limits.trial();
        var budget = image.Budget.trial();
        _ = try stage(worker, &limits, &budget);
        try rejected(worker, if (comptime std.mem.eql(u8, which, "limits")) null else &limits, if (comptime std.mem.eql(u8, which, "budget")) null else &budget, if (comptime std.mem.eql(u8, which, "output")) .output else if (comptime std.mem.eql(u8, which, "written")) .written else .none, null);
    }
}

test "munch-image: stricter pending image limits clear storage and preserve scan usability" {
    inline for (.{ "encoded_bytes", "decoded_bytes", "patterns", "voices", "states", "transition_entries", "auxiliary_entries", "live_owned_bytes" }) |field| {
        const worker = try load(fixture("singleton"));
        defer ffi.free(worker);
        var limits = image.Limits.trial();
        var budget = image.Budget.trial();
        const needed = try stage(worker, &limits, &budget);
        @field(limits, field) = if (comptime std.mem.eql(u8, field, "encoded_bytes") or std.mem.eql(u8, field, "live_owned_bytes")) needed - 1 else if (comptime std.mem.eql(u8, field, "decoded_bytes")) 575 else 0;
        try rejected(worker, &limits, &budget, .none, error.Oversized);
    }
}

test "munch-image: one-short pending copy budget leaves every output byte untouched" {
    const worker = try load(fixture("singleton"));
    defer ffi.free(worker);
    const limits = image.Limits.trial();
    var budget = image.Budget.trial();
    const needed = try stage(worker, &limits, &budget);
    budget.work_left = needed - 1;
    const allocation = budget.allocation_left;
    try rejected(worker, &limits, &budget, .none, error.BudgetExceeded);
    try t.expectEqual(allocation, budget.allocation_left);
}

test "munch-image: source-created empty programs match independent full byte goldens" {
    inline for (.{ "empty-default", "empty-byte-dotall" }) |name| {
        const f = fixture(name);
        var worker: *ffi.Munch = undefined;
        try t.expectEqual(Status.ok, ffi.compile(null, 0, f.expected_flags, &worker));
        defer ffi.free(worker);
        const limits = image.Limits.trial();
        var budget = image.Budget.trial();
        var output: [208]u8 = undefined;
        var written: usize = 0;
        try t.expectEqual(Status.match, ffi.save(worker, &limits, &budget, &output, output.len, &written));
        try t.expectEqual(@as(usize, 208), written);
        try t.expectEqualSlices(u8, f.bytes, &output);
        try t.expect(worker.pending == null);
    }
}

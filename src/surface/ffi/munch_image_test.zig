//! Independent Image1 FFI controls. The data module contains frozen authored
//! bytes and expectations; no expected value is derived from the codec.
const std = @import("std");
const ffi = @import("munch.zig");
const contract = @import("contract.zig");
const fault = @import("../../fault.zig");
const kernel = @import("../../kernel/regex/linear/program/munch.zig");
const data = @import("../../kernel/regex/linear/program/munch_image_vectors.zig");

const t = std.testing;
const Status = contract.Status;

fn limits() ffi.ImageLimits {
    return .{
        .struct_size = 80,
        .version = 1,
        .reserved0 = 0,
        .reserved1 = 0,
        .encoded_bytes = 67108864,
        .decoded_bytes = 134217728,
        .patterns = 4096,
        .voices = 4096,
        .states = 1048576,
        .transition_entries = 16777216,
        .auxiliary_entries = 4194304,
        .live_owned_bytes = 268435456,
    };
}

fn budget() ffi.ImageBudget {
    return .{
        .struct_size = 32,
        .version = 1,
        .reserved0 = 0,
        .reserved1 = 0,
        .allocation_left = 268435456,
        .work_left = 128000000,
    };
}

fn fixture(name: []const u8) *const data.Fixture {
    for (&data.fixtures) |*f| if (std.mem.eql(u8, f.name, name)) return f;
    @panic("authored fixture name is absent");
}

fn loadInto(f: *const data.Fixture, l: ?*const ffi.ImageLimits, b: ?*ffi.ImageBudget, out: ?**ffi.Munch) Status {
    var patterns: [64]ffi.Pattern = undefined;
    std.debug.assert(f.patterns.len <= patterns.len);
    for (f.patterns, patterns[0..f.patterns.len]) |pattern, *slot| {
        slot.* = .{ .pattern = pattern.ptr, .len = pattern.len };
    }
    return ffi.load(if (f.patterns.len == 0) null else &patterns, f.patterns.len, f.expected_flags, f.bytes.ptr, f.bytes.len, l, b, out);
}

/// Limits/budget/descriptors deliberately end their lifetime at this return.
/// A loaded worker must retain only its own data and stable base allocator.
fn loaded(f: *const data.Fixture) !*ffi.Munch {
    const l = limits();
    var b = budget();
    var marker: ffi.Munch = undefined;
    var out: *ffi.Munch = &marker;
    try t.expectEqual(Status.ok, loadInto(f, &l, &b, &out));
    try t.expect(out != &marker);
    try t.expect(fault.last() == null);
    return out;
}

fn expectFault(actual: Status, expected: anyerror) !void {
    const status: Status = switch (expected) {
        error.BudgetExceeded, error.OutOfMemory, error.Exhausted => .out_of_memory,
        error.InvalidArgument => .invalid,
        else => .open_failed,
    };
    try t.expectEqual(status, actual);
    const detail = fault.last() orelse return error.TestExpectedFault;
    try t.expectEqualStrings(@errorName(expected), @errorName(detail.code));
}

fn sameBudget(expected: ffi.ImageBudget, actual: ffi.ImageBudget) !void {
    inline for (.{ "struct_size", "version", "reserved0", "reserved1", "allocation_left", "work_left" }) |field| {
        try t.expectEqual(@field(expected, field), @field(actual, field));
    }
}

fn sameLimits(expected: ffi.ImageLimits, actual: ffi.ImageLimits) !void {
    inline for (.{ "struct_size", "version", "reserved0", "reserved1", "encoded_bytes", "decoded_bytes", "patterns", "voices", "states", "transition_entries", "auxiliary_entries", "live_owned_bytes" }) |field| {
        try t.expectEqual(@field(expected, field), @field(actual, field));
    }
}

fn invalidLoad(f: *const data.Fixture, l: ?*const ffi.ImageLimits, b: ?*ffi.ImageBudget, anchor: *ffi.Munch) !void {
    const before = if (b) |value| value.* else budget();
    var out = anchor;
    try t.expectEqual(Status.invalid, loadInto(f, l, b, &out));
    try t.expect(out == anchor);
    try t.expect(fault.last() == null);
    if (b) |value| try sameBudget(before, value.*);
}

test "munch-image: all authored fixtures preserve typed outcomes and atomic publication" {
    try t.expectEqual(@as(usize, 42), data.fixtures.len);
    const before = kernel.determinizations;
    const anchor = try loaded(fixture("empty-default"));
    defer ffi.free(anchor);
    var positive: usize = 0;
    var negative: usize = 0;
    for (&data.fixtures) |*f| {
        const l = limits();
        var b = budget();
        var out = anchor;
        const status = loadInto(f, &l, &b, &out);
        if (f.expected_fault) |expected| {
            try expectFault(status, expected);
            try t.expect(out == anchor);
            negative += 1;
        } else {
            try t.expectEqual(Status.ok, status);
            try t.expect(out != anchor);
            defer ffi.free(out);
            try t.expect(fault.last() == null);
            try t.expectEqual(f.patterns.len, ffi.len(out));
            positive += 1;
        }
        try sameLimits(limits(), l);
        try t.expectEqual(@as(u32, 32), b.struct_size);
        try t.expectEqual(@as(u32, 1), b.version);
        try t.expectEqual(@as(u32, 0), b.reserved0);
        try t.expectEqual(@as(u32, 0), b.reserved1);
    }
    try t.expectEqual(@as(usize, 7), positive);
    try t.expectEqual(@as(usize, 35), negative);
    try t.expectEqual(before, kernel.determinizations);
}

fn scanQuestion(worker: *ffi.Munch, q: *const data.Question, initial: ?u64, expected_fault: ?anyerror, expected_remaining: u64) !void {
    const empty_allow = [_]u32{0};
    const allowed: ?[*]const u32 = if (q.allow) |list|
        (if (list.len == 0) empty_allow[0..].ptr else list.ptr)
    else
        null;
    const count = if (q.allow) |list| list.len else 0;
    const pick = if (q.pick == .longest) ffi.pick_longest else ffi.pick_shortest;
    var token = ffi.Token{ .len = 999, .count = 999 };
    var winners: [64]u32 = @splat(0xdecafbad);
    var remaining: usize = @intCast(initial orelse 0);
    const status = if (initial != null)
        ffi.scanMetered(worker, q.text.ptr, q.text.len, q.at, allowed, count, pick, &token, &winners, winners.len, &remaining)
    else
        ffi.scan(worker, q.text.ptr, q.text.len, q.at, allowed, count, pick, &token, &winners, winners.len);
    if (initial != null) try t.expectEqual(@as(usize, @intCast(expected_remaining)), remaining);
    if (expected_fault) |expected| {
        try expectFault(status, expected);
        try t.expectEqual(@as(usize, 0), token.len);
        try t.expectEqual(@as(usize, 0), token.count);
        // Refusal cannot publish a partial hit through caller-owned output.
        for (winners) |winner| try t.expectEqual(@as(u32, 0xdecafbad), winner);
    } else {
        try t.expectEqual(if (q.expected_match) Status.match else Status.ok, status);
        try t.expect(fault.last() == null);
        try t.expectEqual(q.expected_len orelse 0, token.len);
        try t.expectEqual(q.expected_winners.len, token.count);
        try t.expect(token.count <= winners.len);
        try t.expectEqualSlices(u32, q.expected_winners, winners[0..token.count]);
    }
}

test "munch-image: independent scan questions preserve exact remaining transition budgets" {
    try t.expectEqual(@as(usize, 84), data.questions.len);
    const before = kernel.determinizations;
    var questions: usize = 0;
    var metered: usize = 0;
    for (&data.questions) |*q| {
        const worker = try loaded(fixture(q.fixture_name));
        defer ffi.free(worker);
        try scanQuestion(worker, q, null, null, 0);
        questions += 1;
        for (q.budgets) |b| {
            try scanQuestion(worker, q, b.initial, b.expected_fault, b.remaining);
            metered += 1;
        }
    }
    try t.expectEqual(@as(usize, 84), questions);
    try t.expectEqual(@as(usize, 336), metered);
    try t.expectEqual(before, kernel.determinizations);
}

test "munch-image: every native argument record offset size and alignment is exact" {
    try t.expectEqual(@as(usize, 80), @sizeOf(ffi.ImageLimits));
    try t.expectEqual(@as(usize, 8), @alignOf(ffi.ImageLimits));
    try t.expectEqual(@as(usize, 32), @sizeOf(ffi.ImageBudget));
    try t.expectEqual(@as(usize, 8), @alignOf(ffi.ImageBudget));
    try t.expectEqual(@as(usize, 0), @offsetOf(ffi.ImageLimits, "struct_size"));
    try t.expectEqual(@as(usize, 4), @offsetOf(ffi.ImageLimits, "version"));
    try t.expectEqual(@as(usize, 8), @offsetOf(ffi.ImageLimits, "reserved0"));
    try t.expectEqual(@as(usize, 12), @offsetOf(ffi.ImageLimits, "reserved1"));
    try t.expectEqual(@as(usize, 16), @offsetOf(ffi.ImageLimits, "encoded_bytes"));
    try t.expectEqual(@as(usize, 24), @offsetOf(ffi.ImageLimits, "decoded_bytes"));
    try t.expectEqual(@as(usize, 32), @offsetOf(ffi.ImageLimits, "patterns"));
    try t.expectEqual(@as(usize, 40), @offsetOf(ffi.ImageLimits, "voices"));
    try t.expectEqual(@as(usize, 48), @offsetOf(ffi.ImageLimits, "states"));
    try t.expectEqual(@as(usize, 56), @offsetOf(ffi.ImageLimits, "transition_entries"));
    try t.expectEqual(@as(usize, 64), @offsetOf(ffi.ImageLimits, "auxiliary_entries"));
    try t.expectEqual(@as(usize, 72), @offsetOf(ffi.ImageLimits, "live_owned_bytes"));
    try t.expectEqual(@as(usize, 0), @offsetOf(ffi.ImageBudget, "struct_size"));
    try t.expectEqual(@as(usize, 4), @offsetOf(ffi.ImageBudget, "version"));
    try t.expectEqual(@as(usize, 8), @offsetOf(ffi.ImageBudget, "reserved0"));
    try t.expectEqual(@as(usize, 12), @offsetOf(ffi.ImageBudget, "reserved1"));
    try t.expectEqual(@as(usize, 16), @offsetOf(ffi.ImageBudget, "allocation_left"));
    try t.expectEqual(@as(usize, 24), @offsetOf(ffi.ImageBudget, "work_left"));
}

test "munch-image: invalid argument records precede image work without counter writes" {
    const f = fixture("singleton");
    const anchor = try loaded(fixture("empty-default"));
    defer ffi.free(anchor);
    inline for (.{ .{ "struct_size", 0 }, .{ "struct_size", 76 }, .{ "struct_size", 84 }, .{ "version", 0 }, .{ "version", 2 }, .{ "reserved0", 1 }, .{ "reserved1", 1 } }) |change| {
        var l = limits();
        @field(l, change[0]) = change[1];
        const saved = l;
        var b = budget();
        b.work_left = 0;
        try invalidLoad(f, &l, &b, anchor);
        try sameLimits(saved, l);
    }
    inline for (.{ .{ "struct_size", 0 }, .{ "struct_size", 28 }, .{ "struct_size", 36 }, .{ "version", 0 }, .{ "version", 2 }, .{ "reserved0", 1 }, .{ "reserved1", 1 } }) |change| {
        const l = limits();
        var b = budget();
        b.work_left = 0;
        @field(b, change[0]) = change[1];
        try invalidLoad(f, &l, &b, anchor);
    }
    const l = limits();
    var b = budget();
    b.work_left = 0;
    try invalidLoad(f, null, &b, anchor);
    try invalidLoad(f, &l, null, anchor);
    const saved = b;
    try t.expectEqual(Status.invalid, loadInto(f, &l, &b, null));
    try t.expect(fault.last() == null);
    try sameBudget(saved, b);
}

test "munch-image: fixed header charges and literal caps refuse without publication" {
    const f = fixture("singleton");
    const anchor = try loaded(fixture("empty-default"));
    defer ffi.free(anchor);
    for ([_]struct { initial: u64, remaining: u64 }{
        .{ .initial = 0, .remaining = 0 },
        .{ .initial = 175, .remaining = 175 },
        .{ .initial = 176, .remaining = 0 },
    }) |row| {
        const l = limits();
        var b = budget();
        b.work_left = row.initial;
        var out = anchor;
        try expectFault(loadInto(f, &l, &b, &out), error.BudgetExceeded);
        try t.expect(out == anchor);
        try t.expectEqual(row.remaining, b.work_left);
        try t.expectEqual(budget().allocation_left, b.allocation_left);
    }
    inline for (.{ .{ "encoded_bytes", 555 }, .{ "decoded_bytes", 575 }, .{ "patterns", 0 }, .{ "voices", 0 }, .{ "states", 0 }, .{ "transition_entries", 1 }, .{ "auxiliary_entries", 2 } }) |row| {
        var l = limits();
        @field(l, row[0]) = row[1];
        var b = budget();
        var out = anchor;
        try expectFault(loadInto(f, &l, &b, &out), error.Oversized);
        try t.expect(out == anchor);
        try t.expectEqual(budget().allocation_left, b.allocation_left);
        if (comptime std.mem.eql(u8, row[0], "encoded_bytes")) {
            try t.expectEqual(budget().work_left, b.work_left);
        }
    }
    {
        const l = limits();
        var b = budget();
        b.allocation_left = 0;
        var out = anchor;
        try expectFault(loadInto(f, &l, &b, &out), error.BudgetExceeded);
        try t.expect(out == anchor);
        try t.expectEqual(@as(u64, 0), b.allocation_left);
    }
    {
        var l = limits();
        l.live_owned_bytes = 0;
        var b = budget();
        var out = anchor;
        try expectFault(loadInto(f, &l, &b, &out), error.Oversized);
        try t.expect(out == anchor);
        try t.expectEqual(budget().allocation_left, b.allocation_left);
    }
}

test "munch-image: zero shape ceilings and large numeric allowances retain their literal meaning" {
    const empty = fixture("empty-default");
    var l = limits();
    l.encoded_bytes = 208;
    l.decoded_bytes = 208;
    l.patterns = 0;
    l.voices = 0;
    l.states = 0;
    l.transition_entries = 0;
    l.auxiliary_entries = 0;
    var b = budget();
    var marker: ffi.Munch = undefined;
    var out: *ffi.Munch = &marker;
    try t.expectEqual(Status.ok, loadInto(empty, &l, &b, &out));
    try t.expect(out != &marker);
    ffi.free(out);

    var large = limits();
    inline for (.{ "encoded_bytes", "decoded_bytes", "patterns", "voices", "states", "transition_entries", "auxiliary_entries", "live_owned_bytes" }) |field| {
        @field(large, field) = std.math.maxInt(u64);
    }
    var allowance = budget();
    allowance.allocation_left = std.math.maxInt(u64);
    allowance.work_left = std.math.maxInt(u64);
    out = &marker;
    try t.expectEqual(Status.ok, loadInto(fixture("singleton"), &large, &allowance, &out));
    try t.expect(out != &marker);
    ffi.free(out);
    try t.expect(allowance.allocation_left < std.math.maxInt(u64));
    try t.expect(allowance.work_left < std.math.maxInt(u64));

    // C accepts distinct live/cumulative rulers; the outer adapter owns its
    // narrower initialization policy. There is no record-invalidity relation.
    const normal = limits();
    allowance = budget();
    allowance.allocation_left = std.math.maxInt(u64);
    out = &marker;
    try t.expectEqual(Status.ok, loadInto(fixture("singleton"), &normal, &allowance, &out));
    try t.expect(out != &marker);
    ffi.free(out);
    try t.expect(allowance.allocation_left > normal.live_owned_bytes);
}

test "munch-image: fixed pointer and count guards leave output and budgets untouched" {
    const f = fixture("singleton");
    const anchor = try loaded(fixture("empty-default"));
    defer ffi.free(anchor);
    const l = limits();
    var b = budget();
    b.work_left = 0;
    const saved = b;
    var out = anchor;
    const pattern = [_]ffi.Pattern{.{ .pattern = ".*", .len = 2 }};
    try t.expectEqual(Status.invalid, ffi.load(null, 1, f.expected_flags, f.bytes.ptr, f.bytes.len, &l, &b, &out));
    try t.expect(out == anchor);
    try t.expect(fault.last() == null);
    try sameBudget(saved, b);
    try t.expectEqual(Status.invalid, ffi.load(&pattern, 1, f.expected_flags, null, f.bytes.len, &l, &b, &out));
    try t.expect(out == anchor);
    try t.expect(fault.last() == null);
    try sameBudget(saved, b);
    try t.expectEqual(Status.invalid, ffi.load(&pattern, 1, 0x80000000, f.bytes.ptr, f.bytes.len, &l, &b, &out));
    try t.expect(out == anchor);
    try t.expect(fault.last() == null);
    try sameBudget(saved, b);
    if (@bitSizeOf(usize) > 32) {
        try expectFault(ffi.load(&pattern, @as(usize, std.math.maxInt(u32)) + 1, f.expected_flags, f.bytes.ptr, f.bytes.len, &l, &b, &out), error.Oversized);
        try t.expect(out == anchor);
        try sameBudget(saved, b);
    }
    try expectFault(ffi.load(&pattern, 1, f.expected_flags, null, 0, &l, &b, &out), error.Truncated);
    try t.expect(out == anchor);
    try sameBudget(saved, b);
    try t.expectEqual(Status.invalid, ffi.cloneWorker(null, &out));
    try t.expect(out == anchor);
    try t.expect(fault.last() == null);
    try t.expectEqual(Status.invalid, ffi.cloneWorker(anchor, null));
    try t.expect(fault.last() == null);
    var written: usize = 999;
    var bytes: [8]u8 = @splat(0xa7);
    try t.expectEqual(Status.invalid, ffi.save(null, &l, &b, &bytes, bytes.len, &written));
    for (bytes) |byte| try t.expectEqual(@as(u8, 0xa7), byte);
    try sameBudget(saved, b);
}

test "munch-image: exported clone keeps a loaded machine after source and decode stack die" {
    const before = kernel.determinizations;
    const source = try loaded(fixture("attributed-two"));
    var source_live = true;
    defer if (source_live) ffi.free(source);
    var marker: ffi.Munch = undefined;
    var copy: *ffi.Munch = &marker;
    try t.expectEqual(Status.ok, ffi.cloneWorker(source, &copy));
    try t.expect(copy != &marker and copy != source);
    defer ffi.free(copy);
    ffi.free(source);
    source_live = false;
    const text = [_]u8{ 0, 0xff, '\n', 'a' };
    var token: ffi.Token = undefined;
    var winners: [2]u32 = undefined;
    var remaining: usize = 4;
    try t.expectEqual(Status.match, ffi.scanMetered(copy, &text, text.len, 0, null, 0, ffi.pick_longest, &token, &winners, winners.len, &remaining));
    try t.expectEqual(@as(usize, 4), token.len);
    try t.expectEqual(@as(usize, 2), token.count);
    try t.expectEqualSlices(u32, &.{ 0, 1 }, &winners);
    try t.expectEqual(@as(usize, 0), remaining);
    try t.expectEqual(before, kernel.determinizations);
}

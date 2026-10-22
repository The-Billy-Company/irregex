//! Image1's private argument records and call-scoped accounting. No allocator
//! vtable wraps Context: every owned object stores only Context.base.
const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ InvalidArgument, Corrupt, Truncated, NonCanonical, VersionMismatch, GenerationMismatch, Oversized, BudgetExceeded, OutOfMemory, Unsupported };

pub const Pattern = extern struct { pattern: ?[*]const u8, len: usize };

pub const Limits = extern struct {
    struct_size: u32,
    version: u32,
    reserved0: u32,
    reserved1: u32,
    encoded_bytes: u64,
    decoded_bytes: u64,
    patterns: u64,
    voices: u64,
    states: u64,
    transition_entries: u64,
    auxiliary_entries: u64,
    live_owned_bytes: u64,

    pub fn valid(l: *const Limits) bool {
        return l.struct_size == 80 and l.version == 1 and l.reserved0 == 0 and l.reserved1 == 0;
    }
    pub fn trial() Limits {
        return .{ .struct_size = 80, .version = 1, .reserved0 = 0, .reserved1 = 0, .encoded_bytes = 67108864, .decoded_bytes = 134217728, .patterns = 4096, .voices = 4096, .states = 1048576, .transition_entries = 16777216, .auxiliary_entries = 4194304, .live_owned_bytes = 268435456 };
    }
};
pub const Budget = extern struct {
    struct_size: u32,
    version: u32,
    reserved0: u32,
    reserved1: u32,
    allocation_left: u64,
    work_left: u64,

    pub fn valid(b: *const Budget) bool {
        return b.struct_size == 32 and b.version == 1 and b.reserved0 == 0 and b.reserved1 == 0;
    }
    pub fn trial() Budget {
        return .{ .struct_size = 32, .version = 1, .reserved0 = 0, .reserved1 = 0, .allocation_left = 268435456, .work_left = 128000000 };
    }
};

pub const Identity = struct {
    source: [32]u8,
    roster: [32]u8,
    flags: u32,
    count: u32,
    text_bytes: u64,
    image_version: u32 = 1,
    scan_epoch: u32 = 1,
    lowering_epoch: u32 = 1,
    unicode_epoch: u32 = 1,
    unicode_version: [3]u32 = .{ 17, 0, 0 },
};
pub const Stats = struct {
    encoded: u64 = 208,
    decoded: u64 = 208,
    patterns: u64 = 0,
    voices: u64 = 0,
    states: u64 = 0,
    transitions: u64 = 0,
    auxiliary: u64 = 0,
};
pub const Site = enum { expected, frame, voices, dfa, transitions, masks, reach, seats, winners, program, worker, allow, validation, pending };
pub const Counters = struct {
    requests: [@typeInfo(Site).@"enum".fields.len]u64 = @splat(0),
    requested_bytes: u64 = 0,
    work: u64 = 0,
    live_peak: u64 = 0,
};
pub threadlocal var counters: Counters = .{};

pub fn add(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch return error.Oversized;
}
pub fn mul(a: u64, b: u64) Error!u64 {
    return std.math.mul(u64, a, b) catch return error.Oversized;
}
pub fn size(n: u64) Error!usize {
    return std.math.cast(usize, n) orelse return error.Oversized;
}

pub const Context = struct {
    base: std.mem.Allocator,
    limits: Limits,
    budget: *Budget,
    live: u64 = 0,

    pub fn init(base: std.mem.Allocator, limits: Limits, budget: *Budget, pending_bytes: u64) Error!Context {
        if (!limits.valid() or !budget.valid()) return error.InvalidArgument;
        if (@sizeOf(usize) != 8 or @sizeOf(Limits) != 80 or @alignOf(Limits) != 8 or
            @sizeOf(Budget) != 32 or @alignOf(Budget) != 8 or
            @offsetOf(Limits, "encoded_bytes") != 16 or @offsetOf(Limits, "live_owned_bytes") != 72 or
            @offsetOf(Budget, "allocation_left") != 16 or @offsetOf(Budget, "work_left") != 24)
            return error.Unsupported;
        if (pending_bytes > limits.live_owned_bytes) return error.Oversized;
        if (builtin.is_test) counters.live_peak = @max(counters.live_peak, pending_bytes);
        return .{ .base = base, .limits = limits, .budget = budget, .live = pending_bytes };
    }
    pub fn work(c: *Context, n: u64) Error!void {
        if (n > c.budget.work_left) return error.BudgetExceeded;
        c.budget.work_left -= n;
        if (builtin.is_test) counters.work +|= n;
    }
    pub fn checkStats(c: *const Context, s: Stats) Error!void {
        const l = c.limits;
        if (s.encoded > l.encoded_bytes or s.decoded > l.decoded_bytes or s.patterns > l.patterns or
            s.voices > l.voices or s.states > l.states or s.transitions > l.transition_entries or
            s.auxiliary > l.auxiliary_entries) return error.Oversized;
    }
    pub fn alloc(c: *Context, comptime T: type, n: usize, site: Site) Error![]T {
        const bytes = try mul(n, @sizeOf(T));
        const live = try add(c.live, bytes);
        if (live > c.limits.live_owned_bytes) return error.Oversized;
        if (bytes > c.budget.allocation_left) return error.BudgetExceeded;
        c.budget.allocation_left -= bytes;
        if (builtin.is_test and bytes != 0) {
            counters.requests[@intFromEnum(site)] +|= 1;
            counters.requested_bytes +|= bytes;
        }
        const result = try c.base.alloc(T, n);
        c.live = live;
        if (builtin.is_test) counters.live_peak = @max(counters.live_peak, live);
        return result;
    }
    pub fn create(c: *Context, comptime T: type, site: Site) Error!*T {
        return &(try c.alloc(T, 1, site))[0];
    }
    pub fn free(c: *Context, slice: anytype) void {
        const T = @typeInfo(@TypeOf(slice)).pointer.child;
        const bytes = @as(u64, slice.len) * @sizeOf(T);
        c.base.free(slice);
        std.debug.assert(bytes <= c.live);
        c.live -= bytes;
    }
    pub fn destroy(c: *Context, pointer: anytype) void {
        const T = @typeInfo(@TypeOf(pointer)).pointer.child;
        c.base.destroy(pointer);
        std.debug.assert(@sizeOf(T) <= c.live);
        c.live -= @sizeOf(T);
    }
    /// Ownership may be freed by ordinary base-allocator destructors. This only
    /// updates this live call's ledger; consumed cumulative debits never return.
    pub fn released(c: *Context, bytes: u64) void {
        std.debug.assert(bytes <= c.live);
        c.live -= bytes;
    }
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(Limits) == 80 and @alignOf(Limits) == 8);
        std.debug.assert(@sizeOf(Budget) == 32 and @alignOf(Budget) == 8);
        std.debug.assert(@offsetOf(Limits, "encoded_bytes") == 16 and @offsetOf(Limits, "live_owned_bytes") == 72);
        std.debug.assert(@offsetOf(Budget, "allocation_left") == 16 and @offsetOf(Budget, "work_left") == 24);
    }
}

test {
    _ = @import("munch_image_budget_test.zig");
}

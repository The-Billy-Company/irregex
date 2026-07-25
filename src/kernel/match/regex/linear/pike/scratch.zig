//! gist — Pike-VM scratch: the memory a linear-time simulation reuses across
//! haystacks. A `ThreadList` is the run-list of NFA states live at ONE input
//! position; `PikeScratch` sizes both lists plus the generation-counted `seen`
//! dedup once per program, so a search allocates nothing per line. Handed to
//! the VM by the caller (`Regex.Sim` / `Regex.SpanSim`) — the compiled `Regex`
//! itself stays immutable and shareable across threads.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const core = @import("../program/core.zig");

const ParseError = syn.ParseError;
const Regex = core.Regex;

/// A run-list of active states: a program-sized fixed buffer plus a fill cursor (capacity bounded by `states.len` — `Sim.seen` dedup adds each state at most once per generation).
pub const ThreadList = struct {
    buf: []u32,
    len: usize = 0,

    pub fn push(self: *ThreadList, s: u32) void {
        self.buf[self.len] = s;
        self.len += 1;
    }
    pub fn slice(self: ThreadList) []const u32 {
        return self.buf[0..self.len];
    }
};

/// Reusable Pike-simulation scratch (sized to the program once).
pub const Sim = PikeScratch(false);

/// Reusable Pike scratch for `matchSpan`, plus the per-state start-offset maps
/// (`scur`/`snxt`, one entry per state id, valid for the list's generation).
/// Kept apart from `Sim` so the hot boolean path never allocates the maps.
pub const SpanSim = PikeScratch(true);

/// One shape for both Pike scratch grains: `spans=true` adds the per-state
/// start-offset maps `matchSpan` threads through its closures; `false` leaves
/// them empty slices (never allocated — the hot boolean path stays map-free).
fn PikeScratch(comptime spans: bool) type {
    return struct {
        cur: ThreadList,
        nxt: ThreadList,
        seen: []u32,
        scur: []usize = &.{},
        snxt: []usize = &.{},
        gen: u32 = 0,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, re: *const Regex) ParseError!@This() {
            const n = re.states.len;
            const seen = try allocator.alloc(u32, n);
            @memset(seen, 0);
            return .{
                .cur = .{ .buf = try allocator.alloc(u32, n) },
                .nxt = .{ .buf = try allocator.alloc(u32, n) },
                .seen = seen,
                .scur = if (spans) try allocator.alloc(usize, n) else &.{},
                .snxt = if (spans) try allocator.alloc(usize, n) else &.{},
                .allocator = allocator,
            };
        }
        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.cur.buf);
            self.allocator.free(self.nxt.buf);
            self.allocator.free(self.seen);
            self.allocator.free(self.scur); // frees nothing when `spans` is off
            self.allocator.free(self.snxt);
            self.* = undefined;
        }
    };
}

//! irregex — the scratch pool: who owns the memory a search reuses.
//!
//! The linear engine allocates nothing per line, and it buys that by making the
//! *caller* hold the simulation state: `matchSpan(&sim, hay, from)`. That is the
//! right trade inside the walk — a worker builds one `SpanSim` and drives it
//! across a whole shard — and the wrong one at the door, where it means the
//! first thing anybody learns about this engine is the name of a Pike VM's
//! thread list.
//!
//! A pool is how both are true at once. It hands out scratch sized for one
//! program and takes it back, so a caller who never wants to know pays one
//! uncontended mutex per search instead of an allocation, and a caller who does
//! want to know still builds a `Sim` by hand and never comes here.
//!
//! **It holds no pointer to the matcher it serves.** The program is an argument
//! to `boolean`/`spans`, not a field, so a `Pattern` embedding a pool stays a
//! plain movable value — a pool that remembered its matcher would make every
//! handle above it self-referential, which is a sharp edge to hand a caller in
//! exchange for one saved parameter.

const std = @import("std");
const matcher = @import("../matcher.zig");
const lease = @import("../../math/lease.zig");

const Matcher = matcher.Matcher;

/// Reusable per-search scratch, by grain, guarded for concurrent callers.
///
/// The two grains are the engine's own (`Matcher.Sim` for the boolean paths,
/// `Matcher.SpanSim` for the span paths) and are kept apart for the reason the
/// engine keeps them apart: the boolean path never allocates the per-state
/// start-offset maps, so pooling them together would hand every `isMatch` the
/// span grain's memory.
pub const Pool = struct {
    gpa: std.mem.Allocator,
    /// The math floor's spin latch (`math.lease.Latch`) rather than a blocking
    /// mutex, and it is the primitive its own docstring asks for: both critical
    /// sections here are one list operation, allocation-shaped at worst, never a
    /// syscall. It also needs no `std.Io` handle, so a pool works on a raw
    /// worker thread — which is where scratch is wanted.
    lock: lease.Latch = .{},
    idle_boolean: std.ArrayList(*Matcher.Sim) = .empty,
    idle_spans: std.ArrayList(*Matcher.SpanSim) = .empty,

    /// The two loans, named so a caller (and a cursor) can hold one in a field.
    pub const Boolean = Loan(Matcher.Sim, "idle_boolean");
    pub const Spans = Loan(Matcher.SpanSim, "idle_spans");

    pub fn init(gpa: std.mem.Allocator) Pool {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Pool) void {
        for (self.idle_boolean.items) |s| {
            s.deinit();
            self.gpa.destroy(s);
        }
        for (self.idle_spans.items) |s| {
            s.deinit();
            self.gpa.destroy(s);
        }
        self.idle_boolean.deinit(self.gpa);
        self.idle_spans.deinit(self.gpa);
        self.* = undefined;
    }

    /// Boolean scratch for `of`, returned to the pool by `release`.
    pub fn boolean(self: *Pool, of: *const Matcher) !Boolean {
        return .{ .pool = self, .sim = try self.take(Matcher.Sim, "idle_boolean", of) };
    }

    /// Span scratch for `of`, returned to the pool by `release`.
    pub fn spans(self: *Pool, of: *const Matcher) !Spans {
        return .{ .pool = self, .sim = try self.take(Matcher.SpanSim, "idle_spans", of) };
    }

    /// How many of each grain are currently shelved — the pool's whole
    /// observable state, and what a test asserts reuse with.
    pub fn idle(self: *Pool) struct { boolean: usize, spans: usize } {
        self.lock.lock();
        defer self.lock.unlock();
        return .{ .boolean = self.idle_boolean.items.len, .spans = self.idle_spans.items.len };
    }

    fn take(self: *Pool, comptime S: type, comptime shelf: []const u8, of: *const Matcher) !*S {
        {
            self.lock.lock();
            defer self.lock.unlock();
            if (@field(self, shelf).pop()) |s| return s;
        }
        // Built outside the lock: sizing scratch to a program allocates, and
        // holding the mutex across it would serialize the one part of a search
        // that has no reason to be serial.
        const s = try self.gpa.create(S);
        errdefer self.gpa.destroy(s);
        s.* = try S.init(self.gpa, of);
        return s;
    }
};

/// A borrowed scratch, and the obligation to give it back.
///
/// `release` cannot fail, which is the only reason a caller can `defer` it. The
/// shelf is a list and re-shelving allocates, so the out-of-memory arm frees the
/// scratch instead of propagating: a pool is a cache, and failing to cache is
/// not a failure to search.
fn Loan(comptime S: type, comptime shelf: []const u8) type {
    return struct {
        pool: *Pool,
        sim: *S,

        pub fn release(self: @This()) void {
            self.pool.lock.lock();
            defer self.pool.lock.unlock();
            @field(self.pool, shelf).append(self.pool.gpa, self.sim) catch {
                self.sim.deinit();
                self.pool.gpa.destroy(self.sim);
            };
        }
    };
}

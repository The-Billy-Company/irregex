//! Ward tests: lease guards exclude correctly, and `readReconciled` takes the
//! fast/miss/error paths exactly — the double-checked dance verified against a
//! call-counting oracle, plus a threaded reader/writer invariant.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Ward = @import("ward.zig").Ward;

test "guards: shared leases overlap, exclusive excludes both" {
    const io = testing.io;
    var ward: Ward = .{};

    const r1 = ward.read(io);
    // A second reader gets in; a writer cannot while any reader holds.
    const r2 = ward.tryRead(io).?;
    try testing.expect(ward.tryWrite(io) == null);
    r2.release();
    try testing.expect(ward.tryWrite(io) == null); // r1 still holds
    r1.release();

    // With nothing held, exclusive is available and then excludes everything.
    const w = ward.tryWrite(io).?;
    try testing.expect(ward.tryRead(io) == null);
    try testing.expect(ward.tryWrite(io) == null);
    w.release();
    const r3 = ward.tryRead(io).?;
    r3.release();
}

test "write.downgrade trades exclusive for shared" {
    const io = testing.io;
    var ward: Ward = .{};

    const w = ward.write(io);
    const r = w.downgrade();
    // Now shared: another reader gets in, a writer does not.
    const r2 = ward.tryRead(io).?;
    try testing.expect(ward.tryWrite(io) == null);
    r2.release();
    r.release();
    try testing.expect(ward.tryWrite(io) != null); // fully released
}

const Oracle = struct {
    fresh_now: bool,
    refresh_calls: usize = 0,

    fn fresh(self: *Oracle) bool {
        return self.fresh_now;
    }
    fn refresh(self: *Oracle) error{}!void {
        self.refresh_calls += 1;
        self.fresh_now = true; // a real refresh brings the snapshot current
    }
    fn refreshFail(self: *Oracle) error{Boom}!void {
        self.refresh_calls += 1;
        return error.Boom;
    }
};

test "readReconciled: fast path answers under shared without refreshing" {
    const io = testing.io;
    var ward: Ward = .{};
    var oracle: Oracle = .{ .fresh_now = true };

    const lease = try ward.readReconciled(io, &oracle, Oracle.fresh, Oracle.refresh);
    try testing.expectEqual(@as(usize, 0), oracle.refresh_calls); // never upgraded
    try testing.expect(ward.tryWrite(io) == null); // shared is held
    lease.release();
    try testing.expect(ward.tryWrite(io) != null);
}

test "readReconciled: miss upgrades, refreshes once, downgrades to shared" {
    const io = testing.io;
    var ward: Ward = .{};
    var oracle: Oracle = .{ .fresh_now = false };

    const lease = try ward.readReconciled(io, &oracle, Oracle.fresh, Oracle.refresh);
    try testing.expectEqual(@as(usize, 1), oracle.refresh_calls);
    try testing.expect(ward.tryWrite(io) == null); // ends holding shared, not exclusive
    lease.release();
    try testing.expect(ward.tryWrite(io) != null);
}

test "readReconciled: a refresh error holds nothing" {
    const io = testing.io;
    var ward: Ward = .{};
    var oracle: Oracle = .{ .fresh_now = false };

    try testing.expectError(
        error.Boom,
        ward.readReconciled(io, &oracle, Oracle.fresh, Oracle.refreshFail),
    );
    try testing.expectEqual(@as(usize, 1), oracle.refresh_calls);
    // Nothing is held: exclusive is immediately available.
    const w = ward.tryWrite(io).?;
    w.release();
}

test "concurrent readers and writers keep the guarded pair consistent" {
    if (builtin.single_threaded) return;

    const io = testing.io;
    const Runner = struct {
        io: std.Io,
        ward: Ward = .{},
        writes: std.atomic.Value(usize) = .init(0),
        a: usize = 0,
        b: usize = 0,

        fn writer(run: *@This(), seed: usize) void {
            var prng = std.Random.DefaultPrng.init(seed);
            const rnd = prng.random();
            for (0..500) |_| {
                const w = run.ward.write(run.io);
                const v = rnd.int(usize);
                const ap: *volatile usize = &run.a;
                const bp: *volatile usize = &run.b;
                ap.* = v;
                std.Thread.yield() catch {};
                bp.* = v;
                _ = run.writes.fetchAdd(1, .monotonic);
                w.release();
            }
        }

        fn reader(run: *@This()) !void {
            for (0..2000) |_| {
                const r = run.ward.read(run.io);
                defer r.release();
                const ap: *const volatile usize = &run.a;
                const bp: *const volatile usize = &run.b;
                const old_a = ap.*;
                std.Thread.yield() catch {};
                // Under the shared lock no writer can be mid-update, so the pair
                // a reader observes is always internally consistent.
                try testing.expectEqual(old_a, bp.*);
            }
        }
    };

    var run: Runner = .{ .io = io };
    var writers: [2]std.Thread = undefined;
    var readers: [4]std.Thread = undefined;
    for (&writers, 0..) |*t, i| t.* = try .spawn(.{}, Runner.writer, .{ &run, i });
    for (&readers) |*t| t.* = try .spawn(.{}, Runner.reader, .{&run});
    for (writers) |t| t.join();
    for (readers) |t| t.join();
    try testing.expectEqual(@as(usize, 1000), run.writes.raw);
}

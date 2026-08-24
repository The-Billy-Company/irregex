//! assay/instrument — one comptime-schema'd counter set.
//!
//! The package grew several near-identical hand-rolled tally structs (the
//! `--json` summary fields, the `--stats` block), each re-declaring the same
//! integer fields plus its own field-by-field `add` for folding a per-worker
//! partial into the run total. `Tally(Schema)` is that mechanism, once: a fixed
//! array of counters indexed by an `enum` whose tags name the fields, with
//! compile-time-checked access (a typo'd counter name is a build error, not a
//! silently-zero field) and an allocation-free vector `fold` for the parallel
//! engine's per-worker → run merge.
//!
//! Deep-module intent: the same counting mechanism backs every distinct tally
//! *schema* rather than forcing unrelated output formats to share one field set
//! — the schema is a parameter, the storage/fold/accessor machinery is shared.

const std = @import("std");

/// A set of `usize` counters named by the tags of `Schema` (an `enum`). Access
/// is by tag, checked at compile time; storage is a flat array, so `fold` is a
/// straight-line vector add with no per-field boilerplate and no atomics on the
/// hot path (each worker owns a private `Tally`; the owner folds at the join).
pub fn Tally(comptime Schema: type) type {
    const info = @typeInfo(Schema);
    if (info != .@"enum") @compileError("Tally schema must be an enum of counter names");
    const n = info.@"enum".fields.len;
    return struct {
        const Self = @This();
        pub const Field = Schema;
        pub const len = n;

        counts: [n]usize = [_]usize{0} ** n,

        /// += 1 on one counter.
        pub fn bump(self: *Self, comptime f: Schema) void {
            self.counts[@intFromEnum(f)] += 1;
        }

        /// += 1 on a counter chosen at RUNTIME — for counting a decision that was
        /// just made, where the caller holds the outcome as a value rather than
        /// knowing statically which counter it lands in. Same storage, same fold;
        /// only the index is dynamic, and an `enum` tag cannot index out of range.
        pub fn record(self: *Self, f: Schema) void {
            self.counts[@intFromEnum(f)] += 1;
        }

        /// += n on one counter.
        pub fn add(self: *Self, comptime f: Schema, n_: usize) void {
            self.counts[@intFromEnum(f)] += n_;
        }

        /// Overwrite one counter (e.g. `bytes_printed`, set once from the final
        /// output buffer length rather than accumulated).
        pub fn set(self: *Self, comptime f: Schema, n_: usize) void {
            self.counts[@intFromEnum(f)] = n_;
        }

        /// Read one counter.
        pub fn get(self: *const Self, comptime f: Schema) usize {
            return self.counts[@intFromEnum(f)];
        }

        /// Sum another tally into this one — the per-worker → run-total merge.
        pub fn fold(self: *Self, other: Self) void {
            for (&self.counts, other.counts) |*c, v| c.* += v;
        }

        /// Sum every counter EXCEPT the named ones (the `--stats` block folds
        /// its accumulating counters but leaves `bytes_printed`, which its owner
        /// sets from the final buffer length after all workers have joined).
        pub fn foldExcept(self: *Self, other: Self, comptime exclude: []const Schema) void {
            inline for (0..n) |i| {
                const skip = comptime blk: {
                    for (exclude) |e| if (@intFromEnum(e) == i) break :blk true;
                    break :blk false;
                };
                if (!skip) self.counts[i] += other.counts[i];
            }
        }
    };
}

test "Tally counts, sets, and reads by tag" {
    const Schema = enum { hits, misses, bytes };
    var t: Tally(Schema) = .{};
    t.bump(.hits);
    t.bump(.hits);
    t.add(.bytes, 100);
    t.set(.misses, 3);
    try std.testing.expectEqual(@as(usize, 2), t.get(.hits));
    try std.testing.expectEqual(@as(usize, 3), t.get(.misses));
    try std.testing.expectEqual(@as(usize, 100), t.get(.bytes));
}

test "Tally.record counts a runtime-chosen counter" {
    const Schema = enum { elide, stale };
    var t: Tally(Schema) = .{};
    // The shape the caller has: an outcome in a variable, not a literal tag.
    for ([_]Schema{ .stale, .elide, .stale }) |v| t.record(v);
    try std.testing.expectEqual(@as(usize, 1), t.get(.elide));
    try std.testing.expectEqual(@as(usize, 2), t.get(.stale));
}

test "Tally.fold sums two partials" {
    const Schema = enum { a, b };
    var run: Tally(Schema) = .{};
    var w1: Tally(Schema) = .{};
    var w2: Tally(Schema) = .{};
    w1.add(.a, 5);
    w1.add(.b, 1);
    w2.add(.a, 2);
    w2.add(.b, 4);
    run.fold(w1);
    run.fold(w2);
    try std.testing.expectEqual(@as(usize, 7), run.get(.a));
    try std.testing.expectEqual(@as(usize, 5), run.get(.b));
}

test "Tally.foldExcept skips the excluded counter" {
    const Schema = enum { matches, bytes_printed };
    var run: Tally(Schema) = .{};
    var worker: Tally(Schema) = .{};
    worker.add(.matches, 4);
    worker.add(.bytes_printed, 999); // a worker must never pre-set this
    run.foldExcept(worker, &.{.bytes_printed});
    try std.testing.expectEqual(@as(usize, 4), run.get(.matches));
    try std.testing.expectEqual(@as(usize, 0), run.get(.bytes_printed));
}

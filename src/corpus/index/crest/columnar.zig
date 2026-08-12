//! Sparse-gather and dense-SIMD execution over a decoded CREST sidecar view.
const std = @import("std");
const crest = @import("../../../kernel/math/crest.zig");

pub fn retain(
    view: anytype,
    gpa: std.mem.Allocator,
    candidates: *std.DynamicBitSet,
    swell: crest.RankedSwell,
) std.mem.Allocator.Error!void {
    if (candidates.count() <= view.document_count / 4)
        return retainSparse(view, gpa, candidates, swell);
    return retainDense(view, gpa, candidates, swell);
}

fn retainSparse(
    view: anytype,
    gpa: std.mem.Allocator,
    candidates: *std.DynamicBitSet,
    swell: crest.RankedSwell,
) std.mem.Allocator.Error!void {
    const Candidate = struct { document: u32, failures: u8 = 0 };
    const selected = try gpa.alloc(Candidate, candidates.count());
    defer gpa.free(selected);
    var iterator = candidates.iterator(.{});
    var count: usize = 0;
    while (iterator.next()) |document| {
        if (document >= view.document_count) continue;
        selected[count] = .{ .document = @intCast(document) };
        count += 1;
    }
    const bounded = selected[0..count];

    for (0..swell.rank) |rank| for (0..crest.K) |predicate| {
        const logical = crest.spectrumLane(predicate, rank);
        var required = false;
        for (swell.requirements[0..swell.len]) |requirement|
            required = required or requirement[logical] != 0;
        if (!required) continue;
        for (bounded) |*candidate| {
            const slot = view.value(predicate, rank, candidate.document);
            for (swell.requirements[0..swell.len], 0..) |requirement, alternative| {
                const failed = @as(u8, 1) << @intCast(alternative);
                if (candidate.failures & failed == 0 and slot < requirement[logical])
                    candidate.failures |= failed;
            }
        }
    };
    const all_failed = allFailed(swell.len);
    for (bounded) |candidate|
        if (candidate.failures == all_failed) candidates.unset(candidate.document);
}

fn retainDense(
    view: anytype,
    gpa: std.mem.Allocator,
    candidates: *std.DynamicBitSet,
    swell: crest.RankedSwell,
) std.mem.Allocator.Error!void {
    const vector_len = std.simd.suggestVectorLength(u8) orelse 16;
    const BaseVector = @Vector(vector_len, u8);
    const failures = try gpa.alloc(u8, view.document_count);
    defer gpa.free(failures);
    @memset(failures, 0);

    for (0..swell.rank) |rank| for (0..crest.K) |predicate| {
        const logical = crest.spectrumLane(predicate, rank);
        var required = false;
        for (swell.requirements[0..swell.len]) |requirement|
            required = required or requirement[logical] != 0;
        if (!required) continue;
        const physical = view.column(predicate, rank) orelse continue;
        var offset: usize = 0;
        while (offset + vector_len <= physical.base.len) : (offset += vector_len) {
            const values: BaseVector = physical.base[offset..][0..vector_len].*;
            for (swell.requirements[0..swell.len], 0..) |requirement, alternative| {
                const threshold = requirement[logical];
                if (threshold == 0) continue;
                const failed = @as(u8, 1) << @intCast(alternative);
                const bound: BaseVector = @splat(@intCast(@min(threshold, 255)));
                const definitely_short = values < bound;
                inline for (0..vector_len) |lane| {
                    const document = offset + lane;
                    if (candidates.isSet(document) and failures[document] & failed == 0 and
                        (definitely_short[lane] or threshold > 255 and physical.value(document) < threshold))
                        failures[document] |= failed;
                }
            }
        }
        while (offset < physical.base.len) : (offset += 1) {
            if (!candidates.isSet(offset)) continue;
            const slot = physical.value(offset);
            for (swell.requirements[0..swell.len], 0..) |requirement, alternative| {
                const failed = @as(u8, 1) << @intCast(alternative);
                if (failures[offset] & failed == 0 and slot < requirement[logical])
                    failures[offset] |= failed;
            }
        }
    };
    const all_failed = allFailed(swell.len);
    var iterator = candidates.iterator(.{});
    while (iterator.next()) |document|
        if (document < failures.len and failures[document] == all_failed)
            candidates.unset(document);
}

fn allFailed(alternatives: u8) u8 {
    const shift: u3 = @intCast(@as(u8, 8) - alternatives);
    return @as(u8, std.math.maxInt(u8)) >> shift;
}

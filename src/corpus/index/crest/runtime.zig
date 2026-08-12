//! Cost-gated application of a validated CREST sidecar.
const std = @import("std");
const crest = @import("../../../kernel/math/crest.zig");
const planner = @import("planner.zig");
const sidecar = @import("sidecar.zig");

/// Apply CREST in place. Until all corpus-fitted coefficients are supplied,
/// retain the proven production behavior and run the sieve.
pub fn apply(
    gpa: std.mem.Allocator,
    view: sidecar.View,
    candidates: *std.DynamicBitSet,
    swell: crest.RankedSwell,
) std.mem.Allocator.Error!?planner.Decision {
    if (!swell.active()) return null;
    const coefficients = calibratedCosts() orelse {
        view.retainColumnar(gpa, candidates, swell) catch return null;
        return null;
    };
    const decision = view.plan(swell, candidates, coefficients);
    if (decision.run) view.retainColumnar(gpa, candidates, swell) catch return null;
    return decision;
}

/// Calibration is deliberately external to the correctness kernel. Partial or
/// malformed settings are absent, preserving the always-sieve default.
pub fn calibratedCosts() ?planner.Coefficients {
    return .{
        .fixed = knob("IRGX_CREST_COST_FIXED") orelse return null,
        .column_document = knob("IRGX_CREST_COST_COLUMN_DOC") orelse return null,
        .verify_document = knob("IRGX_CREST_COST_READ_MATCH_DOC") orelse return null,
    };
}

fn knob(comptime name: [:0]const u8) ?u64 {
    const raw = std.c.getenv(name) orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, std.mem.span(raw), " \t"), 10) catch null;
}

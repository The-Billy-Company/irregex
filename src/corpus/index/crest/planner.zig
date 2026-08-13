//! Calibrated CREST cost gate.
const std = @import("std");

pub const basis_points: u16 = 10_000;

pub const Input = struct {
    touched_columns: u16,
    candidate_docs: u64,
    scanned_docs: u64,
    expected_candidates: u64,
};

pub const Coefficients = struct {
    fixed: u64,
    column_document: u64,
    verify_document: u64,
    minimum_savings: u64 = 0,
    minimum_savings_bps: u16 = 0,

    pub fn valid(self: Coefficients) bool {
        return self.minimum_savings_bps <= basis_points;
    }
};

pub const Reason = enum {
    profitable,
    inactive,
    no_candidates,
    no_reduction,
    invalid_estimate,
    invalid_coefficients,
    arithmetic_overflow,
    unprofitable,
    below_absolute_margin,
    below_relative_margin,
};

pub const Decision = struct {
    run: bool = false,
    reason: Reason,
    touched_columns: u16 = 0,
    candidate_docs: u64 = 0,
    scanned_docs: u64 = 0,
    expected_candidates: u64 = 0,
    expected_rejected: u64 = 0,
    direct_cost: u128 = 0,
    column_cost: u128 = 0,
    survivor_cost: u128 = 0,
    crest_cost: u128 = 0,
    estimated_savings: u128 = 0,
    required_savings: u128 = 0,
};

pub fn fromMask(
    touched: anytype,
    candidate_docs: u64,
    scanned_docs: u64,
    expected_candidates: u64,
    coefficients: Coefficients,
) Decision {
    const count = @popCount(touched);
    if (count > std.math.maxInt(u16))
        return decline(.arithmetic_overflow, .{
            .touched_columns = std.math.maxInt(u16),
            .candidate_docs = candidate_docs,
            .scanned_docs = scanned_docs,
            .expected_candidates = expected_candidates,
        });
    return decide(.{
        .touched_columns = @intCast(count),
        .candidate_docs = candidate_docs,
        .scanned_docs = scanned_docs,
        .expected_candidates = expected_candidates,
    }, coefficients);
}

pub fn scannedDocs(candidate_docs: u64, document_count: u64) u64 {
    return if (candidate_docs <= document_count / 4) candidate_docs else document_count;
}

pub fn decide(input: Input, coefficients: Coefficients) Decision {
    var decision: Decision = .{
        .reason = .inactive,
        .touched_columns = input.touched_columns,
        .candidate_docs = input.candidate_docs,
        .scanned_docs = input.scanned_docs,
        .expected_candidates = input.expected_candidates,
    };
    if (!coefficients.valid()) return withReason(decision, .invalid_coefficients);
    if (input.touched_columns == 0) return decision;
    if (input.expected_candidates > input.candidate_docs or
        input.scanned_docs < input.candidate_docs or
        input.candidate_docs == 0 and input.scanned_docs != 0)
        return withReason(decision, .invalid_estimate);
    if (input.candidate_docs == 0) return withReason(decision, .no_candidates);
    decision.expected_rejected = input.candidate_docs - input.expected_candidates;
    if (decision.expected_rejected == 0) return withReason(decision, .no_reduction);

    decision.direct_cost = mul(input.candidate_docs, coefficients.verify_document) orelse
        return withReason(decision, .arithmetic_overflow);
    const per_document = mul(input.touched_columns, coefficients.column_document) orelse
        return withReason(decision, .arithmetic_overflow);
    const variable_columns = mul(input.scanned_docs, per_document) orelse
        return withReason(decision, .arithmetic_overflow);
    decision.column_cost = add(coefficients.fixed, variable_columns) orelse
        return withReason(decision, .arithmetic_overflow);
    decision.survivor_cost = mul(input.expected_candidates, coefficients.verify_document) orelse
        return withReason(decision, .arithmetic_overflow);
    decision.crest_cost = add(decision.column_cost, decision.survivor_cost) orelse
        return withReason(decision, .arithmetic_overflow);
    if (decision.crest_cost >= decision.direct_cost)
        return withReason(decision, .unprofitable);

    decision.estimated_savings = decision.direct_cost - decision.crest_cost;
    if (decision.estimated_savings < coefficients.minimum_savings) {
        decision.required_savings = coefficients.minimum_savings;
        return withReason(decision, .below_absolute_margin);
    }
    const relative = relativeThreshold(decision.direct_cost, coefficients.minimum_savings_bps) orelse
        return withReason(decision, .arithmetic_overflow);
    decision.required_savings = @max(coefficients.minimum_savings, relative);
    if (decision.estimated_savings < relative)
        return withReason(decision, .below_relative_margin);
    decision.run = true;
    return withReason(decision, .profitable);
}

fn relativeThreshold(cost: u128, bps: u16) ?u128 {
    if (bps == 0) return 0;
    const whole = mul(cost / basis_points, bps) orelse return null;
    const remainder = mul(cost % basis_points, bps) orelse return null;
    return add(whole, (remainder + basis_points - 1) / basis_points);
}

fn decline(reason: Reason, input: Input) Decision {
    return .{
        .reason = reason,
        .touched_columns = input.touched_columns,
        .candidate_docs = input.candidate_docs,
        .scanned_docs = input.scanned_docs,
        .expected_candidates = input.expected_candidates,
    };
}

fn withReason(decision: Decision, reason: Reason) Decision {
    var result = decision;
    result.reason = reason;
    return result;
}

fn mul(a: anytype, b: anytype) ?u128 {
    return std.math.mul(u128, @as(u128, @intCast(a)), @as(u128, @intCast(b))) catch null;
}

fn add(a: anytype, b: anytype) ?u128 {
    return std.math.add(u128, @as(u128, @intCast(a)), @as(u128, @intCast(b))) catch null;
}

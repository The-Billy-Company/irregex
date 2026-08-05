//! Tests for the answer vocabulary — the half-open convention and the
//! zero-width case, which are the two things every consumer of a `Span` has to
//! get right and the two the four separate declarations used to each restate.
//!
//! Nothing here asserts that a field holds what was put in it. What is pinned
//! is the arithmetic the convention forces: that `end` is outside the span, that
//! adjacent spans share an endpoint without overlapping, and that a zero-width
//! span names no byte at all — the case an iterator loops forever on when the
//! convention is misread.

const std = @import("std");
const mark = @import("mark.zig");
const Span = mark.Span;
const Match = mark.Match;
const PatternID = mark.PatternID;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "half-open: end is outside, and adjacent spans share it without overlapping" {
    const hay = "hello world";
    const a: Span = .{ .start = 0, .end = 5 };
    const b: Span = .{ .start = 5, .end = 11 };

    try expectEqualStrings("hello", a.of(hay));
    try expectEqualStrings(" world", b.of(hay));
    try expectEqual(hay.len, a.len() + b.len());

    // The shared endpoint belongs to exactly one of them.
    try expect(!a.holds(5));
    try expect(b.holds(5));
    // And no position is claimed twice.
    for (0..hay.len) |i| try expect(a.holds(i) != b.holds(i));
}

test "a zero-width span names no byte, at any position including the end" {
    const hay = "abc";
    for (0..hay.len + 1) |i| {
        const empty: Span = .{ .start = i, .end = i };
        try expect(empty.isEmpty());
        try expectEqual(@as(usize, 0), empty.len());
        try expectEqualStrings("", empty.of(hay));
        // The position it sits at is not inside it — which is why an iterator
        // resuming from `end` on a nullable pattern never advances.
        try expect(!empty.holds(i));
    }
}

test "a whole-haystack span holds every byte and nothing past the last" {
    const hay = "xyz";
    const all: Span = .{ .start = 0, .end = hay.len };
    try expect(!all.isEmpty());
    for (0..hay.len) |i| try expect(all.holds(i));
    try expect(!all.holds(hay.len));
    try expectEqualStrings(hay, all.of(hay));
}

test "pattern ids round-trip through their ordinals, and `first` is ordinal zero" {
    try expectEqual(@as(u32, 0), PatternID.first.ordinal());
    try expectEqual(PatternID.first, PatternID.at(0));
    for ([_]u32{ 0, 1, 63, 64, 4095, std.math.maxInt(u32) }) |n| {
        try expectEqual(n, PatternID.at(n).ordinal());
    }
    // Distinct ordinals are distinct ids — the property a bare integer index
    // into a mask word does not have.
    try expect(PatternID.at(1) != PatternID.at(64));
}

test "a match defaults to the single-pattern id and borrows its own bytes" {
    const hay = "fn main() void {}";
    const m: Match = .{ .span = .{ .start = 3, .end = 7 } };
    try expectEqual(PatternID.first, m.pattern);
    try expectEqualStrings("main", m.of(hay));

    const second: Match = .{ .span = .{ .start = 0, .end = 2 }, .pattern = PatternID.at(1) };
    try expectEqual(@as(u32, 1), second.pattern.ordinal());
    try expectEqualStrings("fn", second.of(hay));
}

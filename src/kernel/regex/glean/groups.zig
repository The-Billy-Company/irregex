//! irregex — what a capture group caught, addressed by index or by name.
//!
//! The capture engines answer into a slot vector: `find(line, from, out)` fills
//! `out` with `2n` signed integers, group `i` occupying `out[2i]`/`out[2i+1]`,
//! and `-1` meaning that group did not participate in this match. That is the
//! right representation to *compute* — one flat buffer, no allocation per match,
//! a sentinel that costs no tag — and the wrong one to hand back, because it
//! makes every caller re-derive the same three facts: that slots are pairs, that
//! a group is absent rather than empty when its start is negative, and that the
//! signed integers are really offsets into a haystack it has to keep beside them.
//!
//! `Groups` is the view that knows those three things once. It owns nothing and
//! copies nothing — a pointer, a slice, and the arithmetic — so the flat buffer
//! keeps being the representation and stops being the interface.
//!
//! Absence stays absence. A group that did not participate is `null`, never an
//! empty span at position zero, because `(a)|b` matching `b` and `(a?)` matching
//! empty are different answers and a caller that cannot tell them apart will
//! eventually be asked to.

const std = @import("std");
const captures = @import("../compile/captures.zig");
const mark = @import("../../../mark.zig");

const Caps = captures.Caps;

pub const Span = mark.Span;

/// One match's capture groups: spans by ordinal or by name, over the haystack
/// they were measured in.
///
/// **Borrowed, and briefly.** The slots are the buffer the capture engine just
/// wrote, which its owner reuses for the next match — so a `Groups` is a reading
/// of one answer, valid until the next capture query on the same handle. Copy
/// out the spans (or the bytes) you intend to keep.
pub const Groups = struct {
    caps: *const Caps,
    hay: []const u8,
    slots: []const isize,

    /// How many groups the pattern declares, group 0 (the whole match) included.
    pub fn len(self: Groups) usize {
        return self.slots.len / 2;
    }

    /// Group `i`'s span, or null when it did not participate. Group 0 is the
    /// whole match, which is why this is also how a caller gets that.
    pub fn get(self: Groups, i: usize) ?Span {
        if (i * 2 + 1 >= self.slots.len) return null;
        const start = self.slots[i * 2];
        const end = self.slots[i * 2 + 1];
        if (start < 0 or end < 0) return null;
        return .{ .start = @intCast(start), .end = @intCast(end) };
    }

    /// The whole match — group 0, named because reaching for a literal `0` is
    /// how a reader is left wondering whether the numbering is off by one.
    pub fn all(self: Groups) ?Span {
        return self.get(0);
    }

    /// The span of the group spelled `(?<name>…)`, or null when the pattern has
    /// no such group *or* it did not participate. The two are deliberately one
    /// answer here: both mean "nothing to read under that name", and a caller
    /// that needs to know a name is unknown asks `ordinal`.
    pub fn named(self: Groups, name: []const u8) ?Span {
        return self.get(self.caps.groupByName(name) orelse return null);
    }

    /// Group `i`'s bytes, borrowed from the haystack.
    pub fn text(self: Groups, i: usize) ?[]const u8 {
        return (self.get(i) orelse return null).of(self.hay);
    }

    /// The named group's bytes, borrowed from the haystack.
    pub fn namedText(self: Groups, name: []const u8) ?[]const u8 {
        return (self.named(name) orelse return null).of(self.hay);
    }

    /// Which ordinal a name refers to, whether or not it participated — the
    /// question `named` folds away, kept reachable for the caller that is
    /// validating a pattern rather than reading a match.
    pub fn ordinal(self: Groups, name: []const u8) ?usize {
        return self.caps.groupByName(name) orelse null;
    }

    /// The name of group `i`, when it has one.
    pub fn nameOf(self: Groups, i: usize) ?[]const u8 {
        return self.caps.nameOfGroup(@intCast(i));
    }
};

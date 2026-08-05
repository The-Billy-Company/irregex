//! irregex — rewriting a haystack from the match stream: replace and split.
//!
//! Both verbs are the same walk with different bookkeeping — the matches carve
//! the haystack into alternating kept and cut runs, and the two verbs disagree
//! only about what to do with each. Written once here over a `Cursor`, so they
//! inherit its zero-width rule instead of each re-deriving it (a `split` on a
//! pattern that can match empty is precisely where a hand-rolled loop hangs).
//!
//! **No `$1` template language.** A replacement that can name capture groups is
//! worth having, and a bespoke mini-syntax for it is not: it needs its own
//! parser, its own escaping rule, and its own error channel, all to express
//! something the host language already says better. `replaceWith` takes a
//! callback that is handed the match and writes what it likes — group
//! references, case folding, a lookup table, arithmetic — and costs no grammar.

const std = @import("std");
const cursor_mod = @import("cursor.zig");

const Cursor = cursor_mod.Cursor;
const Span = cursor_mod.Span;

/// How many matches a rewrite acts on: every one, or the first `n`.
///
/// An explicit union rather than a `0 means all` integer, because that
/// convention makes the most common intent look like a degenerate one and turns
/// a caller's arithmetic bug into a silent whole-document rewrite.
pub const Reach = union(enum) {
    all,
    first: usize,

    fn admits(self: Reach, n: usize) bool {
        return switch (self) {
            .all => true,
            .first => |k| n < k,
        };
    }
};

/// The haystack with matched runs replaced by the literal `with`. Caller owns
/// the result.
pub fn replace(gpa: std.mem.Allocator, cur: *Cursor, with: []const u8, reach: Reach) ![]u8 {
    const Lit = struct {
        text: []const u8,
        pub fn put(self: @This(), out: *std.ArrayList(u8), alloc: std.mem.Allocator, _: []const u8, _: Span) !void {
            try out.appendSlice(alloc, self.text);
        }
    };
    return replaceWith(gpa, cur, Lit{ .text = with }, reach);
}

/// The haystack with each matched run replaced by whatever `writer` emits for
/// it. `writer` is any value with
/// `put(*std.ArrayList(u8), std.mem.Allocator, hay, Span) !void` — duck-typed at
/// comptime, so a closure over captures, a table lookup, or a counter all fit
/// without this module knowing which. Caller owns the result.
pub fn replaceWith(
    gpa: std.mem.Allocator,
    cur: *Cursor,
    writer: anytype,
    reach: Reach,
) ![]u8 {
    const hay = cur.win.hay;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var cut: usize = 0;
    var n: usize = 0;
    while (reach.admits(n)) : (n += 1) {
        const m = cur.next() orelse break;
        // A zero-width match behind the write head cannot contribute: the
        // cursor's escape step can land it inside a run already copied out, and
        // emitting there would duplicate the replacement.
        if (m.start < cut) continue;
        try out.appendSlice(gpa, hay[cut..m.start]);
        try writer.put(&out, gpa, hay, m);
        cut = m.end;
    }
    try out.appendSlice(gpa, hay[cut..]);
    return out.toOwnedSlice(gpa);
}

/// The runs between matches, in order. Each piece borrows `hay`; the slice of
/// pieces is the caller's to free.
///
/// A match at either edge yields an empty piece there, which is the answer that
/// composes: the piece count is always one more than the match count, so a
/// caller can index by field position without discovering that a leading
/// separator silently shifted everything left.
pub fn split(gpa: std.mem.Allocator, cur: *Cursor, reach: Reach) ![][]const u8 {
    const hay = cur.win.hay;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    var cut: usize = 0;
    var n: usize = 0;
    while (reach.admits(n)) : (n += 1) {
        const m = cur.next() orelse break;
        if (m.start < cut) continue;
        try out.append(gpa, hay[cut..m.start]);
        cut = m.end;
    }
    try out.append(gpa, hay[cut..]);
    return out.toOwnedSlice(gpa);
}

//! irregex — successive matches, pulled one at a time.
//!
//! The engine answers "where is the leftmost match at or after `from`". Turning
//! that into "every match" is a loop, and the whole difficulty is the zero-width
//! case: `a*` accepts the empty string at every position, so `end == start` and
//! a naive resume at `span.end` searches the same offset forever. The escape is
//! to step one byte past an empty match — one BYTE, in the same coordinate
//! system the spans are reported in, never one codepoint. A codepoint step looks
//! more principled and is wrong: it silently drops the empty match at the second
//! byte of `é`, which every byte-offset regex library reports.
//!
//! **This package answers with two different sequences, on purpose.** They are
//! not a drift; they are two contracts, and a caller is entitled to know which
//! one it is holding.
//!
//! | | `Cursor` (this file) | `query.zig`'s `walk` |
//! |---|---|---|
//! | audience | a library caller with a haystack | the `gist` CLI, and the C ABI over it |
//! | bar | Python `re`, `rust-regex`, JS — byte-identical | ripgrep — byte-identical |
//! | empty match adjacent to the last one | reported | suppressed |
//! | empty match at the very end | reported | only on a newline-terminated line |
//!
//! Concretely, `b*` over `abcb`: here `(0,0) (1,2) (2,2) (3,4) (4,4)`, there
//! `(0,0) (1,2) (3,4)`. Both are right. rg drops the adjacent and unterminated
//! empties because it prints line-oriented rows and those two would be noise on
//! a page; a library that dropped them would disagree with every other regex
//! library its caller has ever used. `../../query/zero_width_test.zig` pins
//! both against their own outside bar, so
//! neither can move without the other's bar noticing.
//!
//! `Cursor` is the house noun for a pull stream (`surface/api.zig` drives whole
//! corpora through one, the C ABI's row protocol is the same shape at the wire).
//! This is that shape at the smallest grain: one pattern, one haystack.

const std = @import("std");
const matcher = @import("../matcher.zig");
const pool_mod = @import("pool.zig");
const mark = @import("../../../mark.zig");

const Matcher = matcher.Matcher;
const Pool = pool_mod.Pool;

pub const Span = mark.Span;
pub const Window = mark.Window;

/// Non-overlapping leftmost matches of one pattern over one window.
///
/// Borrows both the pattern and the haystack — it holds a scratch loan for its
/// whole life, so it is the right shape for a walk and the wrong one to stash.
/// `deinit` returns the loan; a cursor dropped without it leaks one scratch into
/// the pool's owner, not into the allocator.
pub const Cursor = struct {
    of: *const Matcher,
    loan: Pool.Spans,
    win: Window,
    at: usize,
    /// Set once the walk can produce nothing further, so a caller polling a
    /// finished cursor pays a branch rather than a search.
    spent: bool = false,

    pub fn init(of: *const Matcher, loan: Pool.Spans, win: Window) Cursor {
        return .{ .of = of, .loan = loan, .win = win, .at = win.from };
    }

    pub fn deinit(self: *Cursor) void {
        self.loan.release();
        self.* = undefined;
    }

    /// The next match, or null once the window is exhausted.
    pub fn next(self: *Cursor) ?Span {
        if (self.spent) return null;
        const to = @min(self.win.to, self.win.hay.len);
        if (self.at > to) {
            self.spent = true;
            return null;
        }
        const found = switch (self.of.matchWindow(self.loan.sim, .{
            .hay = self.win.hay,
            .from = self.at,
            .to = self.win.to,
        })) {
            .found => |sp| sp,
            // `.none` ends the walk. `.decline` cannot reach here: a cursor is
            // only ever built over a bound its engine accepted (see
            // `Pattern.matchesIn`), so treating it as the end is the fail-closed
            // arm of an unreachable case rather than a silent truncation.
            .none, .decline => {
                self.spent = true;
                return null;
            },
        };
        // The zero-width escape: one byte on, in the coordinate system the span
        // was reported in. Stepping a whole codepoint here would skip the empty
        // match at a continuation byte, which `l*` over `héllo` says exists.
        self.at = if (found.isEmpty()) found.end + 1 else found.end;
        return found;
    }

    /// How many matches remain, consuming the cursor. Separate from a `count`
    /// that re-searches, because the honest answer to "how many" is "walk them",
    /// and a caller who wants the number rather than the spans should not have
    /// to write the discard loop.
    pub fn tally(self: *Cursor) usize {
        var n: usize = 0;
        while (self.next()) |_| n += 1;
        return n;
    }
};

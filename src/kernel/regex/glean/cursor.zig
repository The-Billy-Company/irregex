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

/// Non-overlapping matches of one pattern over one window — leftmost-first by
/// default, and under `Mode` the anchored run or the earliest sequence.
///
/// Borrows both the pattern and the haystack — it holds a scratch loan for its
/// whole life, so it is the right shape for a walk and the wrong one to stash.
/// `deinit` returns the loan; a cursor dropped without it leaks one scratch into
/// the pool's owner, not into the allocator.
pub const Cursor = struct {
    of: *const Matcher,
    loan: Pool.Spans,
    /// The halting machine, borrowed for this walk's life — present only when the
    /// mode asks it something (see `Pattern.walk`). A leftmost walk holds none, so
    /// it keeps exactly the cost it always had.
    probe: ?Pool.Probes,
    win: Window,
    at: usize,
    mode: Mode,
    /// Set once the walk can produce nothing further, so a caller polling a
    /// finished cursor pays a branch rather than a search.
    spent: bool = false,
    /// An earliest step the halting machine could not decide — its determinization
    /// memo quit mid-walk (memory pressure, or an allocation that failed).
    ///
    /// The walk ends there, and this says so, because the two silent alternatives
    /// are both worse: reporting the leftmost span instead would publish a
    /// different sequence under an earliest label, and ending quietly would hand a
    /// caller a truncated count as if it were the total. A caller that sees this
    /// set must refuse rather than publish what it collected.
    undecided: bool = false,

    /// Which sequence a walk reports — the two request bits, and the only thing
    /// that changes WHICH match each step returns.
    pub const Mode = struct {
        /// Must every match begin exactly where the search resumed?
        ///
        /// The anchored walk, and it is a property of the SEARCH rather than of
        /// the pattern: `\A` would still mean offset zero, where this means
        /// wherever this cursor currently stands. So the two differ from the
        /// second match onward, and at a `win.from` past zero they differ
        /// immediately — which is the whole reason it is not spelled by rewriting
        /// the pattern.
        ///
        /// Successive anchored matches are therefore contiguous: each begins where
        /// the last ended, and the walk STOPS at the first position nothing starts
        /// at rather than skipping ahead to the next one that does. That is the
        /// tokenizer's reading of "every match", and it is the only one under which
        /// `anchored` says anything a filter over the unanchored answer could not.
        ///
        /// The zero-width escape below is the one deliberate break in that
        /// contiguity, for the same reason it exists at all: an empty match hands
        /// the walk back the offset it just searched, so a rule with no step would
        /// report it forever.
        anchored: bool = false,
        /// Report the match that ENDS first rather than the one that starts first.
        ///
        /// Not a filter over the leftmost sequence and not derivable from it: `a+`
        /// over `aaa` is one leftmost match `(0,3)` and three earliest ones
        /// `(0,1) (1,2) (2,3)`, and `a*` is `(0,3)` against an empty match at 0.
        /// It is what `regex-automata`'s earliest search reports and what a
        /// "does this prefix match yet" caller is actually asking.
        ///
        /// Both spans still come out of the same span engine (`matchWindow`); what
        /// the earliest walk changes is the CEILING it is asked under — the first
        /// accepting position, which the halting walk found without extracting
        /// anything. Every match in `[at, that position]` ends exactly there, by
        /// minimality, so the leftmost-first answer inside it is the earliest
        /// match: the earliest end, and the leftmost start among the matches
        /// reaching it.
        earliest: bool = false,
    };

    pub fn init(of: *const Matcher, loan: Pool.Spans, win: Window, mode: Mode, probe: ?Pool.Probes) Cursor {
        return .{ .of = of, .loan = loan, .probe = probe, .win = win, .at = win.from, .mode = mode };
    }

    pub fn deinit(self: *Cursor) void {
        if (self.probe) |p| p.release();
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
        const found = self.step() orelse {
            self.spent = true;
            return null;
        };
        // The zero-width escape: one byte on, in the coordinate system the span
        // was reported in. Stepping a whole codepoint here would skip the empty
        // match at a continuation byte, which `l*` over `héllo` says exists.
        self.at = if (found.isEmpty()) found.end + 1 else found.end;
        return found;
    }

    /// One search from `self.at` under this walk's mode.
    fn step(self: *Cursor) ?Span {
        const win: Window = .{ .hay = self.win.hay, .from = self.at, .to = self.win.to };
        switch (self.halt(win)) {
            // Nothing in the rest of the window accepts — anchored, nothing
            // BEGINS here, and there is nothing further to look for either, since
            // every later start is further still from where the search stood.
            // Either way no leftmost search could produce an admissible span, so
            // none is run. This is the work the anchored walk used to pay for and
            // discard: a hunt across positions it was never allowed to report.
            .none => return null,
            .at => |end| if (self.mode.earliest) {
                // The start needs no search in two cases. Anchored, it is where
                // the walk began, by construction. And an acceptance AT that
                // offset is the empty match there whether anchored or not — no
                // span starting at or after `self.at` can end at `self.at` and be
                // wider — so the collapsed window is read off rather than handed
                // to the span engine.
                if (self.mode.anchored or end == self.at) return .{ .start = self.at, .end = end };
                // Otherwise the end is fixed and the start is the leftmost one
                // that reaches it (see `Mode.earliest`).
                return self.leftmost(.{ .hay = self.win.hay, .from = self.at, .to = end });
            },
            // No machine, or one that quit. Every mode but earliest has a leftmost
            // answer to fall back on; earliest has none, and says so rather than
            // relabelling the wrong sequence.
            .decline => if (self.mode.earliest) {
                self.undecided = true;
                return null;
            },
        }
        // The leftmost walk, and the anchored one once its machine has said a match
        // begins here — so an anchored search now pays for the match rather than
        // for the hunt for one.
        const found = self.leftmost(win) orelse return null;
        // The anchored filter is EXACT rather than an approximation of the
        // re-seed-free machine above: if any match begins at `self.at`,
        // leftmost-first is that match, because no admissible start is smaller
        // than the one the search began at. It stands under the halting walk
        // rather than instead of it — a declined probe leaves this the whole
        // answer, which is what keeps the sequence identical either way.
        if (self.mode.anchored and found.start != self.at) return null;
        return found;
    }

    /// What the halting machine says about the rest of the window, or `.decline`
    /// when this walk holds none to ask.
    fn halt(self: *Cursor, win: Window) Matcher.Onset {
        if (!self.mode.anchored and !self.mode.earliest) return .decline;
        const loan = self.probe orelse return .decline;
        return loan.sim.onset(win, self.mode.anchored);
    }

    /// The leftmost-first match inside `win`, or null.
    fn leftmost(self: *Cursor, win: Window) ?Span {
        return switch (self.of.matchWindow(self.loan.sim, win)) {
            .found => |sp| sp,
            // `.none` ends the walk. `.decline` cannot reach here: a cursor is
            // only ever built over a bound its engine accepted (see
            // `Pattern.matchesIn`), so treating it as the end is the fail-closed
            // arm of an unreachable case rather than a silent truncation.
            .none, .decline => null,
        };
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

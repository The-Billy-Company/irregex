//! irregex — where a match landed, which pattern landed it, and how much that
//! settles.
//!
//! The third of the three vocabularies every tier speaks, beside `portal.zig`
//! (what the platform is called) and `fault.zig` (what went wrong). This one is
//! what an answer is *made of*, and it exists because it was previously made of
//! four different things: the span engine, the class-run kernel, the hosted API
//! and the FM-index each declared their own `Span`, three of them structurally
//! identical and the fourth an entirely different concept wearing the same name.
//! Identical types with separate declarations do not compose — every crossing
//! costs a field-by-field copy that the compiler cannot tell from a conversion —
//! and a name that means two things costs a reader the same thing twice.
//!
//! Five nouns, and the last two are here for a second reason. A `Window` (what
//! to search vs what to read) and an `Authority` (decides vs merely nominates)
//! were each defined inside the one engine that first needed them — the caliper
//! and the literal dispatcher. Both are load-bearing package-wide claims, and a
//! claim addressed as one tier's detail is one a caller has to go find before
//! they can honor it.
//!
//! std only, and below every tier that reports a position, so nothing has to
//! invert to reach it.
//!
//! **The C ABI keeps its own.** `surface/ffi/pattern.zig` declares an `extern`
//! span of two `i64`s, because a capture group that did not participate is a
//! real answer there and `-1` is how the slot vector already spells absence.
//! That is a wire representation of this idea, not a second copy of it: Zig
//! spells the same absence `?Span`, which costs no sentinel and cannot be
//! mistaken for a position.

const std = @import("std");

/// A byte range `[start, end)` over one haystack.
///
/// Half-open, so `len` is a subtraction and adjacent spans share an endpoint.
/// `start == end` is a zero-width match, which is a real answer — `a*` accepts
/// the empty string at every position — and the reason an iterator over spans
/// has to advance past one deliberately rather than resume from `end`.
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn len(self: Span) usize {
        return self.end - self.start;
    }

    pub fn isEmpty(self: Span) bool {
        return self.end == self.start;
    }

    /// The bytes this span names, borrowed from `hay`. Asserts the span is in
    /// bounds, which is the same check the slice would make anyway — stated
    /// here so the failure names the span rather than an anonymous slice op.
    pub fn of(self: Span, hay: []const u8) []const u8 {
        std.debug.assert(self.start <= self.end and self.end <= hay.len);
        return hay[self.start..self.end];
    }

    /// Whether byte `at` lies inside. Half-open: `end` does not, and no
    /// position at all lies inside a zero-width span.
    pub fn holds(self: Span, at: usize) bool {
        return at >= self.start and at < self.end;
    }
};

/// **What to search, and what to read while searching.**
///
/// `hay` is the haystack: every zero-width assertion (`^ $ \b \B \< \> \A \z`)
/// resolves against it end to end. `[from, to]` is the region a match may
/// occupy — it must start at or after `from` and end at or before `to`. Within
/// that region the answer is the ordinary leftmost-first one.
///
/// The separation is the whole point, and the name is the argument for it.
/// Slicing a haystack to bound a search *also* moves its edges, so `$`, `\b`,
/// and any look-around at the cut answer a question about the slice instead of
/// about the text — which makes a bounded confirm around a literal, an
/// overlapping walk, or a half-match impossible to build out of slices without
/// changing what the pattern means. A window bounds what you can reach while
/// leaving everything around it visible; that is precisely the contract, and it
/// is why this is not called an "input" (the haystack is input too, and the
/// name would say nothing about the one distinction the type exists to draw).
///
/// `to == hay.len` is the unbounded default, so nobody who doesn't ask for a
/// bound pays for one.
pub const Window = struct {
    hay: []const u8,
    from: usize = 0,
    to: usize,

    /// The whole haystack from `from` — the unbounded search.
    pub fn whole(hay: []const u8, from: usize) Window {
        return .{ .hay = hay, .from = from, .to = hay.len };
    }

    /// Is the end bound inert (no match this haystack holds could be excluded
    /// by it)? Engines that cannot honor a real bound decline on this.
    pub fn unbounded(w: Window) bool {
        return w.to >= w.hay.len;
    }

    /// The prefix a bound turns the haystack into for the *assertion-free*
    /// engines — a pure literal or class run reads nothing but the bytes it
    /// consumes, so for those the region and a slice of it are the same
    /// question, and slicing is how the bound gets enforced for free.
    pub fn region(w: Window) []const u8 {
        return w.hay[0..@min(w.to, w.hay.len)];
    }
};

/// The ceilings a caller may put on one search, each in the currency the engine
/// that honors it actually spends.
///
/// These exist because the engine already HAS ceilings and the caller cannot see
/// them: PCRE2 runs under a hardcoded ten-million step budget and a ten-thousand
/// frame depth, and the determinizer declines at its powerset cap. Those numbers
/// are right for a search a person is waiting on and wrong for the two cases a
/// library gets used in — a server handing the pattern to a stranger, where the
/// defaults are far too generous to be a safety property, and a batch job that
/// would rather spend a minute than be declined. Neither host can express itself
/// today, so this is the vocabulary for both.
///
/// **`null` is not "no limit"** — it is "whatever this engine already does",
/// which is how a host asks for nothing and still gets the defaults. `0` is not
/// a spelling of null; a caller that means "refuse everything" can say so.
///
/// A ceiling is deliberately per-engine, and NOT normalized into one abstract
/// "effort" number. A step of backtracking and a minted DFA state are not
/// convertible, and a single fake unit would have to lie about one of them to
/// report the other. So each field says which engine spends it, and a field the
/// chosen engine does not spend is **inert rather than an error**: the linear
/// engine cannot exceed a step budget because it cannot backtrack, and reporting
/// `Unsupported` for a host that defensively set one would punish exactly the
/// caution this type exists to allow.
pub const Limits = struct {
    /// Match steps before the search gives up — PCRE2's backtracking budget.
    /// Inert on the linear engine, which is linear in the haystack by
    /// construction and so has no step count to exceed.
    steps: ?u64 = null,

    /// Frames of recursion the match may descend — PCRE2's depth budget, and the
    /// one that stands between a nested quantifier and the stack. Inert on the
    /// linear engine.
    depth: ?u32 = null,

    /// Bytes of heap one match may hold. Honored by PCRE2, which today sets no
    /// heap ceiling at all, so a pathological subject can grow its frame vector
    /// until the allocator refuses — the gap this field closes.
    heap_bytes: ?usize = null,

    /// DFA states the determinizer may mint before it declines. Inert on PCRE2,
    /// which builds no automaton. Lowering it trades recall of the fast path for
    /// a bounded footprint: the engine falls back rather than failing, because
    /// this cap is the one ceiling here whose overrun already has a safe answer.
    states: ?u32 = null,
};

/// Which pattern of a slate an answer is about.
///
/// A distinct type rather than a bare `u32` because the engines are full of
/// integers that index something else — a state, a bit inside an attribution
/// mask, a voice inside a grouped munch — and a slate's ordinals are the one
/// numbering a *caller* is allowed to hold. Non-exhaustive: the range is the
/// caller's slate, so there is no set of ids this enum could enumerate.
///
/// There is no `none`. A pattern that did not match is `?PatternID`, because a
/// sentinel id is a value that compares equal to a real one on the day someone
/// forgets to check it.
pub const PatternID = enum(u32) {
    /// The id a single-pattern engine reports, and the first ordinal of a
    /// slate. Named so the common case does not read as a magic zero.
    first = 0,
    _,

    pub fn at(n: u32) PatternID {
        return @enumFromInt(n);
    }

    pub fn ordinal(self: PatternID) u32 {
        return @intFromEnum(self);
    }
};

/// One match: where it landed, and which pattern landed it.
///
/// The pattern defaults to `.first`, so a single-pattern engine constructs one
/// by naming only the span and a multi-pattern engine cannot forget to say
/// which voice it heard.
pub const Match = struct {
    span: Span,
    pattern: PatternID = .first,

    /// The matched bytes, borrowed from `hay`.
    pub fn of(self: Match, hay: []const u8) []const u8 {
        return self.span.of(hay);
    }
};

/// How much a caller may conclude from an answer: `.exact` decides outright,
/// `.candidate` only nominates and must still be verified.
///
/// Vocabulary rather than one scanner's detail, because it is this package's
/// central claim written as a type. Every acceleration here — the trigram
/// index, the crest sieve, the literal prefilters, a stale artifact — may
/// *eliminate* work and may not *decide* a match. That asymmetry is what makes
/// a days-old index cost speed instead of correctness, and it is the promise
/// separating this engine from the indexed searchers that answer a mutated tree
/// wrongly. Two-valued so the compiler carries the promise instead of everyone
/// remembering it: a `.candidate` reaching a caller that wanted a verdict does
/// not typecheck as one, and a prefilter is free to be as aggressive as it
/// likes precisely because it cannot be believed.
pub const Authority = enum { exact, candidate };

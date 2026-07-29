//! gist — where a match lies, measured from both ends.
//!
//! `-o` and every mode built on it (`--count-matches`, `--column`,
//! `--vimgrep`, `--json`, `-w`, and colored highlighting) need a match's byte
//! extent, not a yes/no. The Pike VM can produce one, and did: a priority-
//! ordered thread list carrying a start offset per state. It costs about forty
//! times what the boolean DFA costs per byte of the lines it walks, because
//! every byte re-closes every live thread.
//!
//! A caliper measures an extent by closing two jaws on it, and that is the
//! shape of the answer here (RE2 / rust-`regex`'s construction):
//!
//!   1. the **forward** jaw runs the leftmost-first automaton from the search
//!      origin and records the last position a match completed. Match
//!      dominance (`automaton.zig`) keeps the earliest-starting thread alive
//!      and drops every start discovered after a match was in hand, so the end
//!      it stops on belongs to the leftmost match, not to whichever match
//!      happened to finish first;
//!   2. the **backward** jaw runs the reversed program (`reverse.zig`) from
//!      that end, anchored, and records the furthest left it can still be in a
//!      match — the leftmost start reaching that end.
//!
//! Two table walks over the match region, no thread list, no per-state offset
//! map. The Pike span stays in the tree behind this: it is the oracle the
//! differential fuzz compares against, and it is what runs whenever the caliper
//! declines, so a pattern this file cannot determinize cheaply still answers.
//!
//! Not every span comes here. A pure-literal alternation resolves by SIMD
//! substring scan and a span-exact class run by the SIMD window kernel, both
//! strictly cheaper than any automaton; `pike/span.zig` still tries those
//! first. The caliper is for everything left — the multi-segment patterns
//! (`[A-Z][a-z]+[A-Z]\w*`, `[a-z]+_[a-z]+_[a-z]+`, `func \w+\(`) that no
//! reduction covers and the VM used to own alone.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const subset = @import("../dfa/subset.zig");
const word = @import("../../syntax/word.zig");
const automaton = @import("automaton.zig");
const reverse = @import("reverse.zig");
const prefilter = @import("../../analysis/prefilter.zig");

const State = syn.State;

/// A byte span `[start, end)` of one match. `end == start` is a zero-width
/// match (the `-o` caller advances past it to avoid looping).
pub const Span = struct { start: usize, end: usize };

/// **What to search, and what to read while searching** — the span engines'
/// input, and the reason the two are separable.
///
/// `hay` is the haystack: every zero-width assertion (`^ $ \b \B \< \> \A \z`)
/// resolves against it end to end. `[from, to]` is the region a match may
/// occupy — it must start at or after `from` and end at or before `to`. Within
/// that region the answer is the ordinary leftmost-first one.
///
/// The distinction is the whole point. Slicing a haystack to bound a search
/// *also* moves its edges, so `$`, `\b`, and any look-around at the cut answer a
/// question about the slice instead of about the text — which makes a bounded
/// confirm around a literal, an overlapping walk, or a half-match impossible to
/// build out of slices without changing what the pattern means. A window keeps
/// the context and moves only the search. (Same separation rust-`regex` draws
/// with `Input { haystack, span }`; `to == hay.len` is the unbounded default,
/// so nobody who doesn't ask for a bound pays for one.)
pub const Window = struct {
    hay: []const u8,
    from: usize = 0,
    to: usize,

    /// The whole haystack from `from` — what `matchSpan` means.
    pub fn whole(hay: []const u8, from: usize) Window {
        return .{ .hay = hay, .from = from, .to = hay.len };
    }

    /// Is the end bound inert (no match this haystack holds could be excluded by
    /// it)? Engines that cannot honor a real bound decline on this.
    pub fn unbounded(w: Window) bool {
        return w.to >= w.hay.len;
    }

    /// The prefix a bound turns the haystack into for the *assertion-free*
    /// engines — a pure literal or class-run reads nothing but the bytes it
    /// consumes, so for those the region and a slice of it are the same
    /// question, and slicing is how the bound gets enforced for free.
    pub fn region(w: Window) []const u8 {
        return w.hay[0..@min(w.to, w.hay.len)];
    }
};

/// What a measurement produced. `decline` is not a failure and not an answer —
/// it means this pattern outgrew the caliper's budget on this thread and the
/// Pike VM must decide the line, exactly as it did before this engine existed.
pub const Verdict = union(enum) { none, found: Span, decline };

/// The immutable half: one reversed program and the two machine configurations
/// that read it and the forward program. Heap-allocated because each `Machine`
/// borrows the shared byte-class partition by pointer.
pub const Caliper = struct {
    rev: reverse.Program,
    cls: subset.Classes,
    forward: automaton.Machine,
    backward: automaton.Machine,
    word_ctx: bool,
    unicode: bool,
    gpa: std.mem.Allocator,

    pub fn deinit(cal: *Caliper) void {
        const gpa = cal.gpa;
        cal.rev.deinit();
        gpa.destroy(cal);
    }
};

/// Per-thread mutable half: one determinization cache per jaw, built on first
/// use. A `SpanSim` is sometimes constructed per line, so nothing is allocated
/// until a measurement is actually asked for.
pub const Jaws = struct {
    cal: *const Caliper,
    fwd: ?automaton.Cache = null,
    bwd: ?automaton.Cache = null,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, cal: *const Caliper) Jaws {
        return .{ .cal = cal, .gpa = gpa };
    }

    pub fn deinit(j: *Jaws) void {
        if (j.fwd) |*c| c.deinit();
        if (j.bwd) |*c| c.deinit();
        j.* = undefined;
    }

    fn cache(j: *Jaws, which: *?automaton.Cache, m: *const automaton.Machine) ?*automaton.Cache {
        if (which.* == null) {
            which.* = automaton.Cache.init(j.gpa, m) catch return null;
        }
        const c = &which.*.?;
        return if (c.quit) null else c;
    }
};

/// Should this pattern get a caliper at all? Multiline is out (a buffer anchor
/// has no per-line determinization, and `-U` spans are the whole-buffer model),
/// and so is any program the reverser cannot name a single `match` in.
pub fn eligible(states: []const State, multiline: bool) bool {
    return !multiline and reverse.matchIndex(states) != null;
}

/// Build the reversed program and both machine configurations. O(program), no
/// determinization — every state either jaw needs is discovered lazily, by the
/// first haystack that walks into it.
pub fn build(
    gpa: std.mem.Allocator,
    states: []const State,
    start: u32,
    unicode: bool,
) std.mem.Allocator.Error!?*Caliper {
    const match_idx = reverse.matchIndex(states) orelse return null;
    var rev = try reverse.build(gpa, states, start, match_idx);
    errdefer rev.deinit();

    const cal = try gpa.create(Caliper);
    errdefer gpa.destroy(cal);

    // One partition serves both directions: the reversed program consumes the
    // very same byte sets, so it induces the very same equivalence classes.
    // Word-ness never refines it — a gap's word context reaches the memo as
    // part of the gap's shape, not smuggled through the class of a byte, which
    // is what lets the backward jaw (whose "byte just consumed" sits on the
    // other side) reuse this untouched.
    cal.* = .{
        .rev = rev,
        .cls = subset.Classes.build(states, false),
        .forward = undefined,
        .backward = undefined,
        .word_ctx = hasWordAssertion(states),
        .unicode = unicode,
        .gpa = gpa,
    };
    cal.forward = .{
        .states = states,
        .start_nfa = start,
        .cls = &cal.cls,
        .dominate = true,
        .word_ctx = cal.word_ctx,
    };
    cal.backward = .{
        .states = cal.rev.states,
        .start_nfa = cal.rev.start,
        .cls = &cal.cls,
        .dominate = false,
        .word_ctx = cal.word_ctx,
    };
    return cal;
}

fn hasWordAssertion(states: []const State) bool {
    for (states) |st| switch (st) {
        .assert_word => return true,
        else => {},
    };
    return false;
}

/// The position predicates in force at gap `i`. Read off real coordinates, not
/// scan direction — which is the whole reason a reversed edge can carry its
/// assertion verbatim. An assertion-free program pays two comparisons.
///
/// Null means quit — hand the line to the Pike VM. The memo keys a gap by two
/// word bits, which cannot distinguish "silence" from "the middle of a
/// character", and `\B` and the two halves need that distinction
/// (`syntax.mask.holds`). Rather than widen every row of every state to carry a
/// case that only arises beside a multi-byte character, decline the line — the
/// byte-class DFA already quits on the same ground.
/// The shape every gap in a line's interior has when no `\b` can read it: not
/// the buffer's start, not its end, and word context nobody consults. It is the
/// row a long run stays on, which is what `Cache.glide` needs named up front.
const interior: subset.Gap = .{ .at_start = false, .at_end = false, .word_before = false, .word_after = false };

fn gapAt(cal: *const Caliper, line: []const u8, i: usize) ?subset.Gap {
    if (!cal.word_ctx) return .{ .at_start = i == 0, .at_end = i == line.len, .word_before = false, .word_after = false };
    const s = word.sides(cal.unicode, line, i);
    if (!s.left_ok or !s.right_ok) return null;
    return .{ .at_start = i == 0, .at_end = i == line.len, .word_before = s.before, .word_after = s.after };
}

/// Leftmost-first span of the pattern within the window `w`, measured by both
/// jaws. See the file header for why two passes beat one thread list.
///
/// `skip` is the caller's first-byte prefilter, or null to walk every gap. It is
/// an accelerator with no say in the answer: the forward jaw consults it only
/// after asking its own machine whether a match could be zero-width, and the
/// backward jaw never sees it (it is anchored — there is nothing to skip to).
pub fn measure(j: *Jaws, win: Window, skip: ?*const prefilter.Prefilter) Verdict {
    const w: Window = .{ .hay = win.hay, .from = win.from, .to = @min(win.to, win.hay.len) };
    if (w.from > w.to) return .none;
    const end = forwardEnd(j, w, skip) orelse return .decline;
    return switch (end) {
        .none => .none,
        .at => |e| if (backwardStart(j, w.hay, e, w.from)) |s|
            .{ .found = .{ .start = s, .end = e } }
        else
            .decline,
        .quit => .decline,
    };
}

const End = union(enum) { none, at: usize, quit };

/// Jaw one: the last position a match completes, scanning right from `from`.
/// "Last", not "first" — under match dominance the automaton stays alive only
/// while some thread outranks the match in hand, so the final match it reports
/// is the one the leftmost start prefers. `a|ab` dies right after `a`; `a+`
/// keeps extending; `axxx|x` reaches past the `x` at 1 because the thread that
/// began at 0 is still senior to it.
///
/// The search re-seeds a fresh start at every gap only UNTIL the first match is
/// recorded. After that the question is no longer "is there a match" but "how
/// far does the leftmost one reach", and a new start would be a strictly worse
/// answer — dominance drops such threads inside the closure, and this drops the
/// one the closure never sees.
///
/// While still seeding, a `skip` prefilter turns that gap-by-gap re-seed into
/// the boolean scanner's `.skip` policy (`pike/search.zig`): seed only where a
/// byte could actually begin a match, which lets the state go empty over dead
/// text, and jump straight to the next candidate when it does. Equivalent to
/// seeding everywhere — a start whose first byte the prefilter rejects dies on
/// its first step — minus the walk. The soundness condition is the one thing
/// this policy cannot see for itself, so it asks the machine: skipping loses
/// only a match that consumes nothing, and `Cache.zeroWidth` is exactly whether
/// one exists.
fn forwardEnd(j: *Jaws, w: Window, pre: ?*const prefilter.Prefilter) ?End {
    const cal = j.cal;
    const line = w.hay;
    const c = j.cache(&j.fwd, &cal.forward) orelse return null;
    const skip: ?*const prefilter.Prefilter = if (pre) |p| (if (c.zeroWidth()) null else p) else null;
    // Candidate starts are hunted inside the bound: a match must END by `w.to`,
    // so a start at or past it cannot consume anything.
    const region = w.region();

    var st = c.enter(gapAt(cal, line, w.from) orelse return null) orelse return null;
    var last: ?usize = if (st.matched()) w.from else null;
    var i = w.from;
    while (i < w.to) {
        if (st.dead()) {
            // An empty set ends the scan once a match is committed: dominance
            // has then discarded every rival on purpose. While still seeding,
            // emptiness means only that nothing is live at THIS gap — an
            // assertion refused the seed (`\bfoo\b` mid-word), or the prefilter
            // withheld it — so the search moves to the next gap that could
            // start one, by jump when a prefilter says where and by step when
            // it doesn't.
            if (last != null) break;
            if (skip) |s| {
                i = s.nextStart(region, i) orelse return .none;
                st = c.enter(gapAt(cal, line, i) orelse return null) orelse return null;
                if (st.matched()) last = i;
            }
        }
        // A start at `i+1` needs a byte to consume inside the bound, and (under
        // the skip policy) a byte the prefilter admits.
        const seed = last == null and (if (skip) |s| i + 1 < w.to and s.has(line[i + 1]) else true);
        // Hand the memo as long a run as the row survives (`Cache.glide`). The
        // row holds while two things do: every landing is an interior gap —
        // which needs the buffer's end out of reach and no `\b` context to read
        // — and the seed decision stays one decision. With no prefilter
        // choosing, it never changes. With one, it changes only where the
        // prefilter admits a byte, and the same jump that hunts candidates finds
        // where that is, so the run is simply the stretch before the next one.
        if (!cal.word_ctx) {
            const ceiling = @min(w.to, line.len -| 1);
            const lim = if (skip != null and last == null)
                @min(ceiling, (skip.?.nextStart(region, i + 1) orelse ceiling) -| 1)
            else
                ceiling;
            if (i < lim) {
                const run = c.glide(st, interior, seed, line[i..lim], .forward);
                if (run.len > 0) {
                    st = run.cell;
                    i += run.len;
                    if (st.matched()) last = i;
                    continue;
                }
            }
        }
        st = c.step(st, cal.cls.class[line[i]], gapAt(cal, line, i + 1) orelse return null, seed) orelse return null;
        if (st.matched()) last = i + 1;
        i += 1;
    }
    return if (last) |e| .{ .at = e } else .none;
}

/// Jaw two: the leftmost position from which a match still reaches `end`,
/// scanning left and never past the search origin. The reversed automaton is
/// anchored at `end`, so every match state it enters marks a real start; the
/// last one it sees is the furthest left.
fn backwardStart(j: *Jaws, line: []const u8, end: usize, floor: usize) ?usize {
    const cal = j.cal;
    const c = j.cache(&j.bwd, &cal.backward) orelse return null;
    var st = c.enter(gapAt(cal, line, end) orelse return null) orelse return null;
    var best: ?usize = if (st.matched()) end else null;
    var i = end;
    while (i > floor and !st.dead()) {
        // This jaw is anchored, so it never seeds — its row is constant for the
        // whole run, and the only landing that leaves the interior is gap 0.
        if (!cal.word_ctx) {
            const lo = @max(floor, 1);
            if (i > lo) {
                const run = c.glide(st, interior, false, line[lo..i], .backward);
                if (run.len > 0) {
                    st = run.cell;
                    i -= run.len;
                    if (st.matched()) best = i;
                    continue;
                }
            }
        }
        st = c.step(st, cal.cls.class[line[i - 1]], gapAt(cal, line, i - 1) orelse return null, false) orelse return null;
        if (st.matched()) best = i - 1;
        i -= 1;
    }
    return best;
}

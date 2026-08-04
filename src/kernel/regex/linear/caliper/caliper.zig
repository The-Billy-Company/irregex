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

/// A byte span `[start, end)` of one match — the package vocabulary
/// (`../../../../mark.zig`), bound here because this engine is where a span is
/// measured and callers reach for `Regex.Span` by that name.
pub const Span = @import("../../../../mark.zig").Span;

/// **What to search, and what to read while searching** — the span engines'
/// input, and the reason the two are separable. The package vocabulary
/// (`../../../../mark.zig`), bound here because this engine is where a bound is
/// honored and callers reach for `Regex.Window` by that name.
pub const Window = @import("../../../../mark.zig").Window;

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
    /// The last thing the prefilter was asked, and what it said (`hunt`).
    recall: Recall = .{},

    pub fn init(gpa: std.mem.Allocator, cal: *const Caliper) Jaws {
        return .{ .cal = cal, .gpa = gpa };
    }

    pub fn deinit(j: *Jaws) void {
        if (j.fwd) |*c| c.deinit();
        if (j.bwd) |*c| c.deinit();
        j.* = undefined;
    }

    /// This jaw's determinization cache, or null if it has declined. Twice per
    /// span, so the resident case is a load and a branch and the build is
    /// somewhere else — inlined together they cost 9% of a saturated-line span
    /// to arrive at a pointer that has been the same pointer since the first
    /// line of the file.
    inline fn cache(j: *Jaws, which: *?automaton.Cache, m: *const automaton.Machine) ?*automaton.Cache {
        const c = if (which.*) |*resident| resident else j.open(which, m) orelse return null;
        return if (c.quit) null else c;
    }

    fn open(j: *Jaws, which: *?automaton.Cache, m: *const automaton.Machine) ?*automaton.Cache {
        @branchHint(.cold);
        which.* = automaton.Cache.init(j.gpa, m) catch return null;
        return &which.*.?;
    }

    /// The prefilter, asked through one span's worth of memory.
    ///
    /// A span asks the first-byte set two questions — *where does the next
    /// candidate begin* (to stand on one) and *where does the one after it
    /// begin* (to bound the glide, so the seeding decision holds for the whole
    /// run) — and on a match-dense line those are the same question one span
    /// apart. The second scan of a span crosses exactly the bytes the next
    /// span's first scan would cross again, because a match ends before the
    /// candidate that bounded it. Remembering one answer collapses the pair, so
    /// the walk reads the haystack once rather than twice.
    ///
    /// The memo is a claim about bytes, not about a call: *the first candidate
    /// at index ≥ `from` is `at`*. It answers a later question only when that
    /// question's floor lies in `[from, at]` — where the recorded scan already
    /// proved there is nothing — over the same haystack, the same prefilter, and
    /// a region still long enough to contain `at`.
    const Recall = struct {
        hay: ?[*]const u8 = null,
        pre: ?*const prefilter.Prefilter = null,
        from: usize = 0,
        at: usize = 0,
    };

    fn hunt(j: *Jaws, p: *const prefilter.Prefilter, region: []const u8, from: usize) ?usize {
        const r = &j.recall;
        if (r.hay == region.ptr and r.pre == p and from >= r.from and from <= r.at and r.at < region.len)
            return r.at;
        const at = p.nextStart(region, from) orelse return null;
        r.* = .{ .hay = region.ptr, .pre = p, .from = from, .at = at };
        return at;
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
        .unicode = unicode,
    };
    cal.backward = .{
        .states = cal.rev.states,
        .start_nfa = cal.rev.start,
        .cls = &cal.cls,
        .dominate = false,
        .word_ctx = cal.word_ctx,
        .unicode = unicode,
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
        .at => |r| blk: {
            const s = r.start orelse
                backwardStart(j, w.hay, r.end, w.from) orelse
                break :blk .decline;
            break :blk .{ .found = .{ .start = s, .end = r.end } };
        },
        .quit => .decline,
    };
}

/// Where the forward jaw stopped, and — when the walk can prove it — where the
/// match must have begun.
///
/// **A jaw that never re-seeded already knows the start.** `program/core.zig`
/// compiles an ANCHORED program; unanchoredness is this file's re-seed and
/// nothing else. So every thread alive at `end` descends from the single start
/// that `enter` seeded, and if no step in between re-seeded, they all began at
/// that one gap — which is the leftmost start reaching `end`, which is the
/// answer the backward jaw exists to compute. Under a first-byte prefilter a
/// re-seed only fires where the prefilter admits a byte, so on the shape this
/// engine is for — a match found by jumping to its own first byte — `start` is
/// populated and the second jaw does not run at all.
///
/// Null means a re-seed did fire, so some survivor may have begun later than
/// the entry, and only the reversed automaton can say which. That is the case
/// with no usable prefilter (`seed` is then true at every gap until a match),
/// so the fallback is the whole of the old behavior and nothing declines that
/// did not decline before.
const Reach = struct { end: usize, start: ?usize };

const End = union(enum) { none, at: Reach, quit };

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
    // Two ways an offered prefilter is not one. A machine that can match
    // nothing (`zeroWidth`) may not be skipped past at all. And an EMPTY
    // first-byte set is `analyzeFirst` saying "I could not tell", not "no byte
    // begins a match" — trusting it would read every haystack as matchless.
    // That distinction only ever cost a wasted jump while the old walk consulted
    // the prefilter after a death; now that the walk stands on a candidate
    // before it seeds anything, it decides whether there is a match at all.
    const skip: ?*const prefilter.Prefilter = if (pre) |p|
        (if (c.zeroWidth() or p.count() == 0) null else p)
    else
        null;
    // Candidate starts are hunted inside the bound: a match must END by `w.to`,
    // so a start at or past it cannot consume anything.
    const region = w.region();

    // Stand on a candidate BEFORE paying for a start closure. Nothing is live
    // at `w.from` yet, so the license is the loop's own: a prefilter is offered
    // only when no match can be zero-width, hence every match consumes a first
    // byte the prefilter admits, hence a gap it refuses cannot begin one.
    // Entering anyway costs a closure, a bound scan, and a glide that dies on
    // its first byte — three quarters of a span's fixed cost on a match-dense
    // line, spent to rediscover what the prefilter was about to say.
    var i = w.from;
    if (skip) |s| i = j.hunt(s, region, i) orelse return .none;
    var st = c.enter(gapAt(cal, line, i) orelse return null) orelse return null;
    var last: ?usize = if (st.matched()) i else null;
    // The gap the live threads were seeded at, and whether anything has been
    // seeded since — together, the backward jaw's answer whenever the second
    // is false. A re-entry after death resets both: an empty set leaves nothing
    // behind for a later start to be junior to. See `Reach`.
    var origin = i;
    var reseeded = false;
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
                i = j.hunt(s, region, i) orelse return .none;
                st = c.enter(gapAt(cal, line, i) orelse return null) orelse return null;
                origin = i;
                reseeded = false;
                if (st.matched()) last = i;
            }
        }
        // A start at `i+1` needs a byte to consume inside the bound, and (under
        // the skip policy) a byte the prefilter admits.
        const seed = last == null and (if (skip) |s| i + 1 < w.to and s.has(line[i + 1]) else true);
        // Hand the memo as long a run as it can keep (`Cache.glide`). Two things
        // have to hold. Every landing must be an interior gap, which the
        // `line.len -| 1` ceiling buys — a `\b` context no longer costs the run,
        // since the memo now reads its row off the bytes. And the seed decision
        // must stay one decision: with no prefilter choosing it never changes,
        // and with one it changes only where the prefilter admits a byte, which
        // the same jump that hunts candidates already located — so the run is
        // simply the stretch before the next candidate.
        const ceiling = @min(w.to, line.len -| 1);
        const lim = if (skip != null and last == null)
            @min(ceiling, (j.hunt(skip.?, region, i + 1) orelse ceiling) -| 1)
        else
            ceiling;
        if (i < lim) {
            const run = c.glide(st, interior, seed, line[i..lim], line[lim], .forward);
            if (run.len > 0) {
                reseeded = reseeded or seed;
                st = run.cell;
                i += run.len;
                if (st.matched()) last = i;
                continue;
            }
        }
        reseeded = reseeded or seed;
        st = c.step(st, cal.cls.class[line[i]], gapAt(cal, line, i + 1) orelse return null, seed) orelse return null;
        if (st.matched()) last = i + 1;
        i += 1;
    }
    return if (last) |e| .{ .at = .{ .end = e, .start = if (reseeded) null else origin } } else .none;
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
        // This jaw is anchored, so it never seeds — one seeding decision for the
        // whole run, and the only landing that leaves the interior is gap 0.
        const lo = @max(floor, 1);
        if (i > lo) {
            const run = c.glide(st, interior, false, line[lo..i], line[lo - 1], .backward);
            if (run.len > 0) {
                st = run.cell;
                i -= run.len;
                if (st.matched()) best = i;
                continue;
            }
        }
        st = c.step(st, cal.cls.class[line[i - 1]], gapAt(cal, line, i - 1) orelse return null, false) orelse return null;
        if (st.matched()) best = i - 1;
        i -= 1;
    }
    return best;
}

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

const State = syn.State;

/// A byte span `[start, end)` of one match. `end == start` is a zero-width
/// match (the `-o` caller advances past it to avoid looping).
pub const Span = struct { start: usize, end: usize };

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
        .assert_word_b, .assert_not_word_b, .assert_word_start, .assert_word_end => return true,
        else => {},
    };
    return false;
}

/// The position predicates in force at gap `i`. Read off real coordinates, not
/// scan direction — which is the whole reason a reversed edge can carry its
/// assertion verbatim. An assertion-free program pays two comparisons.
fn gapAt(cal: *const Caliper, line: []const u8, i: usize) subset.Gap {
    return .{
        .at_start = i == 0,
        .at_end = i == line.len,
        .word_before = cal.word_ctx and word.wordBefore(cal.unicode, line, i),
        .word_after = cal.word_ctx and word.wordAt(cal.unicode, line, i),
    };
}

/// Leftmost-first span of the pattern within `line[from..]`, measured by both
/// jaws. See the file header for why two passes beat one thread list.
pub fn measure(j: *Jaws, line: []const u8, from: usize) Verdict {
    const end = forwardEnd(j, line, from) orelse return .decline;
    return switch (end) {
        .none => .none,
        .at => |e| if (backwardStart(j, line, e, from)) |s|
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
fn forwardEnd(j: *Jaws, line: []const u8, from: usize) ?End {
    const cal = j.cal;
    const c = j.cache(&j.fwd, &cal.forward) orelse return null;
    var st = c.enter(gapAt(cal, line, from)) orelse return null;
    var last: ?usize = if (c.matched(st)) from else null;
    var i = from;
    while (i < line.len) : (i += 1) {
        // An empty set ends the scan only once a match is committed. While the
        // search is still seeding, emptiness means nothing is live at THIS gap
        // — an assertion just refused the seed (`\bfoo\b` mid-word) — and the
        // next gap may well start one. Only a committed match makes emptiness
        // final, because dominance has then discarded every rival on purpose.
        if (last != null and c.isDead(st)) break;
        st = c.step(st, cal.cls.class[line[i]], gapAt(cal, line, i + 1), last == null) orelse return null;
        if (c.matched(st)) last = i + 1;
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
    var st = c.enter(gapAt(cal, line, end)) orelse return null;
    var best: ?usize = if (c.matched(st)) end else null;
    var i = end;
    while (i > floor and !c.isDead(st)) : (i -= 1) {
        st = c.step(st, cal.cls.class[line[i - 1]], gapAt(cal, line, i - 1), false) orelse return null;
        if (c.matched(st)) best = i - 1;
    }
    return best;
}

//! irregex — the two questions a leftmost-first ladder cannot ask, and the pair
//! of automata that answer them.
//!
//! The span ladder above this (`pike/span.zig`, `caliper/`) answers one question
//! in two grains: *where is the leftmost-first match at or after `from`*. Two
//! requests are not that question and cannot be filtered out of its answer:
//!
//!   * **earliest** — the match that ENDS first, which is what `regex-automata`'s
//!     `MatchKind::All` earliest search and `re2::RE2::PartialMatch` report. A
//!     leftmost-first answer is chosen by where it STARTS and then extended by
//!     priority, so it is frequently neither the earliest-ending match nor
//!     reducible to one: `a+` over `aaa` is leftmost `(0,3)` and earliest `(0,1)`,
//!     and no predicate over the first recovers the second.
//!   * **anchored** — does a match begin exactly HERE. A leftmost search plus a
//!     `start == from` test decides it exactly, and pays for a hunt across every
//!     position it was never allowed to report from.
//!
//! Both bottom out in the same primitive: a determinized walk that HALTS at its
//! first acceptance (`lazy.Cache.onset`). This file is the policy over that walk —
//! which automaton a mode needs, and when to build it.
//!
//! **Two automata, because the re-seed is baked into the states.** An unanchored
//! subset construction folds a fresh start into every transition, so its first
//! acceptance is the earliest end of *any* match in the region; an anchored one
//! seeds once and dies when its thread set drains, so its first acceptance means a
//! match begins where the walk began. `subset.zig` has built both since the
//! determinizer was written — the `anchored` argument to `Subset.init` is exactly
//! this — and nothing above it had a way to ask for the second one.
//!
//! **Cost is deferred all the way down.** A `Probe` is per-thread scratch handed
//! out by `glean`'s pool, and it allocates nothing until a mode actually asks:
//! each automaton is built on the first ask that needs it and then reused for the
//! life of the scratch. A build that fails allocates no fallback either — it
//! declines, and every caller has a leftmost answer to fall back on except the
//! earliest span, which refuses rather than relabel one.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const lazy_mod = @import("lazy.zig");

const State = syn.State;

pub const Onset = lazy_mod.Onset;

/// The halting machines for one compiled program, built on demand.
///
/// Per-thread scratch: it owns mutable determinization memo, so it is never
/// shared, and it is the same grain as a `Sim` rather than a second kind of
/// thing (see `glean/pool.zig`, which shelves all three the same way).
pub const Probe = struct {
    gpa: std.mem.Allocator,
    /// The program the halting walks determinize, or null when this engine has
    /// none to offer — PCRE2's is not inspectable, and a program carrying a
    /// positional assertion is refused for the reason `Machine` states.
    program: ?Program,
    /// Re-seeded at every gap: its first acceptance is the earliest END.
    loose: ?Machine = null,
    /// Seeded once: its first acceptance means a match BEGINS at the walk's start,
    /// and its dead state means none does.
    pinned: ?Machine = null,

    /// What a halting walk needs from a compiled program. Deliberately not the
    /// `Regex` itself: this floor determinizes NFA states, and taking the handle
    /// would let it reach for the leftmost machinery it exists to avoid.
    pub const Program = struct { states: []const State, start: u32 };

    pub fn init(gpa: std.mem.Allocator, program: ?Program) Probe {
        return .{ .gpa = gpa, .program = program };
    }

    pub fn deinit(p: *Probe) void {
        if (p.loose) |*m| m.deinit();
        if (p.pinned) |*m| m.deinit();
        p.* = undefined;
    }

    /// The first position in `hay[from..to]` at which a match ends — anchored,
    /// the first at which a match starting at `from` ends.
    ///
    /// `.decline` for a program with no halting machine and for a memo that quit,
    /// which are one answer on purpose: both mean *this tier has no verdict*, and
    /// a caller that treats them differently is a caller deciding on a reason
    /// rather than on an answer.
    pub fn onset(p: *Probe, hay: []const u8, from: usize, to: usize, anchored: bool) Onset {
        std.debug.assert(from <= to and to <= hay.len);
        const m = p.machine(anchored) orelse return .decline;
        return m.cache.onset(hay, from, to);
    }

    /// Is there a halting machine for this program at all? A static property of
    /// the compiled pattern, so a caller asks once instead of reading a reason out
    /// of a `.decline` it cannot act on.
    pub fn able(p: *const Probe) bool {
        return p.program != null;
    }

    fn machine(p: *Probe, anchored: bool) ?*Machine {
        const slot = if (anchored) &p.pinned else &p.loose;
        if (slot.* == null) {
            const program = p.program orelse return null;
            const built = Machine.build(p.gpa, program, anchored) catch return null;
            // A program no determinizer will ever take is a PERMANENT no, and
            // recording it once keeps every later ask from re-deriving it. An
            // allocation failure is not recorded, because the next ask may have
            // the room this one didn't.
            slot.* = built orelse {
                p.program = null;
                return null;
            };
        }
        return if (slot.*) |*m| m else null;
    }
};

/// One determinized automaton and the memo a thread walks it with.
///
/// `Lazy` is the immutable half and `Cache` the mutable one, which is the same
/// division the eager and on-demand drivers already keep; this pairs them because
/// a halting walk wants both and nothing else does.
const Machine = struct {
    lz: *lazy_mod.Lazy,
    cache: lazy_mod.Cache,

    fn build(gpa: std.mem.Allocator, program: Probe.Program, anchored: bool) !?Machine {
        // The Unicode-word argument is `false` rather than the pattern's real
        // setting, and stating that is cheaper than letting a reader infer a
        // dependency: it gates the word-context quit alone, and an assertion-free
        // program has no word context to quit over.
        const lz = try lazy_mod.Lazy.build(gpa, program.states, program.start, anchored, false) orelse return null;
        errdefer lz.deinit();
        return .{ .lz = lz, .cache = try lazy_mod.Cache.init(gpa, lz) };
    }

    fn deinit(m: *Machine) void {
        m.cache.deinit();
        m.lz.deinit();
        m.* = undefined;
    }
};

/// The end a verdict names, or null when it names none — test sugar, so a row
/// below reads as the offset it is about.
fn endAt(o: Onset) ?usize {
    return switch (o) {
        .at => |e| e,
        else => null,
    };
}

fn byte(c: u8) syn.ByteSet {
    var set: syn.ByteSet = .{};
    set.set(c);
    return set;
}

test "dfa onset: the unanchored machine halts at the earliest end, not the leftmost one" {
    const t = std.testing;
    // `a+`: one consume state looping back through a split, then the terminal.
    const states = [_]State{
        .{ .consume = .{ .set = byte('a'), .out = 1 } },
        .{ .split = .{ .a = 0, .b = 2 } },
        .match,
    };
    var p = Probe.init(t.allocator, .{ .states = &states, .start = 0 });
    defer p.deinit();
    try t.expect(p.able());

    // Leftmost-first over `aaa` is (0,3). The earliest END is 1, and a walk that
    // ran the run out to decide the answer could not have reported it.
    try t.expectEqual(@as(?usize, 1), endAt(p.onset("aaa", 0, 3, false)));
    try t.expectEqual(@as(?usize, 3), endAt(p.onset("aaa", 2, 3, false)));
    // The region is a ceiling, not a slice: nothing accepts inside [0,0].
    try t.expectEqual(std.meta.Tag(Onset).none, std.meta.activeTag(p.onset("aaa", 0, 0, false)));
    try t.expectEqual(std.meta.Tag(Onset).none, std.meta.activeTag(p.onset("bbb", 0, 3, false)));
}

test "dfa onset: the anchored machine decides where a match begins without searching on" {
    const t = std.testing;
    const states = [_]State{ .{ .consume = .{ .set = byte('a'), .out = 1 } }, .match };
    var p = Probe.init(t.allocator, .{ .states = &states, .start = 0 });
    defer p.deinit();

    // `a` over `ba`: the unanchored walk finds the accept at 2; the anchored one
    // reports that nothing begins at 0 — after ONE byte, with no hunt for the
    // match it would not have been allowed to report.
    try t.expectEqual(@as(?usize, 2), endAt(p.onset("ba", 0, 2, false)));
    try t.expectEqual(std.meta.Tag(Onset).none, std.meta.activeTag(p.onset("ba", 0, 2, true)));
    try t.expectEqual(@as(?usize, 2), endAt(p.onset("ba", 1, 2, true)));
    // Both automata are live at once, each memoized for the life of the probe.
    try t.expect(p.loose != null and p.pinned != null);
}

test "dfa onset: a nullable program accepts before a byte is read" {
    const t = std.testing;
    // `a*`: the split reaches the terminal without consuming anything.
    const states = [_]State{
        .{ .split = .{ .a = 1, .b = 2 } },
        .{ .consume = .{ .set = byte('a'), .out = 0 } },
        .match,
    };
    var p = Probe.init(t.allocator, .{ .states = &states, .start = 0 });
    defer p.deinit();
    // Earliest for `a*` is the empty match where the walk stands — which is what
    // every regex library reports and what a greedy leftmost search hides.
    try t.expectEqual(@as(?usize, 0), endAt(p.onset("aaa", 0, 3, false)));
    try t.expectEqual(@as(?usize, 2), endAt(p.onset("aaa", 2, 3, true)));
    try t.expectEqual(@as(?usize, 3), endAt(p.onset("aaa", 3, 3, true)));
}

test "dfa onset: a program with no halting machine declines rather than guessing" {
    const t = std.testing;
    var p = Probe.init(t.allocator, null);
    defer p.deinit();
    try t.expect(!p.able());
    try t.expectEqual(std.meta.Tag(Onset).decline, std.meta.activeTag(p.onset("aaa", 0, 3, false)));
    try t.expectEqual(std.meta.Tag(Onset).decline, std.meta.activeTag(p.onset("aaa", 0, 3, true)));
}

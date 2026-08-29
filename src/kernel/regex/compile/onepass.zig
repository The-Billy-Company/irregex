//! irregex — the one-pass capture engine: submatches without a search.
//!
//! `captures.zig` runs a priority-ordered Pike simulation because, in general, a
//! capture engine must keep every live alternative alive: two threads can sit on
//! the same byte with different slot vectors, and only the input decides which
//! one survives. That is why it `@memcpy`s a whole slot vector on every `save`,
//! and why `-r`/`--json` cost 35–92× the boolean ladder on the same corpus.
//!
//! But MOST patterns never have two live alternatives. `(\w+)\s*=\s*(\w+)`,
//! `fn (\w+)\(`, `([^"]*)"` — at every point in the walk exactly one NFA
//! transition is viable for the byte in hand. Such a pattern is ONE-PASS: its
//! ε-closures determinize without ever splitting, so the slot vector needs no
//! replication at all and the caller's own `out` buffer IS the working set. No
//! thread list, no per-thread snapshot, no per-worker scratch.
//!
//! This module decides that property and, when it holds, builds the small
//! deterministic table that exploits it. It is a THIRD ARM of `Caps`, never a
//! replacement: the Pike VM is both the fallback for everything ineligible and
//! the correctness oracle the differential tests hold this engine to.
//!
//! FAIL CLOSED is the whole contract. Every uncertainty in the checker —
//! a converging ε-path, a conflicting transition, a second `match`, an
//! assertion guarding an accept that has live successors, a table past its cap —
//! resolves to a declinature, and the caller keeps the Pike VM. A pattern
//! wrongly accepted here would return silently wrong groups; a pattern wrongly
//! refused only costs speed.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const captures = @import("captures.zig");
const fault = @import("../../../fault.zig");
const word = @import("../syntax/word.zig");
const closure_mod = @import("../linear/pike/closure.zig");
const Prefilter = @import("../analysis/prefilter.zig").Prefilter;

const ByteSet = syn.ByteSet;
const Captures = captures.Captures;

/// Determinizer failure modes, PRIVATE to the builder below: `Bail` = this
/// pattern is not provably one-pass; OOM propagates. `Bail` never leaves the
/// file — `attach` folds it into `fault.Answer`'s declined arm, because
/// "this pattern needs a search" is a routine outcome with a correct answer one
/// tier down, not a fault (fault-channel law 1).
const Err = error{ Bail, OutOfMemory };

/// Caps chosen so a hostile pattern degrades to the Pike VM instead of eating
/// memory or compile time. Real one-pass patterns land far below all three:
/// `(\w+)\s*=\s*(\w+)` builds 6 states and 9 transitions.
const max_states = 2048;
const max_trans = 1 << 14;
const max_work = 1 << 22; // byte-slots written while building rows
/// Budget trips before the engine stops trying and hands the pattern to the
/// Pike VM for good (see `OnePass.trips`).
const max_trips = 16;

/// The zero-width assertions an ε-path can carry. A path may accumulate several
/// (`^\bfoo`), and contradictory pairs (`\b\B`) simply never fire — the same
/// outcome the Pike VM reaches by taking neither branch.
const Assert = struct {
    const start: u8 = 1 << 0; // `^` — line-aware under `(?m)`, else buffer start
    const end: u8 = 1 << 1; // `$` — line-aware under `(?m)`, else buffer end
    const buf_start: u8 = 1 << 2; // `\A` — the true buffer start, `(?m)` or not
    const buf_end: u8 = 1 << 3; // `\z` — the true buffer end
};

/// Everything an ε-path between two consuming instructions does, flattened:
/// which slots it writes (all at the same input position, so a bitmask suffices)
/// and which assertions must hold for it to be taken at all. This flattening is
/// the whole optimization — the Pike VM re-walks those ε-instructions per byte
/// per thread; here they collapse into one `u64` and one `u8` at build time.
const Eps = struct {
    slots: u64 = 0,
    asserts: u8 = 0,
    /// Every word assertion on the path, intersected — see `syntax.mask`. The
    /// empty mask is a contradiction (`\B\<`) the builder sees for free, where a
    /// bit per spelling could only rediscover it once per byte at run time.
    word: u4 = syn.mask.free,

    fn plus(self: Eps, a: u8) Eps {
        return .{ .slots = self.slots, .asserts = self.asserts | a, .word = self.word };
    }
    /// Word assertions compose by intersection, not union: a path guarded by two
    /// of them admits only the pairs both admit.
    fn narrow(self: Eps, mask: syn.Word) Eps {
        return .{ .slots = self.slots, .asserts = self.asserts, .word = self.word & @intFromEnum(mask) };
    }
    /// Nothing to check at run time — the path is takeable wherever it is reached.
    fn free(self: Eps) bool {
        return self.asserts == 0 and self.word == syn.mask.free;
    }
    fn eql(a: Eps, b: Eps) bool {
        return a.slots == b.slots and a.asserts == b.asserts and a.word == b.word;
    }
};

const Trans = struct { target: u16, eps: Eps };
const State = struct { accept: ?Eps, ntrans: u32 };

/// A compiled one-pass capture matcher. Owns the `Captures` it was built from:
/// that instance supplies the group names and stands as the fallback the budget
/// bails into, so the two arms can never disagree about what the pattern means.
pub const OnePass = struct {
    caps: Captures,
    /// `nstates × 256` transition indices; 0 is the dead entry.
    rows: []u16,
    states: []State,
    /// Index 0 is a reserved dead slot so `rows` can use 0 as "no transition".
    trans: []Trans,
    /// Bytes that can begin a match, when no zero-length match is possible.
    pre: ?Prefilter,
    /// Copy-on-write snapshot of `out`, taken only when a write lands after an
    /// accept that might still be superseded.
    saved: []isize,
    nslots: usize,
    unicode: bool,
    /// `(?m)` — mirrored from the `Captures` this table was determinized from,
    /// so `holds` reads the same line predicates its ε-instructions meant.
    line_anchors: bool,
    /// Mirrored from the same `Captures`, for the same reason — see its own field
    /// and `closure.lineStart`.
    nl_terminates: bool = true,
    /// How many `find` calls hit the step budget. One pathological line (a
    /// minified bundle) must not cost a good pattern its fast arm for the rest of
    /// the run, but a pattern that is pathological EVERYWHERE should stop
    /// re-discovering that per line — so the trip count is the evidence and
    /// `max_trips` is where the engine concedes. Each trip is itself bounded by
    /// the budget, so the total wasted work before conceding is linear.
    trips: u32 = 0,
    degraded: bool = false,
    gpa: std.mem.Allocator,

    /// Determinize `caps`' program into a one-pass table.
    ///
    /// On `.got` the returned engine OWNS `caps` (deinit it through the result,
    /// never separately). On `.declined` — the routine outcome for the ~half of
    /// capture patterns that genuinely need a search — `caps` is untouched and
    /// the caller keeps using it directly. Only OOM is a fault.
    pub fn attach(gpa: std.mem.Allocator, caps: Captures) std.mem.Allocator.Error!fault.Answer(OnePass) {
        const built = build(gpa, caps) catch |e| switch (e) {
            error.Bail => return .{ .declined = .not_worthwhile },
            error.OutOfMemory => |oom| return oom,
        };
        return .{ .got = built };
    }

    fn build(gpa: std.mem.Allocator, caps: Captures) Err!OnePass {
        var b = Build{ .gpa = gpa, .prog = caps.prog, .ids = undefined, .seen = undefined };
        b.ids = try gpa.alloc(u32, caps.prog.len);
        @memset(b.ids, 0);
        defer gpa.free(b.ids);
        b.seen = try gpa.alloc(u32, caps.prog.len);
        @memset(b.seen, 0);
        defer gpa.free(b.seen);
        defer b.deinit();

        try b.trans.append(gpa, .{ .target = 0, .eps = .{} }); // the dead slot
        _ = try b.stateFor(caps.start);
        var qi: usize = 0;
        while (qi < b.queue.items.len) : (qi += 1) {
            const pc = b.queue.items[qi];
            const id = b.ids[pc] - 1;
            b.gen += 1;
            b.row = @splat(0);
            b.acc = null;
            b.ntrans = 0;
            try b.closure(pc, .{});
            @memcpy(b.rows.items[id * 256 ..][0..256], &b.row);
            b.states.items[id] = .{ .accept = b.acc, .ntrans = b.ntrans };
        }

        // A prefilter is sound only when every match consumes a byte: with a
        // nullable start state the empty match at any position is legal and
        // skipping positions would lose it.
        const pre: ?Prefilter = if (b.states.items[0].accept != null) null else blk: {
            var set = ByteSet{};
            for (b.rows.items[0..256], 0..) |t, byte| if (t != 0) set.set(@intCast(byte));
            break :blk Prefilter.init(set);
        };

        const saved = try gpa.alloc(isize, caps.nslots);
        errdefer gpa.free(saved);
        const rows = try b.rows.toOwnedSlice(gpa);
        errdefer gpa.free(rows);
        const states = try b.states.toOwnedSlice(gpa);
        errdefer gpa.free(states);
        return .{
            .caps = caps,
            .rows = rows,
            .states = states,
            .trans = try b.trans.toOwnedSlice(gpa),
            .pre = pre,
            .saved = saved,
            .nslots = caps.nslots,
            .unicode = caps.unicode,
            .line_anchors = caps.line_anchors,
            .nl_terminates = caps.nl_terminates,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *OnePass) void {
        self.gpa.free(self.rows);
        self.gpa.free(self.states);
        self.gpa.free(self.trans);
        self.gpa.free(self.saved);
        self.caps.deinit();
        self.* = undefined;
    }

    pub fn groupByName(self: *const OnePass, name: []const u8) ?u32 {
        return self.caps.groupByName(name);
    }

    pub fn nameOfGroup(self: *const OnePass, index: u32) ?[]const u8 {
        return self.caps.nameOfGroup(index);
    }

    /// Leftmost-first match within `line[from..]`, filling `out` exactly as
    /// `Captures.find` would. Unanchored search is a restart loop over candidate
    /// starts — sound because an anchored one-pass walk is O(1) per byte, and
    /// budgeted because a pattern whose prefilter admits nearly every position
    /// (`(a+)b` on a run of `a`s) would otherwise be quadratic where the Pike VM
    /// is linear. Tripping the budget hands the whole query back to the Pike VM.
    pub fn find(self: *OnePass, line: []const u8, from: usize, out: []isize) bool {
        if (self.degraded) return self.caps.find(line, from, out);
        const budget = 4 * line.len + 1024;
        var steps: usize = 0;
        var p = from;
        while (p <= line.len) : (p += 1) {
            if (self.pre) |*pf| p = pf.nextStart(line, p) orelse return false;
            @memset(out, -1);
            if (self.walk(line, p, out, &steps)) return true;
            if (steps > budget) {
                self.trips += 1;
                if (self.trips >= max_trips) self.degraded = true;
                return self.caps.find(line, from, out);
            }
        }
        return false;
    }

    /// The anchored twin of `find`: exactly the one-pass walk, with the candidate
    /// -start restart loop removed. No budget is needed — a single walk is O(1)
    /// per byte by construction, so the quadratic shape `find` guards against
    /// cannot arise here.
    pub fn matchAt(self: *OnePass, line: []const u8, from: usize, out: []isize) bool {
        if (self.degraded) return self.caps.matchAt(line, from, out);
        if (from > line.len) return false;
        var steps: usize = 0;
        @memset(out, -1);
        return self.walk(line, from, out, &steps);
    }

    /// One anchored walk from `at`. Exactly one transition is viable per byte by
    /// construction, so this is a plain DFA loop that writes group offsets
    /// straight into the caller's buffer.
    ///
    /// The one subtlety is a greedy accept with live successors: a longer match
    /// may still be found, so the accept's own ε-writes are DEFERRED (applying
    /// them eagerly would leak a group the surviving path never entered) and the
    /// buffer is snapshotted copy-on-write before the first later write. In the
    /// common trailing-repeat shape (`(\w+)$`) the loop transition writes no
    /// slots, so no copy is ever taken.
    fn walk(self: *const OnePass, line: []const u8, at: usize, out: []isize, steps: *usize) bool {
        var sid: u16 = 0;
        var pos = at;
        var pend: ?Eps = null;
        var pend_pos: usize = 0;
        var snapped = false;
        while (true) {
            const st = self.states[sid];
            if (st.accept) |acc| {
                if (self.holds(acc, line, pos)) {
                    if (st.ntrans == 0) {
                        apply(out, acc.slots, pos);
                        return true;
                    }
                    pend = acc;
                    pend_pos = pos;
                    snapped = false;
                }
            }
            if (pos >= line.len) break;
            const ti = self.rows[@as(usize, sid) * 256 + line[pos]];
            if (ti == 0) break;
            const t = self.trans[ti];
            if (!t.eps.free() and !self.holds(t.eps, line, pos)) break;
            if (t.eps.slots != 0) {
                if (pend != null and !snapped) {
                    @memcpy(self.saved, out);
                    snapped = true;
                }
                apply(out, t.eps.slots, pos);
            }
            sid = t.target;
            pos += 1;
            steps.* += 1;
        }
        const acc = pend orelse return false;
        if (snapped) @memcpy(out, self.saved);
        apply(out, acc.slots, pend_pos);
        return true;
    }

    /// Do the assertions on an ε-path hold at gap position `pos`? Byte-identical
    /// to the Pike VM's per-instruction tests (`word.zig` is the shared oracle
    /// for `\b`, `closure.zig`'s line predicates for `(?m)` `^`/`$`), which is
    /// what keeps the two arms from disagreeing in Unicode or multiline mode.
    fn holds(self: *const OnePass, eps: Eps, line: []const u8, pos: usize) bool {
        if (eps.asserts & Assert.start != 0 and
            !(if (self.line_anchors) closure_mod.lineStart(line, pos, self.nl_terminates) else pos == 0)) return false;
        if (eps.asserts & Assert.end != 0 and
            !(if (self.line_anchors) closure_mod.lineEnd(line, pos) else pos == line.len)) return false;
        if (eps.asserts & Assert.buf_start != 0 and pos != 0) return false;
        if (eps.asserts & Assert.buf_end != 0 and pos != line.len) return false;
        if (eps.word == syn.mask.free) return true;
        return syn.mask.holds(eps.word, word.sides(self.unicode, line, pos));
    }
};

/// Write `pos` into every slot named by `mask`.
inline fn apply(out: []isize, mask: u64, pos: usize) void {
    var m = mask;
    while (m != 0) {
        const i = @ctz(m);
        m &= m - 1;
        out[i] = @intCast(pos);
    }
}

/// The determinizer. Walks the capture program's ε-closure from each reachable
/// consuming instruction, flattening saves and assertions into `Eps` and
/// refusing the moment two alternatives could be live at once.
const Build = struct {
    gpa: std.mem.Allocator,
    prog: []const captures.Inst,
    /// `pc → state id + 1`; 0 means this pc has no state yet.
    ids: []u32,
    /// `pc → generation` dedup for one closure walk.
    seen: []u32,
    gen: u32 = 0,
    rows: std.ArrayList(u16) = .empty,
    states: std.ArrayList(State) = .empty,
    trans: std.ArrayList(Trans) = .empty,
    queue: std.ArrayList(u32) = .empty,
    work: usize = 0,
    // Scratch for the state currently being built.
    row: [256]u16 = @splat(0),
    acc: ?Eps = null,
    ntrans: u32 = 0,

    fn deinit(self: *Build) void {
        self.rows.deinit(self.gpa);
        self.states.deinit(self.gpa);
        self.trans.deinit(self.gpa);
        self.queue.deinit(self.gpa);
    }

    fn stateFor(self: *Build, pc: u32) Err!u16 {
        if (self.ids[pc] != 0) return @intCast(self.ids[pc] - 1);
        if (self.states.items.len >= max_states) return error.Bail;
        const id: u16 = @intCast(self.states.items.len);
        try self.states.append(self.gpa, .{ .accept = null, .ntrans = 0 });
        try self.rows.appendNTimes(self.gpa, 0, 256);
        self.ids[pc] = id + 1;
        try self.queue.append(self.gpa, pc);
        return id;
    }

    /// ε-closure of `pc`, accumulating `eps` along the way.
    ///
    /// Revisiting a pc within one closure means two distinct ε-paths converge on
    /// the same NFA state — two live alternatives, possibly with different slot
    /// writes. That is precisely what one-pass forbids, so it is a refusal and
    /// not a dedup. (The Pike VM's identically-shaped `addThread` merges there;
    /// merging is what costs it the slot copy.)
    fn closure(self: *Build, pc: u32, eps: Eps) Err!void {
        if (self.seen[pc] == self.gen) return error.Bail;
        self.seen[pc] = self.gen;
        switch (self.prog[pc]) {
            .split => |sp| {
                try self.closure(sp.a, eps);
                try self.closure(sp.b, eps);
            },
            .save => |sv| try self.closure(sv.out, .{
                .slots = eps.slots | (@as(u64, 1) << @intCast(sv.slot)),
                .asserts = eps.asserts,
                .word = eps.word,
            }),
            .astart => |o| try self.closure(o, eps.plus(Assert.start)),
            .aend => |o| try self.closure(o, eps.plus(Assert.end)),
            .abufstart => |o| try self.closure(o, eps.plus(Assert.buf_start)),
            .abufend => |o| try self.closure(o, eps.plus(Assert.buf_end)),
            .aword => |w| try self.closure(w.out, eps.narrow(w.mask)),
            .match => {
                if (self.acc != null) return error.Bail;
                self.acc = eps;
            },
            .char => |cn| {
                // Reached BELOW a `match` in priority order. If that match is
                // unconditional the Pike VM could never prefer this branch, so
                // dropping it is exact. If the match is assertion-guarded it may
                // fail at run time and hand control here — a choice the table
                // cannot express, so refuse.
                if (self.acc) |m| {
                    if (!m.free()) return error.Bail;
                    return;
                }
                try self.addTrans(cn.set, cn.out, eps);
            },
        }
    }

    /// Claim every byte of `set` for the transition `eps → out`. A byte already
    /// claimed by a DIFFERENT transition is the definitional one-pass conflict.
    fn addTrans(self: *Build, set: ByteSet, out: u32, eps: Eps) Err!void {
        const t = Trans{ .target = try self.stateFor(out), .eps = eps };
        var ti: u16 = 0;
        for (set.bits, 0..) |wbits, w| {
            var m = wbits;
            while (m != 0) {
                const byte = w * 64 + @ctz(m);
                m &= m - 1;
                self.work += 1;
                if (self.work > max_work) return error.Bail;
                const cur = self.row[byte];
                if (cur != 0) {
                    const o = self.trans.items[cur];
                    if (o.target != t.target or !o.eps.eql(t.eps)) return error.Bail;
                    continue;
                }
                if (ti == 0) {
                    if (self.trans.items.len >= max_trans) return error.Bail;
                    try self.trans.append(self.gpa, t);
                    ti = @intCast(self.trans.items.len - 1);
                }
                self.row[byte] = ti;
                self.ntrans += 1;
            }
        }
    }
};

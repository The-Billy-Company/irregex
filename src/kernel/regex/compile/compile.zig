//! irregex — Thompson NFA construction: lowers the `syntax.zig` AST into the flat
//! `State` program that both the Pike VM (`../linear/pike/`) and the eager DFA
//! (`../linear/dfa/powerset.zig`) execute. The structural counterpart to
//! powerset construction (the *other* lowering, NFA→DFA), kept out of the engine
//! so that tier is purely the `Regex` handle + its runtimes.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const u8seq = @import("../unicode/utf8seq.zig");
const Node = syn.Node;
const State = syn.State;
const ByteSet = syn.ByteSet;
const ParseError = syn.ParseError;

/// Lowers the AST into a flat NFA-state program (Thompson 1968 construction —
/// linear-time matching ancestry of the Pike/RE2 lane).
pub const Compiler = struct {
    states: std.ArrayList(State) = .empty,
    /// Woven `uclass` tries, reused across occurrences. Scratch: `states` is
    /// handed on to the program, this is torn down.
    loom: Loom = .empty,
    gpa: std.mem.Allocator,

    pub fn push(self: *Compiler, s: State) ParseError!u32 {
        try self.states.append(self.gpa, s);
        return @intCast(self.states.items.len - 1);
    }

    /// The two `lowerUtf8` emit hooks: a byte-range consume state flowing to
    /// `out`, and a two-way ε-split. (The capture compiler implements the same
    /// pair over its own instruction set, so one lowering serves both engines.)
    pub fn emitConsume(self: *Compiler, lo: u8, hi: u8, out: u32) ParseError!u32 {
        var set = ByteSet{};
        set.setRange(lo, hi);
        return self.push(.{ .consume = .{ .set = set, .out = out } });
    }
    pub fn emitSplit(self: *Compiler, a: u32, b: u32) ParseError!u32 {
        return self.push(.{ .split = .{ .a = a, .b = b } });
    }

    /// Compile `node` so all its exits flow to state `next`; return its entry.
    pub fn compileNode(self: *Compiler, node: *Node, next: u32) ParseError!u32 {
        switch (node.*) {
            .empty => return next,
            .anchor_start => return self.push(.{ .assert_start = next }),
            .anchor_end => return self.push(.{ .assert_end = next }),
            .anchor_buf_start => return self.push(.{ .assert_buf_start = next }),
            .anchor_buf_end => return self.push(.{ .assert_buf_end = next }),
            .word => |mask| return self.push(.{ .assert_word = .{ .mask = mask, .out = next } }),
            .class => |set| return self.push(.{ .consume = .{ .set = set, .out = next } }),
            // A Unicode codepoint class lowers to a compact UTF-8 byte
            // sub-automaton (shared with the capture compiler).
            .uclass => |ranges| return lowerUtf8(self.gpa, &self.loom, ranges, next, self),
            // A capture group is transparent to the boolean engine — lower its child
            // (the index is only meaningful to the separate capture VM).
            .capture => |g| return self.compileNode(g.child, next),
            .concat => |ab| {
                const s2 = try self.compileNode(ab[1], next);
                return self.compileNode(ab[0], s2);
            },
            .alt => |ab| {
                // An alternation whose every branch consumes exactly one byte is not a
                // choice at all — it is a byte CLASS, and `(a|b|…|h)` should reach the
                // determinizer as one consume over `[a-h]` rather than as 8 consumes
                // behind 7 splits. See `oneByteUnion` for why this is span-safe.
                if (oneByteUnion(node)) |set| return self.push(.{ .consume = .{ .set = set, .out = next } });
                const sa = try self.compileNode(ab[0], next);
                const sb = try self.compileNode(ab[1], next);
                return self.push(.{ .split = .{ .a = sa, .b = sb } });
            },
            .quest => |r| {
                const sx = try self.compileNode(r.node, next);
                // Priority order: greedy prefers the body (`sx`), lazy prefers the
                // exit (`next`). The Pike VM adds `split.a` before `split.b`, so the
                // high-priority branch is `.a`.
                return self.push(if (r.lazy) .{ .split = .{ .a = next, .b = sx } } else .{ .split = .{ .a = sx, .b = next } });
            },
            .star, .plus => |r, tag| {
                const sp = try self.push(.{ .split = .{ .a = 0, .b = 0 } });
                const sx = try self.compileNode(r.node, sp);
                // Greedy: loop back (`sx`) is high priority, exit (`next`) low. Lazy
                // swaps them (prefer to stop). Set both arms explicitly per laziness.
                self.states.items[sp].split = if (r.lazy) .{ .a = next, .b = sx } else .{ .a = sx, .b = next };
                // star enters at the split (zero iters OK); plus enters at x (run once, then loop back via the split).
                return if (tag == .star) sp else sx;
            },
        }
    }
};

/// The union of an alternation's branches when **every** branch consumes exactly one
/// byte, else null — the one shape where collapsing a choice into a class is free.
///
/// Why this is safe where re-associating an alternation is not (`../ast/intern.zig`):
/// leftmost-first selection depends on branch order only when two branches can reach
/// the same start with *different* ends. Here every branch consumes one byte and
/// flows to the same `next`, so each branch's thread arrives at the identical
/// (state, position) pair — which the Pike VM already dedupes — and the surviving
/// thread is the same one whichever branch had priority. Spans, `-o`, and the
/// `a|ab ⇒ a` rule are therefore unaffected: `ab` is a `.concat`, so it declines
/// here and keeps its split.
///
/// Declines by construction on everything that could observe the order: `.concat`
/// and `.uclass` (more than one byte), `.empty` and the assertions (zero bytes), and
/// every quantifier (a variable count). `.capture` descends because this compiler
/// already lowers a group transparently — and the *capture* VM has its own
/// alternation lowering (`captures.zig`), so no slot boundary is reachable from here.
fn oneByteUnion(node: *const Node) ?ByteSet {
    switch (node.*) {
        .class => |set| return set,
        .capture => |g| return oneByteUnion(g.child),
        .alt => |ab| {
            var set = oneByteUnion(ab[0]) orelse return null;
            set.unionWith(oneByteUnion(ab[1]) orelse return null);
            return set;
        },
        else => return null,
    }
}

// ─────────────────────── Unicode class → UTF-8 byte trie ───────────────────────
//
// A `uclass` (a set of Unicode scalar ranges) is lowered into a byte
// sub-automaton that recognizes exactly the well-formed UTF-8 encodings of those
// scalar values, flowing to `next`. Each scalar range is decomposed into 1–4
// successive byte ranges (`utf8seq`), then all the resulting byte sequences are
// woven into a **prefix-merged, hash-consed** trie: sequences sharing a leading
// byte-range fuse at the front, and identical suffixes (e.g. every 3-byte tail
// `[80-BF][80-BF] → next`) collapse to one shared chain. This keeps `\w`
// (~800 ranges) or `.` (all of Unicode) to a few dozen NFA states rather than
// thousands — the determinizer then sees a tiny byte alphabet and stays at its
// O(1)/byte floor. Emits through the caller's `emitConsume`/`emitSplit` hooks so
// the same routine serves the boolean compiler here and the capture VM.
//
// **The trie is woven once per class, not once per occurrence.** Expanding the
// ranges, sorting the sequences, and weaving the prefix trie is the entire cost,
// and none of it depends on where the class flows to — only the leaf targets do.
// So `Loom` keeps the finished shape and an occurrence replays it: a few dozen
// emits against the real `next`. `(\w)(\w)(\w)(\w)` weaves one trie and replays
// it four times, where it used to weave four.

const Cache = std.AutoHashMap(u64, u32);

/// A `uclass` lowered to the SHAPE of its byte trie, with the exit left open.
///
/// The weave records its emissions against a virtual id space — `exit` for
/// wherever the occurrence continues, an index into `ops` for anything the weave
/// emitted itself — in the order it emitted them.
///
/// **A replay reproduces the byte-identical program a direct weave would have.**
/// The recording IS a weave (same grouping, same hash-consing, driven through the
/// same `ctx` hooks), and virtual → real is injective: `exit` becomes the
/// caller's `next`, which was pushed before the replay starts, and `ops[i]`
/// becomes the i-th state the replay pushes. So two subtries land on one real
/// state exactly when they landed on one virtual state.
pub const Weave = struct {
    ops: []const Op,
    /// Where an occurrence enters — a `Ref` rather than "the last op", because a
    /// hash-cons can serve the entry from a node emitted earlier, and an empty
    /// class emits a single unsatisfiable consume.
    entry: Ref,

    /// A virtual state: `exit` is whatever the occurrence flows to, anything else
    /// indexes `ops`.
    pub const Ref = u32;
    pub const exit: Ref = std.math.maxInt(u32);

    pub const Op = union(enum) {
        consume: struct { lo: u8, hi: u8, out: Ref },
        split: struct { a: Ref, b: Ref },
    };

    fn real(r: Ref, next: u32, ids: []const u32) u32 {
        return if (r == exit) next else ids[r];
    }
};

/// The weaves one compile has already paid for, keyed by the scalar ranges they
/// lower. Pure scratch — it never becomes part of a program, so a caller tears it
/// down unconditionally rather than handing it on like `states`.
///
/// Keys borrow the AST's own range slices, which outlive the compile.
pub const Loom = struct {
    made: WeaveMap = .empty,
    /// Replay scratch: one real state id per trie node, kept here so a class with
    /// twenty occurrences allocates it once.
    ids: std.ArrayList(u32) = .empty,

    pub const empty: Loom = .{};

    pub fn deinit(l: *Loom, gpa: std.mem.Allocator) void {
        var it = l.made.valueIterator();
        while (it.next()) |wv| gpa.free(wv.ops);
        l.made.deinit(gpa);
        l.ids.deinit(gpa);
    }

    /// The weave for `ranges`, recording it on first sight.
    fn weaveFor(l: *Loom, gpa: std.mem.Allocator, ranges: []const [2]u21) ParseError!Weave {
        const gop = try l.made.getOrPut(gpa, ranges);
        if (!gop.found_existing) {
            gop.value_ptr.* = record(gpa, ranges) catch |e| {
                // A half-inserted key would be found on the retry and read as a
                // weave nothing wrote.
                _ = l.made.remove(ranges);
                return e;
            };
        }
        return gop.value_ptr.*;
    }
};

const WeaveCtx = struct {
    pub fn hash(_: WeaveCtx, k: []const [2]u21) u64 {
        // Through `u32` rather than `asBytes` on the `u21`s: a `u21` is stored in
        // four bytes whose top eleven bits no value owns.
        var h = std.hash.Wyhash.init(k.len);
        for (k) |r| h.update(std.mem.asBytes(&[2]u32{ r[0], r[1] }));
        return h.final();
    }
    pub fn eql(_: WeaveCtx, a: []const [2]u21, b: []const [2]u21) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (x[0] != y[0] or x[1] != y[1]) return false;
        return true;
    }
};

const WeaveMap = std.HashMapUnmanaged(
    []const [2]u21,
    Weave,
    WeaveCtx,
    std.hash_map.default_max_load_percentage,
);

/// The `ctx` that turns a weave into a `Weave` instead of into a program: the
/// same two hooks, writing ops and handing back their indices as virtual ids.
const Recorder = struct {
    gpa: std.mem.Allocator,
    ops: std.ArrayList(Weave.Op) = .empty,

    fn emit(r: *Recorder, op: Weave.Op) ParseError!u32 {
        try r.ops.append(r.gpa, op);
        return @intCast(r.ops.items.len - 1);
    }
    pub fn emitConsume(r: *Recorder, lo: u8, hi: u8, out: u32) ParseError!u32 {
        return r.emit(.{ .consume = .{ .lo = lo, .hi = hi, .out = out } });
    }
    pub fn emitSplit(r: *Recorder, a: u32, b: u32) ParseError!u32 {
        return r.emit(.{ .split = .{ .a = a, .b = b } });
    }
};

const Woven = struct {
    consume: Cache,
    split: Cache,

    /// Reuse or create a byte-range consume state; hash-consed so shared suffixes
    /// (and duplicate branches) collapse to one state.
    /// Interning key for a consume state: `(lo, hi, out)` packed into a u64.
    fn cons(w: *Woven, ctx: anytype, lo: u8, hi: u8, out: u32) ParseError!u32 {
        const gop = try w.consume.getOrPut((@as(u64, lo) << 40) | (@as(u64, hi) << 32) | out);
        if (!gop.found_existing) gop.value_ptr.* = try ctx.emitConsume(lo, hi, out);
        return gop.value_ptr.*;
    }
    fn alt(w: *Woven, ctx: anytype, a: u32, b: u32) ParseError!u32 {
        const gop = try w.split.getOrPut((@as(u64, a) << 32) | b);
        if (!gop.found_existing) gop.value_ptr.* = try ctx.emitSplit(a, b);
        return gop.value_ptr.*;
    }
};

/// Order sequences lexicographically by their byte ranges — so equal-prefix runs
/// are contiguous (which is what makes the single-pass trie grouping correct).
fn lessSeq(_: void, x: u8seq.Sequence, y: u8seq.Sequence) bool {
    const n = @min(x.len, y.len);
    for (x.ranges[0..n], y.ranges[0..n]) |a, b| {
        if (a.start != b.start) return a.start < b.start;
        if (a.end != b.end) return a.end < b.end;
    }
    return x.len < y.len;
}

/// Build the trie for the (sorted) sequences at byte position `depth`, flowing to
/// `next`; returns the entry state. Groups by the range at `depth`, recurses on
/// each group's tails, and combines the group entries with hash-consed splits.
fn weave(seqs: []const u8seq.Sequence, depth: usize, next: u32, w: *Woven, ctx: anytype) ParseError!u32 {
    var acc: ?u32 = null;
    var idx: usize = 0;
    while (idx < seqs.len) {
        const f = seqs[idx].ranges[depth];
        var j = idx + 1;
        while (j < seqs.len and std.meta.eql(seqs[j].ranges[depth], f)) j += 1;
        // Every sequence in this group shares byte `f` at `depth`, hence the same
        // UTF-8 length, so `seqs[idx].len` is the group's length.
        const child = if (depth + 1 == seqs[idx].len) next else try weave(seqs[idx..j], depth + 1, next, w, ctx);
        const st = try w.cons(ctx, f.start, f.end, child);
        acc = if (acc) |a| try w.alt(ctx, a, st) else st;
        idx = j;
    }
    return acc.?; // callers never pass an empty slice
}

/// Lower a set of Unicode scalar ranges into a UTF-8 byte sub-automaton flowing
/// to `next`, via `ctx.emitConsume(lo,hi,out)` / `ctx.emitSplit(a,b)`. Returns the
/// entry state.
///
/// The weave itself happens once per distinct range set per compile (`Loom`); this
/// is the replay, and it emits in the recorded order so the program is the one a
/// direct weave would have written.
pub fn lowerUtf8(
    gpa: std.mem.Allocator,
    loom: *Loom,
    ranges: []const [2]u21,
    next: u32,
    ctx: anytype,
) ParseError!u32 {
    const wv = try loom.weaveFor(gpa, ranges);
    const ids = try loom.ids.addManyAsSlice(gpa, wv.ops.len);
    defer loom.ids.clearRetainingCapacity();
    for (wv.ops, ids) |op, *slot| slot.* = switch (op) {
        .consume => |c| try ctx.emitConsume(c.lo, c.hi, Weave.real(c.out, next, ids)),
        .split => |s| try ctx.emitSplit(
            Weave.real(s.a, next, ids),
            Weave.real(s.b, next, ids),
        ),
    };
    return Weave.real(wv.entry, next, ids);
}

/// Weave `ranges` once, against the virtual exit, and keep what it emitted.
fn record(gpa: std.mem.Allocator, ranges: []const [2]u21) ParseError!Weave {
    var rec = Recorder{ .gpa = gpa };
    errdefer rec.ops.deinit(gpa);

    var seqs: std.ArrayList(u8seq.Sequence) = .empty;
    defer seqs.deinit(gpa);
    for (ranges) |rng| {
        var it = u8seq.Sequences.init(@intCast(rng[0]), @intCast(rng[1]));
        while (it.next()) |s| try seqs.append(gpa, s);
    }
    // An empty class (e.g. a negation that covers everything) matches nothing:
    // a consume with an empty byte set (lo > hi) that can never fire.
    const entry = if (seqs.items.len == 0)
        try rec.emitConsume(1, 0, Weave.exit)
    else blk: {
        std.mem.sort(u8seq.Sequence, seqs.items, {}, lessSeq);
        var w = Woven{ .consume = Cache.init(gpa), .split = Cache.init(gpa) };
        defer w.consume.deinit();
        defer w.split.deinit();
        break :blk try weave(seqs.items, 0, Weave.exit, &w, &rec);
    };
    return .{ .ops = try rec.ops.toOwnedSlice(gpa), .entry = entry };
}

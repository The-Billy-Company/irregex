//! gist — Thompson NFA construction: lowers the `syntax.zig` AST into the flat
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
            .uclass => |ranges| return lowerUtf8(self.gpa, ranges, next, self),
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

const Cache = std.AutoHashMap(u64, u32);

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
pub fn lowerUtf8(gpa: std.mem.Allocator, ranges: []const [2]u21, next: u32, ctx: anytype) ParseError!u32 {
    var seqs: std.ArrayList(u8seq.Sequence) = .empty;
    defer seqs.deinit(gpa);
    for (ranges) |rng| {
        var it = u8seq.Sequences.init(@intCast(rng[0]), @intCast(rng[1]));
        while (it.next()) |s| try seqs.append(gpa, s);
    }
    // An empty class (e.g. a negation that covers everything) matches nothing:
    // a consume with an empty byte set (lo > hi) that can never fire.
    if (seqs.items.len == 0) return ctx.emitConsume(1, 0, next);

    std.mem.sort(u8seq.Sequence, seqs.items, {}, lessSeq);
    var w = Woven{ .consume = Cache.init(gpa), .split = Cache.init(gpa) };
    defer w.consume.deinit();
    defer w.split.deinit();
    return weave(seqs.items, 0, next, &w, ctx);
}

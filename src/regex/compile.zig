//! gist — Thompson NFA construction: lowers the `syntax.zig` AST into the flat
//! `State` program that both the Pike VM (`core.zig`) and the lazy DFA
//! (`powerset.zig`) execute. The structural counterpart to `powerset.zig` (the
//! *other* lowering, NFA→DFA), kept out of `core.zig` so that file is purely the
//! `Regex` handle + Pike runtime.

const std = @import("std");
const syn = @import("syntax.zig");
const u8seq = @import("unicode/utf8seq.zig");
const Node = syn.Node;
const State = syn.State;
const ByteSet = syn.ByteSet;
const ParseError = syn.ParseError;

/// Lowers the AST into a flat NFA-state program (Thompson construction).
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
            .word_boundary => return self.push(.{ .assert_word_b = next }),
            .not_word_boundary => return self.push(.{ .assert_not_word_b = next }),
            .word_start => return self.push(.{ .assert_word_start = next }),
            .word_end => return self.push(.{ .assert_word_end = next }),
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

// ─────────────────────── Unicode class → UTF-8 byte trie ───────────────────────
//
// A `uclass` (a set of Unicode scalar ranges) is lowered into a byte
// sub-automaton that recognises exactly the well-formed UTF-8 encodings of those
// scalar values, flowing to `next`. Each scalar range is decomposed into 1–4
// successive byte ranges (`utf8seq`), then all the resulting byte sequences are
// woven into a **prefix-merged, hash-consed** trie: sequences sharing a leading
// byte-range fuse at the front, and identical suffixes (e.g. every 3-byte tail
// `[80-BF][80-BF] → next`) collapse to one shared chain. This keeps `\w`
// (~800 ranges) or `.` (all of Unicode) to a few dozen NFA states rather than
// thousands — the determinizer then sees a tiny byte alphabet and stays at its
// O(1)/byte floor. Emits through the caller's `emitConsume`/`emitSplit` hooks so
// the same routine serves the boolean compiler here and the capture VM.

/// Interning key for a consume state: `(lo, hi, out)` packed into a u64.
fn consumeKey(lo: u8, hi: u8, out: u32) u64 {
    return (@as(u64, lo) << 40) | (@as(u64, hi) << 32) | out;
}
fn splitKey(a: u32, b: u32) u64 {
    return (@as(u64, a) << 32) | b;
}

const Cache = std.AutoHashMap(u64, u32);

const Woven = struct {
    gpa: std.mem.Allocator,
    consume: Cache,
    split: Cache,

    /// Reuse or create a byte-range consume state; hash-consed so shared suffixes
    /// (and duplicate branches) collapse to one state.
    fn cons(w: *Woven, ctx: anytype, lo: u8, hi: u8, out: u32) ParseError!u32 {
        const gop = w.consume.getOrPut(consumeKey(lo, hi, out)) catch return ParseError.OutOfMemory;
        if (!gop.found_existing) gop.value_ptr.* = try ctx.emitConsume(lo, hi, out);
        return gop.value_ptr.*;
    }
    fn alt(w: *Woven, ctx: anytype, a: u32, b: u32) ParseError!u32 {
        const gop = w.split.getOrPut(splitKey(a, b)) catch return ParseError.OutOfMemory;
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

fn rangeEq(a: u8seq.ByteRange, b: u8seq.ByteRange) bool {
    return a.start == b.start and a.end == b.end;
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
        while (j < seqs.len and rangeEq(seqs[j].ranges[depth], f)) j += 1;
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
    var w = Woven{ .gpa = gpa, .consume = Cache.init(gpa), .split = Cache.init(gpa) };
    defer w.consume.deinit();
    defer w.split.deinit();
    return weave(seqs.items, 0, next, &w, ctx);
}

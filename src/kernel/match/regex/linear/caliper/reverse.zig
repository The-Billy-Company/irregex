//! gist — the Thompson program, read right to left.
//!
//! The caliper closes on a match from both sides: a forward pass finds where it
//! ENDS, a backward pass finds where it BEGAN. The backward pass needs an
//! automaton for the reversed language, and this file builds one from the
//! forward program — no second parse, no second lowering, so the two directions
//! cannot disagree about what the pattern means.
//!
//! **Assertions survive reversal untouched.** `^ $ \b \B \< \>` are *position
//! predicates* — `^` asserts "this gap is a line start", `\b` asserts "the bytes
//! straddling this gap differ in word-ness". Neither says anything about which
//! way a scan is traveling, so a reversed edge carries its assertion verbatim
//! and `subset.passes` resolves it against the same real coordinates. Only the
//! ORDER in which a path meets its assertions flips, and a path is a set of
//! predicates over positions, not a sequence.
//!
//! ## Shape of the output
//!
//! Node `i` of the reversed program is the **hub** of original state `i`: a
//! split-chain fanning out to every reversed edge that lands on it. Aligning
//! hubs with original indices is what lets an edge name its target without a
//! mapping table.
//!
//!   * original `consume{set, out}` at `i` ⇒ a fresh `consume{set, i}` hung off
//!     hub `out` (walk the byte backwards and you are at `i`);
//!   * original `split{a, b}` at `i` ⇒ hub `a` and hub `b` each gain `i`;
//!   * original `assert_X{o}` at `i` ⇒ a fresh `assert_X{i}` hung off hub `o`;
//!   * the original start's hub gains a fresh `match` — arriving there means the
//!     backward walk retraced a whole path, so a match begins at this position.
//!
//! The reversed start is the original `match` state's hub. A hub with `k`
//! successors is `k-1` binary splits (`k-2` of them appended past the hubs); a
//! hub with one successor duplicates it, and a hub with none self-loops, so no
//! dead sentinel is needed — the closure's dedup terminates both.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");

const State = syn.State;

/// A reversed program and the two ends that matter. `start` is where a backward
/// walk begins (the forward program's `match`); reaching `accept` means a match
/// starts at the current position.
pub const Program = struct {
    states: []State,
    start: u32,
    accept: u32,
    gpa: std.mem.Allocator,

    pub fn deinit(p: *Program) void {
        p.gpa.free(p.states);
        p.* = undefined;
    }
};

/// The successor of a zero-width state, or null for everything that isn't one.
fn epsOut(st: State) ?u32 {
    return switch (st) {
        .assert_start,
        .assert_end,
        .assert_word_b,
        .assert_not_word_b,
        .assert_word_start,
        .assert_word_end,
        .assert_buf_start,
        .assert_buf_end,
        => |o| o,
        else => null,
    };
}

/// The same assertion, pointing somewhere else — the mirrored edge.
fn retarget(st: State, o: u32) State {
    return switch (st) {
        inline .assert_start,
        .assert_end,
        .assert_word_b,
        .assert_not_word_b,
        .assert_word_start,
        .assert_word_end,
        .assert_buf_start,
        .assert_buf_end,
        => |_, tag| @unionInit(State, @tagName(tag), o),
        else => unreachable,
    };
}

/// Reverse `states` (a lowered Thompson program whose sole `match` is at
/// `match_idx`) into an automaton for the reversed language.
pub fn build(gpa: std.mem.Allocator, states: []const State, start: u32, match_idx: u32) std.mem.Allocator.Error!Program {
    const n = states.len;

    // How many reversed edges land on each hub, and how many fresh nodes those
    // edges need. `+1` on the start's hub is the accept this construction adds.
    const fan = try gpa.alloc(u32, n);
    defer gpa.free(fan);
    @memset(fan, 0);
    var edge_nodes: usize = 1; // the accept
    for (states) |st| switch (st) {
        .consume => |c| {
            fan[c.out] += 1;
            edge_nodes += 1;
        },
        .split => |sp| {
            fan[sp.a] += 1;
            fan[sp.b] += 1;
        },
        .match => {},
        else => {
            fan[epsOut(st).?] += 1;
            edge_nodes += 1;
        },
    };
    fan[start] += 1;

    // A hub of k successors is k-1 splits; it already owns one, so k-2 are new.
    var chain: usize = 0;
    var succ_total: usize = 0;
    for (fan) |k| {
        succ_total += k;
        if (k >= 2) chain += k - 2;
    }

    const out = try gpa.alloc(State, n + edge_nodes + chain);
    errdefer gpa.free(out);

    // Successors per hub, CSR-style: `off` bounds each hub's run, `fill` is its
    // append cursor.
    const off = try gpa.alloc(u32, n + 1);
    defer gpa.free(off);
    const succ = try gpa.alloc(u32, succ_total);
    defer gpa.free(succ);
    const fill = try gpa.alloc(u32, n);
    defer gpa.free(fill);
    @memset(fill, 0);
    var acc: u32 = 0;
    for (fan, 0..) |k, i| {
        off[i] = acc;
        acc += k;
    }
    off[n] = acc;

    // Materialize one fresh node per consuming / asserting edge, and file it
    // under the hub that edge now leaves from.
    var next: u32 = @intCast(n);
    const hang = struct {
        fn at(s: []u32, o: []const u32, f: []u32, hub: u32, node: u32) void {
            s[o[hub] + f[hub]] = node;
            f[hub] += 1;
        }
    }.at;
    for (states, 0..) |st, i| {
        const self: u32 = @intCast(i);
        switch (st) {
            .consume => |c| {
                out[next] = .{ .consume = .{ .set = c.set, .out = self } };
                hang(succ, off, fill, c.out, next);
                next += 1;
            },
            .split => |sp| {
                hang(succ, off, fill, sp.a, self);
                hang(succ, off, fill, sp.b, self);
            },
            .match => {},
            else => {
                const o = epsOut(st).?;
                out[next] = retarget(st, self);
                hang(succ, off, fill, o, next);
                next += 1;
            },
        }
    }
    const accept = next;
    out[accept] = .match;
    hang(succ, off, fill, start, accept);
    next += 1;

    // Fan each hub out as a split-chain over the edges filed under it.
    for (0..n) |i| {
        const mine = succ[off[i]..off[i + 1]];
        const self: u32 = @intCast(i);
        if (mine.len < 2) {
            // No successors ⇒ an inert self-loop the closure's dedup absorbs;
            // exactly one ⇒ name it twice rather than invent a dead sentinel.
            const only = if (mine.len == 1) mine[0] else self;
            out[i] = .{ .split = .{ .a = only, .b = only } };
            continue;
        }
        var cur = self;
        for (mine[0 .. mine.len - 1], 0..) |s, j| {
            const rest = if (j + 2 == mine.len) mine[mine.len - 1] else blk: {
                defer next += 1;
                break :blk next;
            };
            out[cur] = .{ .split = .{ .a = s, .b = rest } };
            cur = rest;
        }
    }

    return .{ .states = out, .start = match_idx, .accept = accept, .gpa = gpa };
}

/// The lone `match` in a lowered program, or null if it carries a buffer anchor
/// (`\A`/`\z`, multiline only) the caliper declines to reverse.
pub fn matchIndex(states: []const State) ?u32 {
    var found: ?u32 = null;
    for (states, 0..) |st, i| switch (st) {
        .match => found = @intCast(i),
        .assert_buf_start, .assert_buf_end => return null,
        else => {},
    };
    return found;
}

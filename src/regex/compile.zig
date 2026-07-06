//! gist — Thompson NFA construction: lowers the `syntax.zig` AST into the flat
//! `State` program that both the Pike VM (`core.zig`) and the lazy DFA
//! (`powerset.zig`) execute. The structural counterpart to `powerset.zig` (the
//! *other* lowering, NFA→DFA), kept out of `core.zig` so that file is purely the
//! `Regex` handle + Pike runtime.

const std = @import("std");
const syn = @import("syntax.zig");
const Node = syn.Node;
const State = syn.State;
const ParseError = syn.ParseError;

/// Lowers the AST into a flat NFA-state program (Thompson construction).
pub const Compiler = struct {
    states: std.ArrayList(State) = .empty,
    gpa: std.mem.Allocator,

    pub fn push(self: *Compiler, s: State) ParseError!u32 {
        try self.states.append(self.gpa, s);
        return @intCast(self.states.items.len - 1);
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

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
            .class => |set| return self.push(.{ .consume = .{ .set = set, .out = next } }),
            .concat => |ab| {
                const s2 = try self.compileNode(ab[1], next);
                return self.compileNode(ab[0], s2);
            },
            .alt => |ab| {
                const sa = try self.compileNode(ab[0], next);
                const sb = try self.compileNode(ab[1], next);
                return self.push(.{ .split = .{ .a = sa, .b = sb } });
            },
            .quest => |x| {
                const sx = try self.compileNode(x, next);
                return self.push(.{ .split = .{ .a = sx, .b = next } });
            },
            .star, .plus => |x, tag| {
                const sp = try self.push(.{ .split = .{ .a = 0, .b = next } });
                const sx = try self.compileNode(x, sp);
                self.states.items[sp].split.a = sx;
                // star enters at the split (zero iters OK); plus enters at x (run once, then loop back via the split).
                return if (tag == .star) sp else sx;
            },
        }
    }
};

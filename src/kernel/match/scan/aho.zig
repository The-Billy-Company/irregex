//! Sparse Aho–Corasick for large literal sets.
//!
//! Construction follows Aho and Corasick (1975): trie edges plus failure links.
//! Edges are sibling-linked rather than a `states × 256` matrix, bounding compile
//! memory by the literal bytes. The compiled slices are immutable; scanning does
//! not allocate. Each state carries the longest suffix output so `find` preserves
//! leftmost-start semantics, not merely earliest-ending semantics.

const std = @import("std");

const none = std.math.maxInt(u32);
pub const max_literals: usize = 8192;
pub const max_literal_bytes: usize = 1024 * 1024;

const Node = struct {
    first_edge: u32 = none,
    fail: u32 = 0,
    output_len: u32 = 0,
};

const Edge = struct {
    byte: u8,
    next: u32,
    sibling: u32,
};

// Cap refusals stay file-private (ADR-373); `BuildError` unions them so callers
// see one set without minting a second public spelling of the same facts.
const Cap = error{
    TooManyLiterals,
    LiteralBytesExceeded,
};
pub const BuildError = std.mem.Allocator.Error || Cap;

/// Immutable sparse automaton. It borrows no input literals after `build`.
pub const Aho = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    edges: []Edge,
    has_empty: bool,
    max_len: usize,

    pub fn build(allocator: std.mem.Allocator, needles: []const []const u8) BuildError!Aho {
        if (needles.len > max_literals) return Cap.TooManyLiterals;
        var bytes: usize = 0;
        for (needles) |needle|
            bytes = std.math.add(usize, bytes, needle.len) catch return Cap.LiteralBytesExceeded;
        if (bytes > max_literal_bytes) return Cap.LiteralBytesExceeded;

        var nodes: std.ArrayList(Node) = .empty;
        defer nodes.deinit(allocator);
        var edges: std.ArrayList(Edge) = .empty;
        defer edges.deinit(allocator);
        try nodes.ensureTotalCapacity(allocator, bytes + 1);
        try edges.ensureTotalCapacity(allocator, bytes);
        try nodes.append(allocator, .{});

        var has_empty = false;
        var max_len: usize = 0;
        for (needles) |needle| {
            if (needle.len == 0) {
                has_empty = true;
                continue;
            }
            max_len = @max(max_len, needle.len);
            var state: u32 = 0;
            for (needle) |byte| {
                state = findEdge(nodes.items, edges.items, state, byte) orelse blk: {
                    const child: u32 = @intCast(nodes.items.len);
                    const edge: u32 = @intCast(edges.items.len);
                    try nodes.append(allocator, .{});
                    try edges.append(allocator, .{
                        .byte = byte,
                        .next = child,
                        .sibling = nodes.items[state].first_edge,
                    });
                    nodes.items[state].first_edge = edge;
                    break :blk child;
                };
            }
            nodes.items[state].output_len = @max(nodes.items[state].output_len, @as(u32, @intCast(needle.len)));
        }

        var queue = try allocator.alloc(u32, nodes.items.len);
        defer allocator.free(queue);
        var read: usize = 0;
        var write: usize = 0;
        var edge = nodes.items[0].first_edge;
        while (edge != none) : (edge = edges.items[edge].sibling) {
            const child = edges.items[edge].next;
            nodes.items[child].fail = 0;
            queue[write] = child;
            write += 1;
        }
        while (read < write) : (read += 1) {
            const parent = queue[read];
            edge = nodes.items[parent].first_edge;
            while (edge != none) : (edge = edges.items[edge].sibling) {
                const child = edges.items[edge].next;
                const byte = edges.items[edge].byte;
                var fallback = nodes.items[parent].fail;
                while (fallback != 0 and findEdge(nodes.items, edges.items, fallback, byte) == null)
                    fallback = nodes.items[fallback].fail;
                nodes.items[child].fail = findEdge(nodes.items, edges.items, fallback, byte) orelse 0;
                nodes.items[child].output_len = @max(
                    nodes.items[child].output_len,
                    nodes.items[nodes.items[child].fail].output_len,
                );
                queue[write] = child;
                write += 1;
            }
        }

        const owned_nodes = try nodes.toOwnedSlice(allocator);
        errdefer allocator.free(owned_nodes);
        const owned_edges = try edges.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .nodes = owned_nodes,
            .edges = owned_edges,
            .has_empty = has_empty,
            .max_len = max_len,
        };
    }

    pub fn deinit(self: *Aho) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.edges);
        self.* = undefined;
    }

    /// Leftmost occurrence at or after `from`. Scans only until no future match
    /// can start before the best start already seen.
    pub fn find(self: *const Aho, hay: []const u8, from: usize) ?usize {
        if (from > hay.len) return null;
        if (self.has_empty) return from;
        var state: u32 = 0;
        var best: ?usize = null;
        for (hay[from..], from..) |byte, end| {
            while (state != 0 and findEdge(self.nodes, self.edges, state, byte) == null)
                state = self.nodes[state].fail;
            state = findEdge(self.nodes, self.edges, state, byte) orelse 0;
            const output_len = self.nodes[state].output_len;
            if (output_len != 0) {
                const start = end + 1 - output_len;
                if (best == null or start < best.?) best = start;
            }
            if (best) |start| if (end + 1 >= start + self.max_len) break;
        }
        return best;
    }

    pub fn contains(self: *const Aho, hay: []const u8) bool {
        return self.find(hay, 0) != null;
    }
};

inline fn findEdge(nodes: []const Node, edges: []const Edge, state: u32, byte: u8) ?u32 {
    var edge = nodes[state].first_edge;
    while (edge != none) : (edge = edges[edge].sibling)
        if (edges[edge].byte == byte) return edges[edge].next;
    return null;
}

test "sparse Aho preserves leftmost across shared prefixes and duplicates" {
    const needles = [_][]const u8{ "bc", "abcdef", "abc", "bc", "abacus" };
    var ac = try Aho.build(std.testing.allocator, &needles);
    defer ac.deinit();
    try std.testing.expectEqual(@as(?usize, 2), ac.find("__abcdef", 0));
    try std.testing.expectEqual(@as(?usize, 3), ac.find("___bc", 1));
}

test "sparse Aho handles empty needles and 65 literals" {
    const sixty_five = comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: [65][]const u8 = undefined;
        for (&out, 0..) |*n, i| n.* = std.fmt.comptimePrint("aho-{d:0>2}", .{i});
        break :blk out;
    };
    var ac = try Aho.build(std.testing.allocator, &sixty_five);
    defer ac.deinit();
    try std.testing.expectEqual(@as(?usize, 2), ac.find("__aho-64__", 0));

    const empty = [_][]const u8{ "", "later" };
    var empty_ac = try Aho.build(std.testing.allocator, &empty);
    defer empty_ac.deinit();
    try std.testing.expectEqual(@as(?usize, 3), empty_ac.find("abc", 3));
}

test "sparse Aho compiles and finds the 5000 boundary without scan allocation" {
    const allocator = std.testing.allocator;
    var storage: [5000][8]u8 = undefined;
    var needles: [5000][]const u8 = undefined;
    for (&storage, &needles, 0..) |*buf, *needle, i| {
        const rendered = try std.fmt.bufPrint(buf, "k{d:0>7}", .{i});
        needle.* = rendered;
    }
    var ac = try Aho.build(allocator, &needles);
    defer ac.deinit();
    try std.testing.expectEqual(@as(?usize, 2), ac.find("__k0004999__", 0));
}

//! Disjoint-set forest — union-find with path-halving finds and min-index
//! roots, so a component's identity is stable regardless of join order.
//! Pure graph math with zero kinship semantics; `kinship/cluster/families`
//! collapses its verified near-duplicate edges through this.

const std = @import("std");

/// Union-find with path compression. Roots are the minimum member index, so a
/// component's identity is stable regardless of join order.
pub const Forest = struct {
    parent: []u32,

    pub fn init(gpa: std.mem.Allocator, n: usize) !Forest {
        const parent = try gpa.alloc(u32, n);
        for (parent, 0..) |*p, i| p.* = @intCast(i);
        return .{ .parent = parent };
    }

    pub fn deinit(self: *Forest, gpa: std.mem.Allocator) void {
        gpa.free(self.parent);
    }

    pub fn find(self: *Forest, x0: u32) u32 {
        var x = x0;
        while (self.parent[x] != x) {
            self.parent[x] = self.parent[self.parent[x]]; // halve the path
            x = self.parent[x];
        }
        return x;
    }

    pub fn join(self: *Forest, a: u32, b: u32) void {
        const ra = self.find(a);
        const rb = self.find(b);
        if (ra != rb) self.parent[@max(ra, rb)] = @min(ra, rb);
    }
};

const t = std.testing;

test "Forest: transitive joins collapse into one min-rooted component" {
    var forest = try Forest.init(t.allocator, 6);
    defer forest.deinit(t.allocator);
    forest.join(0, 1);
    forest.join(1, 2); // 0-1-2 chain: transitivity through the shared member
    forest.join(4, 5);

    try t.expectEqual(forest.find(0), forest.find(2));
    try t.expectEqual(@as(u32, 0), forest.find(2)); // root is the min index
    try t.expectEqual(@as(u32, 4), forest.find(5));
    try t.expectEqual(@as(u32, 3), forest.find(3)); // untouched singleton
    try t.expect(forest.find(0) != forest.find(4));

    forest.join(2, 5); // merging the components re-roots at the global min
    try t.expectEqual(@as(u32, 0), forest.find(4));
}

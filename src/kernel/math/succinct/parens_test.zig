//! parens adversarial suite — every operation against a naive stack walk.
//!
//! Nothing here asserts a value the implementation produced for itself. The
//! oracle is one O(n) scan with an explicit stack that knows nothing about
//! excess, blocks, or min-max trees: it matches parentheses by pushing and
//! popping, and derives depth, parent, subtree size and LCA by walking parent
//! pointers. Rank and excess come from running counters, which is the
//! definition rather than a second implementation of the sampled scheme.
//!
//! The shapes are chosen for what the range min-max tree can get wrong:
//! sequences shorter than one block (nothing to climb), sequences spanning
//! several blocks (a real climb and descent), a deep-left chain (excess
//! monotone, every search crosses the whole tree), a flat comb (excess never
//! leaves {0,1}), a star (one node, maximum fan-out), and matches straddling a
//! block boundary exactly.

const std = @import("std");
const parens = @import("parens.zig");

const t = std.testing;
const Parens = parens.Parens;
const blk = parens.block_bits;

// ── the oracle: an explicit stack, no arithmetic on excess ──────────────────

const Oracle = struct {
    shape: []const u8,
    match: []usize, // position ↔ its partner, both directions
    parent: []?usize, // for an open position, its enclosing open
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, shape: []const u8) !Oracle {
        const match = try gpa.alloc(usize, shape.len);
        errdefer gpa.free(match);
        const parent = try gpa.alloc(?usize, shape.len);
        errdefer gpa.free(parent);
        @memset(parent, null);
        var stack: std.ArrayList(usize) = .empty;
        defer stack.deinit(gpa);
        for (shape, 0..) |c, i| {
            if (c == '(') {
                if (stack.items.len > 0) parent[i] = stack.items[stack.items.len - 1];
                try stack.append(gpa, i);
            } else {
                const o = stack.pop().?;
                match[o] = i;
                match[i] = o;
            }
        }
        try t.expectEqual(@as(usize, 0), stack.items.len);
        return .{ .shape = shape, .match = match, .parent = parent, .gpa = gpa };
    }

    fn deinit(self: *Oracle) void {
        self.gpa.free(self.match);
        self.gpa.free(self.parent);
    }

    fn depth(self: *const Oracle, i: usize) usize {
        var d: usize = 1;
        var p = self.parent[i];
        while (p) |q| : (p = self.parent[q]) d += 1;
        return d;
    }

    /// Deepest common ancestor by walking both ancestor chains — no excess.
    fn lca(self: *const Oracle, a: usize, b: usize) !?usize {
        var up: std.ArrayList(usize) = .empty;
        defer up.deinit(self.gpa);
        var x: ?usize = a;
        while (x) |q| : (x = self.parent[q]) try up.append(self.gpa, q);
        var y: ?usize = b;
        while (y) |q| : (y = self.parent[q]) {
            for (up.items) |anc| if (anc == q) return q;
        }
        return null;
    }

    fn firstChild(self: *const Oracle, i: usize) ?usize {
        return if (self.shape[i + 1] == '(') i + 1 else null;
    }

    fn nextSibling(self: *const Oracle, i: usize) ?usize {
        const after = self.match[i] + 1;
        return if (after < self.shape.len and self.shape[after] == '(') after else null;
    }
};

/// A random balanced sequence of `pairs` pairs, by the remaining-opens walk
/// that keeps every prefix non-negative.
fn randomShape(gpa: std.mem.Allocator, r: std.Random, pairs: usize) ![]u8 {
    const out = try gpa.alloc(u8, pairs * 2);
    var open_left = pairs;
    var depth: usize = 0;
    for (out) |*c| {
        const take_open = if (depth == 0) true else if (open_left == 0) false else r.boolean();
        if (take_open) {
            c.* = '(';
            open_left -= 1;
            depth += 1;
        } else {
            c.* = ')';
            depth -= 1;
        }
    }
    std.debug.assert(open_left == 0 and depth == 0);
    return out;
}

/// Hold every operation on one shape against the oracle, at every position.
fn agree(gpa: std.mem.Allocator, shape: []const u8) !void {
    var oracle = try Oracle.init(gpa, shape);
    defer oracle.deinit();
    var p = try Parens.fromShape(gpa, shape);
    defer p.deinit(gpa);

    try t.expectEqual(shape.len, p.bitLen());
    try t.expectEqual(shape.len / 2, p.nodeCount());

    var opens: usize = 0; // running counters — rank and excess by definition
    var closes: usize = 0;
    for (shape, 0..) |c, i| {
        try t.expectEqual(c == '(', p.isOpen(i));
        try t.expectEqual(opens, p.rank1(i));
        try t.expectEqual(closes, p.rank0(i));

        if (c == '(') {
            try t.expectEqual(@as(?usize, i), p.select1(opens));
            try t.expectEqual(opens, p.preorder(i));
            try t.expectEqual(@as(?usize, i), p.nodeAt(opens));
            opens += 1;
        } else {
            try t.expectEqual(@as(?usize, i), p.select0(closes));
            closes += 1;
        }
        try t.expectEqual(@as(i32, @intCast(opens)) - @as(i32, @intCast(closes)), p.excess(i));

        if (c == '(') {
            try t.expectEqual(oracle.match[i], p.findClose(i));
            try t.expectEqual(oracle.parent[i], p.enclose(i));
            try t.expectEqual(oracle.depth(i), p.depth(i));
            try t.expectEqual((oracle.match[i] - i + 1) / 2, p.subtreeSize(i));
            try t.expectEqual(oracle.firstChild(i), p.firstChild(i));
            try t.expectEqual(oracle.nextSibling(i), p.nextSibling(i));

            // Walk the oracle's child list to its end, remembering the one
            // before it: that is lastChild, and prevSibling of lastChild.
            var last = oracle.firstChild(i);
            var before_last: ?usize = null;
            while (last) |c2| {
                const n = oracle.nextSibling(c2) orelse break;
                before_last = c2;
                last = n;
            }
            try t.expectEqual(last, p.lastChild(i));
            if (oracle.firstChild(i)) |fc| try t.expectEqual(@as(?usize, null), p.prevSibling(fc));
            if (last) |lc| if (before_last) |pv| try t.expectEqual(@as(?usize, pv), p.prevSibling(lc));
        } else {
            try t.expectEqual(oracle.match[i], p.findOpen(i));
        }
    }

    // Ancestry and LCA over a bounded sample of node pairs.
    var nodes: std.ArrayList(usize) = .empty;
    defer nodes.deinit(gpa);
    for (shape, 0..) |c, i| if (c == '(') try nodes.append(gpa, i);
    const stride = @max(1, nodes.items.len / 24);
    var ai: usize = 0;
    while (ai < nodes.items.len) : (ai += stride) {
        var bi: usize = 0;
        while (bi < nodes.items.len) : (bi += stride) {
            const a = nodes.items[ai];
            const b = nodes.items[bi];
            try t.expectEqual(try oracle.lca(a, b), p.lca(a, b));
            try t.expectEqual(a <= b and oracle.match[a] >= b, p.isAncestor(a, b));
        }
    }
}

// ── the shapes ─────────────────────────────────────────────────────────────

test "parens: degenerate shapes — empty, single node, two roots" {
    var empty = try Parens.fromShape(t.allocator, "");
    defer empty.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), empty.nodeCount());
    try t.expectEqual(@as(usize, 0), empty.bitLen());
    try t.expectEqual(@as(?usize, null), empty.select1(0));
    try t.expectEqual(@as(?usize, null), empty.nodeAt(0));

    try agree(t.allocator, "()");
    try agree(t.allocator, "(())");
    try agree(t.allocator, "()()");
    try agree(t.allocator, "(()())");

    var one = try Parens.fromShape(t.allocator, "()");
    defer one.deinit(t.allocator);
    try t.expectEqual(@as(?usize, null), one.enclose(0));
    try t.expectEqual(@as(?usize, null), one.firstChild(0));
    try t.expectEqual(@as(?usize, null), one.lastChild(0));
    try t.expectEqual(@as(?usize, null), one.nextSibling(0));
    try t.expectEqual(@as(?usize, null), one.prevSibling(0));
    try t.expectEqual(@as(usize, 1), one.subtreeSize(0));
    try t.expectEqual(@as(usize, 1), one.depth(0));
    try t.expectEqual(@as(?usize, 0), one.lca(0, 0));
}

test "parens: a deep-left chain, a flat comb, and a maximum-fan-out star" {
    for ([_]usize{ 1, 7, 8, 63, 64, 255, blk / 2, blk / 2 + 1, 900 }) |d| {
        const buf = try t.allocator.alloc(u8, d * 2 + 2);
        defer t.allocator.free(buf);

        // maximum depth: every node encloses the next
        const chain = buf[0 .. d * 2];
        @memset(chain[0..d], '(');
        @memset(chain[d..], ')');
        try agree(t.allocator, chain);

        // maximum breadth at depth 1: excess never leaves {0, 1}
        const comb = buf[0 .. d * 2];
        for (0..d) |i| {
            comb[2 * i] = '(';
            comb[2 * i + 1] = ')';
        }
        try agree(t.allocator, comb);

        // one root with d children: the widest child list a walk can face
        buf[0] = '(';
        for (0..d) |i| {
            buf[1 + 2 * i] = '(';
            buf[2 + 2 * i] = ')';
        }
        buf[d * 2 + 1] = ')';
        try agree(t.allocator, buf);
    }
}

test "parens: a match that straddles a block boundary exactly" {
    // One outer pair whose partner sits just before, on, and just after each
    // of the first block boundaries — the case an in-block scan alone cannot
    // answer, so it is the climb-and-descend path or nothing.
    for ([_]usize{ blk - 2, blk - 1, blk, blk + 1, 2 * blk, 2 * blk + 1 }) |gap| {
        const inner_pairs = gap / 2;
        const shape = try t.allocator.alloc(u8, 2 + inner_pairs * 2);
        defer t.allocator.free(shape);
        shape[0] = '(';
        for (0..inner_pairs) |i| {
            shape[1 + 2 * i] = '(';
            shape[2 + 2 * i] = ')';
        }
        shape[shape.len - 1] = ')';
        try agree(t.allocator, shape);
    }
}

test "parens: random balanced sequences agree with a stack walk" {
    var rng = std.Random.DefaultPrng.init(0x9a11ed);
    const r = rng.random();
    for ([_]usize{ 1, 2, 3, 5, 17, 64, 200, 700, 2000 }) |pairs| {
        for (0..6) |_| {
            const shape = try randomShape(t.allocator, r, pairs);
            defer t.allocator.free(shape);
            try agree(t.allocator, shape);
        }
    }
}

test "parens: the min-max measure equals a linear scan of the same range" {
    var rng = std.Random.DefaultPrng.init(0x5aada);
    const r = rng.random();
    for ([_]usize{ 40, 400, 1600 }) |pairs| {
        const shape = try randomShape(t.allocator, r, pairs);
        defer t.allocator.free(shape);
        var p = try Parens.fromShape(t.allocator, shape);
        defer p.deinit(t.allocator);
        for (0..300) |_| {
            const a = r.uintLessThan(usize, shape.len);
            const b = r.uintLessThan(usize, shape.len);
            const lo = @min(a, b);
            const hi = @max(a, b);
            var mn: i32 = std.math.maxInt(i32);
            var mx: i32 = std.math.minInt(i32);
            for (lo..hi + 1) |i| {
                const e = p.excess(i);
                mn = @min(mn, e);
                mx = @max(mx, e);
            }
            const got = p.measure(lo, hi);
            try t.expectEqual(mn, got.min);
            try t.expectEqual(mx, got.max);
        }
    }
}

test "parens: an unbalanced shape is refused rather than indexed" {
    try t.expectError(error.NonCanonical, Parens.fromShape(t.allocator, ")("));
    try t.expectError(error.NonCanonical, Parens.fromShape(t.allocator, "("));
    try t.expectError(error.NonCanonical, Parens.fromShape(t.allocator, "())"));
    try t.expectError(error.NonCanonical, Parens.fromShape(t.allocator, "(x)"));
}

test "parens: the builder emits a forest depth-first and seals it" {
    // Two roots, the first with two children — `(()())()` — built the way a
    // serializer would, so the Builder path is exercised rather than the
    // literal door. The capacity is deliberately over-reserved: a builder that
    // guessed high must still seal at the length it wrote.
    var b = try Parens.Builder.init(t.allocator, 10);
    errdefer b.deinit(t.allocator);
    b.open(); // root A       @0
    b.open(); // A's first    @1
    try b.close(); //         @2
    b.open(); // A's second   @3
    try b.close(); //         @4
    try b.close(); // A       @5
    b.open(); // root B       @6
    try b.close(); //         @7
    var p = try b.seal(t.allocator);
    defer p.deinit(t.allocator);

    try t.expectEqual(@as(usize, 8), p.bitLen());
    try t.expectEqual(@as(usize, 4), p.nodeCount());
    try t.expectEqual(@as(usize, 5), p.findClose(0));
    try t.expectEqual(@as(?usize, 6), p.nextSibling(0));
    try t.expectEqual(@as(?usize, null), p.lca(0, 6)); // roots of different trees
    try t.expectEqual(@as(?usize, 0), p.lca(1, 3));
    try t.expectEqual(@as(usize, 3), p.subtreeSize(0));
    try t.expectEqual(@as(usize, 2), p.depth(1));
}

test "parens: an incomplete or over-closed build is refused at the seam" {
    var b = try Parens.Builder.init(t.allocator, 4);
    defer b.deinit(t.allocator);
    b.open();
    try t.expectError(error.NonCanonical, b.seal(t.allocator)); // still open
    try b.close();
    try t.expectError(error.NonCanonical, b.close()); // nothing left to close
}

test "parens: space stays near the two bits a node is worth" {
    var rng = std.Random.DefaultPrng.init(0x512e);
    const nodes = 50_000;
    const shape = try randomShape(t.allocator, rng.random(), nodes);
    defer t.allocator.free(shape);
    var p = try Parens.fromShape(t.allocator, shape);
    defer p.deinit(t.allocator);
    // 2 bits per node is the information-theoretic floor; the rank samples and
    // the min-max tree are the overhead term, and they are Θ(n/512) words, so
    // the ratio is near-flat in n. It measures 2.65-2.96 from 1e3 to 1e7 nodes
    // (the spread is the tree's power-of-two rounding, worst at 1e7). The
    // ceiling here is set just above that, so widening `Span` or shrinking
    // `block_bits` shows up as a failure rather than as quiet bloat.
    const bits_per_node = @as(f64, @floatFromInt(p.sizeBytes() * 8)) / @as(f64, nodes);
    try t.expect(bits_per_node > 2.0); // the index is not free, and must not claim to be
    try t.expect(bits_per_node < 3.5);
}

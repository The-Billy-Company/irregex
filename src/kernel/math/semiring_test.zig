//! semiring adversarial suite — the laws, then the algorithms against oracles.
//!
//! Two halves. The first asserts the axioms directly over randomized elements
//! of each carrier, including the saturation boundary, because a "semiring"
//! whose ⊗ wraps is not one and every algorithm below silently inherits the
//! damage. The second checks the two algebraic-path algorithms against
//! independent naive oracles: tropical `closure` and `shortestDistance` against
//! textbook Bellman-Ford (|V|−1 full relaxation passes — a different algorithm,
//! not a re-spelling of either), Boolean against BFS reachability, and counting
//! against a topological-order path-count DP on random DAGs.

const std = @import("std");
const semiring = @import("semiring.zig");

const t = std.testing;

const Trop = semiring.Tropical(u32);
const TropF = semiring.Tropical(f64);
const Count = semiring.Counting(u64);
const Vit = semiring.Viterbi(f64);
const Bool = semiring.Boolean;

// ── half one: the axioms ───────────────────────────────────────────────────

/// Every semiring law, over `n` random triples drawn by the caller's generator.
fn laws(comptime S: type, r: std.Random, n: usize, comptime gen: fn (std.Random) S.T) !void {
    for (0..n) |_| {
        const a = gen(r);
        const b = gen(r);
        const c = gen(r);

        try t.expectEqual(S.add(a, S.zero), a); // ⊕ identity
        try t.expectEqual(S.add(S.zero, a), a);
        try t.expectEqual(S.add(a, b), S.add(b, a)); // ⊕ commutative
        try t.expectEqual(S.add(S.add(a, b), c), S.add(a, S.add(b, c))); // ⊕ associative

        try t.expectEqual(S.mul(a, S.one), a); // ⊗ identity
        try t.expectEqual(S.mul(S.one, a), a);
        try t.expectEqual(S.mul(S.mul(a, b), c), S.mul(a, S.mul(b, c))); // ⊗ associative

        try t.expectEqual(S.mul(a, S.zero), S.zero); // ⊗ annihilated by zero
        try t.expectEqual(S.mul(S.zero, a), S.zero);

        // ⊗ distributes over ⊕, on both sides
        try t.expectEqual(S.mul(a, S.add(b, c)), S.add(S.mul(a, b), S.mul(a, c)));
        try t.expectEqual(S.mul(S.add(a, b), c), S.add(S.mul(a, c), S.mul(b, c)));

        // where a closure exists it is a fixpoint: a* = 1 ⊕ a ⊗ a*
        if (S.star(a)) |s| {
            try t.expectEqual(s, S.add(S.one, S.mul(a, s)));
            try t.expectEqual(s, S.mul(s, s)); // ⊗-idempotent, which `closure` relies on
        }
    }
}

/// Costs biased hard toward the saturation boundary: a third of draws land in
/// the top 64 values, so associativity and distributivity are exercised where
/// the cap actually bites rather than only in the comfortable middle.
fn tropCost(r: std.Random) u32 {
    return switch (r.uintLessThan(u8, 3)) {
        0 => r.uintLessThan(u32, 64),
        1 => std.math.maxInt(u32) - r.uintLessThan(u32, 64),
        else => r.int(u32),
    };
}

fn tropCostF(r: std.Random) f64 {
    if (r.uintLessThan(u8, 4) == 0) return std.math.inf(f64);
    return @floatFromInt(r.uintLessThan(u32, 1 << 20));
}

/// Eighths, so every product and triple product below is exact in f64 — the
/// only regime in which a float semiring satisfies the laws on the nose.
fn dyadic(r: std.Random) f64 {
    return @as(f64, @floatFromInt(r.uintLessThan(u32, 9))) / 8.0;
}

fn smallCount(r: std.Random) u64 {
    return switch (r.uintLessThan(u8, 3)) {
        0 => r.uintLessThan(u64, 16),
        1 => std.math.maxInt(u64) - r.uintLessThan(u64, 4),
        else => r.uintLessThan(u64, 1 << 40),
    };
}

fn coin(r: std.Random) bool {
    return r.boolean();
}

test "semiring: every law holds in all four carriers, boundary values included" {
    var rng = std.Random.DefaultPrng.init(0x5e_a11);
    const r = rng.random();
    try laws(Bool, r, 64, coin);
    try laws(Trop, r, 4000, tropCost);
    try laws(TropF, r, 2000, tropCostF);
    try laws(Vit, r, 2000, dyadic);
    try laws(Count, r, 4000, smallCount);
}

test "semiring: tropical saturation reads as unreachable, never as cheap" {
    const inf = Trop.zero;
    try t.expectEqual(inf, Trop.mul(inf, 7));
    try t.expectEqual(inf, Trop.mul(7, inf));
    try t.expectEqual(inf, Trop.mul(inf, inf));

    // The boundary itself: one below the cap plus anything positive pins at
    // the cap. Wrapping here would make an unaffordable repair look free, and
    // `min` would then choose it — the one failure that would actually hurt.
    try t.expectEqual(inf, Trop.mul(inf - 1, 1));
    try t.expectEqual(inf, Trop.mul(inf - 1, inf - 1));
    try t.expectEqual(inf - 1, Trop.mul(inf - 1, 0));
    try t.expectEqual(@as(u32, 1000), Trop.mul(400, 600));
    try t.expect(Trop.mul(inf - 1, 2) > Trop.mul(5, 5)); // saturation still loses the min

    // Counting saturates the same way, for the same reason.
    const many = std.math.maxInt(u64);
    try t.expectEqual(many, Count.add(many, 1));
    try t.expectEqual(many, Count.mul(many, 2));
    try t.expectEqual(@as(u64, 0), Count.mul(many, 0));
}

test "semiring: a closure that does not exist is refused, not invented" {
    try t.expectEqual(@as(?u64, 1), Count.star(0));
    try t.expectEqual(@as(?u64, null), Count.star(1)); // 1 + 1 + 1 + … diverges
    try t.expectEqual(@as(?f64, 1.0), Vit.star(0.5));
    try t.expectEqual(@as(?f64, 1.0), Vit.star(1.0));
    try t.expectEqual(@as(?f64, null), Vit.star(1.5)); // powers grow without bound
    try t.expectEqual(@as(?u32, 0), Trop.star(9)); // unsigned: always total
    try t.expectEqual(@as(?bool, true), Bool.star(false));

    // …and it propagates out of the matrix algorithm as an error.
    var a = [_]u64{ 1, 0, 0, 0 }; // a self-loop on vertex 0
    try t.expectError(error.Unsupported, semiring.closure(Count, &a, 2));
}

// ── half two: oracles ──────────────────────────────────────────────────────

const inf32 = Trop.zero;

/// Textbook Bellman-Ford: |V|−1 full passes over every edge, no worklist, no
/// residuals. Arithmetic in u64 so the oracle itself cannot saturate.
fn bellmanFord(gpa: std.mem.Allocator, n: usize, edges: []const semiring.Edge(Trop), source: u32) ![]u32 {
    const dist = try gpa.alloc(u32, n);
    @memset(dist, inf32);
    if (n == 0) return dist;
    dist[source] = 0;
    for (0..n) |_| {
        for (edges) |e| {
            if (dist[e.from] == inf32) continue;
            const relaxed = @as(u64, dist[e.from]) + e.weight;
            if (relaxed < dist[e.to]) dist[e.to] = @intCast(relaxed);
        }
    }
    return dist;
}

fn randomGraph(
    gpa: std.mem.Allocator,
    r: std.Random,
    n: usize,
    density: u8,
    comptime acyclic: bool,
) ![]semiring.Edge(Trop) {
    var out: std.ArrayList(semiring.Edge(Trop)) = .empty;
    errdefer out.deinit(gpa);
    for (0..n) |i| for (0..n) |j| {
        if (acyclic and j <= i) continue;
        if (r.uintLessThan(u8, 100) >= density) continue;
        try out.append(gpa, .{ .from = @intCast(i), .to = @intCast(j), .weight = r.uintLessThan(u32, 50) + 1 });
    };
    return out.toOwnedSlice(gpa);
}

fn denseFrom(gpa: std.mem.Allocator, comptime S: type, n: usize, edges: []const semiring.Edge(Trop), comptime lift: fn (u32) S.T) ![]S.T {
    const a = try gpa.alloc(S.T, n * n);
    @memset(a, S.zero);
    for (edges) |e| a[e.from * n + e.to] = S.add(a[e.from * n + e.to], lift(e.weight));
    return a;
}

fn liftCost(w: u32) u32 {
    return w;
}
fn liftTrue(_: u32) bool {
    return true;
}
fn liftOne(_: u32) u64 {
    return 1;
}

test "semiring: tropical closure is all-pairs shortest paths, vs Bellman-Ford" {
    var rng = std.Random.DefaultPrng.init(0xbe11_4a4);
    const r = rng.random();
    for ([_]usize{ 1, 2, 3, 5, 9, 14 }) |n| {
        for ([_]u8{ 10, 35, 90 }) |density| {
            const edges = try randomGraph(t.allocator, r, n, density, false);
            defer t.allocator.free(edges);
            const a = try denseFrom(t.allocator, Trop, n, edges, liftCost);
            defer t.allocator.free(a);
            try semiring.closure(Trop, a, n);

            for (0..n) |s| {
                const oracle = try bellmanFord(t.allocator, n, edges, @intCast(s));
                defer t.allocator.free(oracle);
                for (0..n) |v| try t.expectEqual(oracle[v], a[s * n + v]);
            }
        }
    }
}

test "semiring: the worklist shortest distance agrees with Bellman-Ford" {
    var rng = std.Random.DefaultPrng.init(0x0f_51);
    const r = rng.random();
    for ([_]usize{ 1, 2, 4, 8, 20, 40 }) |n| {
        for ([_]u8{ 5, 30, 80 }) |density| {
            const edges = try randomGraph(t.allocator, r, n, density, false);
            defer t.allocator.free(edges);
            for (0..n) |s| {
                const got = try semiring.shortestDistance(Trop, t.allocator, n, edges, @intCast(s));
                defer t.allocator.free(got);
                const oracle = try bellmanFord(t.allocator, n, edges, @intCast(s));
                defer t.allocator.free(oracle);
                try t.expectEqualSlices(u32, oracle, got);
            }
        }
    }
}

test "semiring: Boolean closure is reachability, vs a BFS oracle" {
    var rng = std.Random.DefaultPrng.init(0xb001);
    const r = rng.random();
    for ([_]usize{ 1, 3, 7, 12 }) |n| {
        const edges = try randomGraph(t.allocator, r, n, 20, false);
        defer t.allocator.free(edges);
        const a = try denseFrom(t.allocator, Bool, n, edges, liftTrue);
        defer t.allocator.free(a);
        try semiring.closure(Bool, a, n);

        for (0..n) |s| {
            // BFS from s, counting s itself as reached (a* holds the empty path)
            var seen = try t.allocator.alloc(bool, n);
            defer t.allocator.free(seen);
            @memset(seen, false);
            var queue: std.ArrayList(u32) = .empty;
            defer queue.deinit(t.allocator);
            seen[s] = true;
            try queue.append(t.allocator, @intCast(s));
            var head: usize = 0;
            while (head < queue.items.len) : (head += 1) {
                const v = queue.items[head];
                for (edges) |e| if (e.from == v and !seen[e.to]) {
                    seen[e.to] = true;
                    try queue.append(t.allocator, e.to);
                };
            }
            for (0..n) |v| try t.expectEqual(seen[v], a[s * n + v]);
        }
    }
}

test "semiring: counting closure counts paths on a DAG, vs a topological DP" {
    var rng = std.Random.DefaultPrng.init(0xc0117);
    const r = rng.random();
    for ([_]usize{ 1, 2, 5, 9, 13 }) |n| {
        const edges = try randomGraph(t.allocator, r, n, 55, true);
        defer t.allocator.free(edges);
        const a = try denseFrom(t.allocator, Count, n, edges, liftOne);
        defer t.allocator.free(a);
        const adj = try denseFrom(t.allocator, Count, n, edges, liftOne);
        defer t.allocator.free(adj);
        try semiring.closure(Count, a, n);

        // paths[i][j] = Σ_k adj[i][k]·paths[k][j], evaluated in reverse
        // topological order (vertices are numbered so every edge goes up).
        const paths = try t.allocator.alloc(u64, n * n);
        defer t.allocator.free(paths);
        @memset(paths, 0);
        var i = n;
        while (i > 0) {
            i -= 1;
            paths[i * n + i] = 1;
            for (i + 1..n) |k| {
                if (adj[i * n + k] == 0) continue;
                for (k..n) |j| paths[i * n + j] += adj[i * n + k] * paths[k * n + j];
            }
        }
        for (0..n * n) |x| try t.expectEqual(paths[x], a[x]);
    }
}

test "semiring: closure satisfies its fixpoint law in every carrier" {
    var rng = std.Random.DefaultPrng.init(0xf1_9207);
    const r = rng.random();
    const n: usize = 6;
    const edges = try randomGraph(t.allocator, r, n, 40, false);
    defer t.allocator.free(edges);

    inline for (.{ .{ Trop, liftCost }, .{ Bool, liftTrue } }) |pair| {
        const S = pair[0];
        const a = try denseFrom(t.allocator, S, n, edges, pair[1]);
        defer t.allocator.free(a);
        const star = try denseFrom(t.allocator, S, n, edges, pair[1]);
        defer t.allocator.free(star);
        try semiring.closure(S, star, n);

        // A* == I ⊕ A ⊗ A*
        for (0..n) |i| for (0..n) |j| {
            var acc: S.T = if (i == j) S.one else S.zero;
            for (0..n) |k| acc = S.add(acc, S.mul(a[i * n + k], star[k * n + j]));
            try t.expectEqual(star[i * n + j], acc);
        };
    }
}

test "semiring: adverse graphs — no vertices, no edges, nothing reachable" {
    const none: []const semiring.Edge(Trop) = &.{};

    var empty: [0]u32 = .{};
    try semiring.closure(Trop, &empty, 0); // n = 0 must not touch anything

    const solo = try semiring.shortestDistance(Trop, t.allocator, 1, none, 0);
    defer t.allocator.free(solo);
    try t.expectEqual(@as(u32, Trop.one), solo[0]); // the empty path costs nothing

    const island = try semiring.shortestDistance(Trop, t.allocator, 4, none, 2);
    defer t.allocator.free(island);
    try t.expectEqualSlices(u32, &.{ inf32, inf32, 0, inf32 }, island);

    // A vertex reachable only by a saturating path stays unreachable, which is
    // the whole point of pinning rather than wrapping.
    const far: []const semiring.Edge(Trop) = &.{
        .{ .from = 0, .to = 1, .weight = inf32 - 1 },
        .{ .from = 1, .to = 2, .weight = 5 },
    };
    const d = try semiring.shortestDistance(Trop, t.allocator, 3, far, 0);
    defer t.allocator.free(d);
    try t.expectEqual(inf32 - 1, d[1]);
    try t.expectEqual(inf32, d[2]);
}

test "semiring: a self-loop is folded in, not walked forever" {
    // The cycle is where a naive relaxation loops; the closure of the loop
    // weight is what makes the answer finite in one pass.
    const cyc: []const semiring.Edge(Trop) = &.{
        .{ .from = 0, .to = 1, .weight = 3 },
        .{ .from = 1, .to = 1, .weight = 7 }, // self-loop, cost 7
        .{ .from = 1, .to = 2, .weight = 2 },
        .{ .from = 2, .to = 0, .weight = 1 }, // back edge closes a 3-cycle
    };
    const d = try semiring.shortestDistance(Trop, t.allocator, 3, cyc, 0);
    defer t.allocator.free(d);
    try t.expectEqualSlices(u32, &.{ 0, 3, 5 }, d);

    const a = try t.allocator.alloc(u32, 9);
    defer t.allocator.free(a);
    @memset(a, inf32);
    for (cyc) |e| a[e.from * 3 + e.to] = e.weight;
    try semiring.closure(Trop, a, 3);
    try t.expectEqualSlices(u32, &.{ 0, 3, 5 }, a[0..3]);
}

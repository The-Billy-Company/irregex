//! semiring — one algorithm, four questions.
//!
//! A semiring is a carrier with two operations: ⊕ (associative, commutative,
//! identity `zero`) and ⊗ (associative, identity `one`), where ⊗ distributes
//! over ⊕ and `zero` annihilates ⊗. That is the entire prerequisite for the
//! algebraic-path algorithms below, and it is why *changing the semiring
//! changes the question* while the code stays put:
//!
//! | Semiring   | ⊕   | ⊗ | answers                          |
//! |------------|-----|---|----------------------------------|
//! | `Boolean`  | ∨   | ∧ | is there a path at all           |
//! | `Tropical` | min | + | the least-cost path — error repair |
//! | `Viterbi`  | max | × | the most likely derivation        |
//! | `Counting` | +   | × | how many derivations there are    |
//!
//! The closure `a* = ⊕ₖ aᵏ` is what makes cycles finite. It does not exist
//! everywhere, so `star` returns an optional: counting refuses anything
//! non-`zero` (a reachable cycle really does have infinitely many
//! derivations), Viterbi refuses a probability above one (the series
//! diverges), and a `null` propagates out of `closure` as `error.Unsupported`
//! rather than a silently wrong number. Tropical and Boolean never refuse —
//! tropical buys that by refusing signed *carriers* at compile time instead,
//! since a negative cycle is exactly the case with no least cost.
//!
//! Prior art worth reading rather than name-dropping:
//! [Mohri, *Semiring Frameworks and Algorithms for Shortest-Distance
//! Problems*](https://doi.org/10.1142/S0129054102001217) (J. Autom. Lang.
//! Comb. 7(3), 2002) — where `shortestDistance` below comes from, including
//! the k-closed condition that decides when the queue terminates;
//! [Lehmann, *Algebraic structures for transitive
//! closure*](https://doi.org/10.1016/0304-3975(77)90056-1) (TCS 4(1), 1977) —
//! the Gauss-Jordan elimination `closure` below is, of which Floyd-Warshall is
//! the tropical instance; and Kuich & Salomaa, *Semirings, Automata,
//! Languages* (Springer, 1986) for the formal-power-series view that makes a
//! parse forest one of these too.
//!
//! **A semiring is a TYPE here, not a value.** It carries `T`, `zero`, `one`,
//! `add`, `mul`, `star`, and is passed as a comptime parameter, so every
//! operation inlines and a tropical relaxation costs a compare and an add.

const std = @import("std");

/// Compile-time shape check, so a malformed semiring fails at the seam that
/// used it rather than three inlined frames deep.
fn require(comptime S: type) void {
    comptime {
        for (.{ "T", "zero", "one", "add", "mul", "star" }) |name| {
            if (!@hasDecl(S, name)) @compileError(@typeName(S) ++ " is not a semiring: missing `" ++ name ++ "`");
        }
    }
}

fn unsignedInt(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |i| i.signedness == .unsigned,
        else => false,
    };
}

fn float(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float => true,
        else => false,
    };
}

/// Reachability. The degenerate case, and the one that proves the abstraction
/// is not secretly about numbers.
pub const Boolean = struct {
    pub const T = bool;
    pub const zero: T = false;
    pub const one: T = true;

    pub fn add(a: T, b: T) T {
        return a or b;
    }
    pub fn mul(a: T, b: T) T {
        return a and b;
    }
    /// Total: a⁰ = true is always in the sum.
    pub fn star(_: T) ?T {
        return one;
    }
};

/// Min-plus over a cost. `zero` is ∞ (no path), `one` is 0 (the free path).
/// The load-bearing one: least-cost error repair is a tropical walk over the
/// trellis of (position × configuration).
///
/// **`Cost` must be an unsigned integer or a float.** Both restrictions are
/// deliberate. A signed cost admits negative cycles, under which "least cost"
/// is not a number and `star` would have to fail on inputs a grammar author
/// cannot see; refusing the carrier outright is the honest fail-closed
/// position. A float carrier needs no saturation — `inf` is a real value that
/// already absorbs — but is associative only up to rounding, so an integer
/// carrier is the one to reach for when the laws must hold exactly.
///
/// **Integer saturation.** `zero` is `maxInt(Cost)` and ⊗ is *saturating*
/// addition, which pins there. That is not a hack around overflow, it is the
/// quotient semiring in which every cost at or above the cap is identified
/// with ∞: saturating addition is associative and monotone, so it commutes
/// with `min` and every law survives (the tests assert this at the boundary).
/// The alternative — wrapping — is the one failure that would actually hurt:
/// a repair path whose cost overflowed would come back looking *cheap* and
/// win the minimum. Saturating makes an unaffordable repair read as
/// unreachable, which is the safe direction.
pub fn Tropical(comptime Cost: type) type {
    const is_int = unsignedInt(Cost);
    comptime if (!is_int and !float(Cost))
        @compileError("Tropical needs an unsigned integer or a float cost: a signed one admits negative cycles");
    return struct {
        pub const T = Cost;
        pub const zero: T = if (is_int) std.math.maxInt(Cost) else std.math.inf(Cost);
        pub const one: T = 0;

        pub fn add(a: T, b: T) T {
            return @min(a, b);
        }

        pub fn mul(a: T, b: T) T {
            if (!is_int) return a + b; // inf absorbs; no −inf exists, so no NaN
            const sum, const carry = @addWithOverflow(a, b);
            return if (carry != 0) zero else sum;
        }

        /// `a* = min over k of k·a`, which is 0 for any a ≥ 0 — and every a is,
        /// because the carrier is unsigned. Total on this carrier, and that
        /// totality is exactly what the signedness restriction buys.
        pub fn star(_: T) ?T {
            return one;
        }
    };
}

/// Max-times: the most likely derivation, and the semiring the Viterbi
/// algorithm is named for. Probabilities live in [0, 1], where `star` is `one`
/// because 1 = a⁰ dominates every later power.
///
/// Float multiplication is associative only up to rounding, so the algebraic
/// laws hold exactly only on values whose products are exactly representable
/// (dyadic rationals of small precision — which is what the property tests
/// use). A consumer that needs exactness should work in the log domain, i.e.
/// in `Tropical`.
pub fn Viterbi(comptime P: type) type {
    comptime if (!float(P)) @compileError("Viterbi needs a float probability");
    return struct {
        pub const T = P;
        pub const zero: T = 0;
        pub const one: T = 1;

        pub fn add(a: T, b: T) T {
            return @max(a, b);
        }
        pub fn mul(a: T, b: T) T {
            return a * b;
        }
        /// Diverges above 1: the powers grow without bound, so there is no
        /// closure and the caller is told rather than handed `inf`.
        pub fn star(a: T) ?T {
            return if (a <= one) one else null;
        }
    };
}

/// (ℕ, +, ×) — how many derivations, i.e. how ambiguous the grammar is.
///
/// Both operations saturate, for the same reason tropical's does: a derivation
/// count that wrapped would report a hugely ambiguous parse as unambiguous.
/// Saturation caps it at `maxInt`, read as "more than we can count", and
/// because both ops are monotone the capped algebra is still a semiring.
pub fn Counting(comptime N: type) type {
    comptime if (!unsignedInt(N)) @compileError("Counting needs an unsigned integer");
    return struct {
        pub const T = N;
        pub const zero: T = 0;
        pub const one: T = 1;

        pub fn add(a: T, b: T) T {
            const sum, const carry = @addWithOverflow(a, b);
            return if (carry != 0) std.math.maxInt(N) else sum;
        }

        pub fn mul(a: T, b: T) T {
            const prod, const carry = @mulWithOverflow(a, b);
            return if (carry != 0) std.math.maxInt(N) else prod;
        }

        /// `0* = 1`; anything else sums infinitely many positive terms and has
        /// no closure. A cyclic grammar really does have infinitely many
        /// derivations, and saying so beats reporting `maxInt`.
        pub fn star(a: T) ?T {
            return if (a == zero) one else null;
        }
    };
}

/// A diagonal element has no star, so the asteration this carrier was asked for
/// does not exist. `Unsupported` is the taxonomy's declared name for a query with
/// no answer under the selected engine, and a semiring *is* the selected engine
/// of the arithmetic — the carrier, not the input, is what refuses. A `NoClosure`
/// here would be a second spelling of that one fact.
pub const Error = error{Unsupported};

/// The asteration of a dense `n × n` adjacency matrix, in place and in any
/// semiring: `A* = I ⊕ A ⊕ A² ⊕ …`, i.e. the weight of every path between
/// every pair, cycles folded in by `star`.
///
/// This is Lehmann's Gauss-Jordan elimination. Read it in the tropical
/// semiring and it is literally Floyd-Warshall; read it in the Boolean one and
/// it is Warshall's transitive closure. The loop computes A⁺ (paths of length
/// ≥ 1), and the identity is added at the end, which is what makes the fixpoint
/// law `A* = I ⊕ A ⊗ A*` hold — the property the tests pin.
///
/// O(n³) ⊗ and O(n³) ⊕, no allocation. `error.Unsupported` when a diagonal
/// element has none, which is how a negative or divergent cycle surfaces.
///
/// In place is safe without snapshotting row or column k, and the reason is
/// worth writing down because it is not obvious. Pass k rewrites row k to
///
///     a[k][j] ⊕ (a[k][k] ⊗ s ⊗ a[k][j]) = (1 ⊕ a[k][k] ⊗ a[k][k]*) ⊗ a[k][j]
///                                       = a[k][k]* ⊗ a[k][j] = s ⊗ a[k][j]
///
/// by the definition of star, and column k to `col_k ⊗ s` symmetrically. So a
/// later row reads a value that has already absorbed one `s` and multiplies in
/// a second; that lands on the same answer because `s ⊗ s = a* ⊗ a* = a*`.
///
/// In all four carriers here the argument is not even needed: `star` returns
/// `one` in every one of them, so row and column k come out of their own pass
/// unchanged. It is stated in the general form because `closure` is generic,
/// and a caller bringing an exotic semiring needs to know which identity the
/// in-place update is standing on.
pub fn closure(comptime S: type, a: []S.T, n: usize) Error!void {
    require(S);
    std.debug.assert(a.len == n * n);
    for (0..n) |k| {
        const s = S.star(a[k * n + k]) orelse return error.Unsupported;
        for (0..n) |i| {
            const ik = S.mul(a[i * n + k], s);
            if (ik == S.zero) continue;
            for (0..n) |j| {
                const via = S.mul(ik, a[k * n + j]);
                a[i * n + j] = S.add(a[i * n + j], via);
            }
        }
    }
    for (0..n) |i| a[i * n + i] = S.add(a[i * n + i], S.one);
}

/// One edge of a weighted graph, as the shortest-distance walk wants it.
pub fn Edge(comptime S: type) type {
    return struct { from: u32, to: u32, weight: S.T };
}

/// Mohri's generic single-source shortest distance: relax along a worklist
/// until no potential changes, accumulating the ⊕ of every path weight.
///
/// Not Bellman-Ford — there is no |V|−1 pass structure. Each vertex carries a
/// *residual* `r` (what has arrived since it was last expanded), and only the
/// residual is pushed forward, so a vertex is re-expanded exactly as often as
/// new weight reaches it. On a k-closed semiring (which all four above are for
/// non-negative input) that terminates; the `visits` budget below is the
/// fail-closed guard for a caller who hands it one that is not, and it returns
/// `error.Unsupported` rather than spinning.
///
/// Caller owns the returned slice: `dist[v] = ⊕ over all paths source → v`,
/// `S.zero` where none exist.
pub fn shortestDistance(
    comptime S: type,
    gpa: std.mem.Allocator,
    n: usize,
    edges: []const Edge(S),
    source: u32,
) ![]S.T {
    require(S);
    const dist = try gpa.alloc(S.T, n);
    errdefer gpa.free(dist);
    const residual = try gpa.alloc(S.T, n);
    defer gpa.free(residual);
    @memset(dist, S.zero);
    @memset(residual, S.zero);

    // Adjacency in CSR, so an expansion touches only its own out-edges.
    const head = try gpa.alloc(u32, n + 1);
    defer gpa.free(head);
    @memset(head, 0);
    for (edges) |e| head[e.from + 1] += 1;
    for (1..n + 1) |i| head[i] += head[i - 1];
    const out = try gpa.alloc(Edge(S), edges.len);
    defer gpa.free(out);
    {
        const cursor = try gpa.alloc(u32, n);
        defer gpa.free(cursor);
        @memcpy(cursor, head[0..n]);
        for (edges) |e| {
            out[cursor[e.from]] = e;
            cursor[e.from] += 1;
        }
    }

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);
    const queued = try gpa.alloc(bool, n);
    defer gpa.free(queued);
    @memset(queued, false);

    dist[source] = S.one;
    residual[source] = S.one;
    try queue.append(gpa, source);
    queued[source] = true;

    // n·(m+1) expansions is generous for every k-closed case and finite for
    // every case; exceeding it means the semiring was not k-closed here.
    var budget = (n + 1) * (edges.len + 1);
    var head_i: usize = 0;
    while (head_i < queue.items.len) {
        const v = queue.items[head_i];
        head_i += 1;
        queued[v] = false;
        if (head_i > queue.items.len / 2 and head_i > 64) {
            std.mem.copyForwards(u32, queue.items, queue.items[head_i..]);
            queue.shrinkRetainingCapacity(queue.items.len - head_i);
            head_i = 0;
        }
        const r = residual[v];
        residual[v] = S.zero;
        for (out[head[v]..head[v + 1]]) |e| {
            const w = S.mul(r, e.weight);
            if (w == S.zero) continue;
            const next = S.add(dist[e.to], w);
            if (next == dist[e.to]) continue;
            if (budget == 0) return error.Unsupported;
            budget -= 1;
            dist[e.to] = next;
            residual[e.to] = S.add(residual[e.to], w);
            if (!queued[e.to]) {
                try queue.append(gpa, e.to);
                queued[e.to] = true;
            }
        }
    }
    return dist;
}

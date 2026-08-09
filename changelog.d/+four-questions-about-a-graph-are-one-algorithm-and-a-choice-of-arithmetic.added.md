`math.semiring` — the algebra that lets one shortest-path routine answer four
different questions depending on which arithmetic you hand it: is there a path
(Boolean), what is the cheapest (tropical, min-plus), which is likeliest
(Viterbi, max-times), and how many are there (counting, plus-times).

Ships the carriers plus two algorithms over any of them: `closure`, all-pairs
asteration in O(n³) (Lehmann 1977 - Floyd-Warshall's shape, derived from the
semiring axioms rather than from arithmetic on reals), and `shortestDistance`,
Mohri's single-source worklist with the residual trick that makes one loop
correct for idempotent and non-idempotent semirings alike.

The generic dispatch is free. `add`/`mul` are comptime declarations, so
`closure`'s inner statement compiles to the same compare and add a
hand-specialized Floyd-Warshall would: measured 0.43 ns per relaxed cell
tropical and 0.30 ns Boolean at n = 256 over dense random graphs (M-series,
ReleaseFast), under two cycles a cell.

Two decisions in the tropical carrier are load-bearing, because it is the one a
least-cost error repair actually runs on.

**The carrier is unsigned, refused at compile time otherwise.** A signed cost
admits a negative cycle; a negative cycle means `a*` does not exist; and
without `a*` neither algorithm here has a termination argument, so `closure`
would return a number that is not the answer to any question. Making that a
`@compileError` on the type rather than a runtime check on the weights means a
consumer cannot construct the broken case at all. What it buys in return is
that `star` is *total* on this carrier - `a* = min over k of k·a`, which is 0
for every a ≥ 0 - so tropical closure never refuses.

**Costs saturate to infinity, never wrap.** `mul` is `@addWithOverflow` and
maps a carry to `zero`, which in this semiring is unreachable. Wrapping would
be the worst possible failure here: a path too expensive to represent would
come back as a *cheap* path, and a least-cost repair would confidently pick the
one route it cannot afford. Saturating instead makes an unrepresentable path
read as no path, which is conservative in the only direction that is safe. The
property test pins exactly this: a graph whose second hop overflows `u32`
reports the far vertex unreachable, and it is the first test to fail if the
saturation is removed.

Counting is the carrier where `star` genuinely does not exist - a reachable
cycle means infinitely many derivations - so `star` returns an optional and
`closure` fails with `error.Unsupported` rather than returning a wrong finite
number. Viterbi's `star` is `one` on `[0, 1]` and refuses above it, since a
probability greater than one has a divergent series.

Tested in two halves. Every axiom - both identities, commutativity of `⊕`,
associativity of both, distributivity on both sides, annihilation by `zero`,
and the `a* = 1 ⊕ a ⊗ a*` fixpoint - checked over random elements in all four
carriers, with generators that deliberately include the boundary values
(`zero`, `one`, and the saturation edge). Then the algorithms against
independent oracles: tropical `closure` and `shortestDistance` against a
textbook Bellman-Ford, Boolean `closure` against a BFS reachability oracle, and
counting `closure` on DAGs against a topological-order dynamic program, over
random graphs including the empty graph, the edgeless graph, isolated
vertices, and self-loops.

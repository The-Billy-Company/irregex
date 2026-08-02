# regex/ast — the pattern's shape, interned once and asked everything at once

The parser hands back a tree. It is the right thing to **lower** — its
bracketing is what decides which leftmost-first match wins — and the wrong thing
to **interrogate**, because it shares nothing. Compiling a pattern today asks it
about fourteen separate questions, and every question re-walks it from the root.
`requiredAny` is worse than that: it needs each node's mandatory literal to
decide whether descending buys selectivity, and it gets it by calling
`literalInfo`, which walks that node's whole subtree. Quadratic, in the planner.

This package is the same language in a shape that is cheap to ask. Three stages,
three files, one `analyze` call:

| Stage | File | What it spends |
|---|---|---|
| **Intern** | `intern.zig` | Hash-consing. Identical subtrees become one node, so structural equality is an integer compare and a shared shape is analyzed once no matter how many parents reach it. |
| **Canonicalize** | `algebra.zig` | The operator identities — ε units, alternation idempotence, the union of two classes being a class, the closure table that makes `(a*)*` one star. Every rule strictly shrinks the graph. |
| **Sweep** | `facts.zig` | One forward loop filling every synthesized attribute at the same time. |

The substrate underneath is `../../math/dag.zig`, which has no regex opinion:
it is the hash-consed DAG and its three operations (`fold`, `descend`, `power`).

## Why the sweep is a `for` loop

A node may only be interned after its children, so a child's id is always lower
than its parent's. Topological order is therefore free, and a bottom-up analysis
needs no recursion, no explicit stack, no visited set and no worklist — just a
forward scan over three dense arrays, which is a shape a prefetcher can follow.

Fusing is not a mechanism here, which is the property worth keeping: it is one
fold whose accumulator happens to be a struct. **Adding the next question costs
a field on `Facts` and a few lines in `sweep`, not another traversal.**

## Two rewrites, and why they are safe

Interning re-associates. The parser left-folds, so `abcd` arrives as
`((a·b)·c)·d` — a chain whose every prefix is a distinct shape, and therefore
one hash-consing cannot compress at all. Flattened and rebuilt balanced,
identical halves become the same node. A flattened spine is also run-length
compressed, so the thousand copies `a{1000}` expands to become one `power` call
and about nineteen nodes.

Both are licensed by associativity, and both are safe for **every fact computed
here**, because each is a property of the flattened sequence rather than of the
bracketing. Neither is safe for leftmost-first span selection, which depends on
alternation *order* being the order the Thompson split was emitted in. That is
the whole reason this is an analysis structure and `compile/` still lowers the
parser's own tree: the engine keeps the bracketing that decides which match is
chosen, and the analyses get the shape that is cheap to ask.

`intern.zig`'s memo looks like an optimization and is not one. The parser's
`{n,m}` expansion points many cells at one atom, so the tree is already a DAG;
without memoizing on the parse node's address, a nested bound like
`((a{10}){10}){10}` re-converts the shared subtree once per path that reaches
it — exponential in nesting depth.

## What it answers

`Ast.root()` carries the mandatory-literal facts (replacing
`analysis.literalInfo`), the first-byte set (which `analyzeFirst` currently
recovers by walking the *compiled* program), nullability, the line-start anchor,
min/max match length, Kleene star height, and whether a codepoint class appears
anywhere. `Ast.cover()` is the alternation cover set — the same contract as
`analysis.requiredAny`, but with the per-node literal already in hand, so it is
one forward pass instead of a quadratic descent. `Ast.signature()` names the
whole language in 128 bits, which is how a wide `-e`/`-f` slate can drop
duplicate intents before compiling an engine each.

## What is proven, and where

- **Soundness** — `ast_test.zig` checks the consuming facts against a language
  oracle built from the semantics rather than from either implementation: a
  set-of-positions recognizer with no NFA, no DFA and no shared code with the
  engine. Every string over a small alphabet is run through it, and every match
  must satisfy what the facts claimed. A fact that over-claims is a missed match
  in production, so the direction of each assertion is the direction of the harm.
- **Agreement** — every fact that replaces a walker is compared against that
  walker. The sweep may be faster; it may not answer differently.
- **Preservation** — canonicalization is held to never degrade a fact, only
  improve or preserve it.
- **Worth** — `bench/rungs/sweep/` races each consumer against its incumbent,
  alone and bundled, and reports how many consumers must move together before
  the graph pays for itself. It is what decided that `lower.zig` builds one
  graph for three answers instead of transferring anything one at a time.

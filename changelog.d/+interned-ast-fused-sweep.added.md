**Interned AST** (`kernel/regex/ast/`): the pattern's shape hash-consed into a
DAG over the new `kernel/math/dag.zig` substrate, canonicalized by the operator
identities, and swept once for every synthesized fact at the same time. Compiling
used to ask the parser's tree about fourteen separate questions, each a fresh
recursion with no memo, and `requiredAny` was quadratic outright — it needed each
node's mandatory literal to decide whether descending bought selectivity, and got
it by calling `literalInfo`, which re-walked that node's whole subtree. Interning
makes structural equality an integer compare, gives topological order for free
(so a bottom-up analysis is a `for` loop with no recursion, stack or visited set),
and raises bounded repetitions by squaring, so `a{1000}` is ~19 nodes rather than
a thousand. One fold fills the literal facts, first-byte set, nullability, anchor,
length bounds, star height and codepoint-class flag together; the next question
costs a field, not a traversal.

Re-association and the algebra are licensed by associativity and safe for every
fact here, because each is a property of the flattened sequence rather than of
the bracketing — but not for leftmost-first span selection, so `compile/` still
lowers the parser's own tree and this stays an analysis structure. Held to a
language oracle built from the semantics (not from either implementation), to
per-walker agreement, and to a preservation invariant that canonicalization may
only improve a fact.

`compileOpts` now sources its required literal, its cover set and its anchor from
one graph built in the arena it already holds (`linear/program/lower.zig`), which
is the transfer the new `bench/rungs/sweep/` rung licensed: it races each consumer
against its incumbent alone and bundled, classifies every disagreement against
that question's own quality order, withholds the timing on any answer that got
worse, and prints how many consumers must move together before the graph pays for
itself. Asked one question the fabric loses by 30×; asked the two the planner
actually needs it wins, and every consumer after that is free.

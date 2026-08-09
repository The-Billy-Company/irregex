`docMatchDense` - the multi-lane DFA walk behind every no-prefilter scan - gave
each of its four lanes a LINE and advanced them in lockstep to the shortest lane's
line end. Lines are independent in the per-line model, so that carve is the
obvious one, and being obvious is most of why it lasted. Its step size is a
minimum over four line remainders, which makes the walk hostage to a distribution:
on lines of identical length the minimum is the whole line and the carve costs
nothing, and on the line lengths of real source it is 22.5 bytes and often far
fewer. A burst that short never gets four dependent load chains in flight before
it drains them again, which is the single thing a lockstep walk exists to do.

A lane owns a contiguous REGION now, cut at a line boundary. Matches never cross
`\n` and this scan answers only whether some line matches, so the document can be
read in any order; `\n` is handled where it is met, resolving `$` through
`trans_fin` off the `prev` the body already keeps and resetting to `start`. The
lanes never have to agree about anything, so there is no minimum, no per-burst
lane-end test, no `memchr` to find a line's end before the walk can start it, and
no reseat. Two whole-document short-circuits that the per-line seed re-tested at
every line - a start state that already accepts, and the empty-line case - are
decided once. `seedLine` and its `Seed` union are gone with the carve that needed
them.

Measured on the `burst` rung across both document geometries: 1.52-1.59x on every
source-geometry row (0.5661 -> 0.3891 ns/byte where the automaton wanders), and
1.10-1.16x on the uniform rows where it wanders. It loses ~1.21x in exactly one
place - a parked automaton reading lines of identical length, where the old
carve's bookkeeping was already amortized to nothing and the new per-byte `\n`
compare is pure cost. Both carves stay on the ladder so that stays visible. The
rung that would close it is folding `\n` into the transition table as a reset
column, which needs `freeze` to own the column.

Equivalence is not argued: the doc-level DFA-vs-Pike differential fuzz passes, and
the rung's own mutation sweep checks every arm against the scalar oracle and the
shipped `docMatch` on thousands of mutated documents per row.

`automata-rung -- dwell` grew the two arms that settle claim C4 — skipping out of
*every* dwell rather than only the start state. The census said the premise held:
97.5% of a document's bytes sit in an interior state with a narrow exit set, and
every refusal was the profitability bar rather than the automaton's shape. So the
skip got built in the harness and timed, and the answer is **no**.

Three arms interleaved over one buffer, because two of them answer different
questions. `step` is the scalar walk and differs from the skip arm in exactly one
respect, so `vs step` is attributable. `ship` is the multi-lane `docMatch` the engine
actually runs, so `vs ship` is what decides. With the profitability bar **waived**,
so every narrow-exit state is armed, C4 is **0.41× geomean** — a 2.5× regression.

The new `stride` column says why in one number, by reporting the bytes a skip
*actually* elides here instead of what the corpus prior predicted. `foo.*bar`'s
interior dwell exits on `b`, its document contains `b`, so each skip elides 3.8 bytes
and pays full vector-kernel entry for them: ~10× slower. `a.*b` wins 1.18× only
because its fill excludes `b` outright and the stride becomes the whole distance to
`\n`. Same exit set, same build-time prediction, opposite outcomes — the difference
is a property of the document, which no build-time prior can see.

A break-even sweep then found the threshold. Holding the automaton, alphabet, and
instruction mix fixed and moving only the line length makes the realized stride the
sole variable, and `vs ship` crosses 1.000× between a 23.1-byte stride (0.79×) and a
31.0-byte one (1.03×). Break-even is a **≈30-byte** stride; the shipped
`dwell.min_profitable_stride` is **32**, calibrated on the start case alone. It was
right to within 6%, so there is nothing to change: the engine already arms this skip
in the one place no `\n` caps the stride.

The correctness oracle is the part worth keeping. A skip validated only on
match-free documents is validated on its easy case, so each row must survive 4000
single-mutation rounds where both walks agree — and half those mutations splice a
random *substring of the pattern* over the document rather than random bytes, because
spelling `bar` by chance is 1 in 2²⁴ and a uniform sweep silently degrades to "false
agrees with false". A row whose mutations never produced a match **fails** instead of
publishing a timing, which is how `foo.*bar` was caught reporting a number its oracle
had not earned. The sweep also proved a real bug it was written for: after a skip,
the state `trans_fin` needs for the last byte of a line is the dwell's own state, not
the state before the last *stepped* byte.

No engine behavior changes. `walkDwelling`, `observedStride`, and the mutation oracle
live in the bench, which is where a declined claim's evidence belongs.

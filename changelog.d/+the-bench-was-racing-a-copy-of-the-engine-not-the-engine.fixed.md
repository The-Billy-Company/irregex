Every arm on the `burst` ladder was a reimplementation of `docMatchDense` written
inside the bench, and `ship` - the column that claims to describe production -
was one of them, picked by matching parameters. `burstAgrees` proved the arms
agree with the shipped `docMatch` about the ANSWER on thousands of mutated
documents. Nothing proved they agree about the COST, and they did not: the region
carve read 1.55x on this ladder against the bench's own `walkLanes`, and ~1.0x
when I built the real search binary before and after and timed it on real files.
Two spellings of one algorithm are two programs, and the compiler is allowed to
treat them that way.

`prod` is now an arm that calls `Dfa.docMatch` itself. `ship` and the geomean are
measurements of the binary instead of labels on a copy, and every other column is
a mechanism priced against it - so a body that only beats its neighbors in this
file can no longer read as a body that beats the engine. On source geometry
`prod` is the fastest arm on every row (0.3808 ns/byte against the classed
four-lane baseline's 0.6187), which is the result the reimplementations were
mis-attributing to the carve.

The ladder also races the wrong automata. `Regex.compile` leaves `unicode` false,
and the product face is Unicode-by-default for rg parity, so a slate row and the
product compile different machines from the same pattern text: `\w+X` is 3 states with a
byte-indexed mirror here and 318 states with no mirror there, `\w+\.\w+\(` is 635.
Only 6 of the 24 slate patterns reach `docMatchDense` in the product at all - the
literal, class-run, and rung tiers answer the other 18 first - and of those 6 only
2 have a mirror, so the population production actually sends this walk runs the
classed three-load path over tables that miss L1, at 0.78-0.88 ns/byte rather than
the 0.38 measured here. The rung currently skips a row with no mirror outright, so
it cannot see that population even in principle. `prod` closes the
same-algorithm-two-spellings gap; the population gap is recorded here and not yet
fixed.

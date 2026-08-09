The `burst` ladder raced the DFA lockstep body's bookkeeping as one bundle: either
you kept the per-lane `prev` copy, cursor bump, and match test, or you dropped all
three. The bundle loses, so the ladder's verdict was "slimming the body doesn't
pay" - true, and useless, because it says nothing about which of the three
mechanisms it was true of. That is exactly the shape a retirement has to have to
stop the same proposal coming back.

Each removal is now its own arm at the width and table shape the decision is made
on, plus a fourth for the vector spelling of the fold. Peeling `prev` to the
burst's final step and sharing one induction variable are washes - 0.2336 and
0.2353 ns/byte against the shipped body's 0.2368 - because move elimination
retires the copy in rename and aarch64 folds the bump into a post-indexed load.
Folding the four compares into one branch is the whole regression: 0.2515 through
a scalar `@min` tree, 0.3070 through `@reduce(.Min, @Vector(4, u32))`. Four
independent compares are four perfectly-predicted not-taken branches that never
reach the critical path; a fold puts a serial reduction in front of one branch on
every byte, and the vector form adds four GPR→SIMD transfers to gather states the
table loads already produced in general registers.

The two bundle arms run verbatim bodies rather than the flag-driven one, which is
not duplication left untidied. Parameterizing them was the first attempt, and it
moved the twelve-lane slim arm 15% while leaving every four-lane arm alone: one
hoisted loop bound and a cursor bump moved across the match test were enough,
because at the widths that spill, where a register lands is the result. A rung
that measures codegen cannot share a body between the thing it measures and the
thing it measures against.

No production behavior changed - the walk was already the fastest arm, and now the
comment above it cites the decomposition rather than one bundled number.

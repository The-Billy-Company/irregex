`Munch.longestAmong` takes a permission set, and until now that set governed
what the walk **recorded** and never how far it **ran**. The walk ran until the
union automaton died, and a union of sixty-four patterns dies where the last of
them does - so one wide member kept every narrow one walking. Ask a slate for
`return` at a position where `[^'&]+` is also alive, and you paid for `[^'&]+`
to reach end-of-file before being told about the six bytes you asked for.

The old premise is in the doc comment that shipped, and it is true:

> a forbidden pattern may still be on the path to a permitted longer one

It is just not the whole rule. A forbidden pattern is worth following only while
some *permitted* one can still reach an accept. Past that point no number of
remaining bytes can produce a reportable match, so stopping is not an
optimization with a correctness argument bolted on - it is the same answer,
reached without the walk that could not have changed it.

So a `Dfa` now carries `reach`, one `u64` per state saying which patterns still
have an accept ahead of them, and the walk exits on `s == dead` **or**
`reach[s] & permitted == 0`. It is built at freeze by a worklist fixpoint over
reverse edges, only for an attributed automaton; single-pattern programs - which
is most of what gist compiles - get no table and are not even asked.

Two things about that fixpoint are load-bearing and neither is obvious. It
unions successors over `trans_in` **and** `trans_fin`, because `trans_fin` is
what resolves `$` and an accept can be reachable only through it, on the true
last byte; an interior-only fixpoint would stop one byte short of an anchored
accept, which is a wrong token stream rather than a slow one. And erring broad
is free - a mask that admits too much only walks a little further - so where
there was a choice it went that way.

What it was worth, measured on outliner's javascript slate, where
`unescaped_single_jsx_string_fragment` shares a voice with the keywords a
statement parse asks for at nearly every position. Mean bytes walked per call,
over a 128 KiB file:

| grammar    | before   | after |
| ---------- | -------- | ----- |
| javascript | 16,322.6 | 1.9   |
| java       | 78.5     | 1.8   |
| json       | 3.8      | 2.4   |

Call counts are identical to the byte on all three, which is the point: the
answer never moved, only the distance travelled to reach it. Parsing that
javascript file went from 34,776 ns/byte to 1,168, and the file that took 16.5 s
takes 186 ms.

The all-permitted caller was expected to be a no-op, since with every pattern
permitted the test reduces to `reach[s] == 0`, which in a *minimal* automaton is
the dead state and nothing else. These automata are not minimal, and the traps
turn out to be worth having: with every terminal admitted, java walks 29% fewer
bytes and json 25% fewer, for the same tokens. So it is a small win rather than
nothing, which is the better half of the two answers that were available.

The test pins the distance rather than the effect, because a walk that runs too
far returns the same answer as one that stops - which is exactly why nobody
noticed for so long. `munch.steps` counts bytes stepped under
`builtin.is_test`, comptime-erased everywhere else, and the case asserts a
keyword-only walk over a 4 KiB haystack costs under sixteen steps. Disabling the
new exit turns that case red; without the counter it stayed green, which was the
first draft.

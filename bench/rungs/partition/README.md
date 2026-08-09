# `bench/rungs/partition` — Where The Floor's Collapse Primitives Win, And Where They Don't

`zig build partition-rung` (from the repository root) prices the two primitives
in [`src/kernel/math/`](../../../src/kernel/math/README.md) that collapse a
structure by an equivalence: [`refine.zig`](../../../src/kernel/math/refine.zig),
which computes the coarsest stable partition of a transition table, and
[`dafsa.zig`](../../../src/kernel/math/dafsa.zig), which stores a string set as
the smallest automaton accepting it — a trie quotiented by exactly that
equivalence.

Neither has a speed problem. Both have a **regime** problem: each one wins
outright on one family of inputs and loses outright on another, and in both cases
the losing family is the one the received wisdom is stated about. That is what
this rung exists to keep true, because it is the sort of claim that rots quietly.

## The Three Boards

**1. A blown-up quotient, `k=16` — the shape a determinizer hands you.** Moore
is `O(n²k)`, Hopcroft `O(nk log n)`, and the asymptotics say the argument is
over. Measured, Moore wins by 3 to 5× at every size to 65 536 states, because
the partition here is wide and shallow — 2 to 6 passes — and a splitter queue
plus an inverted delta is overhead a shallow partition never amortizes.

The generator matters more than the timing loop. Its quotient is known by
construction: `classes` behavior classes, every state one blown-up copy of a
class, with each copy's successors drawn from anywhere inside the target class so
the copies are genuinely equivalent rather than merely identically colored. A
*random* delta is the trap — nothing merges there, every state ends alone, and
the board measures queue overhead against a refinement that never happened.

**2. A chain, `k=1` — Moore's adversary, and why `auto` exists.** Every state's
distance to the end differs, so the coarsest stable partition is the discrete one
and it can only be reached one state at a time. Moore pays a full `n·k` sweep per
state and loses by 2 634× at 16 384 states. `.auto` — Moore until it has spent
more passes than `log₂ n`, then Hopcroft from the partition Moore reached —
finishes within 3.2× of Hopcroft here while tracking Moore on board 1. One
default, correct on both sides of a line the caller cannot see.

**3. The DAFSA against a sorted array, at a fixed key count.** A DAFSA's
compression is entirely the tails its keys share, which makes it a property of the
corpus and not of the structure. So the board holds 4 096 keys constant and moves
only the sharing: 4 096 distinct tails is 1.33× a sorted array, 64 tails shared
64 ways is 11.1×. Then it does the honest case — 34-byte keys with genuinely
unshared 25-byte stems, which is roughly a list of file paths — and the DAFSA
**loses by 7 to 8×**, at every count from 128 keys to 32 768, with no crossing.

What survives every row is `rank`: 27 to 108 ns per key, pointer-free,
order-preserving, and not available from the sorted array at any size. Come here
for the ordinal, not the bytes.

## The Generators Are Checked, Not Trusted

A board is evidence only if its input is the shape it claims, so the rung's own
tests are folded into `zig build test` and hold both generators to their stated
quotient. Two versions of the string generator were wrong in exactly the way that
reads as a *result* rather than as a bug:

- Rendering the key index in base 26 directly produces the **cube** `aaaaa,
  aaaab, …`. A cube is a product of independent letter positions, so it minimizes
  to about a dozen states however the factors are split — 4 096 keys in 14 states,
  112× a sorted array — and the sharing axis the board means to vary disappears.
  Indices are scrambled through a unit mod 26ⁿ instead, which keeps them distinct
  and countable over an arbitrary-looking subset.
- Base 26 of a small number is mostly `'a'`, so a 25-letter stem taken straight
  from the index carried a shared 19-letter run: the *most* shared corpus on the
  board, printed in the row labeled unshared. The stem positions are hashed, and
  only the low positions — enough to name the count — carry the index bijectively,
  which is what keeps the keys distinct while the stems genuinely diverge.

Both engines also check each other on every row, the same way
[`refine_test.zig`](../../../src/kernel/math/refine_test.zig) does. A
disagreement fails the rung rather than printing a slow line.

## Reading It

Timings are wall clock (`clock_gettime(MONOTONIC)`), single-shot per cell, in
`ReleaseFast` against the shipped engine module. They are for **ratios within a
row** — `m/h`, `auto/h`, `vs flat` — not for absolute comparison across machines;
the shapes are synthetic and generated in process, so there is no corpus to fetch
and nothing to keep in sync.

`held B` is the DAFSA's resident size in the representation it actually ships:
one byte of label per edge and accept per state, `u32` for every start offset,
target, and subtree count. `vs flat` is that against the same keys as a sorted
byte block with one `u32` offset each — which answers membership in
`O(len·log n)` and has no rank at all, so it is a floor on what a rank would cost,
not a like-for-like rival.

- The symbolic path's product walk builds the minimal automaton directly now,
  instead of building three times too much and asking `reduce` to throw the rest
  away.

  What was wrong: `transcribe` crosses the UTF-8 decoder with the codepoint
  automaton and interns every reachable `(node, pattern state)`. `pairBound` said
  those two factors were independent and measured itself exact on 33 patterns,
  which was true and beside the point. Mid-codepoint the pattern is not running -
  a continuation byte carries its state through untouched - so the only thing a
  node can ever do with that state is hand it to the transition table once a
  codepoint completes, and only for the minterms whose leaves are still reachable
  below it. Deep in the trie for Unicode `\w` that set is a single minterm, so
  every pattern state agreeing on that one column is, from there, the same state.
  `reduce` was already finding exactly this, afterwards, by hashing a
  `1 + 2*ncls` signature per state per pass over a table three times bigger than
  the answer.

  So `linear/symbolic/horizon.zig` reads the set off the two factors before a
  pair is interned. One ascending sweep of the decoder DAG folds each node's
  reachable minterms bottom-up (nodes are interned children-first, so one pass is
  a fixpoint), then one signature pass per node groups the pattern's states
  against that horizon. `intern` substitutes a state's representative. The root
  is held apart on purpose: a codepoint boundary has just passed there, its
  horizon is every decoded minterm, and it is the one node where `is_match` is
  read at all.

  It is a congruence, not an approximation, and the census says so rather than me
  saying so - raw pairs now equal the finished state count on every row:

  | pattern | raw pairs | now | table |
  |---|---|---|---|
  | `\w+X` | 948 | 318 | 318x97, unchanged |
  | `\w{3,8}` | 1264 | 949 | 949x96, unchanged |
  | `\p{L}+;` | 894 | 300 | 300x96, unchanged |
  | `é+X` | 6 | 4 | 4x4, unchanged |

  The counts fall out of the two factors, which is the part I like: `\w+X` is 316
  decoder nodes x 3 states, and 3 at the root plus 315 elsewhere is 318.
  `\w{3,8}`'s counter keeps three of its four states apart under a one-minterm
  horizon, so 4 + 315x3 = 949. Both exact.

  Compile, ReleaseFast, min-of-21, one process, against `re` on 3.12:

  - `(\w+)=(\d+)` 2551 -> 1782 us, so 218x `re` -> 128x
  - `(\w+) (\w+) (\w+)` 4541 -> 3263 us, 296x -> 205x
  - `\w+X` 1955 -> 1151 us; `\w+\d+` 2033 -> 1357; `\w+X\w+` 2947 -> 2025
  - `X\w+` 1895 -> 1515 us; `\d+X` 547 -> 499

  Scan does not move, and not because I checked a stopwatch - the frozen table is
  byte-identical, which is what the census rows above are asserting.

  Two things did not move, with the reason instead of a shrug, and one of those
  reasons was wrong when I first wrote it down. `\b\w+@\w+\.\w+\b` (2829 -> 2787)
  never reaches this path at all: `\b` is a second determinization axis the
  codepoint alphabet cannot express, so the program goes to the byte powerset,
  and there is no product for a horizon to quotient. `\s*(\S+)\s*:\s*(\S+)`
  (1448 -> 1431) is not a word-context program - it has no `\b` in it - and it
  does take this path and does reduce, 47 pairs to 40. It did not move because
  its product is not where its time goes: every stage this change touches is 3%
  of that compile and the other 97% is the analyses, which is the next thing the
  lowering rung has to attribute rather than anything I can claim here.

  The rest of the bill, since I measured it properly this time instead of
  guessing: compile is about 0.27 us per codepoint range per class OCCURRENCE,
  and `lowerUtf8` rebuilds that trie for each one. `\s` is 10 ranges, `\d` 71,
  `\w` 796; `(\w)(\w)(\w)(\w)` is 963 us and dead linear in the count. On top of
  that, needing a real DFA at all costs roughly another 9x - `\w+` is a pure
  class run at 232 us because the SIMD kernel answers it and nothing
  determinizes, and one adjacent literal makes it `\w+X`. `[a-z]+X` pays none of
  it at 8.9 us. Repetition itself is free: `(\w+)` and `(\w)` are the same 236 us.

  `pairBound` is no longer exact and its comment now says which of its two claims
  broke. The horizon's own `pairs` is the exact figure, and using it as the gate
  is a separate rung - it would let patterns that currently decline to the
  on-demand tier hold an eager table instead, which is a scan change and wants
  its own differentials.

  One thing I tried and reverted: merging identical table columns before the row
  refinement rather than after. `reduce`'s own header predicts it cannot help,
  because column merging never creates a row merge, and the stopwatch agreed -
  2551 -> 2696 us and 4541 -> 4774. The header was right.

- I built the instrument the fragment above was guessing without, and then spent
  it. `bench/rungs/lowering/` prices a COMPILE the way every other rung prices a
  scan: one row per pattern, split into parse, Thompson lowering, the symbolic
  road's phases, the crossing broken into decoder / horizon / product walk, and a
  residue labelled honestly as "everything I have not named yet" rather than
  folded into whichever stage was convenient. Two more sections fit the scaling
  laws on controlled axes - the same class repeated k times, and classes built to
  hold an exact chosen number of codepoint ranges - and a fourth prints the pair
  space the symbolic gate admits on. Before any of it runs, every eligible
  pattern is compiled down BOTH determinizations and held against each other and
  against the Pike VM over haystacks laced with malformed UTF-8, because compile
  time is a number you can always shrink by building something else.

  Three things fell out of it, in the order the rung found them.

  **`lowerUtf8` weaves each class's trie once now, not once per occurrence.** The
  fragment above costed this at 0.27 us per codepoint range per occurrence and it
  was right about the shape - the byte compiler rebuilt the whole UTF-8
  sub-automaton at every `\w`. A `Loom` caches the trie's SHAPE keyed on the
  class's ranges (its operations in a virtual id space, with one exit), and each
  further occurrence replays that into fresh state ids. Same NFA, state for
  state. The cache is cold on the first occurrence and warm after, so one process
  shows both halves without needing a baseline to compare against: `\w`'s first
  occurrence weaves in ~61 us and every one after replays in 7-10, `\p{L}` ~49
  then 7.6-7.9, `\p{Greek}` 3.3 then 0.7. Per NFA state that is ~34 ns to weave
  against ~4.7 ns to replay - call it 7x, and the range rather than a single
  figure because a slope fit on a 60 us stage across three runs of this rung
  moves ~15% on a laptop with other work on it. On the controlled range axis,
  which is a wider stage and holds still, the replay bills 0.05 us per codepoint
  range where the weave billed 0.27.

  **The gate reads the horizon's exact `pairs`, not just the free rectangle.**
  This is the rung the fragment above left for later, and it lands as predicted:
  `pgxpool\.\w+`'s rectangle is 316 nodes x 17 states = 5372 against a 4096
  ceiling, its real pair space is 647, and it holds an eager 332-state table now
  instead of buying a byte powerset and then an on-demand DFA. `const\s+\w+\s*=`
  is the other one, 4740 -> 677 -> 360 states. The gate takes the MINIMUM of the
  two readings rather than replacing one with the other, because neither
  dominates - `pairs` is a per-node class count and is far tighter on anything
  Unicode, while the rectangle carries the anchored refinement `pairs` cannot,
  where `reseed == dead` collapses a whole column of the space onto one absorbing
  pair. Both are upper bounds, so the smaller is one too. That is a change of
  TIER, not of answer, and it is why the differentials above cover it.

  A tier change is a scan change, so it owes a scan number rather than the
  assertion that eager beats on-demand. `symbolic = .off` reproduces exactly
  where those two patterns used to land - it pins the byte powerset, which
  declines them `too_costly` and drops them on the on-demand tier, same
  destination the old gate sent them to - so the two roads can be timed against
  each other in one process. Over a 4 MiB document laced to ARM each pattern's
  required literal and never complete a match, which is the only shape that
  actually runs the automaton rather than the prefilter:

  - `pgxpool\.\w+` 340 -> 620 MiB/s, **1.8x**
  - `const\s+\w+\s*=` 366 -> 619 MiB/s, **1.7x**
  - `func\s+\w+\(` 357 -> 549 MiB/s as the control, since the old gate already
    admitted it (3792 clears 4096) and it was eager before this change

  Both haystacks answer 0 hits over every window, which is the point: a document
  the prefilter can reject reads 30-38 GiB/s and a document that matches early
  cuts each window short, and neither number is about the table. `\w+X` is
  95 GiB/s on both roads because the class-run kernel answers it and no DFA is
  consulted at all.

  Sizing `seen` to `pairs` came along free, since the count was already in hand:
  the interning table is 658 slots on `func\s+\w+\(` where the rectangle wanted
  3792, and the `@memset` in front of every walk shrank with it. Horizons are
  deduplicated by their minterm SET on the way, because a node id never enters a
  signature - `\w`'s 316-node trie has two or three distinct horizons depending
  on the pattern, so the signature pass went from `nodes x states` to
  `horizons x states`.

  **`reduce` handles the word-context axis, so nothing declines for lacking it.**
  A word-context program carries a third transition table - the interior byte
  again, under a following word byte - and `reduce` knew about two. `run`, `rows`
  and `classes` take a slice of axes now, and a `comptime` assert ties that count
  to `Tables`' own field count, so a fourth table added there is a compile error
  rather than a dimension quietly merged across without being read. The word axis
  gets no slack: two states agreeing on every interior byte still differ if the
  byte after them being a word byte routes them apart, which is the distinction
  `\b` exists to draw. The line-final axis keeps its existing over-strictness,
  which is sound and stated where it is taken.

  Then the rung said the walk was not the bill, so I went where it pointed.
  `reduce` was costing 1.5x to 3x the product walk, mostly to prove that nothing
  merges. Two fixes, both root-cause:

  - The codepoint automaton was not minimal. A determinizer interns on the NFA
    state SET, and two different sets routinely accept the same suffixes; every
    surviving twin then multiplies through all 316 decoder nodes in the product.
    So `determinize` minimizes itself - a dozen states over a dozen minterms,
    hundreds of times cheaper than asking the same question of the finished byte
    table, and it is also what makes the horizon's one-step quotient exact rather
    than approximate.
  - `reduce`'s column pass read the table column-major, which is a fresh cache
    line per element on a row-major table: ~243 K strided touches on
    `(\w)(\w)(\w)(\w)`, measured at ~700 us of a 900 us reduction, more than the
    entire walk that built the table. It carries one rolling accumulator per
    column and streams the table in the order it is laid out now. The fold is a
    filter and not the verdict - a confirmation sweep runs row-major over the
    real bytes, and on a 64-bit collision the whole question goes to an
    exhaustive pairwise pass - so the partition does not depend on the hash.

  The row half is delegated to `math/refine.zig` outright and the duplicate Moore
  that used to live in `reduce` is gone. I re-measured Moore against `.auto`
  across the whole slate while I was in there, because the previous choice rested
  on one 133-state pattern: Moore still wins small (89 states 45 us vs 77, 104
  states 62 vs 104, 133 states 88 vs 119) and it is a wash large (1265 states 914
  vs 930, 1897 states 1802 vs 1735). No crossover, so no flip - both engines are
  bound by streaming the same `states x axes*classes` table, which is also the
  honest statement of where the next win is. It is the WIDTH of that signature
  and not the engine: all but a handful of a product row's columns are the shared
  resync row every state at that node carries, so refining on a node's live edges
  alone would be a twentyfold narrower table. I did not do it here because it is
  not the same partition - two nodes with different live sets whose live targets
  happen to coincide with the resync ones merge today and would stop - and finer
  is sound but is still a different automaton, so it owes its own differentials.

  The walk itself got the one fix that was free. `stepByte`'s lost-sync tail
  never reads the pattern state it came from, so every non-root node resyncs to
  the same landing on the same byte: that row is interned once before the walk
  and copied per state, and the walk's per-state work drops to the node's live
  edges - 6 columns instead of 102, with the other 96 becoming a memcpy the table
  had to pay for anyway. A resync column is only interned if some node actually
  resyncs on it, which is what keeps this from inventing states, so the product's
  state count is unchanged rather than merely similar.

  And the byte road's own number is on the record now, because the rung kept
  reporting a 207 ms compile for `\b\w+@\w+\.\w+\b` with 207 ms of it
  unattributed. It is the byte powerset, and it is unbudgeted on purpose: the
  rung asks for `force_dfa` (it exists to price a determinization, so it must not
  measure a pattern skipping one) and `force_dfa` waives the visit budget. 154.5
  million NFA-state visits in 208 ms is 1.35 ns a visit - so the 750 K budget is
  calibrated correctly after all, and a caller who did not demand a DFA gets a
  `too_costly` decline in 1.3 ms and the Pike VM. The rung prints the unbudgeted
  clock and the budgeted verdict side by side, because reading one as the other is
  exactly the mistake I made for an afternoon.

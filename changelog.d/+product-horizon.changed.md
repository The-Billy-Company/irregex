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

  Two things did not move, with the reason instead of a shrug. `\b\w+@\w+\.\w+\b`
  (2829 -> 2787) and `\s*(\S+)\s*:\s*(\S+)` (1448 -> 1431) are word-context
  programs, and that road declines the reduction outright, so there was never a
  redundant product to not build.

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

- `Match` is a C type in the accelerator now, which was the rung 2.2.0 wrote
  down and left for later.

  The shape: a base type in `_accel` holding the pattern, the subject, the span
  and the capture pass's answer, with the cold half of the API (`groupdict`,
  `expand`, the named-group and wide-subject arms) still the Python methods,
  grafted onto it rather than forked away from it. There is one `Match` class,
  not two. Every rule the Python arm stated is still stated there and only
  there: what a refusing capture engine means, how an out-of-range group is
  phrased, `None` vs `(-1, -1)` vs `-1` for a group nobody entered, and
  byte-to-character translation on a non-ASCII `str`. The C side answers only
  what it can prove is a slice of something it already holds, and declines the
  rest by name.

  Three fusions came with it. `sought` answers an unbounded `search` in one
  crossing instead of two, since `find_first` was minting a span tuple only for
  the constructor to take it apart again. `spliced` and `pieces` answer a whole
  `sub` with a constant replacement, and a whole groupless `split`, on the C
  side of the boundary. And the capture pass is resolved and held in C now,
  calling the Python rule directly with the text it already has instead of
  reaching it through a `TextView` it was building for no other reason;
  `Pattern._captures_at` takes that text rather than the view, which is all it
  ever read out of one.

  Measured on 3.12, min-of-11, interleaved against `re` in one process:

  - `m.group(1)` on a match that already resolved its groups: 302 ns -> 63 ns,
    against `re`'s 33 ns. `span`, `start` and `end` on a real group moved the
    same way; they were all going out to Python for a span the match was
    already holding.
  - `search(...).groups()`: 892 ns -> 658 ns, against `re`'s 154 ns.
  - `split` on a 59-byte line is 1.9x `re`, `sub` over 1 KiB is 2.8x, a 17 KiB
    miss is 6.3x, and `findall` holds 1.5-1.7x across line, 1 KiB and 17 KiB.

  What did not move, with the arithmetic instead of a verdict:

  - `search` / `match` / `is_match` answering a literal in a short line sit at
    0.41-0.42x. The seam call alone is 67-69 ns there and `re`'s entire answer
    is 59-68 ns, so that row is lost below the bindings and no Python layer
    above it wins it back. The 73-134 ns above the seam is the `Pattern`
    method, which is the next rung; it narrows the gap and does not flip it.
  - `group` is 0.23x because the engine's capture pass costs 217 ns on its own,
    where `re` does the search and the captures together in 154. That is an
    engine question and this change does not touch it.
  - `compile` on a Unicode pattern is still 2.6 ms against `re`'s 12 us. I went
    looking this round instead of guessing: the cost is the symbolic path's
    product walk in `transcribe` plus `reduce`, roughly 14 ns a cell, and not
    the decoder weave I would have bet on. Pre-sizing the walk's buffers
    changed nothing measurable, so I reverted it. Still unfixed, but located.

  Both transports agree throughout, which is the point of having two: 3114
  `Match` answers over 12 patterns, 2 domains and 4 doors, with zero
  divergences native-vs-ctypes and zero against `re`; 16128 `sub`/`split`
  answers likewise.

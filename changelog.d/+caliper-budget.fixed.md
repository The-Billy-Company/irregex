- The caliper's memo budget is counted in the currency it is spent in, so a `\b` no longer prices a pattern out of its own automaton.

  The budget was `clamp(nfa_states * 64, 128 KiB, 2 MiB)`. The memo is charged in
  `Machine.stride` units, and stride is `rows * ncls` - so the floor was stated
  in bytes while the spending happens in states, and the exchange rate is
  different for every program.

  It is worst for the programs with the most to determinize. A word assertion
  takes `rows` from four gap shapes to sixteen, because a gap's word context
  selects the transition; a Unicode word class widens `ncls` on top of that. Put
  both together and one state costs 4864 bytes where its word-free twin costs
  1216. Same flat 128 KiB floor, 27 states affordable against 107, for two
  patterns one character apart.

  Twenty-seven is below the powerset of any real multi-segment pattern, so the
  forward jaw hit `quit` partway through the first scan and stayed quit - the
  flag is sticky. Every span after that declined, and a 394-state program went to
  the Pike VM at 109 ns/byte while the twin ran the caliper at 4. The budget was
  not protecting memory there; the memo never got large. It was cutting
  determinization off a third of the way in and paying for the abandoned work.

  So the floor now scales with the stride, which holds a program's affordable
  *state* count roughly constant instead of its byte count. 256 states sits just
  above the ~195 a flat 128 KiB already bought a typical assertion-free program,
  so nothing that fit before fits less well, and the 2 MiB cap still bounds the
  absolute spend for a program whose stride is genuinely enormous.

  On the pattern that found this - a caseless seven-verb alternation with a
  hinge, a trailing alternation and one `\b`, over 3.4 KB of ordinary prose -
  the span walk goes 374 us to 17 us, and the jaw reaches its true 30-state
  powerset instead of dying at 27.

  The regression test asserts the thing that is actually invariant rather than a
  duration: two patterns differing only by a trailing word assertion must both
  determinize to completion, and the widened engine's spans are held to this
  file's standing Pike oracle.

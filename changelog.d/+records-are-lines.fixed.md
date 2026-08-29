- `^` and `$` are newline assertions under a NUL record separator now, and a
  record that holds newlines costs what the lines in it cost.

  A `--null-data` haystack is not a line — it is a NUL-delimited record, and a
  record holds newlines. The engine had no way to say that: `multiline` carried
  the whole "this haystack is wider than a line" fact, and the record path did
  not set it, so `^zz` reported no match for a `zz` sitting after an interior
  newline. Both incumbents disagree — `rg --null-data '^zz'` and BSD `grep -z
  '^zz'` each match it, because `^` in a line-oriented tool asserts about
  NEWLINES and choosing a different record separator does not retract that. So
  `records` is now its own option beside `multiline`, `wide` is their union, and
  every decision that used to read `multiline` (anchor semantics, whether `(?s).`
  may cross a `\n`, whether a class run stays line-local, whether an eager
  anchored determinization is even expressible) asks that instead. The
  `\n`-aware Pike walk `-U` already had is now shared with the per-line entry
  rather than reimplemented, which is what made the two arms answer differently
  in the first place.

  A record's trailing `\n` is content, not a terminator — its terminator was the
  NUL, and that was stripped before the engine saw it — so it opens the empty
  line after it exactly as an interior newline does. That is one bit
  (`nl_terminates`), read at every site where `^` is resolved, because the
  boolean arm and the span arm answering it separately is how `-c` came to
  report a record matched while `-o` printed nothing from it.

  Then the speed, which is the same observation used twice: a record is a
  SEQUENCE OF LINES whenever the pattern cannot see across one. An
  assertion-bearing wide program gets no DFA and no accelerator tier — `^`/`$`
  as `\n`-boundary predicates are content-dependent in a way an eager BOL/EOL
  table cannot encode — so `^(?:alpha|beta|gamma)` fell all the way to the Pike
  whole-record scan. When no consuming class admits a `\n` and no `\A`/`\z` is
  present, splitting the record at its newlines loses no answer and hands every
  piece to the ordinary per-line ladder, anchors and all.

  Measured on 50 MB of NUL-delimited records against this same source with that
  one switch forced off, both builds and a real `rg` run back to back inside each
  round, minimum of 15, counts identical: `^\w+ mid` went from 341.9 ms wall /
  2885 ms CPU to 16.2 / 50 — a 21× wall and **57× CPU** cut, because a `\w`-led
  program is precisely what earns no DFA and no accelerator tier once the
  haystack is wide. `^(?:alpha|beta|gamma)` went 45.7 / 387 → 11.8 / 37, and
  `^[a-z]+ [a-z]+ [a-z]+` 16.8 / 104 → 8.2 / 18. The three rows a required
  literal already carried moved by under 1%, which is the other half of the
  claim: the decomposition is free where it buys nothing.

  Against ripgrep that is now ahead on both axes rather than trading one for the
  other — the alternation was already 1.6× faster on wall clock before any of
  this, but on 387 ms of CPU against rg's 72, which is a loss on any laptop doing
  something else with its cores. It is 6.2× faster on wall and 1.9× on CPU now.

  Python `re` referees the result: over 322 cells of record-mode `-c` and `-o`
  answers, we now agree with it on every one, and ripgrep disagrees on 13 — it
  misses a record's own start for `^` (reading `^` as "after a `\n`", so a
  record beginning after a NUL is not a line start to it), prints whole records
  as `-o` rows for matches it rejected (`^.` yields `ef`, two bytes, for a
  pattern that can match one), and matches nothing at all for `\z`, whose NUL it
  keeps in the searched slice.

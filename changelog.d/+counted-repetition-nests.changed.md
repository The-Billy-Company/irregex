- A counted repetition desugars nested now — `a{2,5}` becomes
  `aa(?:a(?:a(?:a)?)?)?`, RE2's shape — instead of the flat `aaa?a?a?` chain it
  used to lower to.

  The flat chain is the textbook desugar and it is wrong for every engine this
  package runs. Each optional copy is its own fork, so "matched one `a`" is
  reachable along many ε-orderings — take-the-first, take-the-second, and so on
  — and every arm pays for that ambiguity in its own currency: the capture VM
  carries each ordering as a distinct thread (quadratic in the bound), the
  one-pass table sees two live paths on the same byte and refuses the pattern
  outright, and the powerset construction mints subset states for distinctions
  no answer can observe. Nested, each count has exactly one path. Same language,
  same leftmost-first spans, and `[^:]{0,255}` — the shape every file:line
  parser writes — stops disqualifying the fast arms it should have been running
  on.

  The Parabix gate's peephole knew the flat chain by sight, so it learned the
  nested one: `optionalRun` unrolls the tail back into the `opt(k)` run the term
  fuser folds, and refuses the moment two levels repeat different classes,
  because `(?:A(?:B)?)?` does not admit the lone `B` that flat `A?B?` does.

- Verbose mode — `re.VERBOSE`, `(?x)`, `IRGX_VERBOSE`, `verbose=True` — works on
  the linear arm now, so a commented pattern no longer costs the linear-time
  guarantee. `(?#…)` inline comments work in every mode, and `\Z` is Python's
  absolute end instead of an unrecognized escape.

  Refusing `(?x)` was the gap that stung most in practice, because verbose is not
  a feature a caller opts into for power — it is how a *long* pattern gets
  written, and long patterns are exactly the ones where a backtracker's worst
  case matters. Every `re.VERBOSE` module in a codebase was structurally
  ineligible for this engine, and the two workarounds are both bad: strip the
  whitespace by hand (and now the pattern is unreadable and its error offsets
  point at bytes nobody typed) or pass `pcre=True` (and trade away the one
  property the pattern was long enough to need).

  Verbose is purely lexical — it changes which bytes are a *token*, never what a
  token means — so it belongs to the recursive descent and nowhere else. It is a
  `trivia()` skip called at the two points where a token may begin: the concat
  loop and the quantifier loop. Deliberately not called anywhere else, because
  everywhere else the same bytes are significant, and `re` agrees byte-for-byte:
  `[ ]` keeps its space, `a{1, 2}` is not a bound, and `a *?` is one lazy star
  rather than a star and an optional. A source-rewriting pre-pass, the obvious
  alternative, would have had to re-implement the grammar to know which spaces
  are inside a class — and would then report every error at an offset into a
  string the caller never wrote.

  Both arms honor it and agree: the linear parser reads it, and PCRE2 gets
  `PCRE2_EXTENDED`. On the PCRE2 arm the required-literal miner and the shadow
  gate now stand down under verbose, because both read the pattern *text* — one
  would have demanded the bytes `"a b"` of every match of `a b`, and the other
  would have read a `(` inside a `#` comment as structure. A prefilter that is
  not an over-approximation does not slow a search down, it loses matches. The
  linear arm keeps every prefilter, since it derives them from the single
  verbose-aware parse rather than from the bytes.

  The planes that cannot carry it say so instead of dropping it: `compile_set`
  and `compile_munch` raise, and a slate pattern whose own head says `(?x)` is
  refused with `refused` naming it — a member that wants verbose wraps itself in
  the scoped `(?x: … )`, which works anywhere. Measured against `re` over 30
  verbose patterns on both arms: zero disagreements, and the same pattern
  commented and uncommented scans within 0.5% of itself, which is the whole
  claim — the mode is free at match time.

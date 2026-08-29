- The emit layer skips dead LINES with the engine's own opinion of what is rare,
  instead of handing the engine every line and letting it decide one at a time.

  The engine already skips dead spans *inside* a haystack with a first-byte set
  priced against a fitted corpus model. One grain up, the layer that decides which
  lines the engine ever sees was walking all of them. So the same set, and the same
  economics, now travel upward: `prefilter` and `dwell` are exposed from the engine
  root precisely so the emit layer cannot re-derive either and drift from the
  engine's own judgment of when a skip pays.

  Three shapes get three answers, and each is a necessary condition only — a hit
  nominates a line and the real engine confirms it, so none of this can change an
  answer:

  - **A literal-bearing pattern jumps to candidate lines.** One whole-buffer sweep
    over a literal set, the required literal, or the first-byte set marks the lines
    worth entering; the rest are never visited. This is the `rare 2-byte literal`
    and `rare wide class` rows in the table under *"Three scan dispatches…"* —
    13.1 ms wall against ripgrep's 43.9, on 1.6× less CPU.
  - **A pure `-c` over a class-run pattern is fused into one pass.** Counting needs
    no spans, and the class-run kernel classifies every block anyway, so the whole
    slice settles in ONE classification pass rather than jumping to each candidate
    line and dispatching the engine on it — it needs no sweep to jump on at all.
    That is the `dense class` row: `\w` over 268 MB in 21.1 ms wall / 98.8 ms CPU
    against 141.2 / 142.3. Shards are cut at line starts so a count is never split
    across a line.
  - **A `^`-anchored pattern gets a document-grain needle.** `"\n" ++ prefix` sits
    immediately before every match that is not in the buffer's first line, so an
    anchored search skips dead lines with a two-byte memchr instead of testing the
    anchor once per line. Null — and therefore silent — when the pattern is `-U`,
    caseless, has no literal match-prefix, or is PCRE2's, whose program this
    package does not analyze. The `anchored literal` row: 16.4 ms wall against
    50.6.

  A count is the same number either way and a span is the same span; these are
  routing decisions above the engine, not a second matcher.

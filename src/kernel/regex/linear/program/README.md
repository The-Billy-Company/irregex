# linear/program — what a pattern becomes

The **compiled artifact and the pipeline that produces it**. Everything here is
about a `Regex` at rest: the immutable state a match reads, and the one-time
compile that decides what that state contains.

Nothing in this folder scans a haystack. Answering questions is `../ladder/`'s
job; executing them is `../pike/` and `../dfa/`.

- **[`core.zig`](core.zig)** is the public `Regex` handle: the immutable
  compiled state with its field-by-field contract, `deinit`, the program-walk
  predicates (`claimsNewline` / `bansByte`), and the decls adopted from every
  neighbor.
- **[`lower.zig`](lower.zig)** compiles: parse → case-fold → Thompson lowering
  → the accelerator analyses (required literal, alternation cover, pure
  literals, first set, zero-width reachability) → which engines to build. That
  last step decides three things, not one: which determinizer runs
  (`../symbolic/` or the byte powerset), whether its result is eager or on
  demand, and which optional rungs `../ladder/rungs.zig` can offer over it.

  The fold's placement is load-bearing and it costs something. Folding before
  every analysis is what keeps the prefilters and the match engines reading the
  same classes — but it also erases the literals those analyses were going to
  find, so a caseless pattern yields an empty `required` and declines every
  literal acceleration. So the caseless arm re-parses the source unfolded and
  reads the literal off that twin's AST, keeping the fold-closed window as the
  `gate` the walking paths reject on. Only the parse and the literal pass run on
  the twin; the literal is an AST property, so lowering it would mean building a
  second engine to read one field.
- **[`core_test.zig`](core_test.zig)** runs parser / Pike VM / prefilter /
  scan-accelerator cases.
- **[`chorus.zig`](chorus.zig)** runs the same pipeline for MANY patterns: N
  patterns lowered into one program whose N terminals sit at indices `0..N-1`,
  determinized once, walked once. It yields `(end, patterns)` pairs, which is
  simultaneously attribution, overlapping search, and end-only (HalfMatch)
  search. It declines to null rather than guessing, so every caller keeps a
  fallback.
- **[`chorus_test.zig`](chorus_test.zig)** covers the three tiers, plus the
  differential that holds one chorus walk against N standalone engines.
- **[`munch.zig`](munch.zig)** runs the same slate **anchored**, asking the
  lexer's question instead of the search one: starting at exactly this offset,
  which pattern reaches furthest? One automaton's attribution mask is 64 bits
  wide, so a `Munch` holds as many automata as it needs for any number of
  patterns; it admits a slate by bisection so one unusable pattern is named in
  `declined` rather than costing the other hundred and fifty; it reports every
  tie because the tie-break belongs to the grammar; and it takes a per-call
  `Allow` so a state-directed lexer can ask for the longest match *among the
  terminals it will accept*. `longest` neither allocates nor fails.
- **[`munch_test.zig`](munch_test.zig)** checks that anchoring is real (`abc`
  does not match `xabc` at zero), that partial admission names the right
  ordinals, that a narrowed slate is provably not a filtered answer, and holds
  the differential against N whole-span engines at every offset.

## Why the Handle and Its Constructor Sit Together

The field contract in `core.zig` and the code that establishes it in `lower.zig`
are one invariant read twice — every field's doc comment names the analysis that
fills it, and `deinit` is the other half of the ownership `lower` takes on. They
change together or the handle lies.

The adopted-decl block in `core.zig` is what keeps that split invisible: Zig has
no `usingnamespace`, so each neighbor's entry point is bound by name and callers
still see one type (`Regex.compile`, `re.docMatch`, `Regex.Span` …).

# exec/cold/writ — What the Patterns Decide

A writ is what an invocation's argv patterns compile to. Not the matcher
alone: the matcher plus every value derived from it — both literal gates,
the trigram prefilters, the crest sieve, whether binary detection is live —
each already stood down wherever it would be unsound.

- **`writ.zig`** holds the `Writ` itself: one `compile` call resolves
  every derived value, guards included, plus `binaryDetect`, the one
  owner of "is the detector live?"
- **`directive.zig`** folds many argv patterns into one effective pattern:
  `-F`/`-f`/`-e` folding and leading `(?flags)` reconciliation across a
  single run-wide engine.
- **`gate.zig`** holds the prefilters and the three predicates that say
  when each may fire — the required-literal gate, the trigram filter, the
  crest sieve. Its `winnow` draws the cover plan and the sieve off one
  shared derivation the resident session reads too.
- **`arm.zig`** decides which engine compiles this pattern: linear, PCRE2
  outright (`-P`), or an `--engine auto` escalation, and the `-r` capture
  matcher that follows it.

## Computing, Not Carrying

The obvious shape for this package is a context struct — a bag of
parameters threaded through the pipeline to shorten signatures. That is
the shallow module Ousterhout warns about, and it was explicitly rejected
under the cold-engine deep-module split: it shortens signatures without
removing a single duplication, because callers still reach in and
re-derive.

A `Writ` computes. `filters` is already empty when index elision is
inadmissible; `file_needle` is already null when the output mode must
read every body. There is no "remember to also check" left for a caller
to forget.

## One Owner per Policy

Two predicates in this tier are load-bearing, and both used to be written
out by hand wherever they were needed.

- **`observesEveryByte`** asks does this run emit or tally *non-matching*
  bytes? `--stats`, `--json`, and `--passthru` do, which makes "skip what
  cannot match" a wrong answer rather than a faster one. This was spelled
  at five call sites; a new output mode that forgot one would return a
  wrong result with a clean exit code.
- **`binaryDetect`** tracks that `-a` / `--binary` / `--null-data` each
  stand the detector down. This was spelled seven times across four files
  in three different arities, and two of those spellings were equal only
  by an unstated coupling to a caller's eligibility check.

`mayDropFileUnread` and `mayElideByIndex` stay separate predicates on
purpose: `--files-without-match` forbids the whole-file gate but still
permits index prefiltering, so folding them together would be a silent
behavior change. Each says why in its own doc comment.

Proved by the rgsuite differential harness
(`gist/bench/conformance/rgsuite/`) and
`gist/bench/conformance/gates/parity/index_elision_parity.sh`, both in the
sibling `gist` repo: a gate may change speed, never results.

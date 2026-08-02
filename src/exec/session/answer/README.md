# `answer/` — what may be asked, what comes back, and the walk between them

The contract layer. A consumer can read this folder and learn the whole warm
surface without opening an engine: which requests are answerable warm, what
shapes come back, what bounds a run, and the one candidate walk every face
runs through. The faces that turn those candidates into bytes, sets, or records
live next door in [`../facet/`](../facet).

| Module                       | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [`answer.zig`](answer.zig)   | The answer + budget vocabulary every face shares: `QueryError` — only `Stale` and `OutOfMemory`, which _is_ the fail-closed contract — the answer shapes (`Result`, `Lines`, `MatchRecord`), and the cooperative bounds a hosted run carries (`CancelToken`, `RunBudget`, and the `Ceiling` whose clock read is sampled per stride so a wall-clock backstop costs nothing in the hot walk). Re-exported by `resident.zig`, so `resident.MatchRecord` and `answer.MatchRecord` are one type.                                                                                                            |
| [`request.zig`](request.zig) | The eligibility classifier — accepts only the supported argv surface (bare pattern → `lines`, `-l`/`-c`, `-F`, the last-wins case family `-i`/`-s`/`-S`, `-w`, `-v`, `-q`, `-m N`/`--max-count N` (incl `-m0`), `-n`/`-N`, `-e`/`--regexp`; **rootless only** — any explicit PATH arg, even `.`, stays cold; a `\n`/NUL/empty pattern stays cold), everything else → `error.Unsupported` (cold fallback). `Request.effectiveIgnoreCase` is the **single smart-case resolution site**: `-S` folds via `args.hasUpper` at the compile seam, so clients ship the raw bit and never re-implement the fold. |
| [`gather.zig`](gather.zig)   | The candidate walk all four faces share: compile the request through the shared search core, prune through **the same three-stage stack cold prunes by** (the conjunctive cover plan, then the crest sieve over the mirror's per-doc ρ(d), then the path filter — see below), then visit the surviving base docs plus the whole overlay under one budget + ceiling — with the per-match existence stat applied on every path the watcher has not proven clean, so a delete racing the walk→report window is never reported.                                                                            |
| [`keep.zig`](keep.zig)       | The answer keep: rendered stdout + exit code held against a corpus change epoch, for the questions no index can make cheap. Everything above answers a query faster; this one declines to answer it twice. The daemon never computes here — a client computes cold and offers the result, and the keep only compares epochs and evicts by LRU against a byte ceiling, so a store that cannot recompute cannot recompute wrongly. See `gist/src/surface/cli/reprise.zig` for the caller's half.                                                                                     |

`request_test.zig` sits beside its subject.

## The two budgets are not interchangeable

A `Ceiling` overrun **declines** the query (`freshness_unprovable` → the
certified cold path); a `RunBudget` trip is a **clean partial stop** that keeps
whatever was gathered. One is the daemon's liveness backstop, the other a hosted
caller's cooperative halt, and conflating them would either abandon good results
or serve an answer the session cannot vouch for.

## Three prunings, each independently declinable

`gather.candidateIds` is the resident twin of cold's read-elision oracle
([`../../cold/quarry/elide.zig`](../../cold/quarry/elide.zig)), and it asks the
same questions in the same order — cheap-and-strong first:

1. **The index**, asked the strongest question the pattern forces: the
   conjunctive cover plan, else the flat OR of the sound prefilter literals.
   That is cold's `askIndex` precedence including its fall-through — a plan the
   postings cannot witness declines to the _weaker_ question rather than to an
   empty answer.
2. **The crest sieve** over the mirror's per-doc crest vectors, which prunes the
   one class the trigram index concedes outright: a literal-free class repetition
   like `[0-9a-f]{8}` forces no trigram at all, so before this the session read
   100% of the corpus for it.
3. **The path filter**, last because it is the only stage that touches strings.

Each is a _necessary_ condition on matching, so dropping any one can only widen
the candidate set — never drop a match. Both AST-derived prunings come off ONE
parse ([`../../../kernel/query/prefilter.zig`](../../../kernel/query/prefilter.zig)'s
`winnow`, which cold's `Writ` also calls), and both stand down where they would
be unsound: a caseless pattern keeps its case-variant filter, and a `-F` literal
or a PCRE2 body arrives with a null `source`, which is the standing "do not
re-parse" certificate.

`GIST_NO_COVER` / `GIST_NO_CREST` stand one half down each. They are read in the
**daemon's** environment, not the client's, since that is where the pruning is
derived — which is what lets one binary A/B the wired path against itself
(`bench/rungs/sieve/warm_parity.sh` runs two daemons on two sockets for exactly
this reason). The `.index` lens reports the tier that answered and how much each
stage admitted, in the same grammar cold uses, and it rides the `diag` frame back
to the client's stderr.

## One argv authority, one projection

`request.zig` is the single argv authority — the CLI client, auto-spawn, and the
warm hints all call it. The Python `session.warm_eligible` field-predicate is its
only cross-language projection, and it is mechanically parity-tested
(`bindings/python/tests/test_classify_parity.py`) against the built classifier
through the `warm` trace lens (`GIST_TRACE=warm`) `[eligible]`/`[ineligible]`
verdict, so the two cannot drift.

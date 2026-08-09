# exec/cold/engine — Walk + Match Orchestration

The control planes that wire [`argv`](../argv) → [`writ`](../writ) →
[`quarry`](../quarry) → [`read`](../read) → [`emit`](../emit) into a
finished search. Matching itself lives in `kernel/query/query.zig`; the
tree walk, read elision, and file ordering live in `quarry/`; pattern-
derived gates live in `writ/`. What is left here is scheduling: when to
walk, in what shape, and how to stream the result.

- **`serial.zig`** is the certified rg-compat control plane and the tier's
  public face — mode dispatch, walk/read fallbacks, stdin / JSON / stats
  branches, exit semantics, and the re-exports callers still import
  through. Re-exported as `irregex.engine.search`.
- **[`swarm/`](swarm)** is the fused work-stealing walk+read+match, taken
  when the flag set allows; ineligible combinations fall through to serial
  unchanged. Seven modules behind two functions (`eligible`, `run`).
- **The retrieval rung** moved to `relate/src/exec/retrieval/` in the
  sibling `relate` repo — the fingerprint-lexicon path for `similar` /
  `pack`, shared by cold and warm.

## Two Schedulers, One Policy

Serial's recursive descent exists because ignore rules must load as the
walk descends; `swarm/`'s work-stealing queue exists because one
`getattrlistbulk` call returns metadata beside the listing. Those are
different algorithms on purpose (the cold-engine deep-module split) — what
they must never disagree on is the verdict, and that lives once in
[`corpus/tree/ignore.zig`](../../../corpus/tree/ignore.zig).

## Index Is an Accelerator, Not an Authority

Read elision is decided by the oracle in
[`../quarry/elide.zig`](../quarry), which both engines admit before they
open a byte; the walk stays the sole authority on the file set.
`--no-index` forces the pure walk; a missing or stale index is invisible to
the user, just slower.

`defaultFileSet` here is also what the warm session uses to select its
corpus, so resident reconcile and cold walk agree on what is in the tree.

## Why Relate's Engine Lives Beside Gist's

The cold-engine deep-module split lifted the native lenses to
[`../view/`](../view) so this package would mean one thing, and then
stopped, because `retrieval.zig` already satisfies that meaning. What these
three share is not a face but a rung: each drives a corpus to a finished
answer in a fresh process, against the same walk, the same persisted
index, and the same freshness discipline.

Moving retrieval under `face/relate/` would put an engine inside a face —
the one direction [`exec/`](../../README.md) forbids — and would buy a
tidier folder name at the cost of a real layering rule, while lifting no
abstraction (depth-over-decomposition).

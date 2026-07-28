<!--
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/exec/session/answer/answer.zig
    - pkg/kernels/irregex/src/exec/session/answer/request.zig
    - pkg/kernels/irregex/src/exec/session/answer/gather.zig
    - pkg/kernels/irregex/bindings/python/tests/test_classify_parity.py
  sentinels:
    - file: pkg/kernels/irregex/src/exec/session/answer/request.zig
      contains: ["effectiveIgnoreCase", "smart_case"]
    - file: pkg/kernels/irregex/src/surface/face/gist/main.zig
      contains: ["[eligible]", "[ineligible]"]
    - file: pkg/kernels/irregex/src/exec/session/answer/keep.zig
      description: the keep holds answers against an epoch and never computes one
      contains: ["pub fn recall", "pub fn retain", "max_total_bytes"]
-->

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
| [`gather.zig`](gather.zig)   | The candidate walk all four faces share: compile the request through the shared search core, prune through the trigram index, then visit the surviving base docs plus the whole overlay under one budget + ceiling — with the per-match existence stat applied on every path the watcher has not proven clean, so a delete racing the walk→report window is never reported.                                                                                                                                                                                                                            |
| [`keep.zig`](keep.zig)       | The answer keep: rendered stdout + exit code held against a corpus change epoch, for the questions no index can make cheap. Everything above answers a query faster; this one declines to answer it twice. The daemon never computes here — a client computes cold and offers the result, and the keep only compares epochs and evicts by LRU against a byte ceiling, so a store that cannot recompute cannot recompute wrongly. See [`../../../cli/reprise.zig`](../../../cli/reprise.zig) for the caller's half.                                                                                     |

`request_test.zig` sits beside its subject.

## The two budgets are not interchangeable

A `Ceiling` overrun **declines** the query (`freshness_unprovable` → the
certified cold path); a `RunBudget` trip is a **clean partial stop** that keeps
whatever was gathered. One is the daemon's liveness backstop, the other a hosted
caller's cooperative halt, and conflating them would either abandon good results
or serve an answer the session cannot vouch for.

## One argv authority, one projection

`request.zig` is the single argv authority — the CLI client, auto-spawn, and the
warm hints all call it. The Python `session.warm_eligible` field-predicate is its
only cross-language projection, and it is mechanically parity-tested
(`bindings/python/tests/test_classify_parity.py`) against the built classifier
through the `warm` trace lens (`GIST_TRACE=warm`) `[eligible]`/`[ineligible]`
verdict, so the two cannot drift.

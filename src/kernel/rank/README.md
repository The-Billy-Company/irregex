---
doc_radar:
  sentinels:
    - description: "rank stays weighted RRF over intrinsic signals"
      file: pkg/kernels/irregex/src/kernel/rank/rank.zig
      contains: "Reciprocal"
---

# `src/kernel/rank/` — T4 definition-first ranking

Turns the verified match set into the ranked, token-compressed list an agent
actually wants: the one line that answers the question first, not 200
identical call sites. This is the shape `rg` cannot express — `gist --rank`.

## Files

| File          | Job                                                                                                                                   |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `rank.zig`    | Weighted **Reciprocal Rank Fusion** (Cormack et al. 2009) over the signals below; emits `path:line [def\|use\|gen\|mirror] ×n <line>` |
| `signals.zig` | Language-agnostic byte features: declaration detection and codegen demotion                                                           |
| `mirror.zig`  | Narrow cache/VCS snapshot classification, byte fingerprints, exact canonical-duplicate resolution                                     |

## What the boosts do

- **Definition boost** — a decl line outranks its call sites.
- **Authored boost** — sinks codegen (`*_pb2.py`, `*.sql.go`, …) and
  cache/VCS mirrors below hand-written code.
- **Class-split, tie-aware** — ranking stays neutral _within_ each class so
  you never invent a total order the signals don't support.
- Exact duplicate mirrors name their canonical result instead of flooding
  the list.

## When to edit

New intrinsic signals, class labels, or RRF weights. Do not put walk or
emit logic here — rank consumes an already-verified hit set from
`kernel/match/` + `surface/exec/cold/engine/ranked.zig`.

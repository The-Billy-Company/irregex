---
doc_radar:
  counts:
    - description: "compose tier after anatomy split — candidates + regions + context + four kernels + candidates test"
      glob: pkg/kernels/irregex/src/kernel/compose/*.zig
      unit: files
      equals: 7
  sentinels:
    - description: "candidates.zig caps the pattern mask at one u64 word"
      file: pkg/kernels/irregex/src/kernel/compose/candidates.zig
      contains: "max_patterns = 64"
---

# `src/kernel/compose/` — the exact-before-statistical tier

The pure composition kernels the `irregex` binary drives
([ADR-367](../../../../../../docs/architecture/3-decisions/367-composed-irregex-cli.md)).
A loaded corpus plus a compiled `PatternSet` (the MATCH primitive) yields a
typed **`CandidateSet`**: the subset of docs the exact selector admits, each
carrying the per-pattern mask that admitted it. The compression kernels then
run **only over that subset** — so an exact intent narrows the statistical one,
instead of a caller unioning two independent queries by hand and paying
whole-corpus noise.

| File             | Kernel         | What it computes                                                                                                                                                                                                                                                |
| ---------------- | -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `candidates.zig` | `CandidateSet` | the docs a `PatternSet` selects under `any`/`all`, each with its match mask (bit-identical to N single-pattern runs)                                                                                                                                            |
| `regions.zig`    | `Region`       | lifts exact matches into comparison-sized units (file / enclosing function / bounded match window) so kinship compares implementations, not whole files                                                                                                         |
| `context.zig`    | `context`      | coverage packing of a query over a lexicon built from ONLY the candidate docs; each pick carries its exact mask and its marginal bits                                                                                                                           |
| `family.zig`     | `family`       | verified byte, structure, or echo families among exact-selected files or regions, plus nearest-neighbor receipts for genuinely distinct regions                                                                                                                 |
| `provenance.zig` | `provenance`   | re-verify a quoted phrase against an exemplar's CURRENT bytes; returns the live offset/line/window, or nothing if the file drifted                                                                                                                              |
| `blast.zig`      | `blast`        | the live blast radius of a symbol from CURRENT bytes: seed def + kind (declared only by source files, and the body read from the strongest declaration rather than the earliest), direct dependents/dependencies, tangential twins/ripple, and comment mentions |

## Invariants

- **Pure kernels.** No I/O, no argv, no stdout. The [`surface/face/irregex/`](../../surface/face/irregex/README.md)
  face loads the corpus / codex shelf and renders; these compute.
- **The mask is one `u64`.** `candidates` caps at 64 patterns — well past any
  composed workflow's ask; a caller with more intents is running a `relate
patterns` sweep, not this.
- **Scores stay separate.** `context` never fuses the exact mask and the
  compression bits into one relevance number.
- **Comparison units are explicit.** Family analysis defaults to enclosing
  functions, can use bounded match windows or whole files, and never lets
  unrelated file bytes drown a small implementation. Region candidate sets
  verify every pair; no seed accelerator may hide a structural twin.
- **Difference is an answer.** Regions outside every admitted family still
  surface with their nearest structural neighbor and independent structure /
  byte distances instead of disappearing as dropped singletons.
- **Provenance never lies about location.** A phrase the current bytes cannot
  verify is not located — the driver reports drift instead of a stale line.

These kernels reuse the existing floor directly — the `PatternSet` from
[`../slate/`](../slate/README.md), the lexicon + coverage + kinship machinery
from [`../kinship/`](../kinship/README.md) — and add no matcher of their
own.

---
doc_radar:
  sentinels:
    - description: "PatternSet + loom.Plan remain the closed set-ops surface"
      file: pkg/kernels/irregex/src/kernel/slate/patterns.zig
      contains: "pub const PatternSet"
    - description: "loom keeps the closed plan ops"
      file: pkg/kernels/irregex/src/kernel/slate/loom.zig
      contains: "pub const Plan"
---

# `src/kernel/slate/` — many patterns, one walk

Was `kernel/slate/`. Operate on **many intents** or a **whole result stream**
at once, engine-side, with exact answers — the set-shaped half of the irregex
primitives (ADR-363). What backs `relate patterns` and the dragnet/trawl
multipattern tiers (`muster` · `trawl`).

## Files

| File           | Job                                                                                                                                       |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `patterns.zig` | `PatternSet` — compile N patterns once through `kernel/query/query.zig` with exact per-pattern attribution (`docMask` / `lineHits`) |
| `loom.zig`     | `loom.Plan` — closed filter → group → sort → limit over attributed rows; total-ordered and deterministic                                  |

## Invariants

- The fused alternation gate is **skip-only**: answers ≡ N independent
  single-pattern searches (gate on or off).
- Loom ops are hand-tallied for a total, deterministic result
  (`loom_test.zig`); no “approximately sorted” shortcuts.
- No argv / walk / emit — pure kernels over already-attributed rows.

## When to edit

New closed ops in the loom vocabulary, attribution shape changes, or fused
gate soundness. Verb UX lives in `surface/face/relate/`; match semantics in
`kernel/regex/`.

Design: [ADR-363](../../../../../../docs/architecture/3-decisions/363-irregex-primitives.md).

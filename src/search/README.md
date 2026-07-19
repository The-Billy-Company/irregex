---
doc_radar:
  counts:
    - description: "search keeps four kernels: match · rank · similarity · batch"
      glob: pkg/kernels/irregex/src/search/*
      unit: dirs
      equals: 4
  sentinels:
    - description: "the shared query core keeps fail-closed + immutable-after-compile"
      file: pkg/kernels/irregex/src/search/match/query.zig
      contains: ["error.Unsupported", "immutable after"]
---

# `src/search/` — pure search kernels

Match, rank, kinship, and set ops — **no argv, no walk, no emit**. Every
transport (cold CLI, warm session, FFI, bindings) compiles through here so
they cannot drift on what a hit is.

| Kernel | Job |
| ------ | --- |
| [`match/`](match) | Exact matching: `CompiledQuery` + regex ladder + SIMD scan |
| [`rank/`](rank) | **T4** weighted RRF for `gist --rank` (def-first, codegen demoted) |
| [`similarity/`](similarity) | Compression kinship: LZJD sketch · fingerprint lexicon · Ziv–Merhav zipper |
| [`batch/`](batch) | Closed set ops (ADR-363): `PatternSet` + `loom.Plan` |

## The match ladder (cheapest sound rung first)

1. **Fixed string** (`-F`, caseful) → `match/scan/` SIMD presence.
2. **Linear regex** → Thompson NFA + eager byte-class DFA; Pike VM for
   `\b` / multiline / powerset past `max_states = 4096`.
3. **PCRE2** (`-P` or `--engine auto`) for lookaround / backreferences the
   linear tier cannot express — resource-capped, hermetic vendor.

Unicode is default-on at rg parity. See
[`match/regex/README.md`](match/regex/README.md).

## Relate's kernels

- `similarity/lexicon` nominates; `similarity/zipper` decides (`relate search`).
- `similarity/sketch` is the symmetric metric behind `similar` / `dups`.
- `batch/patterns` attributes N intents exactly; its fused gate is
  **skip-only** (answers ≡ N independent searches).
- `batch/loom` shapes rows engine-side (filter → group → sort → limit).

## When to edit here

- Match semantics, prefilter soundness, DFA/Pike/PCRE caps.
- Ranking signals or class-split tie rules.
- Relate math (sketch / lexicon / zipper) or multipattern attribution.

Do not put ignore rules, flag parsing, or output coloring here — that is
`runtime/cold/`. Design rules:
[ADR-363](../../../../../docs/architecture/3-decisions/363-irregex-primitives.md).

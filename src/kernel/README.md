---
doc_radar:
  counts:
    - description: "ten ward tier packages under kernel/ (math…compose); transitional empty match/ shell may still be present"
      glob: pkg/kernels/irregex/src/kernel/*
      unit: dirs
      min: 10
      max: 11
  sentinels:
    - description: "the shared query core keeps fail-closed + immutable-after-compile"
      file: pkg/kernels/irregex/src/kernel/query/query.zig
      contains: ["error.Unsupported", "immutable after"]
    - description: "the regex package is sealed through its entry file"
      file: pkg/kernels/irregex/contract/irregex.ward
      contains: "seal kernel/regex through regex.zig"
---

# `src/kernel/` — pure search kernels

Algorithms and math — **no argv, no walk, no emit, no filesystem**. Every
transport (cold CLI, warm session, FFI, bindings) compiles through here so they
cannot drift on what a hit is. The ward declares **ten tiers**, low→high; an
import may only point back down the page. `compose/` is the only tier allowed
to know all the others.

| Package | Job |
| ------- | --- |
| [`math/`](math) | **The math floor** — bits, mix, pure glob matcher, crest sieve, misread, forest, lease, parallel, succinct structures. Arithmetic with no product opinion. |
| [`scan/`](scan) | SIMD scanners + the literal-lane vocabulary they share with the regex composer |
| [`regex/`](regex) | **THE regex package** — parser, linear engines (dfa/pike/ladder/sieve/symbolic/parabix/caliper/shuffle), PCRE2 bridge, `matcher.zig` meta dispatcher; sealed through `regex.zig`. Ambition: beat rust-regex |
| [`query/`](query) | Shared compiled query every transport compiles through |
| [`rank/`](rank) | Result fusion + per-language definition signals (`gist --rank`) |
| [`slate/`](slate) | Many patterns in one walk (was `batch/`) — `patterns` · `muster` · `trawl` · `loom` |
| [`anatomy/`](anatomy) | Source anatomy — comment spans, identifier tokens, structural leans |
| [`kinship/`](kinship) | Compression-as-similarity: `metric/` · `cluster/` · `recall/` |
| [`codex/`](codex) | Compression codebook math (FM-index, wavelet, RRR, SA-IS) — seals payloads with the wire floor |
| [`compose/`](compose) | Set algebra over candidate sets — exact-before-statistical (ADR-367) |

## The match ladder (cheapest sound rung first)

1. **Fixed string** (`-F`, caseful) → `scan/` SIMD presence.
2. **Linear regex** → Thompson NFA + byte-class DFA; Pike VM for multiline /
   oracle; optional accelerator rungs (shuffle, parabix, sieve, …).
3. **PCRE2** (`-P` or `--engine auto`) for lookaround / backreferences.

Unicode is default-on at rg parity. See [`regex/README.md`](regex/README.md).
The seam deliberately mirrors the rust-regex ecosystem: `regex/` ≈
regex-syntax + regex-automata; sibling `scan/` ≈ memchr + aho-corasick + teddy;
sibling `query/` ≈ the meta engine.

## Relate's kernels

- `kinship/recall/lexicon` nominates; `kinship/recall/zipper` decides.
- `kinship/metric/sketch` is the symmetric metric behind `similar` / echoes.
- `slate/patterns` attributes N intents exactly; its fused gate is **skip-only**.
- `slate/loom` shapes rows engine-side (filter → group → sort → limit).
- `compose/` narrows a typed `CandidateSet` before kinship/coverage run inside.

## When to edit here

Match semantics, prefilter soundness, DFA/Pike/PCRE caps, ranking signals,
relate math, multipattern attribution, composition algebra. Do **not** put
ignore rules, flag parsing, or output coloring here — that is `exec/cold/` /
`corpus/`. Design: [ADR-363](../../../../../docs/architecture/3-decisions/363-irregex-primitives.md).

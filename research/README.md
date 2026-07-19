---
doc_radar:
  counts:
    - description: "research keeps the crest theory dossier"
      glob: pkg/kernels/irregex/research/*
      unit: dirs
      equals: 1
  sentinels:
    - description: "the Sieve Theorem write-up remains the crest authority"
      file: pkg/kernels/irregex/research/crest/PROOF.md
      contains: "Sieve"
---

# `research/` — theory dossiers (not production code)

Writing that backs novel claims in the kernel. Production math and wiring
live under `src/`; harnesses live under `bench/`. If you need a behavior
change, edit source — then update the dossier if the claim moved.

| Dossier | About |
| ------- | ----- |
| [`crest/`](crest) | Crest sieve: Sieve Theorem proof, prior art, testing narrative |

Crest production code: [`../src/math/crest.zig`](../src/math/crest.zig) +
[`../src/index/crest/`](../src/index/crest/). Production harness:
`zig build crest` / [`../bench/crest/`](../bench/crest/).

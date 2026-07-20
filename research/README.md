---
doc_radar:
  counts:
    - description: "research keeps the crest + gist + relate theory dossiers"
      glob: pkg/kernels/irregex/research/*
      unit: dirs
      equals: 3
  sentinels:
    - description: "the Sieve Theorem write-up remains the crest authority"
      file: pkg/kernels/irregex/research/crest/PROOF.md
      contains: "Sieve"
    - description: "the gist composition claim remains the product-scope authority"
      file: pkg/kernels/irregex/research/gist/CLAIM.md
      contains: "systems/workload composition"
    - description: "the relate composition claim remains the compression-as-search authority"
      file: pkg/kernels/irregex/research/relate/CLAIM.md
      contains: "compression kinship"
---

# `research/` — theory dossiers (not production code)

Writing that backs claims in the kernel. Production math and wiring live
under `src/`; harnesses live under `bench/`. If you need a behavior change,
edit source — then update the dossier if the claim moved.

| Dossier | About |
| ------- | ----- |
| [`crest/`](crest) | Crest sieve: Sieve Theorem proof, prior art, testing narrative |
| [`gist/`](gist) | Gist product claim: composition scope, prior-art landscape, evidence story |
| [`relate/`](relate) | Relate compression-as-search: Language Trees lineage, prior art we used, evidence |

Crest production code: [`../src/math/crest.zig`](../src/math/crest.zig) +
[`../src/index/crest/`](../src/index/crest/). Production harness:
`zig build crest` / [`../bench/crest/`](../bench/crest/).

Gist production face: [`../src/cli/gist/`](../src/cli/gist/). Evidence:
[`../bench/gates/`](../bench/gates/), [`../bench/rgsuite/`](../bench/rgsuite/),
[`../bench/certify/`](../bench/certify/).

Relate production face: [`../src/cli/relate/`](../src/cli/relate/). Engines:
[`../src/search/similarity/`](../src/search/similarity/). Evidence:
[`../bench/relate/`](../bench/relate/).

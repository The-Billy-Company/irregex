---
doc_radar:
  counts:
    - description: "research keeps the crest + gist + relate + ceiling + automata + pincer theory dossiers"
      glob: pkg/kernels/irregex/research/*
      unit: dirs
      equals: 6
  sentinels:
    - description: "the closed-roads record remains the authority on routes already shut"
      file: pkg/kernels/irregex/research/ceiling/CLOSED.md
      contains: "Closed roads"
    - description: "the Sieve Theorem write-up remains the crest authority"
      file: pkg/kernels/irregex/research/crest/PROOF.md
      contains: "Sieve"
    - description: "the gist composition claim remains the product-scope authority"
      file: pkg/kernels/irregex/research/gist/CLAIM.md
      contains: "systems/workload composition"
    - description: "the relate composition claim remains the compression-as-search authority"
      file: pkg/kernels/irregex/research/relate/CLAIM.md
      contains: "compression kinship"
    - description: "the automata dossier remains the authority on the machine algebra and the competitive program against regex-automata"
      file: pkg/kernels/irregex/research/automata/CLAIM.md
      contains: "SP-quotient sieve is ours"
    - description: "the pincer dossier remains the authority on anchor selection — it keeps the independence diagnosis, the measured limit of the separation tie-break, and an honest integration status"
      file: pkg/kernels/irregex/research/pincer/PROOF.md
      contains:
        - "Independence is assumed and text violates it"
        - "a tie-break, not a selectivity model"
        - "Not yet integrated"
---

# `research/` — claim, ancestry, and falsification

This is irregex's research record, not production code. Each dossier separates
three questions that engineering prose too often collapses: **what useful
thing did we build, what did the world already know, and what evidence could
prove us wrong?** Production math and wiring live under `src/`; executable
evidence lives under `bench/`.

| Dossier               | Research program                                                                                                                                                                                     |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`crest/`](crest)     | new mathematics: [Sieve Theorem](crest/PROOF.md), [prior-art review](crest/PRIOR_ART.md), and [falsification strategy](crest/TESTING.md)                                                             |
| [`gist/`](gist)       | agent-loop exact search: [product claim](gist/CLAIM.md), [competitive ancestry](gist/PRIOR_ART.md), and [evidence story](gist/TESTING.md)                                                            |
| [`relate/`](relate)   | compression-as-search: [product claim](relate/CLAIM.md), [Language Trees lineage](relate/PRIOR_ART.md), and [evidence story](relate/TESTING.md)                                                      |
| [`ceiling/`](ceiling) | the scan speed limit: [what the field reaches](ceiling/PRIOR_ART.md), [which routes past it are shut](ceiling/CLOSED.md), and [where the compiler cost more than the algorithm](ceiling/LOWERING.md) |
| [`automata/`](automata) | the machine algebra: [where the package belongs](automata/README.md), [`regex-automata` dissected](automata/PRIOR_ART.md), [what we take and what is ours](automata/CLAIM.md), and [how each claim dies](automata/TESTING.md) |
| [`pincer/`](pincer)   | which two bytes the vector unit compares: [the measured defect and the calibrating repair](pincer/PROOF.md), [rare-byte ancestry](pincer/PRIOR_ART.md), and [the adverse tests](pincer/TESTING.md) |

Read each row left to right: the claim earns attention, prior art limits what
is ours, and testing decides whether the implementation deserves the claim.
The fourth row is the exception that proves the shape — `ceiling/` defends no
shipped thing. It holds a measured limit and a record of closed routes, so
that dead ends cost a citation to rediscover instead of a month.
If behavior changes, edit source first; then update the dossier only where the
claim or evidence truly moved.

Crest production code: [`../src/kernel/math/crest.zig`](../src/kernel/math/crest.zig) +
[`../src/corpus/index/crest/`](../src/corpus/index/crest/). Production harness:
`zig build crest` / [`../bench/crest/`](../bench/crest/).

Gist production face: [`../src/surface/face/gist/`](../src/surface/face/gist/). Evidence:
[`../bench/gates/`](../bench/gates/), [`../bench/rgsuite/`](../bench/rgsuite/),
[`../bench/certify/`](../bench/certify/).

Relate production face: [`../src/surface/face/relate/`](../src/surface/face/relate/). Engines:
[`../src/kernel/kinship/`](../src/kernel/kinship/). Evidence:
[`../bench/knn/`](../bench/knn/).

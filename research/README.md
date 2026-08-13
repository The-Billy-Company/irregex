# `research/` — Claim, Ancestry, and Falsification

This is irregex's research record, not production code. Each dossier separates three questions that engineering prose too often collapses: what useful thing got built, what the world already knew, and what evidence could prove it wrong. Production math and wiring live under `src/`; executable evidence lives under `bench/`.

Read each dossier left to right: the claim earns attention, prior art limits what is ours, and testing decides whether the implementation deserves the claim.

- **[`crest/`](crest)** makes the new-mathematics claim, carried across a [Sieve Theorem proof](crest/PROOF.md), a [prior-art review](crest/PRIOR_ART.md), and a [falsification strategy](crest/TESTING.md).
- **The exact-search face's own `research/`** (its sibling repo) documents agent-loop exact search — the product claim, its competitive ancestry, and its evidence story, in that package's `research/{CLAIM,PRIOR_ART,TESTING}.md`.
- **The kinship package's own `research/`** (its sibling repo) documents compression-as-search — the product claim, its lineage from *Language Trees and Zipping*, and its evidence story, in that package's `research/{CLAIM,PRIOR_ART,TESTING}.md`.
- **[`ceiling/`](ceiling)** documents the scan speed limit, spanning [what the field reaches](ceiling/PRIOR_ART.md), [which routes past it are shut](ceiling/CLOSED.md), and [where the compiler cost more than the algorithm](ceiling/LOWERING.md).
- **[`automata/`](automata)** documents the machine algebra, spanning where the package belongs, a [dissection of `regex-automata`](automata/PRIOR_ART.md), [what we take and what is ours](automata/CLAIM.md), and [how each claim dies](automata/TESTING.md).
- **[`pincer/`](pincer)** documents which two bytes the vector unit compares, spanning [the measured defect and its calibrating repair](pincer/PROOF.md), [rare-byte ancestry](pincer/PRIOR_ART.md), and [the adverse tests](pincer/TESTING.md).
- **[`seams/`](seams)** documents the bytes a type does not own, spanning [the prediction written before the sweep](seams/PREDICTION-1-seams.md) and [every byte-view site classified by what it reaches](seams/RESULT-1-seams.md) — a defect class rather than a component, opened because one of the two record types that leaked process memory into a sibling's persisted artifact was ours.

`ceiling/` is the exception that proves the shape: it defends no shipped thing. It holds a measured limit and a record of closed routes, so a dead end costs a citation to rediscover instead of a month.

If behavior changes, edit source first, then update the dossier only where the claim or evidence truly moved.

## Where the Code and Evidence Live

Crest's production code lives at [`../src/kernel/math/crest.zig`](../src/kernel/math/crest.zig) and [`../src/corpus/index/crest/`](../src/corpus/index/crest/), and its harness runs as `zig build crest` from [`../bench/rungs/crest/`](../bench/rungs/crest/).

The exact-search face's production code lives at its own `src/surface/face/` in the sibling repo, with evidence under that package's `bench/conformance/gates/`, `bench/conformance/rgsuite/`, and `bench/certificate/`.

The kinship face's production code lives at its own `src/surface/face/` in the sibling repo, its kinship engines at that package's `src/kernel/kinship/`, and its evidence under its `bench/`.

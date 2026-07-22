---
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/kernel/primitives/crest.zig
    - pkg/kernels/irregex/src/kernel/primitives/crest_test.zig
    - pkg/kernels/irregex/src/corpus/index/crest/sidecar.zig
    - pkg/kernels/irregex/bench/crest/bench.zig
  sentinels:
    - file: pkg/kernels/irregex/build.zig
      contains:
        - 'b.step("crest"'
    - file: pkg/kernels/irregex/src/kernel/primitives/crest.zig
      contains:
        - "pub fn ghat"
        - "pub fn crest"
        - "pub fn pruned"
    - file: pkg/kernels/irregex/src/surface/exec/cold/engine/serial.zig
      contains:
        - "crestSieve"
---

# Crest — forced-class-run pruning

A **sound necessary condition** for regex candidate pruning that fires exactly
where the trigram index concedes a full scan: literal-free class repetitions
(`[0-9a-f]{8}`, `[0-9]{6}`, `[A-Z]{4}` — the gist Certificate's
`regex-classcount` hole, cand% = 100%).

Per document, index the **crest vector** — the longest consecutive run per
byte-class (8 classes, 16 bytes/doc). Per query, extract the **forced crest**
`ĝ(R)` — the run every accepted string must contain — by a min-of-max
prefix/suffix/best algebra over the AST. Prune when the document's crest falls
below the forced crest: `k` integer compares, no byte scan, provably no false
negatives.

## This folder (research: writing + proofs only)

| file           | role                                                                                                                                                                    |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PROOF.md`     | definitions, Sieve Theorem, forced-crest calculus + soundness lemma, alphabet contract, selectivity model, measured results                                             |
| `PRIOR_ART.md` | the full adversarial prior-art review: every neighboring family, why each is a different object, the referee verdict                                                    |
| `TESTING.md`   | the complete testing story: unit calculus tests, sidecar codec adversarial tests, corpus-wide fail-closed soundness, randomized sweeps, ablation, reproduction commands |

## The code (lives with the system, not here)

| where                                                | what                                                                                                                    |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `src/kernel/primitives/crest.zig`                    | pure kernel: class lattice, crest vector, profile calculus, parser, `ghat`, and `pruned`                                |
| `src/corpus/index/crest/sidecar.zig`                 | persisted per-document crest table (`crest.bin`), generation-atomic with the trigram pair                               |
| `src/surface/exec/cold/engine/{serial,parallel}.zig` | `crestSieve` and both read-elision oracles, composed with trigram candidates and freshness                              |
| `bench/crest/bench.zig`                              | production proof harness (`zig build crest`) — fail-closed soundness, pruning, speed, and ablation over the live corpus |

## Run

```bash
cd pkg/kernels/irregex
zig build crest       # proof harness over the live corpus → .local/gist-verify/crest.csv
zig build test        # kernel + sidecar unit tests ride the main suite
gist index            # persists crest.bin beside index.gist
gist '[0-9a-f]{12}'   # the sieve elides pruned reads in production
```

## Measured (Apple Silicon, ReleaseFast, 52.7k files / 494 MiB)

Narrow-class repetitions: **91–95% of files pruned, 8–15× wall-clock** vs the
real matcher's full scan, with **0 false negatives** (fail-closed, corpus-wide

- 48k randomized pairs across both engine modes). Wide classes (`\w{3,8}`):
  ≈0% pruned, ≈1× — the honest scope boundary. The count-population cousin at
  the same thresholds prunes ≤1% on hex-8 vs Crest's 91% — the _run_ is the
  operative condition. Full table: `PROOF.md` §5.

## Status

**Integrated (single-run sieve).** Referee-verified novel (adversarial
prior-art review, 2026-07-19 — `PRIOR_ART.md`). `gist index` persists the crest
sidecar; both the serial and parallel engines prune candidates with it
(caseless disables the sieve; Unicode mode certifies only alphabet-safe
constructs — the Alphabet Contract, `PROOF.md` §3.7). Lineage:
`spikes/classrun-formula/` (Python reference + 240k-pair property
suite + originality dossier).

**Two proven extensions (`PROOF.md` §3.6, §7).** (1) An _independent exact
oracle_ — `g(R,C)` by NFA × run-monitor emptiness — shows the shipped forced-run
calculus is **98% exactly tight** against the true language minimum, not merely
sound. (2) The forced-run **spectrum** (Ridge): store the top-q maximal runs
per class and force a run _multiset_ via a gap-aware `all_out` calculus, so
`[0-9]{4}-[0-9]{2}-[0-9]{2}` forces `digit:{4,2,2}` — pruning multi-field
tokens Crest's single run cannot (+5.9pp on dates, no regression on single-run
queries). Referee 2026-07-20: no collision, re-scoped to the run-order-statistic

- multiset calculus (`PRIOR_ART.md` §8). Lineage + reproduction:
  `spikes/ridge-spectrum/`.

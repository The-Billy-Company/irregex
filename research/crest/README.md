# Crest — forced-class-run pruning

A **sound necessary condition** for regex candidate pruning that complements
Gist's required-literal trigram extractor on literal-free class repetitions
(`[0-9a-f]{8}`, `[0-9]{6}`, `[A-Z]{4}` — the Certificate's current
`regex-classcount` hole). A different n-gram implementation could enumerate a
large OR-union of class trigrams; Crest avoids that expansion.

Per document, index the **crest vector** — the longest consecutive run per
family member (eight byte classes × two alphabets, 32 bytes/doc; the second
alphabet is what lets `\d` prune under the engine's Unicode default). Per
query, extract the **forced crest**
`ĝ(R)` — the run every accepted string must contain — by a min-of-max
prefix/suffix/best algebra over the AST, **one per top-level alternative**,
since `R₁|R₂` obliges a match to satisfy only one of them. Prune a document
whose crest falls below every alternative's forced crest: `k` integer compares
per branch, no byte scan, provably no false negatives.

## This folder (research: writing + proofs only)

| file           | role                                                                                                                                                                    |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PROOF.md`     | definitions, Sieve Theorem, forced-crest calculus + soundness lemma, alphabet contract, selectivity model, measured results                                             |
| `PRIOR_ART.md` | dated, search-qualified prior-art review: neighboring families, databases, terms, and exclusions                                                                        |
| `TESTING.md`   | the complete testing story: unit calculus tests, sidecar codec adversarial tests, corpus-wide fail-closed soundness, randomized sweeps, ablation, reproduction commands |

## The code (lives with the system, not here)

| where                                 | what                                                                                                                       |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `src/kernel/math/crest.zig`           | pure kernel: fixed class family, crest vector, the `Swell` disjunction, and the dominance test                             |
| `src/kernel/regex/analysis/swell.zig` | the query half: `forcedSwell` folds ĝ out of the engine's own AST, one per top-level alternative                           |
| `src/corpus/index/crest/sidecar.zig`  | persisted per-document crest table (`crest.bin`), generation-atomic with the trigram pair                                  |
| `src/exec/cold/writ/gate.zig`         | `winnow` — the query's swell and its cover plan off ONE parse, each stood down wherever pruning would be unsound           |
| `src/exec/cold/quarry/elide.zig`      | the read-elision oracle both cold schedulers admit: crest sieve composed with trigram candidates and the freshness proof   |
| `src/exec/session/answer/gather.zig`  | the resident twin of that oracle — the daemon prunes by the same swell, from the mirror's own ρ(d) rather than the sidecar |
| `bench/rungs/crest/bench.zig`         | production proof harness (`zig build crest`) — fail-closed soundness, pruning, speed, and ablation over the live corpus    |

## Run

```bash
cd <irregex-repo-root>
zig build crest       # exploratory proof → .local/crest-evidence/
zig build test        # kernel + sidecar unit tests ride the main suite
gist index            # persists crest.bin beside index.gist
gist '[0-9a-f]{12}'   # the sieve elides pruned reads in production
python3 bench/rungs/crest/evidence/crest_evidence.py package
# clean committed HEAD only: revision-bound source, tests, measurements, monograph
```

## Evidence is revision-bound

The repair changes candidate selectivity, so this document carries no inherited
performance table. `crest_evidence.py package` refuses a dirty tree, runs the
real matcher proof and tests, captures every timing sample, corpus-content
manifest, machine/filesystem/cache conditions, seeds, matcher differentials,
and `crest.csv`, then renders a monograph only from that committed revision.
See `PROOF.md` §5 and `bench/rungs/crest/evidence/README.md`.

## Status

**Integrated (single-run sieve, disjunctive over alternatives).** A dated adversarial search found no prior
instance of the full composite as of 2026-07-20 (`PRIOR_ART.md`); that is not
proof of global novelty. `gist index` persists the Crest
sidecar; both the serial and parallel engines prune candidates with it
(caseless keeps case-closed certificates and self-declines unsafe folds;
Unicode mode certifies only alphabet-safe constructs — the Alphabet Contract,
`PROOF.md` §3.7). Lineage: a Python reference sieve, cleared by a 240,000-pair
randomized property suite against Python `re` with zero false negatives, plus
the count-cousin ablation and an originality dossier. That spike is not in this
repo; `bench/rungs/crest/` proves the same soundness against the shipped matcher
instead.

**Two research extensions (`PROOF.md` §3.6, §7).** (1) An _independent exact
oracle_ — `g(R,C)` by NFA × run-monitor emptiness — checks soundness and
tightness; its pre-repair percentage is historical and must be rerun before it
is attributed to this calculus. (2) The forced-run **spectrum** (Ridge): store
the top-q maximal runs
per class and force a run _multiset_ via a gap-aware `all_out` calculus, so
`[0-9]{4}-[0-9]{2}-[0-9]{2}` forces `digit:{4,2,2}` — pruning multi-field
tokens Crest's single run cannot (+5.9pp on dates, no regression on single-run
queries). Referee 2026-07-20: no collision, re-scoped to the run-order-statistic

- multiset calculus (`PRIOR_ART.md` §8). Both extensions came from one Python
  spike that does not ship here: it carried the gap-aware segment calculus, the
  NFA×monitor oracle (5,224 forced-run checks, sound on every one, 98.2% exactly
  tight), a 160,000-pair sieve property suite with zero false negatives, and the
  base-vs-ridge corpus bench `PROOF.md` §7.4 tabulates. Nothing in this
  repository re-runs it.

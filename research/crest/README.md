# Crest — Forced-Class-Run Pruning

Crest is a sound necessary condition for regex candidate pruning that complements this engine's required-literal trigram extractor on literal-free class repetitions such as `[0-9a-f]{8}`, `[0-9]{6}`, and `[A-Z]{4}`, the Certificate's `regex-classcount` hole. A different n-gram implementation could enumerate a large OR-union of class trigrams instead; Crest avoids that expansion.

Per document, v6 indexes the top four maximal runs for 48 fixed predicates:
15 workload predicates over ASCII/scalar/codepoint alphabets plus exact pinned-
UCD `Nd`, `Letter`, and `White_Space` lanes. Per query, a bounded Pareto
compiler extracts the forced run spectrum each accepted branch must contain.
Production remains at `q=1`, `B=8`; q=4 is implemented end to end but cannot be
promoted before held-out corpus and query-trace evidence.

The prune rule follows directly: a document whose crest falls below every alternative's forced crest cannot match. That costs `k` integer compares per branch, no byte scan, and is provably free of false negatives.

## Why This Is A New Object

Every surveyed production candidate filter reduces a pattern to required substrings and tests presence, so a pattern with no extractable literal degenerates to a full scan; this engine's own trigram prefilter is in that family, and its Certificate records the hole honestly at `cand% = 100%` on `regex-classcount`.

The closest published neighbor, Bannai et al.'s *Text Indexing for Simple Regular Expressions* (CPM 2025), does index text by class-run structure, so that idea is prior art and Crest does not claim to originate it. Their indexed object is a window of `k` distinct symbols rather than the longest run of a fixed class, they store no per-document signature, and their exactness theorem requires an anchor outside the class; Crest's motivating query, `[0-9a-f]{12}`, is exactly the anchorless case their own lower bound proves has no efficient exact index, which is why a false-positive-tolerant sieve occupies different ground.

A dated adversarial search (2026-07-20) found no instance of the complete composite: a per-document max-run signature, a regex-derived sound forced-run functional, and a componentwise no-false-negative sieve, taken together. That is a reproducible search result, not proof of global novelty; the full review, every neighboring family, and the exclusions are in [`PRIOR_ART.md`](PRIOR_ART.md).

Crest deliberately does not claim to subsume the trigram index; it is complementary, since literals still win where they exist. It is a filter, never a matcher, and its calculus is sound but not tight.

## The Disjunctive Sieve

A single forced-crest vector is a weaker query language than the grammar supplies, because folding `R₁|R₂` into one componentwise minimum discards which branch a match actually satisfies. Multi-pattern search reaches the engine as one alternation, so before this fix every multi-pattern query collapsed to an all-zero vector and ran with the sieve silently disarmed.

The fix keeps the branches apart. The *swell* is one forced crest per top-level alternative, and a document is pruned only when it clears none of them, which is never less selective than the folded version and is often far more so.

## The Ridge Extension

Crest indexes only the single longest run per class, so it cannot force two disjoint runs, and a query like `[0-9]{4}-[0-9]{2}-[0-9]{2}` wants a forced digit multiset `{4,2,2}` rather than one scalar. Ridge lifts the crest vector to the top-`q` longest distinct maximal runs per class and derives a forced-run multiset from the AST instead of a single number.

Measured on a 14,498-file, 250 MiB spike corpus at `q=4`, the extra index costs 0.35% of the corpus (four times Crest's own 0.09%). The date query rises from 58.1% pruned at `q=1` to 64.0% at `q=4`, a gain of 5.9 percentage points, with no regression on single-run queries: `ĝ_1(R,C)` is unchanged, so Ridge only adds lower-ranked forced runs.

An independent adversarial referee pass on 2026-07-20 found no collision for Ridge, with two honest downgrades: it is a strict generalization of Crest rather than an independent object, and the dominance-sieve *shape* itself is anticipated by the count-histogram family. The surviving novelty is the run order-statistic quantity plus the gap-aware forced-run-multiset calculus; see [`PRIOR_ART.md`](PRIOR_ART.md) §8 for the full re-scoping.

## Measured Results

Making `\d`, `\w`, and `\s` certify over the engine's Unicode default rather than declining to speak turned a real gap into real pruning. Ablated on the 21,854-file corpus, `\d{6}` moves from 0.0% pruned to 73.7% (2.12×), `\d{4}` from 0.0% to 52.8% (2.13×), `\s{4}` from 0.0% to 5.5% (1.04×), and `\w{8}` from 0.0% to 1.4% (1.07×), while the ASCII-only `[0-9]{6}` twin stays at 92.7% throughout.

A separate grammar-contract bug, found by referee, mattered more than any of those numbers. A private mini-parser inside the kernel read `\<` and `\>` as escaped literals rather than the word-boundary assertions the matcher actually treats them as, so `\<foo\>` returned 700 files where the unsieved scan returned 2,200, silently eliding 1,500 real matches. The fix moved the calculus out of the kernel and into the engine's own analysis layer so there is no second grammar left to diverge from.

Per-byte scanning is latency-bound rather than throughput-bound: a single scan runs at 4.4 cycles per byte, and splitting a document into four interleaved chains that rejoin exactly by the same run algebra the query side uses reaches 1.87 GiB/s single-threaded (2.56× over one piece, 1.62× over the scalar per-byte reference) and cuts a sharded whole-corpus index build from 45.4 ms to 19.1 ms (2.38×), byte-identical on all 21,854 documents.

## Companion Documents

[`PROOF.md`](PROOF.md) carries the definitions, the Sieve Theorem, the forced-crest calculus and its soundness lemma, the Alphabet Contract, the selectivity model, and the measured results, including the Ridge extension.

[`PRIOR_ART.md`](PRIOR_ART.md) is the dated, search-qualified prior-art review: the neighboring families, the databases and terms searched, and what remains excluded from the claim.

[`TESTING.md`](TESTING.md) records the complete testing story, from the kernel calculus unit tests through the sidecar codec's adversarial tests to the corpus-wide fail-closed soundness sweep, the ablations, and the reproduction commands.

## Where The Production Code Lives

The pure kernel, the fixed class family, the crest vector, the `Swell` disjunction, and the dominance test all live in [`../src/kernel/math/crest.zig`](../../src/kernel/math/crest.zig). The query half, `forcedSwell`, folds `ĝ` out of the engine's own AST, one vector per top-level alternative, in [`src/kernel/regex/analysis/swell.zig`](../../src/kernel/regex/analysis/swell.zig).

The generation-bound `crest.bin` codec lives in
[`src/corpus/index/crest/sidecar.zig`](../../src/corpus/index/crest/sidecar.zig);
`builder.zig`, `columnar.zig`, `planner.zig`, and `runtime.zig` complete the
index-to-execution path. `src/exec/cold/writ/gate.zig`'s `winnow` builds the
q=1 production projection and its cover plan off one parse, standing each down
wherever pruning would be unsound.

`src/exec/cold/quarry/elide.zig` is the read-elision oracle both cold schedulers admit, composing the crest sieve with trigram candidates and the freshness proof, and `src/exec/session/answer/gather.zig` is the resident twin that prunes by the same swell from the mirror's own crest vector rather than the sidecar. `bench/rungs/crest/bench.zig` is the production proof harness (`zig build crest`): fail-closed soundness, pruning, speed, and ablation over the live corpus.

## Run

Reproduce the proof harness and the persisted index from the repository root.

```bash
cd <irregex-repo-root>
zig build crest       # exploratory proof → .local/crest-evidence/
zig build test        # kernel + sidecar unit tests ride the main suite
<face> index          # persists crest.bin beside the trigram index
<face> '[0-9a-f]{12}' # the sieve elides pruned reads in production
python3 bench/rungs/crest/evidence/crest_evidence.py package
```

The last command is the only committed-HEAD source of numbers: revision-bound source, tests, measurements, and monograph.

## Evidence Is Revision-Bound

The repair changes candidate selectivity, so this document carries no inherited performance table. `crest_evidence.py package` refuses a dirty tree, runs the real matcher proof and tests, captures every timing sample, the corpus-content manifest, the machine and filesystem and cache conditions, the seeds, the matcher differentials, and `crest.csv`, then renders a monograph only from that committed revision. See §5 of [`PROOF.md`](PROOF.md) and `bench/rungs/crest/evidence/README.md`.

## Status

Crest is integrated with q=1 as the production query default and q=4 carried
end to end for held-out evaluation. A dated adversarial search found no prior
instance of the full composite as of 2026-07-20 (`PRIOR_ART.md`), which is not
proof of global novelty. An index build persists the columnar v6 sidecar, and
both cold read-elision paths consume it through the cost-gated runtime;
caseless and Unicode analysis retain the Alphabet Contract (`PROOF.md` §3.7).

The lineage is a Python reference sieve, cleared by a 240,000-pair randomized property suite against Python `re` with zero false negatives, plus the count-cousin ablation and an originality dossier. That spike is not in this repository; `bench/rungs/crest/` proves the same soundness against the shipped matcher instead.

The independent exact automata oracle now ships under `oracle/`, explicitly
refuses assertions, and differentially referees q=1/q=2/q=4 compiler output.
Training, mutation, and revision-bound publication tooling also ship here.
Historical tightness/selectivity figures remain lineage only: current corpus
q1/q4, adaptive-dictionary, and planner evidence is explicitly pending and
cannot promote production defaults.

Corpus-independent reproduction:

```bash
mise exec -- zig build check --summary failures
python3 -m unittest discover -s research/crest/evidence -p 'test_*.py'
PYTHONPATH=research/crest/training python3 -m unittest discover \
  -s research/crest/training/tests -p 'test_*.py'
python3 -m unittest discover -s research/crest/mutation -p 'test_*.py'
uv run --project bindings/python --python 3.13 --only-group dev \
  python -m pytest research/crest/oracle/tests -q
```

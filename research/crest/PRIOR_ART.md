# Crest — prior art (the full adversarial review)

**Claim under review.** A per-document signature `ρ(d) ∈ ℕ^k` of maximal
*consecutive-class-run* lengths over a fixed class lattice, paired with a sound
lower-bound *forced-crest* functional `ĝ(R,·) ∈ ℕ^k` extracted from the regex
by a segment-composition run algebra, such that `R` can match inside `d`
**only if** `ρ(d) ≥ ĝ(R)` componentwise.

**Verdict:** NOVEL as a composite (adversarial referee review, 2026-07-19).
Every ingredient is deliberately standard; the *object* — forced-run
per-document indexing as a regex necessary condition — has no published equal
we could find. This file is the paper trail: each neighboring family, what it
actually does, and the load-bearing difference. Every external source is
listed with a link and annotation in [§ References](#references).

The review process: every idea was submitted to an independent adversarial
referee (Grok 4.5 subagent) instructed to kill it — find the paper, the
system, or the folklore trick that already is this object. The families below
are everything the referee and our own sweeps surfaced. Web sweeps ran
continuously through design (2026-07); search terms included every phrasing of
"run-length regex index", "counting constraint prefilter", "character class
repetition index", "necessary condition regex pruning", "forced substring
automaton", and the systems literature by name.

---

## 1. N-gram presence indexes (the family Crest complements)

The dominant paradigm: reduce the pattern to **required substrings**, test
substring *presence* in an inverted index.

| system | mechanism | why it is not Crest |
|---|---|---|
| [Cox 2012](#r-cox-trigram) / [codesearch](#r-codesearch) | required trigram sets, AND/OR query over an inverted trigram index | a pattern with no extractable trigram (`[0-9a-f]{8}`) degenerates to *scan everything*; the index stores presence, never run structure |
| [PostgreSQL `pg_trgm`](#r-pg-trgm) | color-trigram graph extracted from the regex's CFA | same degeneration: no literal ⇒ no trigrams ⇒ full scan |
| [RE2](#r-re2) `FilteredRE2` / `PrefilterTree` | required "atoms" of `min_atom_len ≥ 3`, boolean prefilter tree | patterns yielding no atom are marked `unfiltered_` — always scanned |
| [Zoekt](#r-zoekt) (Sourcegraph) | positional trigram index | presence + position of trigrams; class repetitions yield none |
| [GitHub Blackbird](#r-blackbird) | sparse n-gram selection over code | same object class: substring presence |
| [REI](#r-rei) (SIGMOD 2025), [Zhang et al. 2025](#r-zhang) | learned / cost-based *selection* of which n-grams to index | optimizes the same presence test; concedes the same literal-free hole |
| gist's own trigram prefilter (`src/search/match/query.zig`) | Cox-family required-trigram intersection | the Certificate records the hole honestly: `cand% = 100%` on `regex-classcount` |

**Difference.** All of these answer "does the document contain substring s?"
Crest answers "does the document contain a *run of class-C bytes at least r
long*?" — a property no substring test expresses (the run may be any of
`|C|^r` strings; enumerating is exponential, and presence of any particular
one is neither necessary nor implied). Conversely Crest extracts nothing from
literal-rich patterns — the two filters own complementary pattern families,
which is why the integration *intersects* survivor sets.

## 2. Scan-time counting automata (matcher-layer, not index-layer)

| work | mechanism | why it is not Crest |
|---|---|---|
| [MIN-MAX counter automata](#r-minmax) (IEEE TPDS 2012+) | counters in the automaton track repetition bounds at match time | makes the *matcher* cheap on `C{n,m}`; builds **no per-document index**, prunes **no documents** — every byte of every document is still visited |
| [Counting-set automata](#r-csa2020) (OOPSLA 2020) / [synchronizing CSA](#r-csa2023) | set-valued counters determinize counting constraints | same layer: scan-time state compression, zero index-time artifact |
| [Hyperscan](#r-hyperscan) (Intel) | SIMD multi-pattern scan, FDR/Teddy literal engines | literal-anchored acceleration of the scan itself; class repetitions without literals get no prefilter |

**Difference.** These are *how to run the automaton faster once you are
reading the bytes*. Crest is *how to never read the bytes*. The layers
compose: a counting matcher still benefits from Crest's candidate pruning.

## 3. Run-length structures in string indexing (different query class)

| work | mechanism | why it is not Crest |
|---|---|---|
| [SBC-tree](#r-sbc) (RLE-string indexing) | index runs of *one repeated character* for substring search over RLE-compressed strings | single-character runs, substring queries — not a per-class max-run vector, not a regex necessary condition |
| [RLE-BWT / r-index](#r-rindex) long-match structures | run-length-compressed BWT for pattern *location* | compression artifact of the text, not a query-derived lower bound; answers exact substring location |
| [Kolpakov–Kucherov](#r-runs) maximal-run literature | combinatorics of all maximal repetitions in a string | studies runs of *periodic factors*; no class lattice, no query-side functional, no sieve |

**Difference.** The string-index literature indexes runs to answer *substring*
queries or to compress. None derives a **forced-run lower bound from a regex
AST**, and none uses per-class max-runs as a document-pruning signature.

## 4. Segment-summary algebras (the calculus's algebraic shape, repurposed)

The `(F, P, S, minLen, all_in)` profile composes like [Bentley's 1984](#r-bentley)
maximum-subarray divide-and-conquer summary (best/prefix/suffix/total), and
like the max-plus segment trees used for longest-run-in-range queries over
*strings*. Two honest acknowledgements and the two inversions that make it a
different object:

- Those algebras summarize **one concrete string** bottom-up; Crest's profile
  summarizes **a language** (every string the regex accepts), which forces the
  min-of-max adversarial semantics: each field is a lower bound over `L(E)`,
  with `all_in` the one exact predicate licensing runs to cross seams.
- Those algebras *maximize* over positions; Crest's adversary *minimizes* over
  accepted strings. Alternation is a componentwise min (tropical sum), and
  repetition pumps optional copies to zero — neither exists in the
  single-string setting.

The regex-analysis cousin is required-literal / minimum-length extraction
([RE2](#r-re2)'s `MinMatchLength`, gist's own `analysis/` pass): also an AST
lower-bound functional, but over *length* and *literals* — never over
per-class run structure, and never paired with a per-document run index.

## 5. Sketches and signatures (Bloom, minhash, class histograms)

| object | why it is not Crest |
|---|---|
| [Bloom filters](#r-bloom) over n-grams | substring presence again, probabilistic; false positives fine, but cannot express "run ≥ r" |
| Class histograms / population counts (the "count cousin") | sound but strictly dominated: forced run `n` ⇒ forced count `≥ n`, never the reverse. Measured: hex-8 prunes 0.7% by count vs 91.4% by run (PROOF.md §3.7, §5) — kept in the harness as a permanent ablation |
| Suffix-automaton / FM-index exact tiers (gist's own codex) | exact substring machinery; a class repetition is not a substring |

## 6. Referee summary

The adversarial reviewer's final position, condensed: presence-family indexes
(§1) cannot express the property; counting automata (§2) live at the wrong
layer; run-length string structures (§3) index a different object for a
different query; the algebra (§4) is a known *shape* carrying new semantics
(language-level adversarial lower bounds with an exactness guard); and the
count cousin (§5) is the nearest sound sibling and is empirically dominated.
No single work combines: (a) a per-document per-class max-run signature,
(b) a regex-derived sound forced-run functional, (c) a componentwise-compare
sieve with a no-false-negative theorem. That composite is the contribution.

**Standing obligation.** The novelty claim is dated (2026-07-19) and was
verified against the literature reachable at that date. If a prior instance
surfaces, the correct move is to cite it and re-scope the claim — never to
quietly drop this file. The math stands regardless; only the priority claim
would change.

---

## References

Annotated bibliography for every external source above. Anchor ids match the
in-body citation links.

<span id="r-cox-trigram"></span>
1. **Cox (2012).**
   [*Regular Expression Matching with a Trigram Index*](https://swtch.com/~rsc/regexp/regexp4.html).
   *Annotation:* Required-trigram presence filter — Crest's complementary
   hole (`[0-9a-f]{8}` → full scan).

<span id="r-codesearch"></span>
2. **Google codesearch.**
   [github.com/google/codesearch](https://github.com/google/codesearch).
   *Annotation:* Open `cindex`/`csearch` of Cox's design; presence, never
   run structure.

<span id="r-pg-trgm"></span>
3. **PostgreSQL `pg_trgm`.**
   [`trgm_regexp.c` (source)](https://github.com/postgres/postgres/blob/master/contrib/pg_trgm/trgm_regexp.c).
   *Annotation:* Color-trigram graph from the regex CFA — same no-literal
   degeneration to full scan.

<span id="r-re2"></span>
4. **RE2.**
   [github.com/google/re2](https://github.com/google/re2).
   *Annotation:* `FilteredRE2` / `PrefilterTree` atoms and
   `MinMatchLength` — presence / length lower bounds, not per-class runs.

<span id="r-zoekt"></span>
5. **Zoekt.**
   [github.com/sourcegraph/zoekt](https://github.com/sourcegraph/zoekt).
   *Annotation:* Positional trigram index; class repetitions yield no
   candidates.

<span id="r-blackbird"></span>
6. **GitHub.**
   [Blackbird architecture](https://github.blog/engineering/architecture-optimization/the-technology-behind-githubs-new-code-search/).
   *Annotation:* Sparse n-gram *presence* at global scale — same object
   class as Cox/Zoekt.

<span id="r-rei"></span>
7. **Zhang, Deep, Patel & Sankaralingam (2025).**
   [*Regular Expression Indexing for Log Analysis*](https://doi.org/10.1145/3769820)
   (Proc. ACM Manag. Data / SIGMOD) ·
   [PDF](https://db.cs.cmu.edu/papers/2025/zhang-sigmod2025.pdf) ·
   [code](https://github.com/mush-zhang/REI-Regular-Expression-Indexing).
   *Annotation:* REI — n-gram indexing for log regex workloads; still a
   presence test; still concedes literal-free class repetitions.

<span id="r-zhang"></span>
8. **Zhang, Deep, Patel & Sankaralingam (2025).**
   [*An Evaluation of N-Gram Selection Strategies for Regular Expression Indexing*](https://www.vldb.org/pvldb/vol18/p5703-zhang.pdf)
   (PVLDB).
   *Annotation:* Contemporary n-gram selection study — presence family;
   Crest's hole remains.

<span id="r-minmax"></span>
9. **Wang, Pu, Knezek & Liu (2013).**
   [*MIN-MAX: A Counter-Based Algorithm for Regular Expression Matching*](https://doi.org/10.1109/tpds.2012.116)
   (IEEE Trans. Parallel Distrib. Syst.).
   *Annotation:* Speeds the *matcher* on character-class constraint
   repetitions — no per-document index, no document pruning.

<span id="r-csa2020"></span>
10. **Turoňová, Holík, Lengál, Saarikivi, Veanes & Vojnar (2020).**
    [*Regex Matching with Counting-Set Automata*](https://doi.org/10.1145/3428286)
    (OOPSLA).
    *Annotation:* Set-valued counters for counting constraints at scan
    time — wrong layer for Crest.

<span id="r-csa2023"></span>
11. **Holík, Síč, Turoňová & Vojnar (2023).**
    [*Fast Matching of Regular Patterns with Synchronizing Counting*](https://doi.org/10.48550/arxiv.2301.12851).
    *Annotation:* Synchronizing counting-set automata — further scan-time
    state compression; zero index-time artifact.

<span id="r-hyperscan"></span>
12. **Intel Hyperscan.**
    [github.com/intel/hyperscan](https://github.com/intel/hyperscan).
    *Annotation:* SIMD multi-pattern scan with literal engines — accelerates
    reading bytes, does not prune documents on class runs.

<span id="r-sbc"></span>
13. **RLE / SBC-tree string indexes.**
    Representative line: run-length-encoded text indexes for *substring*
    search (e.g. SBC-tree literature on RLE strings).
    *Annotation:* Indexes runs of one repeated character for substring
    queries — not a per-class max-run regex sieve.

<span id="r-rindex"></span>
14. **r-index / RLE-BWT.**
    [github.com/nicolaprezza/r-index](https://github.com/nicolaprezza/r-index).
    *Annotation:* Run-length BWT for pattern *location* — compression
    artifact, not a regex-derived forced-run lower bound.

<span id="r-runs"></span>
15. **Kolpakov & Kucherov (1999).**
    [*Finding maximal repetitions in a word in linear time*](https://doi.org/10.1109/SFFCS.1999.814634).
    *Annotation:* Combinatorics of maximal *periodic* runs — no class
    lattice, no query-side ĝ, no document sieve.

<span id="r-bentley"></span>
16. **Bentley (1984).**
    [*Programming pearls: algorithm design techniques*](https://doi.org/10.1145/358234.381162)
    (CACM) — maximum-subarray divide-and-conquer summary.
    *Annotation:* Best/prefix/suffix/total shape Crest's profile echoes —
    but over one string, maximizing; Crest minimizes over a language.

<span id="r-bloom"></span>
17. **Bloom (1970).**
    [*Space/time trade-offs in hash coding with allowable errors*](https://doi.org/10.1145/362686.362692)
    (CACM).
    *Annotation:* Probabilistic set membership for n-grams — cannot express
    "run of class C at least r".

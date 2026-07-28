# Crest — prior art (the full adversarial review)

**Claim under review.** A per-document signature `ρ(d) ∈ ℕ^k` of maximal
_consecutive-class-run_ lengths over a fixed class family, paired with a sound
lower-bound _forced-crest_ functional `ĝ(R,·) ∈ ℕ^k` extracted from the regex
by a segment-composition run algebra, such that `R` can match inside `d`
**only if** `ρ(d) ≥ ĝ(R)` componentwise.

**Dated search result:** no instance of the complete composite was found in the
stated adversarial search as of 2026-07-20. Every ingredient is deliberately
standard. This is not proof of absence; it is the reproducible paper trail for
the databases, search families, neighboring work, and exclusions reviewed.
Every external source is listed with a link and annotation in
[§ References](#references).

**Extension verdict:** the run-_spectrum_ lift (Ridge — top-q maximal-run order
statistics + forced-run multiset, `PROOF.md` §7) drew a second referee pass on
2026-07-20: **PARTIAL / no collision**, re-scoped in §8. The count-sieve
_shape_ (§7) and the exact oracle's automata machinery are cited, not claimed;
the surviving novelty is the run order-statistic quantity + gap-aware
forced-run-multiset calculus.

The review process: every idea was submitted to an independent adversarial
referee (Grok 4.5 subagent) instructed to kill it — find the paper, the
system, or the folklore trick that already is this object. The families below
are everything the referee and our own sweeps surfaced, including the CPM 2025
character-class-run index and, on the 2026-07-20 Ridge follow-up review (§8),
the count-histogram/Parikh sieve-shape neighbors and the min/max-automata
oracle family. Web sweeps
ran continuously through design (2026-07); search terms included every
phrasing of "run-length regex index", "counting constraint prefilter",
"character class repetition index", "necessary condition regex pruning",
"forced substring automaton", and the systems literature by name.

---

## 1. N-gram presence indexes (the family Crest complements)

The dominant paradigm: reduce the pattern to **required substrings**, test
substring _presence_ in an inverted index.

| system                                                      | mechanism                                                          | why it is not Crest                                                                                                                    |
| ----------------------------------------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| [Cox 2012](#r-cox-trigram) / [codesearch](#r-codesearch)    | required trigram sets, AND/OR query over an inverted trigram index | a pattern with no extractable trigram (`[0-9a-f]{8}`) degenerates to _scan everything_; the index stores presence, never run structure |
| [PostgreSQL `pg_trgm`](#r-pg-trgm)                          | color-trigram graph extracted from the regex's CFA                 | same degeneration: no literal ⇒ no trigrams ⇒ full scan                                                                                |
| [RE2](#r-re2) `FilteredRE2` / `PrefilterTree`               | required "atoms" of `min_atom_len ≥ 3`, boolean prefilter tree     | patterns yielding no atom are marked `unfiltered_` — always scanned                                                                    |
| [Zoekt](#r-zoekt) (Sourcegraph)                             | positional trigram index                                           | presence + position of trigrams; class repetitions yield none                                                                          |
| [GitHub Blackbird](#r-blackbird)                            | sparse n-gram selection over code                                  | same object class: substring presence                                                                                                  |
| [REI](#r-rei) (SIGMOD 2025), [Zhang et al. 2025](#r-zhang)  | learned / cost-based _selection_ of which n-grams to index         | optimizes the same presence test; concedes the same literal-free hole                                                                  |
| gist's own trigram prefilter (`src/kernel/query/query.zig`) | Cox-family required-trigram intersection                           | the Certificate records the hole honestly: `cand% = 100%` on `regex-classcount`                                                        |

**Difference.** All of these answer "does the document contain substring s?"
Crest answers "does the document contain a _run of class-C bytes at least r
long_?" — a property no substring test expresses (the run may be any of
`|C|^r` strings; enumerating is exponential, and presence of any particular
one is neither necessary nor implied). Conversely Crest extracts nothing from
literal-rich patterns — the two filters own complementary pattern families,
which is why the integration _intersects_ survivor sets.

## 2. Character-class-run text indexing (the closest published neighbor)

[Bannai et al., _Text Indexing for Simple Regular Expressions_ (CPM 2025)](#r-cpm25) is the strongest neighboring work. It does **not** reduce
character classes to n-gram presence: for one text `T` it builds positional
range-reporting structures that locate matches of the restricted anchored forms
`P₁D*P₂` and the interval variants `P₁D^{≥l}P₂`, `P₁D^{≤r}P₂`, and
`P₁D^{[l,r]}P₂`. That is genuine prior art for **indexing text by class-run
structure**, and Crest does not claim to originate the broad idea.

Read closely, though, the indexed object is not a class run. Their Definition 5
is a **k-run**: "the maximal range `[i..j]` such that `T[i..j]` contains exactly
`k` _distinct symbols_" — a window keyed by symbol-set **cardinality**, one per
starting position, whose alphabet `D_{i,k}` is _discovered from the text_ and
matched against the query's `D` through a trie plus one grid per subset (the
`2^k − 1` grids of §3.2). Their other "run" (Definition 8, for `P₁P*P₂`) is the
classical maximal repetition with a Lyndon root. Neither is "the longest stretch
of bytes drawn from a fixed class family," which is the only quantity Crest
stores. So the shared vocabulary is broader than the shared object: CPM answers
class queries _over_ distinct-symbol windows; Crest answers no queries at all
and stores no positions.

The overlap ends there:

- **Different result.** CPM reports exact occurrence positions in one text for
  a restricted query grammar. Crest stores one coarse signature per document
  and only rejects impossible documents; survivors still go to the matcher.
- **Different query contract.** CPM receives `D` and its interval directly,
  with an anchor in `P₁P₂`. Crest derives a conservative forced-run vector from
  a general regex AST by composition across concatenation, alternation, and
  repetition; a bare unanchored `[0-9a-f]{8}` is its central case.
- **Different index object and scale.** CPM stores positional structures over
  text runs and class subsets in near-linear/polylogarithmic space. Crest stores
  the maximum run for each member of one fixed class family: `O(k)` small
  integers per document, independent of positions and query classes.
- **Their hardness result is about our central case.** CPM's Theorem 1 is
  _conditioned on an anchor_ — a character of `P₁P₂` outside `D` — and they
  prove that without one, no efficient index can exist unless the Set
  Disjointness Conjecture fails. Crest's motivating query, `[0-9a-f]{12}`, is
  exactly the anchorless case: no literal anywhere, which is why every index in
  the trigram family concedes it too. So the two works are not competing for one
  design point; CPM proves the exact-index door is closed where Crest enters,
  and a one-sided sieve that admits false positives and rescans survivors is not
  bound by a lower bound on indexed exact reporting. The unoccupied territory is
  unoccupied for a published reason.

**Difference.** CPM is prior art for _class-run text indexing_; it is not prior
art for Crest's composite of a fixed per-document max-run vector, an
AST-derived forced-run lower-bound functional, and a componentwise
no-false-negative sieve. That narrower composite remains the novelty claim.

### 2.1 The decisive design-point comparison (Crest/Ridge vs CPM 2025)

The two works occupy _different design points_ on the same object
(character-class runs); the contrast, not a benchmark race, is the artifact:

| axis                              | CPM 2025 (Bannai et al.)                                                          | Crest / Ridge                                                                                                   |
| --------------------------------- | --------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| **result**                        | exact **positional** occurrence reporting                                         | corpus-level document **sieve** (survivors rescanned)                                                           |
| **query grammar**                 | restricted **anchored** `P₁D^{[l,r]}P₂`                                           | **general regex AST** (concat/alt/bounded-rep), unanchored `[0-9a-f]{8}` is the central case                    |
| **anchoring**                     | anchor required in `P₁P₂`                                                         | none — bare class repetitions                                                                                   |
| **per-doc metadata**              | positional structures over runs+class subsets, near-linear/polylog in text length | **fixed `O(k·q)`** small ints/doc — 16 B (Crest) / 64 B (Ridge q=4), independent of positions and query classes |
| **index overhead (measured)**     | (positional, text-scaled)                                                         | **0.09% / 0.35%** of corpus bytes                                                                               |
| **build**                         | index construction over one text                                                  | one `O(L)` streaming pass/doc, ~1.7 GiB/s parallel                                                              |
| **error model**                   | exact                                                                             | **false-positive-tolerant, zero false negative** (Theorems 1, 3)                                                |
| **multi-run / structured tokens** | interval form handles one `D`-run between anchors                                 | Ridge forces a **run multiset** (`date → digit:{4,2,2}`, `uuid → hex:{8,4,4}`) via the gap-aware calculus       |
| **composability**                 | standalone index                                                                  | intersects survivor sets with the trigram index + freshness overlay (all necessary conditions)                  |

Crest/Ridge deliberately **cede** CPM's territory (exact positions, anchored
grammar) to **own** the coarse-filter point CPM does not target: general-AST,
constant-size-per-doc, false-positive-tolerant corpus pruning that composes
with n-gram and freshness filters. CPM's unanchored conditional lower bound
concerns _indexed exact reporting_ and does not bind a sieve that admits false
positives and rescans survivors.

## 3. Scan-time counting automata (matcher-layer, not index-layer)

| work                                                                                | mechanism                                                       | why it is not Crest                                                                                                                              |
| ----------------------------------------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| [MIN-MAX counter automata](#r-minmax) (IEEE TPDS 2012+)                             | counters in the automaton track repetition bounds at match time | makes the _matcher_ cheap on `C{n,m}`; builds **no per-document index**, prunes **no documents** — every byte of every document is still visited |
| [Counting-set automata](#r-csa2020) (OOPSLA 2020) / [synchronizing CSA](#r-csa2023) | set-valued counters determinize counting constraints            | same layer: scan-time state compression, zero index-time artifact                                                                                |
| [Hyperscan](#r-hyperscan) (Intel)                                                   | SIMD multi-pattern scan, FDR/Teddy literal engines              | literal-anchored acceleration of the scan itself; class repetitions without literals get no prefilter                                            |

**Difference.** These are _how to run the automaton faster once you are
reading the bytes_. Crest is _how to never read the bytes_. The layers
compose: a counting matcher still benefits from Crest's candidate pruning.

## 4. Run-length structures in string indexing (different query class)

| work                                                 | mechanism                                                                               | why it is not Crest                                                                                        |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| [SBC-tree](#r-sbc) (RLE-string indexing)             | index runs of _one repeated character_ for substring search over RLE-compressed strings | single-character runs, substring queries — not a per-class max-run vector, not a regex necessary condition |
| [RLE-BWT / r-index](#r-rindex) long-match structures | run-length-compressed BWT for pattern _location_                                        | compression artifact of the text, not a query-derived lower bound; answers exact substring location        |
| [Kolpakov–Kucherov](#r-runs) maximal-run literature  | combinatorics of all maximal repetitions in a string                                    | studies runs of _periodic factors_; no fixed class family, no query-side functional, no sieve              |

**Difference.** The string-index literature indexes runs to answer _substring_
queries or to compress. None derives a **forced-run lower bound from a regex
AST**, and none uses per-class max-runs as a document-pruning signature.

## 5. Segment-summary algebras (the calculus's algebraic shape, repurposed)

The `(F, P, S, minLen, only_c_cert)` profile composes like
[Bentley's 1984](#r-bentley) maximum-subarray divide-and-conquer summary
(best/prefix/suffix/total), and like max-plus segment trees used for
longest-run-in-range queries over _strings_. Two honest acknowledgements and
the two inversions that make it a different object:

- Those algebras summarize **one concrete string** bottom-up; Crest's profile
  summarizes **a language** (every string the regex accepts), which forces the
  min-of-max adversarial semantics: numeric fields are lower bounds over
  `L(E)`, while one-sided `only_c_cert=true` licenses a seam only when all
  accepted strings are proved all-C.
- Those algebras _maximize_ over positions; Crest's adversary _minimizes_ over
  accepted strings. Alternation is a componentwise min (tropical sum), and
  repetition pumps optional copies to zero — neither exists in the
  single-string setting.

The regex-analysis cousin is required-literal / minimum-length extraction
([RE2](#r-re2)'s `MinMatchLength`, gist's own `analysis/` pass): also an AST
lower-bound functional, but over _length_ and _literals_ — never over
per-class run structure, and never paired with a per-document run index. Note
that this concedes `min_len` outright: the scalar minimum-match-length component
of the profile is standard equipment, in RE2, in `regex-automata`'s
`Properties::minimum_len`, and as the length abstraction string solvers have
used for years. It is the `F`/`P`/`S` run components that have no counterpart.

**Where ĝ properly belongs, and the negative result there.** Stated formally, ĝ
is a sound _abstract semantics_ of a regex — an abstraction of `L(R)` into a
domain ordered by `≤`, with soundness `ĝ(R) ≤ inf_{w∈L(R)} ρ(w)` — which places
it in the string abstract-domain literature
([Costantini, Ferrara & Cortesi](#r-string-domains)). That is the strongest
checkable evidence we have, because the standard suite is enumerable and ĝ's
carrier is not in it: Character Inclusion, Prefix, Suffix, Prefix/Suffix, String
Set, String Length, Bricks, M-Strings. Character Inclusion tracks must/may
_membership_; String Length tracks a scalar interval. **No domain in the suite
expresses "must contain ℓ consecutive class-C bytes."** A referee looking for
ĝ's published analogue has a short, closed list to check, and it does not
contain one.

## 6. Sketches and signatures (Bloom, minhash, class histograms)

| object                                                     | why it is not Crest                                                                                                                                         |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Bloom filters](#r-bloom) over n-grams                     | substring presence again, probabilistic; false positives fine, but cannot express "run ≥ r"                                                                 |
| Class histograms / population counts (the "count cousin")  | sound but strictly dominated: forced run `n` ⇒ forced count `≥ n`, never the reverse; kept at identical thresholds in every revision-bound evidence package |
| Suffix-automaton / FM-index exact tiers (gist's own codex) | exact substring machinery; a class repetition is not a substring                                                                                            |

## 7. Count-vector sieves and the Parikh ceiling (the _shape_, not the quantity)

The sieve _shape_ — a per-document vector signature, a query-derived required
vector, componentwise dominance, fail-to-candidate, zero false negatives — is
**not** original to Crest; only the _quantity_ in the vector is. We concede the
shape without hedging, and to the right ancestors:

- **[Jokinen & Ukkonen 1991](#r-jokinen-ukkonen)** is the canonical form, and it
  predates every system here: a per-window q-gram count vector, a threshold
  _derived_ from the pattern (`m + 1 − (k+1)q` surviving q-grams), and a
  one-sided guarantee. Count-vector-with-derived-threshold filtering is
  1991-vintage; nothing about that skeleton is ours.
- **[REI](#r-rei) (SIGMOD 2025)** is the nearest living relative, and closer to
  Crest's sieve than anything in §1's presence table: a constant-size bit-vector
  stored per log line, a mask derived from the query regex, a componentwise
  test, and a proven no-false-negative property, sitting in front of RE2. Every
  structural element of Crest's sieve is already there. **The delta is the
  carrier and only the carrier** — REI's vector holds boolean presence of
  selected literal bigrams, so it inherits §1's literal-free hole exactly;
  Crest's holds order-sensitive integer class-run maxima, which is what survives
  when no literal exists.
- **[ugrep-indexer](#r-ugrep-indexer)** is the deployed-system twin, and it
  lives in Crest's own context — a grep. Per-file n-gram Bloom signature,
  file-skipping on non-match, soundness argued by monotone bit-halving. Same
  shape, literal carrier again, and its documentation names the gap precisely:
  index search weakens exactly where unbounded repeats and Unicode classes take
  over.

The weaker structural neighbor, and the one Crest measures against directly, is
the **character/class-population histogram prefilter**
([per-doc byte-frequency histogram compared against required counts](#r-charhist)):
identical shape, but over **counts**, so it can demand "≥ 12 digits" and a
single 12-run satisfies it — it cannot demand a _contiguous_ run, still less
_two_ of them. This is Crest's own §3.8 count cousin, and it is dominated for
exactly this reason.

Its theoretical ceiling is the **Parikh / semilinear image** of a regular
language ([Parikh's theorem](#r-parikh); [Stjerna & Rümmer, OOPSLA
2024](#r-parikh-solve)): the tightest count necessary condition derivable from
a regex is its commutative image, and being order-free it _provably_ cannot
encode any run/contiguity predicate.

The separation takes one line. Ψ is a homomorphism into a _commutative_ monoid,
so Ψ(`aabb`) = Ψ(`abab`) = (2,2); but over the class `{a}` their crests are 2
and 1. Hence ρ is **not a function of** Ψ — no Parikh-derived filter, however
tight, can express `ρ ≥ ĝ`, because the two strings it must separate are the
same point in its domain. Crest is not a sharpening of the count condition; it
is a different, non-commutative statistic that the count condition cannot see.

That is measured, not just proved. The count cousin is carried at identical
thresholds in every evidence package: on `[0-9a-f]{8}` over 20 661 files it
prunes **0.91%** where the run prunes **93.37%**. Being "Parikh-adjacent" in
shape costs 99% of the yield — the dominance-sieve _shape_ is indeed old, and
the shape is not where the pruning comes from.

## 8. The run _spectrum_ (Ridge) — referee re-scope, 2026-07-20

Ridge (`PROOF.md` §7) lifts Crest's single max run to the top-`q` maximal-run
order statistics per class, with an AST-derived forced-run **multiset**. It was
submitted to a fresh independent adversarial referee (kill mandate, 16 web
sweeps). **Verdict: PARTIAL — no collision, two honest downgrades**, both
adopted in `PROOF.md` §7.5:

1. Ridge is a **strict generalization of Crest**, not an independent object
   (`q=1` is Crest); the referee-able delta is _single max → sorted top-q_ and
   _single forced run → forced-run multiset_.
2. The multiset-**dominance sieve shape** is anticipated by the count-histogram
   family (§7 above) and the Parikh ceiling; the surviving novelty is the
   **run order-statistic quantity + gap-aware forced-run-multiset calculus**,
   and there the referee found no equal.

| family                       | representative                                               | load-bearing difference                                                                                                               |
| ---------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| single-run sieve (Crest)     | this work, §0                                                | only the _single_ longest run/class — cannot force two distinct runs (`[0-9]{6}[^0-9]+[0-9]{6}`) nor a multiset                       |
| count/char histogram         | [byte-frequency prefilter](#r-charhist)                      | per-doc-vector dominance shape, but over **counts** — order/contiguity abstracted away                                                |
| Parikh / semilinear          | [Parikh](#r-parikh) · [Stjerna–Rümmer 2024](#r-parikh-solve) | the exact count-necessary-condition ceiling; commutative ⇒ no run predicate expressible                                               |
| per-doc run-length signature | [doc-image run-length histogram descriptors](#r-rlhist)      | a per-doc run signature — but a _similarity/retrieval_ descriptor over single-symbol runs, no query lower bound, no dominance theorem |
| scan-layer digit prefilter   | [coregex `DigitPrefilter`](#r-coregex) · Hyperscan           | accelerates _reading bytes_ (SIMD skip to digit regions); builds no per-doc index, prunes no documents                                |

**Secondary — the exact oracle** (`g_i(R,C)`, min over `L(R)` of the _i_-th
largest maximal C-run, via NFA×run-monitor emptiness + binary search): a
textbook instance of **min-over-a-max/distance automaton**
([Kuperberg–Vanden Boom, STACS 2015](#r-minmaxaut); [Alur et al.
CRA, LICS 2013](#r-cra); ranked = [Mohri–Riley N-best](#r-nbest)). We found no
published treatment of this _specific_ functional, but it is unambiguously a
special case of that machinery — **cited as a family, claimed by neither Crest
nor Ridge.** It is used only as an independent soundness+tightness referee.

## 9. Referee summary

The adversarial reviewer's final position, condensed: presence-family indexes
(§1) cannot express the property; CPM 2025 (§2) directly indexes class runs
but solves exact positional queries for a restricted anchored grammar rather
than document sieving from a general regex AST; counting automata (§3) live at
the wrong layer; run-length string structures (§4) index a different object
for a different query; the algebra (§5) is a known _shape_ carrying new semantics
(language-level adversarial lower bounds with an exactness guard); and the
count cousin (§6) is the nearest sound signature sibling and is empirically
dominated.
No reviewed work combines: (a) a per-document per-class max-run signature,
(b) a regex-derived sound forced-run functional, (c) a componentwise-compare
sieve with a no-false-negative theorem. That composite is the contribution.

**Standing obligation.** Two dated searches are recorded: the Crest composite
(through 2026-07-20, no instance found) and the Ridge spectrum extension
(2026-07-20, partial/no collision, re-scoped in §8). Each is limited to the
literature reachable at its date. If a prior instance surfaces, cite it and
re-scope the claim — never quietly drop this file. The math stands regardless;
only the priority claim changes.

---

## References

Annotated bibliography for every external source above. Anchor ids match the
in-body citation links.

<span id="r-cox-trigram"></span>

1. **Cox (2012).**
   [_Regular Expression Matching with a Trigram Index_](https://swtch.com/~rsc/regexp/regexp4.html).
   _Annotation:_ Required-trigram presence filter — Crest's complementary
   hole (`[0-9a-f]{8}` → full scan).

<span id="r-codesearch"></span> 2. **Google codesearch.**
[github.com/google/codesearch](https://github.com/google/codesearch).
_Annotation:_ Open `cindex`/`csearch` of Cox's design; presence, never
run structure.

<span id="r-pg-trgm"></span> 3. **PostgreSQL `pg_trgm`.**
[`trgm_regexp.c` (source)](https://github.com/postgres/postgres/blob/master/contrib/pg_trgm/trgm_regexp.c).
_Annotation:_ Color-trigram graph from the regex CFA — same no-literal
degeneration to full scan.

<span id="r-re2"></span> 4. **RE2.**
[github.com/google/re2](https://github.com/google/re2).
_Annotation:_ `FilteredRE2` / `PrefilterTree` atoms and
`MinMatchLength` — presence / length lower bounds, not per-class runs.

<span id="r-zoekt"></span> 5. **Zoekt.**
[github.com/sourcegraph/zoekt](https://github.com/sourcegraph/zoekt).
_Annotation:_ Positional trigram index; class repetitions yield no
candidates.

<span id="r-blackbird"></span> 6. **GitHub.**
[Blackbird architecture](https://github.blog/engineering/architecture-optimization/the-technology-behind-githubs-new-code-search/).
_Annotation:_ Sparse n-gram _presence_ at global scale — same object
class as Cox/Zoekt.

<span id="r-rei"></span> 7. **Zhang, Deep, Patel & Sankaralingam (2025).**
[_Regular Expression Indexing for Log Analysis_](https://doi.org/10.1145/3769820)
(Proc. ACM Manag. Data / SIGMOD) ·
[PDF](https://db.cs.cmu.edu/papers/2025/zhang-sigmod2025.pdf) ·
[code](https://github.com/mush-zhang/REI-Regular-Expression-Indexing).
_Annotation:_ **The nearest published relative of Crest's sieve, and the one to
argue against.** Not merely n-gram selection: REI stores a constant-size
bit-vector per log line, derives a mask from the query regex, tests by
componentwise dominance, and proves no false negatives (Appendix A) in front of
RE2 — the entire sieve skeleton, already published. The delta is the carrier:
boolean presence of selected literal bigrams, so it inherits the literal-free
hole that class repetitions open, where Crest's integer run maxima do not.

<span id="r-zhang"></span> 8. **Zhang, Deep, Patel & Sankaralingam (2025).**
[_An Evaluation of N-Gram Selection Strategies for Regular Expression Indexing_](https://www.vldb.org/pvldb/vol18/p5703-zhang.pdf)
(PVLDB).
_Annotation:_ Contemporary n-gram selection study — presence family;
Crest's hole remains.

<span id="r-minmax"></span> 9. **Wang, Pu, Knezek & Liu (2013).**
[_MIN-MAX: A Counter-Based Algorithm for Regular Expression Matching_](https://doi.org/10.1109/tpds.2012.116)
(IEEE Trans. Parallel Distrib. Syst.).
_Annotation:_ Speeds the _matcher_ on character-class constraint
repetitions — no per-document index, no document pruning.

<span id="r-csa2020"></span> 10. **Turoňová, Holík, Lengál, Saarikivi, Veanes & Vojnar (2020).**
[_Regex Matching with Counting-Set Automata_](https://doi.org/10.1145/3428286)
(OOPSLA).
_Annotation:_ Set-valued counters for counting constraints at scan
time — wrong layer for Crest.

<span id="r-csa2023"></span> 11. **Holík, Síč, Turoňová & Vojnar (2023).**
[_Fast Matching of Regular Patterns with Synchronizing Counting_](https://doi.org/10.48550/arxiv.2301.12851).
_Annotation:_ Synchronizing counting-set automata — further scan-time
state compression; zero index-time artifact.

<span id="r-hyperscan"></span> 12. **Intel Hyperscan.**
[github.com/intel/hyperscan](https://github.com/intel/hyperscan).
_Annotation:_ SIMD multi-pattern scan with literal engines — accelerates
reading bytes, does not prune documents on class runs.

<span id="r-sbc"></span> 13. **RLE / SBC-tree string indexes.**
Representative line: run-length-encoded text indexes for _substring_
search (e.g. SBC-tree literature on RLE strings).
_Annotation:_ Indexes runs of one repeated character for substring
queries — not a per-class max-run regex sieve.

<span id="r-rindex"></span> 14. **r-index / RLE-BWT.**
[github.com/nicolaprezza/r-index](https://github.com/nicolaprezza/r-index).
_Annotation:_ Run-length BWT for pattern _location_ — compression
artifact, not a regex-derived forced-run lower bound.

<span id="r-runs"></span> 15. **Kolpakov & Kucherov (1999).**
[_Finding maximal repetitions in a word in linear time_](https://doi.org/10.1109/SFFCS.1999.814634).
_Annotation:_ Combinatorics of maximal _periodic_ runs — no fixed class family,
no query-side ĝ, no document sieve.

<span id="r-bentley"></span> 16. **Bentley (1984).**
[_Programming pearls: algorithm design techniques_](https://doi.org/10.1145/358234.381162)
(CACM) — maximum-subarray divide-and-conquer summary.
_Annotation:_ Best/prefix/suffix/total shape Crest's profile echoes —
but over one string, maximizing; Crest minimizes over a language.

<span id="r-bloom"></span> 17. **Bloom (1970).**
[_Space/time trade-offs in hash coding with allowable errors_](https://doi.org/10.1145/362686.362692)
(CACM).
_Annotation:_ Probabilistic set membership for n-grams — cannot express
"run of class C at least r".

<span id="r-cpm25"></span> 18. **Bannai, Bille, Gørtz, Landau, Navarro,
Prezza, Steiner & Tarnow (2025).**
[_Text Indexing for Simple Regular Expressions_](https://doi.org/10.4230/LIPIcs.CPM.2025.20)
(CPM 2025).
_Annotation:_ The closest published neighbor: directly indexes
character-class runs and interval lengths for exact positional queries of
restricted anchored patterns. It does not store a fixed per-document max-run
vector, derive forced runs compositionally from a general regex AST, or use
their componentwise comparison as a coarse document sieve.

<span id="r-charhist"></span> 19. **Character-frequency histogram prefilter.**
[Per-document byte-frequency histogram vs required counts](https://ayoob.ai/blog/ai-anti-cheat-software-gaming-gpu).
_Annotation:_ The count sieve in production form — same per-doc-vector +
componentwise-dominance + fail-to-candidate shape as Crest/Ridge, but over
**counts**, so it cannot demand a contiguous run (Crest §3.8 cousin, dominated).

<span id="r-parikh"></span> 20. **Parikh (1966).**
[_On Context-Free Languages_](https://doi.org/10.1145/321356.321364) (JACM).
_Annotation:_ The commutative (count) image of a regular language — the exact
theoretical ceiling of any count necessary condition; order-free, so no run
predicate is expressible. Ridge lives strictly outside it.

<span id="r-parikh-solve"></span> 21. **Stjerna & Rümmer (2024).**
[_A Constraint Solving Approach to Parikh Images of Regular Languages_](https://doi.org/10.1145/3649855)
(OOPSLA).
_Annotation:_ Contemporary Parikh-image reasoning — the strongest count
necessary condition derivable from a regex; contiguity/run structure is
provably outside its reach.

<span id="r-rlhist"></span> 22. **Run-length histogram document descriptors.**
[Document-image retrieval with run-length histograms](https://www.kiphub.com/paper/61e5011d3ee3040691f6280e);
[run-histogram features (arXiv:1404.0627)](https://arxiv.org/pdf/1404.0627).
_Annotation:_ A per-document run-length _signature_ exists — but as a
similarity/classification descriptor over single-symbol/pixel runs, with no
query-derived lower bound and no no-false-negative dominance theorem.

<span id="r-coregex"></span> 23. **coregex `DigitPrefilter`.**
[github.com/coregx/coregex](https://github.com/coregx/coregex/blob/v0.12.22/docs/OPTIMIZATIONS.md).
_Annotation:_ A current scan-layer digit-run prefilter (SIMD skip to digit
regions) — accelerates reading bytes, builds no per-document index, prunes no
documents; the tighter modern cousin of the Hyperscan cite.

<span id="r-minmaxaut"></span> 24. **Kuperberg & Vanden Boom (2015).**
[_On the Expressive Power of Cost Automata / min-max automata_](https://perso.ens-lyon.fr/denis.kuperberg/papers/STACS2015_MinMax.pdf)
(STACS).
_Annotation:_ Min/max cost automata — the family the exact oracle
`g_i(R,C) = min_{w∈L(R)} (i-th largest maximal C-run)` is a special case of.
Cited, not claimed.

<span id="r-cra"></span> 25. **Alur, D'Antoni, Deshmukh, Raghothaman & Yuan (2013).**
[_Regular Functions and Cost Register Automata_](https://www.cis.upenn.edu/~alur/Lics13reg.pdf)
(LICS).
_Annotation:_ Cost register automata — general machinery for values computed
along an automaton run; the oracle's run-length monitor is an instance.

<span id="r-nbest"></span> 26. **Mohri & Riley; Büchse et al. (2018).**
[_N-best / ranked paths over weighted automata_](https://www.sciencedirect.com/science/article/pii/S002200001730034X)
(JCSS).
_Annotation:_ The "i-th largest" ranking in the oracle is the N-best-paths
problem over a monitor automaton — standard, cited as a family.
<span id="r-jokinen-ukkonen"></span> 27. **Jokinen & Ukkonen (1991).**
[_Two algorithms for approximate string matching in static texts_](https://www.cs.helsinki.fi/u/ukkonen/MFCS91.pdf)
(MFCS).
_Annotation:_ The canonical count-vector filter, and the honest ancestor of the
dominance _shape_ (§7) — a per-window q-gram count vector with a threshold
derived from the pattern and a one-sided guarantee (Lemma 7). Cite this, not
Parikh, when conceding that the sieve skeleton is old: it is order-blind in the
same way the count cousin is, and 34 years earlier.

<span id="r-ugrep-indexer"></span> 28. **Genivia — `ugrep-indexer`.**
[Repository](https://github.com/Genivia/ugrep-indexer) · [ugrep](https://ugrep.com/).
_Annotation:_ The deployed-system twin of Crest's sieve, inside a grep: a
per-file n-gram Bloom signature (490–4256 B/file by accuracy), used to skip
files whose index cannot match, with soundness argued by monotone bit-halving.
Same shape, literal carrier — and its own documentation names Crest's target as
its weak point: index search degrades exactly where unbounded repeats and
Unicode classes dominate the pattern.

<span id="r-string-domains"></span> 29. **Costantini, Ferrara & Cortesi (2015).**
[_A Suite of Abstract Domains for Static Analysis of String Values_](https://pmpub.inf.ethz.ch/publications/CostantiniFerraraCortesi14.pdf)
(Softw. Pract. Exper.).
_Annotation:_ The literature ĝ formally belongs to — a sound abstraction of a
string language into an ordered domain — and the strongest _negative_ evidence
for its novelty (§5). The standard suite is enumerable (Character Inclusion,
Prefix, Suffix, Prefix/Suffix, String Set, String Length, Bricks, M-Strings) and
contains no run-length domain: membership and scalar length are tracked, "must
contain ℓ consecutive class-C bytes" is not.

# Pincer — prior art

**Referee pass: 2026-07-29.** Adversarial posture: the null hypothesis is that
this has been done. Every citation is a URL that was actually fetched or that a
search returned with extracted content; where something could not be verified it
says so inline.

Read this before `PROOF.md`'s conclusions. The short version: the **defect** is
ours, the **diagnosis** was published in this exact domain in 2018, and the
**repair** is standard practice in a neighboring one. Only a narrow slice of the
mechanism is unclaimed, and the part of `PROOF.md` §7 that reads most like an
invention is in fact an adoption.

## What was searched

**Engines:** Google/Bing; direct fetches of GitHub raw source, Fossies Doxygen
source browsers, arXiv/Springer/USENIX PDFs, personal blogs, Hacker News.

**Query families (~40 queries):** `memchr` rare-byte/`packedpair`/
`HeuristicFrequencyRank`; rust `regex` `FreqyPacked`; ripgrep prefilter design
notes and haystack sampling; Hyperscan Noodle offset selection, FDR/Teddy bucket
assignment, "super characters"; Muła SIMD substring search; ClickHouse
Volnitsky; zoekt `findSelectiveNgrams`; Sunday Optimal Mismatch; Hume–Sunday
guard characters; Burkhardt–Kärkkäinen gapped *q*-grams; optimal *q*-sample
selection; Faro–Lecroq surveys (EPSM, SBNDM); spaced seeds (PatternHunter,
Buhler–Keich–Sun, iedera, Optimal Seed Solver, Adaptive Seeds Filter, Hobbes);
minimizers/syncmers; mutual-information probe selection; skip-gram byte
frequency prefilters; distance-conditioned bigram substring search.

**Read in full:** `memchr` `arch/all/packedpair/mod.rs` and `memmem/searcher.rs`;
rust `regex` `literal/imp.rs`; Muła 0x80.pl; Startin "Heuristics for Substring
Search"; Buhler–Keich–Sun RECOMB'03; the iedera manual; Xin et al. Optimal Seed
Solver; Hyperscan NSDI'19; Hyperscan `noodle_build.cpp` and
`ng_literal_analysis.cpp`; zoekt PR #779 and `indexdata.go`; FU Berlin filtration
lecture notes.

**Not verified.** The Burkhardt & Kärkkäinen CPM'01 primary PDF (404 at
`cs.helsinki.fi`) — relied on the ALCOM-FT report abstract, the Springer chapter
abstract, and two independent lecture-note treatments. **Patents are a genuine
gap:** one web query, no direct USPTO/EPO/Google Patents search. Intel
(Hyperscan) and the DPI/IDS world patent aggressively in this area, so the patent
negative is weak and must be closed properly before any novelty is asserted
externally.

## Neighbors

| Name | Year | What it selects | Objective | Background model | Verdict |
| --- | --- | --- | --- | --- | --- |
| Muła, generic SIMD strfind | 2016 | fixed first + last byte | none (structural) | none | no |
| `memchr` `Pair::with_ranker` | 2020– | two byte offsets | minimize each byte's rank independently | static i.i.d. **marginals** | no — this is the incumbent being improved on |
| rust `regex` `FreqyPacked` | 2016– | rarest single byte | minimize marginal frequency | static marginals; **explicitly rejects** haystack analysis | bears on claim 2 |
| Sunday, Optimal Mismatch | 1990 | *order* of comparisons | least-frequent first | i.i.d. empirical marginals | ancestor of marginal selection |
| Hume & Sunday, guard char | 1991 | one guard offset | reduce false starts | marginals / ad-hoc | no |
| Hyperscan Noodle | 2015– | two offsets in a literal | distinguishing-ness, caseless safety | none | no |
| Hyperscan FDR/Teddy bucketing | 2015–21 | pattern→bucket | minimize collisions; score is a **product** over bytes | independence assumed | no — an independence-assuming counterexample |
| Hyperscan "super characters" | 2019 | byte *i* + low bits of *i+1* | suppress shuffle false positives | structural | closest structural use of adjacency; no bigram model |
| ClickHouse / Volnitsky | 2011– | fixed hashed bigram positions | index density | none | no |
| zoekt `findSelectiveNgrams` | 2016– | two trigram offsets at a known distance | **minimize posting-list intersection** | **self-calibrating marginals** + non-overlap heuristic | **kills the shape of claim 2** |
| Burkhardt & Kärkkäinen, gapped *q*-grams | 2001–03 | which positions a shape inspects | maximize threshold (minimum coverage) | **i.i.d. uniform** | no — the crux distinction |
| PatternHunter / Ma–Tromp–Li | 2002 | spaced-seed positions | maximize sensitivity at fixed weight | i.i.d. Bernoulli | no |
| Buhler, Keich & Sun | 2003 | spaced-seed positions | maximize sensitivity | **empirical kth-order Markov** over the alignment alphabet | **narrows claim 1** |
| iedera (Kucherov & Noé) | 2005– | subset-seed templates | sensitivity **and** selectivity | **Markov background (`-b`)**, alignment alphabet | **narrows claim 1** |
| Optimal Seed Solver (Xin et al.) | 2015 | positions + lengths of *x* seeds | minimize the **sum** of frequencies | **self-calibrating** from the real index | kills claim 2; additive, not joint |
| Startin, "Heuristics for Substring Search" | 2018 | fixed first-two-byte pair | (analysis, not selection) | **real-corpus order-1 Markov bigram histograms** | **most dangerous hit** — states the problem, not the fix |

## The strong neighbors

### `memchr` — `Pair::with_ranker`

The selector keeps a running best-two by `ranker.rank(b)` on the individual byte
value, with one side condition — `b != rare1` — and an `assert_ne!(index1,
index2)`. The comment justifying it is the revealing part: *"we really don't want
these to be equivalent. If they were, it would reduce the effectiveness of
candidate searching using these rare bytes by increasing the rate of false
positives."* So the author reasoned explicitly about **correlation between the
two probes**, and handled exactly one degenerate case of it — identical byte
values — with a structural constraint rather than a joint model. There is no
distance term, no pair table, and no conditioning of the second choice on the
first beyond inequality. This is the canonical marginal selector, and the one
`rarity.zig` re-derives.
<https://raw.githubusercontent.com/BurntSushi/memchr/master/src/arch/all/packedpair/mod.rs>

### rust `regex` — `FreqyPacked` (bears on claim 2)

The docstring is the cleanest statement of the received wisdom: *"Since doing
frequency analysis on the haystack is far too expensive, we compute a set of
fixed frequencies up front."* That is a documented, deliberate rejection of
self-calibration — which makes the idea publicly considered-and-declined rather
than unthought-of. `memchr` separately exposes `HeuristicFrequencyRank` as a
public trait so a caller can supply a table computed for their own data. Claim
2's mechanism is an explicitly provided extension point in the incumbent.
<https://github.com/rust-lang/regex/blob/master/src/literal/imp.rs>

### zoekt — `findSelectiveNgrams`, PR #779

Zoekt picks two trigram offsets from the query, looks up each one's **actual
posting-list length in the live index**, takes the two lowest, and intersects
under a distance constraint — structurally the same "two probes at a known
distance, conjunction, then verify" shape as this kernel's filter. Its objective
is not "rarest trigrams" but **smallest intersection**, and PR #779 adds a
heuristic preferring **non-overlapping** trigrams precisely because overlapping
ones are correlated and intersect worse than their marginals predict. Correct
objective, self-calibrating estimator, explicit — but purely structural —
correlation dodge. It builds no joint distribution over (a at *i*, b at *i+d*).
<https://github.com/sourcegraph/zoekt/pull/779/files>

### Burkhardt & Kärkkäinen — gapped *q*-grams

Flagged in advance as the likely strongest hit; it is not. Gapped *q*-grams
choose a **shape** — which positions of a window to inspect — and optimize the
**threshold**, the guaranteed number of shared gapped *q*-grams between strings
within edit distance *k*, via the combinatorial *minimum coverage* property.
That is a worst-case guarantee over alignments; the false-positive side is
analyzed under **i.i.d. uniform random text**. No empirical corpus, no
character-frequency term, no joint distribution. It selects positions by
combinatorial geometry, not background statistics.
<https://users-cs.au.dk/~gerth/alcom-ft/TR/ALCOMFT-TR-01-74.html> ·
<https://link.springer.com/chapter/10.1007/3-540-48194-X_6> ·
<https://www.mi.fu-berlin.de/wiki/pub/ABI/RnaSeqP4/filtering.pdf>

### Buhler, Keich & Sun — "Designing seeds for similarity search in genomic DNA"

The dangerous academic neighbor. They abandon PatternHunter's i.i.d. Bernoulli
background, train a **kth-order Markov chain from real aligned genomic data**,
and choose seed positions to maximize hit probability under that correlated
model — stating outright that *"the probability of at least one match varies
because the probabilities of matches at different offsets are not
independent."* So "select which positions a filter probes using an
empirically-estimated correlated model rather than an independence assumption"
is published, in 2003. Two things leave a residue: the model is over the
**alignment alphabet** (match/mismatch symbols), so no P(byte *a* at *i*, byte
*b* at *i+d*) quantity exists anywhere; and the objective is **sensitivity to
true homologies**, with background selectivity pinned by holding seed weight
fixed rather than being minimized.
<https://www.maths.usyd.edu.au/u/uri/my_papers/2003_spaced_seeds_RECOMB.pdf>

### iedera — Kucherov & Noé

`-b` is a Markov background model of order *k* over the alignment alphabet, used
when computing a seed's selectivity alongside a foreground model. iedera can
therefore select seed templates against a **correlated** background rather than
an i.i.d. one and report the resulting selectivity — the closest anything in the
literature comes to "choose probe positions by minimizing joint background hit
probability under a correlated model." It differs on the same two axes as Buhler
et al.: the alphabet carries no notion of *which* concrete symbol values sit at
the probed positions, and a seed is a template reused across all queries rather
than an offset pair chosen per-needle from that needle's own bytes.
<https://bioinfo.univ-lille.fr/yass/iedera.php>

### Optimal Seed Solver — Xin et al.

A DP picking positions **and** lengths for *x* non-overlapping seeds to
**minimize the sum of their frequencies**, every frequency read from the actual
reference-genome index — fully self-calibrating on the corpus being searched,
optimizing a real cost rather than a proxy. It is not the joint claim for a
structural reason worth stating precisely: OSS's filter is **disjunctive**
(pigeonhole — at least one seed must be error-free), so candidate cost really is
additive in the marginals and no joint term exists to model. The filter under
review here is **conjunctive**, which is exactly where independence stops being
exact and a joint term earns its keep.
<https://repository.bilkent.edu.tr/bitstreams/b1a60396-3d6c-4b4c-aa67-696639b9d5a1/download>

### Richard Startin — "Heuristics for Substring Search"

The most dangerous single document, because it is in precisely the right domain
and gets within one step. Startin builds **byte-pair adjacency matrices from real
corpora**, runs order-1 Markov chains off those bigram histograms to generate
correlated synthetic text, and demonstrates that the naive first-byte heuristic
degrades badly on it — empirically establishing the exact failure mode `PROOF.md`
§2.1 describes. But his conclusion is the aggregate observation that no pair
occurs more than ~3% of the time, and what he implements is a **fixed
offset-0/offset-1 pair**. He never turns the bigram table around and uses it to
*select* the offsets. Statement of the problem: yes. The selector: no.
<https://richardstartin.github.io/posts/heuristics-for-substring-search>

### Hyperscan — Noodle, FDR/Teddy, super characters

Noodle picks two offsets, but `noodle_build.cpp`'s criterion is caseless-safety
and fragment distinguishing-ness, not frequency. Teddy's bucket-grouping score
(ICPP'21) is a **product over per-byte bit-counts** — an explicit independence
assumption, and a counterexample rather than an anticipation. The one place
Hyperscan reaches for adjacency is the NSDI'19 "super character": *"An m-bit
super character consists of a normal (8-bit) character in the lower 8 bits and
low-order (m−8) bits of the next character."* That injects bigram *structure*
into the shuffle masks to suppress cross-pattern false positives, but it is a
fixed structural widening with no corpus bigram distribution and no
frequency-driven offset selection.
<https://www.usenix.org/system/files/nsdi19-wang-xiang.pdf> ·
<https://fossies.org/dox/hyperscan-5.4.2/noodle__build_8cpp_source.html> ·
<https://oaciss.uoregon.edu/icpp21/views/includes/files/pap205s4-file2.pdf>

## Verdicts

### Claim 1 — select (o₁, o₂) by minimizing joint, distance-conditioned pair frequency

**NARROWED.**

No instance was found — in any SIMD prefilter, string-matching library, search
index, or paper — of selecting probe offsets by a distance-conditioned joint byte
pair distribution. Every selector read does one of: fixed positions (Muła,
Volnitsky, Startin, Noodle), independent marginal rank (`memchr`, `regex`, Sunday
1990, Hume–Sunday 1991), or marginal rank plus a *structural* anti-correlation
constraint (`memchr`'s `index1 != index2`, zoekt's non-overlap). Nobody indexes a
table by (byte, byte, distance).

What narrows it:

1. **Buhler–Keich–Sun (2003) and iedera** already establish, in seed design, the
   general move of choosing filter positions under an empirically-estimated
   correlated background rather than an independence assumption. The idea is not
   conceptually new; it is new in this alphabet against this objective.
2. **Startin (2018)** already published the empirical diagnosis — real-corpus
   bigram tables, Markov-generated correlated text, and a demonstration that the
   incumbent heuristic collapses on it — inside the SIMD-prefilter domain
   itself. **The motivating insight is prior art.**
3. **zoekt** already ships the right objective (minimize the conjunction's
   survivors, not the marginals) with a correlation-aware constraint, in a
   two-probes-at-a-known-distance filter.

Residue that remains unclaimed, stated tightly because this is what is
defensible:

> Selecting the probe **offset pair** for a conjunctive SIMD literal prefilter by
> minimizing an estimate of **P(X_i = a ∧ X_{i+d} = b)** — a distance-conditioned
> joint distribution over **concrete byte values** of the specific needle,
> indexed by the specific gap `d = o₂ − o₁` — as the direct objective of
> selection, in place of minimizing a product of per-byte marginals.

Four axes distinguish this from the nearest art simultaneously, and no single
prior work has more than two: (a) the alphabet is 256 raw byte values, not a 2–3
symbol alignment alphabet; (b) the distribution is conditioned on the gap, so
correlation is modeled as a function of distance rather than dodged by a binary
overlap rule; (c) selection is per-needle from that needle's own bytes at query
time, not a reusable template; (d) the objective is background selectivity of a
**conjunction**, where independence is a real approximation error, not a
**disjunction**, where additivity is exact.

### Claim 2 — self-calibrating: estimate the table from the corpus being searched

**KILLED**, as stated.

- **zoekt** does exactly this — probe selection reads live posting-list lengths
  from the index being searched.
- **Optimal Seed Solver** does exactly this with a DP over positions and
  lengths, and beats four prior self-calibrating schemes (GEM's Adaptive Seeds
  Filter, Hobbes' Cheap K-mer Selection) that also do it.
- **`memchr`** ships `HeuristicFrequencyRank` precisely so a caller can
  substitute a table computed for their own data; the `regex` docstring records
  the opposite decision **and its reason**, which is publication of the
  considered alternative.

The only unclaimed part is self-calibrating the *joint* table specifically, which
is wholly parasitic on claim 1. It is not asserted separately here — it is an
embodiment of claim 1, and `PROOF.md` §7 should be read as **adopting a known-good
technique**, not inventing one. That it is standard practice elsewhere is an
argument *for* shipping it, not against.

## What would kill this

Any one of these anticipates claim 1 outright. They are the specific things to
find before asserting novelty anywhere external.

1. **A `memchr` / ripgrep / `regex` issue, PR, commit, or design doc where
   BurntSushi proposes or rejects a byte-*pair* frequency table for `Pair`
   selection.** He demonstrably reasoned about probe correlation. If "use bigram
   frequencies at the candidate distance" is written down in that tracker, it is
   over. The public docs and source were read; **the issue trackers were not
   exhaustively read — this is the highest-yield remaining search.**
2. **Hyperscan/Vectorscan literal-analysis code scoring a fragment with a bigram
   or *n*-gram corpus table.** `ng_literal_analysis.cpp` was read far enough to
   see it is length/uniqueness-driven; not every scoring path in the 5.4.2 tree
   was audited.
3. **A spaced- or subset-seed paper optimizing seed selectivity against an
   empirical Markov background over the raw sequence alphabet, where selection
   depends on the concrete residues of the specific query.** iedera comes
   closest; a query-adaptive variant would be fatal.
4. **An optimal-*q*-sample or *q*-gram filtration paper replacing the i.i.d. text
   assumption with an empirical Markov model when placing sample positions.** The
   Navarro–Raffinot / Faro–Lecroq line assumes i.i.d. as far as it was traced.
5. **A patent.** Coverage here is weak (see above). Must be closed properly
   before any external assertion.
6. **A production search engine — Lucene, Tantivy, Elasticsearch, Manticore, or
   a commercial DPI/IDS engine — whose literal selection consults a
   co-occurrence table indexed by pair and gap.** zoekt was checked; Lucene's and
   Tantivy's phrase-query term-selection paths were not, and they have the same
   two-probes-at-a-known-distance structure.

---
doc_radar:
  sentinels:
    "artifact/positional_pareto.tsv":
      contains: ["carried_trigrams", "pct_corpus", "cand_pgxpool"]
    "artifact/scale_elision.tsv":
      contains: ["indexed_eq_noindex"]
      absent_matches: ["\\tNO$"]
    "artifact/scale_walkcost.tsv":
      contains: ["maxrss_mib", "owned_mib", "gist --no-index -uu", "rg -uu"]
    "artifact/scale_build.tsv":
      contains: ["peak_rss_gib", "post-kiln"]
---

# `bench/sliver` — index tiers under load, in Layer D's own unit

Layer D (`bench/lowerbound/`) measures the floor a **trigram** directory can
reach, in _candidate bytes delivered to verify_. It records four of the twelve
canonical classes arriving at **cand% = 100%** — the whole corpus admitted,
because the needle is thinner than a trigram (`literal-punct2` = `})`) or carries
a branch that is (`regex-litalt` = `panic|0x`). A floor you meet by reading
everything is not a filter; it is the absence of one.

This harness answers the three questions that follow from that, each with its own
committed artifact: what the **sliver tier**
(`src/corpus/index/trigrams/sliver.zig`) recovers on Layer D's own axis, over the
same corpus and probe set so the columns are directly comparable; what a
**positional** tier would cost against what it would buy; and how gist holds up
against **zoekt** and **csearch** on a multi-GB corpus.

```bash
cd <irregex-repo-root>
zig build scale -Doptimize=ReleaseFast     # table on stdout + machine-readable TSV
GIST_SCALE_TRACE=1 zig build scale         # also print the filters each class offers
```

Output: `<GIST_DIR>/scale_tiers.tsv` — the same artifact home `gist index` uses,
so it lands at the repo-root `.local/gist-verify/` by default (a `# k=v`
provenance header, then one row per class).

## What it measures, and why the numbers can be trusted

Two candidate rules over identical inputs:

| Rule        | Meaning                                                                                                                                          |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `directory` | the historical gate — a needle < 3 bytes cannot be queried, so every document is a candidate. Reproduces Layer D's numbers; the honest "before". |
| `tiered`    | the sliver tier answers sub-trigram needles from the same directory, and a mixed alternation is unioned per branch.                              |

- **No production code is instrumented and no candidate rule is re-implemented.**
  `tiered` calls the same `sliver.candidates` production calls, so a number here
  cannot drift from shipped behavior.
- **Soundness is asserted, not assumed.** For every class the production verify
  (`simd.contains` / `Regex.docMatch`) establishes ground truth over _every_
  document, and every truly-matching document must appear in the tiered candidate
  set. One missing match exits non-zero — no measured speed-up excuses it.
- **Fail-closed on the payoff too.** A class whose tiered candidate bytes _exceed_
  the directory rule's is a regression and fails the audit.

## Measured result (Apple M4 Pro, zig 0.16.0, 21,105 files / 209.6 MiB)

Two classes move, and they are exactly the two Layer D reports at 100%:

| class            | pattern     | cand% directory | cand% tiered | reduction |
| ---------------- | ----------- | --------------: | -----------: | --------: |
| `literal-punct2` | `})`        |         100.00% |       49.18% | **2.03×** |
| `regex-litalt`   | `panic\|0x` |         100.00% |       37.42% | **2.67×** |

The corpus is the live working tree, so absolute percentages shift by tenths
between mints as files change; the reduction factors are stable, and the TSV
records the exact corpus each run measured.

The tier costs **0 new bytes on disk** — it reads the trigram directory that
already exists, because a sliver must sit inside one of its document's trigrams.

The ten classes that do not move are the honest half of the table. A sliver tier
is only as selective as the byte it filters on: `regex-eol` (`;$`) and
`regex-classcount` filter on `;` and `-`, which occur in essentially every source
file, so the tier engages, prices the union from exact directory cardinalities,
and correctly declines. `regex-dense-scan` (`\w{3,8}`) offers no literal at all.

## The positional tier: measured, priced, and declined

A **positional** tier stores where in a document a trigram occurs, so verify reads
regions rather than whole documents — the axis Layer D calls the floor. It is
deliberately **not implemented**, and the whole size/benefit surface behind that
decision is committed at `artifact/positional_pareto.tsv`
(`spikes/scale-pareto/pareto_probe.py`). Two axes are swept: a trigram
carries block positions only if its document frequency is below **T**, and at most
**cap** blocks are stored per (trigram, document) — an over-cap posting drops its
constraint, which is sound because dropping a constraint only widens the admitted
region. Sidecar bytes are measured at real delta+varint encoding.

| cap |  df ≤ T |   sidecar | % corpus | `pgxpool` | `context.Context` |  `func` | `panic` |
| --: | ------: | --------: | -------: | --------: | ----------------: | ------: | ------: |
|   8 |       0 |         0 |     0.0% |    12.3 M |            25.5 M | 108.7 M |  41.5 M |
|   8 |     256 |  16.5 MiB |     8.8% |    12.3 M |            25.5 M | 108.7 M |  41.5 M |
|   8 |    1024 |  35.0 MiB |    18.6% |     4.9 M |            25.5 M | 108.7 M |  41.5 M |
|   8 | uniform | 108.8 MiB |    57.8% |     4.9 M |            15.7 M |  80.2 M |  19.7 M |
| inf |    1024 |  74.9 MiB |    39.8% |     0.5 M |            25.5 M | 108.7 M |  41.5 M |
| inf |    4096 | 136.0 MiB |    72.3% |     0.5 M |             7.2 M | 108.7 M |   0.9 M |
| inf | uniform | 245.8 MiB |   130.6% |     0.5 M |             7.2 M |  29.8 M |   0.7 M |

**The cheap end of the curve buys nothing, and the reason is structural.** A
threshold only carries a literal's positions once it reaches that literal's
_rarest_ trigram, and those floors are measured high: `pgxpool` 560 documents,
`WalletService` 686, `context.Context` 2405, `panic` 3933, `func` 7671 of 19440.
A trigram is a 3-byte window over a small alphabet, so document frequency floors
out in the hundreds — there is no population of ultra-rare trigrams to annotate
for free. Below T=1024 every probe is unchanged at every cap.

So the anti-correlation that motivates a selective tier is real on the **cost**
side (98% of distinct trigrams are only ~32% of posting bytes) but the **benefit**
needs exactly the mid-frequency trigrams whose positions are expensive. The large
reductions do reproduce — `panic` 46×, `pgxpool` 25×, `WalletService` 170× — and
they cost 39.8% of corpus at T=1024, 72.3% at T=4096, and **130.6% uncapped and
uniform, a sidecar larger than the text it indexes**. Capping to 8 blocks per
document holds the price to 18.6–57.8% and guts the benefit to 1.4–2.5×.

Declined because of what the money buys: positions help the classes gist is
_already_ fastest on (`literal-rare` admits 6.5% of corpus before any positional
work, and csearch answers it in 4 ms at multi-GB scale), while the classes that
actually cost seconds at scale carry no rare literal — `func` measures **1.0× at
every threshold below uniform**. Compare the sliver tier above: **0 new bytes on
disk**, and a 16.5× win over csearch at scale. gist's postings stay document-level
by choice at a measured price. The decision is gated, not asserted: Layer J
refuses to splice if any threshold costing ≤10% of corpus is ever measured
delivering ≥2× on any probe.

## Scale: gist vs zoekt vs csearch

`scale_race.py` races the three indexed engines over a multi-GB corpus (shallow
clones of linux, llvm, go, rust — 352,316 files / 5.5 GiB on disk) across the same
canonical 12 classes, reusing `bench/races/_compete.sh`'s fairness contract
(`GIST_UNCAP=1`, one shared output mode) and `bench/certify/certify_stats.py` for
medians, bootstrap CIs and the Mann-Whitney verdict. Artifacts: `scale_race.tsv`,
`scale_build.tsv`, `scale_resident.tsv`, `scale_truth.tsv`, `scale_elision.tsv`.

```bash
python3 bench/sliver/scale_race.py --corpus <corpus> --gist-dir <gistdir> \
    --zoekt-dir <zoektdir> --csearch-idx <csearch.idx> --reps 5
```

Headline: gist indexes 3.35 GiB of text in **26.0 s** (9.1× faster than zoekt,
2.2× faster than csearch) into the smallest index (10.4% of its text, against
zoekt's 8.7 GiB of shards), and against csearch — the rival that agrees with
ripgrep about what exists — wins 5 classes, ties 3, loses 4, with the wins at the
hard end (`literal-punct2` 16.5×, `regex-litalt` 9.4×, `regex-eol` 4.0×).

One loss is published unnormalised because it is real: **indexing peak RSS is
4.56 GiB**, 1.6× csearch. It was 14.50 GiB — 5.1× — until the trigram build
stopped materializing corpus-proportional intermediates and started firing in
blocks, and that is the row to re-measure after any builder change, because the
verdict sentence in Layer J is derived from it rather than typed beside it.

Query-time memory needed two metrics, and an earlier draft of this file got its
mechanism wrong. `maximum resident set size` is ~575 MiB whatever the query,
which that draft read as loading the 389 MiB index rather than paging it. It is
not: `vmmap` shows `index.gist` **11.5 MiB resident of 354.9 MiB mapped**, and
two controls settle it — a zero-candidate needle whose filter elides _every_
read still costs 583 MiB, and `--no-index`, mapping nothing, still costs 535 MiB.
The residency is the **live tree walk over all 336,780 files** (one touched byte
costs a 16 KiB page on ARM64), so it tracks file count, and those pages are
clean and evictable. On owned memory — `peak memory footprint`, what the process
cannot have reclaimed — gist is flat at **93–96 MiB**, ~10× csearch and **5.8×
better than zoekt's 558 MiB**.

## Walk cost: the matched pair against ripgrep

`walkcost.py` is the instrument for the one comparison that decides whether a
walk is expensive or gist's walk was: same needle, same `-uu` scope, same cwd,
both counting, both a fresh process with no index and no daemon on either side,
so the only difference left is the implementation of walking. It carries the
same two metrics, and reports the owned ratio as the one that is a cost. Artifact:
`scale_walkcost.tsv`; Layer J renders it rather than quoting numbers, and an
absent measurement reads as absent instead of as the last one anybody took.

```bash
python3 bench/rungs/sliver/walkcost.py --root <tree> [--pattern pgxpool] [--reps 3]
```

This is where the walk's own retention was found: gist mapped every large file it
read and held all of them to exit, so its resident set tracked the corpus rather
than the query. Dropping each mapping in the frame that rendered it took the
matched pair from **274 MiB to ~54 MiB of maxrss** on an 11 GiB tree, and it is
also very slightly *faster* (6.32 s ± 0.33 against 6.75 s ± 0.39 over six runs
each), because 274 MiB of live mappings is VM pressure the walk was paying for
and nothing was reading.

That walk is also the one cause of the cheap-literal latency losses (~1.2 s over
337,949 files), and it is the freshness contract being paid for, not overhead: a
file created after all three indices were built is found by gist and by
ripgrep, and missed by **both** csearch and zoekt.

## Certificate layer

`bench/certify/certify_scale_report.py` splices **Layer J** between
`<!-- SCALE-LAYER-START -->` / `<!-- SCALE-LAYER-END -->` and writes the roster
side-car `bench/certify/artifact/scale.csv`.

It is fail-closed in three directions, and the third is the unusual one:

- **the tier** — any unsound row, any class whose tiered candidate bytes got
  worse, or either `literal-punct2` / `regex-litalt` still admitting the whole
  corpus;
- **scale** — index elision parity is absolute (a class whose indexed and
  `--no-index` answers diverge fails outright); a file-count shortfall against
  csearch demands a recorded parity proof and is ceilinged at 3%, and both
  `literal-punct2` and `regex-litalt` must convert their pruning into a measured
  Mann-Whitney win at multi-GB scale or the tier is a certificate-corpus artifact;
- **the positional refusal itself** — if the Pareto surface ever shows a threshold
  costing ≤10% of corpus that delivers ≥2× on any probe, the "declined" narrative
  is false and the reporter refuses to splice it. The honest "no" cannot rot into
  an excuse.

Re-run standalone (`zig build scale` first; it writes into `GIST_DIR`):

```bash
cd <irregex-repo-root> && zig build scale -Doptimize=ReleaseFast
python3 bench/certificate/report/scale.py \
  --certificate bench/certificate/artifact/CERTIFICATE.md \
  --tsv ../../../.local/gist-verify/scale_tiers.tsv \
  --race bench/rungs/sliver/artifact/scale_race.tsv \
  --build bench/rungs/sliver/artifact/scale_build.tsv \
  --resident bench/rungs/sliver/artifact/scale_resident.tsv \
  --pareto bench/rungs/sliver/artifact/positional_pareto.tsv \
  --elision bench/rungs/sliver/artifact/scale_elision.tsv \
  --walkcost bench/rungs/sliver/artifact/scale_walkcost.tsv \
  --sidecar bench/certificate/artifact/scale.csv \
  --machine "$(sysctl -n machdep.cpu.brand_string)" --zig "$(zig version)"
```

Roster row for `bench/certify/layers.py` (the parent wires it; this lane does not
edit that file) — header `## Layer J — positional + substring index tiers at scale
(vs zoekt)`, side-car `scale.csv`:

```python
Layer(
    "J",
    "Layer J — positional + substring",
    "## Layer J — positional + substring index tiers at scale (vs zoekt)",
    "scale.csv",
),
```

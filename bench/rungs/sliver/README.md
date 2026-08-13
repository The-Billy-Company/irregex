# `bench/rungs/sliver` — Index Tiers Under Load, In Layer D's Own Unit

Layer D (`bench/bounds/lowerbound/`) measures the floor a **trigram** directory can
reach, in _candidate bytes delivered to verify_. It records four of the twelve
canonical classes arriving at **cand% = 100%** — the whole corpus admitted,
because the needle is thinner than a trigram (`literal-punct2` = `})`) or carries
a branch that is (`regex-litalt` = `panic|0x`). A floor you meet by reading
everything is not a filter; it is the absence of one.

This harness answers the three questions that follow from that, each with its own
committed artifact: what the **sliver tier**
(`src/corpus/index/trigrams/sliver.zig`) recovers on Layer D's own axis, over the
same corpus and probe set so the columns are directly comparable; what a
**positional** tier would cost against what it would buy; and how this engine
holds up against **zoekt** and **csearch** on a multi-GB corpus.

```bash
cd <irregex-repo-root>
zig build scale -Doptimize=ReleaseFast     # table on stdout + machine-readable TSV
GIST_SCALE_TRACE=1 zig build scale         # also print the filters each class offers
```

Output: `scale_tiers.tsv` in the artifact home (`<prefix>DIR`) — the same home
an index build uses, so it lands in the repo-root artifact directory by default
(a `# k=v` provenance header, then one row per class).

## What It Measures, And Why The Numbers Can Be Trusted

Two candidate rules run over identical inputs. **`directory`** is the
historical gate — a needle under 3 bytes cannot be queried, so every document
is a candidate, reproducing Layer D's numbers as the honest "before". **`tiered`**
is the sliver tier answering sub-trigram needles from the same directory, with
a mixed alternation unioned per branch.

- **No production code is instrumented and no candidate rule is re-implemented.**
  `tiered` calls the same `sliver.candidates` production calls, so a number here
  cannot drift from shipped behavior.
- **Soundness is asserted, not assumed.** For every class the production verify
  (`simd.contains` / `Regex.docMatch`) establishes ground truth over _every_
  document, and every truly-matching document must appear in the tiered candidate
  set. One missing match exits non-zero — no measured speed-up excuses it.
- **Fail-closed on the payoff too.** A class whose tiered candidate bytes _exceed_
  the directory rule's is a regression and fails the audit.

## Measured Result (Apple M4 Pro, Zig 0.16.0, 21,105 Files / 209.6 MiB)

Two classes move, and they are exactly the two Layer D reports at 100%.
**`literal-punct2`** (`})`) drops from 100.00% of the corpus admitted under
`directory` to 49.18% under `tiered`, a **2.03×** reduction. **`regex-litalt`**
(`panic|0x`) drops from 100.00% to 37.42%, a **2.67×** reduction.

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

## The Positional Tier: Measured, Priced, And Declined

A **positional** tier stores where in a document a trigram occurs, so verify reads
regions rather than whole documents — the axis Layer D calls the floor. It is
deliberately **not implemented**, and the whole size/benefit surface behind that
decision is committed at `artifact/positional_pareto.tsv`, measured by a
standalone probe over this package's own trigram directory across a
19,440-document, 188.2 MiB slice of the corpus at a 256-byte block. Two axes are
swept: a trigram carries block positions only if its document frequency is below
**T**, and at most **cap** blocks are stored per (trigram, document) — an
over-cap posting drops its constraint, which is sound because dropping a
constraint only widens the admitted region. Sidecar bytes are measured at real
delta+varint encoding.

- **`cap=8`** caps every trigram at 8 stored positions per document. At **T=0**
  (no positions carried) sidecar is 0 MiB and every probe pays doc-level cost:
  `pgxpool` 12.3 MiB, `context.Context` 25.5 MiB, `func` 108.7 MiB, `panic`
  41.5 MiB, `WalletService` 17.1 MiB. Raising T to 256 costs 16.5 MiB of
  sidecar (8.8% of corpus) with no probe moving yet. Only past **T=1024**
  (35.0 MiB, 18.6%) does `pgxpool` drop to 4.9 MiB and `WalletService` to
  12.6 MiB. Past **T=4096** (66.9 MiB, 35.5%) `context.Context` drops to
  15.7 MiB, `panic` to 22.0 MiB, and `WalletService` to 11.4 MiB. The ceiling
  of this curve, **T=uniform** (108.8 MiB, 57.8%), finally moves `func` to
  80.2 MiB and settles `panic` at 19.7 MiB.
- **`cap=inf`** stores every block a trigram's document frequency permits, at
  proportionally higher cost. **T=1024** (74.9 MiB, 39.8%) is the first point
  priced above cap-8's ceiling, and it moves `pgxpool` to 0.5 MiB and
  `WalletService` to 0.5 MiB while leaving `context.Context`, `func`, and
  `panic` untouched. **T=4096** (136.0 MiB, 72.3%) moves `context.Context` to
  7.2 MiB, `panic` to 0.9 MiB, and `WalletService` to 0.1 MiB, with `func`
  still untouched. **T=uniform** — every trigram, every position, **245.8 MiB,
  130.6% of corpus, a sidecar larger than the text it indexes** — is the only
  point that ever moves `func`, down to 29.8 MiB.

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

Declined because of what the money buys: positions help the classes this engine
is _already_ fastest on (`literal-rare` admits 6.5% of corpus before any
positional work, and csearch answers it in 4 ms at multi-GB scale), while the
classes that actually cost seconds at scale carry no rare literal — `func`
measures **1.0× at every threshold below uniform**. Compare the sliver tier
above: **0 new bytes on disk**, and a 16.5× win over csearch at scale. Our
postings stay document-level by choice at a measured price. The decision is
gated, not asserted: Layer J refuses to splice if any threshold costing ≤10% of
corpus is ever measured delivering ≥2× on any probe.

## Scale: This Engine Vs Zoekt Vs csearch

`scale_race.py` races the three indexed engines over a multi-GB corpus (shallow
clones of linux, llvm, go, rust — 352,316 files / 5.5 GiB on disk) across the same
canonical 12 classes, reusing `bench/apparatus/field.sh`'s fairness contract
(`<prefix>UNCAP=1`, one shared output mode) and `bench/apparatus/stats.py`
for medians, bootstrap CIs and the Mann-Whitney verdict. Artifacts:
`scale_race.tsv`, `scale_build.tsv`, `scale_resident.tsv`, `scale_truth.tsv`,
`scale_elision.tsv`.

```bash
python3 bench/rungs/sliver/scale_race.py --corpus <corpus> --gist-dir <gistdir> \
    --zoekt-dir <zoektdir> --csearch-idx <csearch.idx> --reps 5
```

Headline: this engine indexes 3.35 GiB of text in **26.0 s** (9.1× faster than
zoekt, 2.2× faster than csearch) into the smallest index (10.4% of its text,
against zoekt's 8.7 GiB of shards), and against csearch — the rival that agrees
with ripgrep about what exists — wins 5 classes, ties 3, loses 4, with the wins
at the hard end (`literal-punct2` 16.5×, `regex-litalt` 9.4×, `regex-eol` 4.0×).

One loss is published unnormalised because it is real: **indexing peak RSS is
4.56 GiB**, 1.6× csearch. It was 14.50 GiB — 5.1× — until the trigram build
stopped materializing corpus-proportional intermediates and started firing in
blocks, and that is the row to re-measure after any builder change, because the
verdict sentence in Layer J is derived from it rather than typed beside it.

Query-time memory needs two metrics on macOS, and two wrong explanations for
our ~575 MiB `maximum resident set size` were tried and retired before
finding the real one. The first guess — that this was the cost of loading the
389 MiB index — is refuted by `vmmap`: `index.gist` shows **11.5 MiB resident
of 354.9 MiB mapped**, genuinely demand-paged rather than loaded whole. Two
controls confirm the index isn't the cost either: a zero-candidate needle
whose filter elides *every* read still costs 583 MiB, and `--no-index`,
mapping nothing, still costs 535 MiB — so the index accounts for only
~48 MiB of that number.

The second guess — that the remaining ~535 MiB is inherent to walking a live
tree of 336,780 files, since one touched byte costs a whole 16 KiB page on
ARM64 — was retired too, by the matched pair against ripgrep in
[Walk Cost](#walk-cost-the-matched-pair-against-ripgrep) below: if the cost
were a property of walking, ripgrep would pay it walking the same tree, and it
does not. The excess was our own *implementation* of walking, in two
retentions that move different columns — held file mappings on `maxrss`, and a
path materialized per walked entry on **owned** memory. Both are closed; that
section carries the current pair.

Which is why the owned figures in `scale_resident.tsv` are stamped **pre-fix**
rather than quoted here as current. They were captured while the walk still
kept a copy of every path it walked in the immortal per-worker arena, so the
familiar "flat at 93–96 MiB" reading now **overstates** what we own, by this
corpus's arena term. What survives it is the *shape* of that row and the rival
comparison, neither of which the walk's own retention touched: our owned
working set is flat across every query class where zoekt spends 558 MiB on one
common term, and csearch still wins `maxrss` outright because it never walks.
Refreshing the numbers themselves needs the multi-GB corpus with rebuilt
csearch and zoekt indexes over byte-identical files — a deliberate re-measure,
not a side effect of the change that invalidated them.

## Walk Cost: The Matched Pair Against Ripgrep

`walkcost.py` is the instrument for the one comparison that decides whether a
walk is expensive or ours was: same needle, same `-uu` scope, same cwd,
both counting, both a fresh process with no index and no daemon on either side,
so the only difference left is the implementation of walking. It carries the
same two metrics, and reports the owned ratio as the one that is a cost. Artifact:
`scale_walkcost.tsv`; Layer J renders it rather than quoting numbers, and an
absent measurement reads as absent instead of as the last one anybody took.

```bash
python3 bench/rungs/sliver/walkcost.py --root <tree> [--root <tree> …] \
    [--pattern pgxpool] [--reps 3]
```

`--root` repeats because the answer is **corpus-shaped**, and that is not a
caveat — it is the finding. Ripgrep's own footprint swings further between two
real trees than ours does, so one tree would let whoever picked it pick the
verdict. Both ends are published. The artifact is the source of truth and the
shape below is what it looks like, not a second copy to keep in step — read
`scale_walkcost.tsv` for this machine's current cells:

| corpus | this engine | ripgrep | owned ratio |
|---|--:|--:|--:|
| `.etc/llvm-project` (193,744 files) | 69.6 / 57.0 MiB | 33.8 / 31.8 MiB | **1.79×** |
| `.etc` (449,684 files) | 89.2 / 76.6 MiB | 112.4 / 110.4 MiB | **0.69×** |

(`maxrss / owned`, zero-match `pgxpool`, 3 reps.) Layer J quotes the **worst** of
them, never the best. On a deep C++ checkout ripgrep still wins; on a tree of many
cloned repositories we now own less memory than ripgrep does for the same
zero-match answer. Which is the point of measuring more than one: a lane that had
only ever walked `.etc` would have reported a win it does not have everywhere.

This is where both of the walk's own retentions were found, and they move
different columns. On `maxrss`: the walk mapped every large file it read and
held all of them to exit, so its resident set tracked the corpus rather than the
query — closed by dropping each mapping in the frame that rendered it. On
**owned**: the walk materialized every path it walked in the immortal per-worker
arena, and twice per entry, because the display path and the scope-relative path
are the same slice on every walk but an explicitly-rooted one and `handleEntry`
joined both. One prefix compare drops the second copy; the remaining joins moved
onto the per-directory scratch a worker already recycles, leaving only the three
branches that outlive a directory owning arena memory — a queued child
`DirTask`, a file deferred while the elision oracle is still loading, and a
`--sort` record. Worth 26.4 MiB of worker arena down to 3.0 on llvm-project.

Re-run `walkcost.py` after any change to the walk's mapping lifecycle **or** to
what it allocates per entry; those are the two things this pair is watching.

That walk is also the one cause of the cheap-literal latency losses (~1.2 s over
337,949 files), and it is the freshness contract being paid for, not overhead: a
file created after all three indices were built is found by this engine and by
ripgrep, and missed by **both** csearch and zoekt.

## Certificate Layer

`bench/certificate/report/scale.py` splices **Layer J** between
`<!-- SCALE-LAYER-START -->` / `<!-- SCALE-LAYER-END -->` and writes the roster
side-car `bench/certificate/artifact/scale.csv`.

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

Re-run standalone (`zig build scale` first; it writes into the artifact home
named by `<prefix>DIR`):

```bash
cd <irregex-repo-root> && zig build scale -Doptimize=ReleaseFast
python3 bench/certificate/report/scale.py \
  --certificate bench/certificate/artifact/CERTIFICATE.md \
  --tsv .gist/scale_tiers.tsv \
  --race bench/rungs/sliver/artifact/scale_race.tsv \
  --build bench/rungs/sliver/artifact/scale_build.tsv \
  --resident bench/rungs/sliver/artifact/scale_resident.tsv \
  --pareto bench/rungs/sliver/artifact/positional_pareto.tsv \
  --elision bench/rungs/sliver/artifact/scale_elision.tsv \
  --walkcost bench/rungs/sliver/artifact/scale_walkcost.tsv \
  --sidecar bench/certificate/artifact/scale.csv \
  --machine "$(sysctl -n machdep.cpu.brand_string)" --zig "$(zig version)"
```

Roster row for `bench/certificate/guard/profile.py` (the parent wires it; this
lane does not edit that file) — header `## Layer J — positional + substring
index tiers at scale (vs zoekt)`, side-car `scale.csv`:

```python
(
    Layer(
        "J",
        "Layer J — positional + substring index tiers",
        "## Layer J — positional + substring index tiers at scale (vs zoekt)",
        "scale.csv",
    ),
)
```

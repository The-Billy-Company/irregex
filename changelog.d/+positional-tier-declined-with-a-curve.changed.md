Priced a **positional index tier** across the full size/benefit surface and
declined it, with the curve committed rather than the conclusion asserted
(`bench/scale/artifact/positional_pareto.tsv`). Sweeping block-position coverage
by trigram document frequency × per-document cap shows the cheap end buys nothing
— a threshold only carries a literal's positions once it reaches that literal's
_rarest_ trigram, and those floor out high (`pgxpool` 560 documents, `panic`
3933, `func` 7671 of 19440), because a trigram is a 3-byte window over a small
alphabet. The large reductions are real (`panic` 46×, `pgxpool` 25×) and cost
39.8% of corpus at df≤1024, 72.3% at df≤4096, and 130.6% uniform and uncapped —
a sidecar larger than the text it indexes — while `func` measures 1.0× at every
threshold below uniform. Positions would accelerate the classes gist is already
fastest on and leave the ones that cost seconds untouched, so postings stay
document-level **by choice at a measured price**. Layer J gates the refusal
itself: any threshold costing ≤10% of corpus that delivers ≥2× on a probe fails
the layer closed instead of letting the "declined" narrative stand.

Also added `bench/scale/scale_race.py`, racing gist against zoekt and csearch over
a multi-GB corpus (352,316 files / 5.5 GiB) across the canonical 12 classes,
reusing `_compete.sh`'s fairness contract and `certify_stats.py`'s statistics.
gist indexes 3.32 GiB of text in 21.4 s — 11.0× faster than zoekt, 2.6× faster
than csearch — into the smallest index (10.4% of its text against zoekt's 8.7 GiB
of shards), and beats csearch on the five hardest classes (`literal-punct2`
16.5×, `regex-litalt` 9.4×). One loss is published unnormalised: 14.50 GiB
indexing peak RSS, 5.1× csearch.

Corrected the **query-residency diagnosis**, which an earlier draft of this layer
got wrong. A flat ~575 MiB `maximum resident set size` was read as gist loading
its 389 MiB index instead of paging it; it is not. `vmmap` over a live query
shows `index.gist` at **11.5 MiB resident of 354.9 MiB mapped** (3.2%), demand-paged
as designed, and two controls isolate the cause: a zero-candidate needle whose
filter elides _every_ read still costs 583 MiB, and `--no-index` — mapping no
index at all — still costs 535 MiB. The residency is the live tree walk over all
336,780 files, where one touched byte costs a 16 KiB page on ARM64, so it tracks
file count rather than index size and every page is clean and evictable. On owned
memory (`peak memory footprint`) gist is flat at **93–96 MiB** across every query
class, ~10× csearch and **5.8× better than zoekt's 558 MiB**. Layer J now
publishes both metrics with the controls beside them, so the maxrss gap reads as
the price of freshness rather than an index architecture.

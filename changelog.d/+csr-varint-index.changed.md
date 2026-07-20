**Trigram index switches from a flat `(trigram,doc)` pair table to a CSR
directory over delta-varint posting bodies** (`src/index/trigrams/trigram.zig`, new
`src/index/postings/varint.zig`) — the fix for the README's own documented weak point:
"gist trails csearch/zoekt on the cold literal one-shot because it maps a
177 MiB index where csearch mmaps 28 MiB." A flat table spent 8 bytes/posting
(4 tag + 4 doc) and most of the tag was redundant — a distinct trigram carries
dozens of postings on average. The index now stores three parallel arrays over
the `n` DISTINCT trigrams (`dir_tri`/`dir_off`/`dir_count` — csearch's own
per-trigram index-entry triple, `index/write.go`) plus one `body` blob: each
group's ascending doc ids are delta-encoded (successor `doc[i]-doc[i-1]`,
always ≥ 1) and LEB128-varint-packed, so a locally-clustered doc-id run — the
common case — costs ~1 byte/posting instead of 4, while the zero-copy `mmap`
load (`persist.zig`) is unchanged: `dir_*`/`body` still alias the mapped pages
directly (`fromMappedBytes`), so a cold query still touches only the handful
of pages its binary search + a few small per-trigram decodes probe. Rarest-first
query intersection is preserved via the explicit `dir_count` column (sort
groups by size before decoding, same algorithm as before).

**Measured on this repo (18,910 files, 160.1 MiB corpus, 343,857 distinct
trigrams, 25.56M postings):** index footprint **195.0 MiB flat → 30.1 MiB
CSR+varint (6.5×)** — smaller than `csearch`'s own index over the identical
corpus (31.1 MiB) for the first time. `bench/coldquery.sh`'s cross-tool cold
literal race (fresh process, hyperfine mean, 8 runs, 8 needles) moves the
geomean gist/csearch ratio **0.3× → 0.7×** and gist/zoekt **0.5× → 0.8×** —
gist now outright _wins_ 7/11 needles against zoekt (up from a near-total
loss) and still trails csearch geomean, but by roughly half the prior margin.
The residual gap is no longer index size (gist's is now the smaller of the
two) — profiling traces it to the corpus-wide freshness `stat()` walk
(`src/index/trigrams/fresh.zig`) that runs on every cold query regardless of hit/miss;
that is the next rung, tracked separately, not hidden.

Correctness re-proven: format bumped to `format_version = 2` (a v1 cache is
rejected, not misread); the full trigram/varint/ngram unit suite (`zig build
test`, 207/207) and the `gist ≡ rg` equality oracle are green on the new
format.

**Confirmed on the fail-closed macro certificate** (`bench/certify/certify.sh`
— fresh-process, hyperfine 20 runs + 3 warmup, gist-vs-rg verdict requires a
lower median _and_ Mann-Whitney p<0.05): **7 win · 1 parity · 1 loss** across
9 measured classes (up from a documented 8 win/3 loss at the old index size —
methodology differs slightly, see README), and the vs-csearch/vs-zoekt split
moved from "rivals win most cold classes" to a genuine ~50/50 split
(geomean ≈1.0× csearch, ≈0.8× zoekt). `certify_stats.py` also hardened to
skip a rival's malformed/empty hyperfine export (a transient hiccup, not a
real result) instead of aborting the whole certificate for one missing cell.

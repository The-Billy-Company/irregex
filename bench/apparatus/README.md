# bench/apparatus

The **instruments.** Nothing here makes a claim; everything here is what the
other buckets measure _with_.

| Piece                           | What                                                                                                                                                                                                                                                            |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`harness/`](harness/README.md) | the gist-bench Zig binaries (`bench.zig`, `certify.zig`, `flagbench.zig`, `pmu.zig`, `sessionprof.zig`) plus the two shared modules every timing lane imports — `probes.zig` (the 12-class query registry) and `stats.zig` (bootstrap-CI median + Mann-Whitney) |
| `roots.sh`                      | where this package's siblings are — climbs to the package root, then names the checkouts that own the `gist` and `relate` binaries and the corpus a race runs over. Each package answers this about itself, so the sibling repos carry their own copy            |

The probe registry and the statistics kernel live here precisely because they
are shared: `bounds/`, `rungs/`, and the sibling `gist` repo's `dominance/` and
`certificate/` all read the same 12 classes and the same verdict math, so a
competitor race and its minted certificate map 1:1 by class name.

The corpus fetcher left with the conformance slate — `conformance/` was its only
consumer, and it now lives at `gist/bench/apparatus/corpora/`.

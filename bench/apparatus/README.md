# bench/apparatus

The **instruments.** Nothing here makes a claim; everything here is what the
other buckets measure _with_.

| Piece                           | What                                                                                                                                                                                                                                        |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [`harness/`](harness/README.md) | the three shared instruments, each exported as a Zig module — `probes.zig` (the 12-class query registry), `pmu.zig` (hardware counters through Apple's kperf / Linux perf), and `stats.zig` (bootstrap-CI median + Mann-Whitney)             |
| `roots.sh`                      | where this package's siblings are — climbs to the package root, then names the checkouts that own the `gist` and `relate` binaries and the corpus a race runs over. Each package answers this about itself, so the sibling repos carry their own copy |
| `stats.py`                      | the Python leg of the same verdict math — Type-7 quantiles, bootstrap-CI medians, and the tie-corrected Mann-Whitney dominance call. `test_stats.py` holds it to known answers derived from the definitions, not from a run of itself                |

These three are the only things in `bench/` that a **consumer** package can
reach, and the only reason `bench/apparatus/harness` appears in this package's
`build.zig.zon` `.paths`. `bounds/`, `rungs/`, and the sibling `gist` repo's
`gist-bench` all import the same `probes` / `pmu` / `stats` modules, so a
competitor race over there and an engine rung over here map 1:1 by class name
and are judged by the same verdict math. A second copy would silently stop
meaning the same thing.

Two things left with the product they measure. The corpus fetcher went with the
conformance slate to `gist/bench/apparatus/corpora/`; the `gist-bench` harness
itself (`bench.zig` and its `certify` / `flagbench` / `sessionprof` modes) went
to `gist/bench/apparatus/harness/`, because its session lane spawns a live
`gist serve` daemon — and this package is upstream of the product, so it cannot
reach down to one.

`stats.py` is the case where that direction bites. It used to be reachable at
`bench/certificate/report/stats.py`, but the certificate is a `gist` concern and
went with it, which left `rungs/sliver/scale_race.py` importing a directory that
no longer exists here. Being upstream means no rescue is possible from below, so
the statistical core lives here now and the certificate keeps its own copy. The
function bodies are identical on purpose; `test_stats.py` is what stops the two
from quietly drifting into different answers.

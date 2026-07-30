# bench/apparatus

The **instruments, and the ground they run over.** Nothing here makes a claim;
everything here is what the other five buckets measure _with_.

| Folder                          | What                                                                                                                                                                                                                                                            |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`harness/`](harness/README.md) | the gist-bench Zig binaries (`bench.zig`, `certify.zig`, `flagbench.zig`, `pmu.zig`, `sessionprof.zig`) plus the two shared modules every timing lane imports — `probes.zig` (the 12-class query registry) and `stats.zig` (bootstrap-CI median + Mann-Whitney) |
| [`corpora/`](corpora/README.md) | the corpus the races run over — `fetch.sh` assembles it, `torture.py` synthesizes adversarial trees, `sweep.py` walks size regimes                                                                                                                              |

The probe registry and the statistics kernel live here precisely because they
are shared: `dominance/`, `certificate/`, and `rungs/` all read the same 12
classes and the same verdict math, so a competitor race and its minted
certificate map 1:1 by class name.

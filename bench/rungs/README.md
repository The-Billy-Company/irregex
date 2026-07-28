# bench/rungs

**Per-mechanism production proofs** — one folder per accelerator gist ships, each
proving _that specific mechanism_ earns its place under a real workload. These
are the rungs of the ladder the certificate climbs; each is self-contained and
already navigable, so none was re-split.

| Folder                                    | Mechanism                                                                                                  |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| [`crest/`](crest/README.md)               | Layer E — the crest-sieve prune/speedup proof, with its `evidence/` monograph                              |
| [`sieve/`](sieve/README.md)               | the trigram sieve — `indexq.zig` + `cover_parity.sh` / `production.sh` / `indexcost.sh`, `csearch_plan.py` |
| [`sliver/`](sliver/README.md)             | the sub-trigram sliver tier — `scale.zig` + `scale_race.py`                                                |
| [`shuffle/`](shuffle/README.md)           | the SIMD shuffle path                                                                                      |
| [`parabix/`](parabix/README.md)           | the parallel-bitstream path                                                                                |
| [`multipattern/`](multipattern/README.md) | the multi-pattern dragnet/trawl — `bench.zig` + `pack.py` / `slate.py` / `vscan.c`                         |
| [`sweep/`](sweep/README.md)               | the interned-AST fused sweep — each recursive analysis raced alone and bundled, with the break-even table  |

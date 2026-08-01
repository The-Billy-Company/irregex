---
doc_radar:
  sentinels:
    - description: "pmu.zig carries the provenance primitives every certificate layer stamps"
      file: bench/apparatus/harness/pmu.zig
      contains: ["pub fn cpuBrand", "pub fn requestPerformanceQos"]
  counts:
    - description: "the harness holds exactly the three shared instruments"
      glob: bench/apparatus/harness/*.zig
      equals: 3
---

# bench/apparatus/harness

The three **shared instruments**. None of them makes a claim; each is what a
claim is measured with. They are the only part of `bench/` a consumer package
can reach, which is why `bench/apparatus/harness` is listed in this package's
`build.zig.zon` `.paths` — the same reason `brigade.zig` is.

Each is exported by `build.zig` as a named Zig module, so a lane imports it by
name rather than by relative path:

| Module      | File          | What it is                                                                                                                                       |
| ----------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `probes`    | `probes.zig`  | the 12-class query registry — the shared vocabulary a race arm, an engine rung, and a minted certificate all report against, so rows line up by class name |
| `pmu`       | `pmu.zig`     | hardware performance counters — Apple's private `kperf` via `dlopen`/`std.DynLib` — cycles and instructions retired, plus the host-provenance primitives (`cpuBrand`, `requestPerformanceQos`) every layer stamps into its report |
| `stats`     | `stats.zig`   | the verdict math — bootstrap-CI median, Tukey outlier rejection, Mann-Whitney significance. Every lane in **both** repos reports through it        |

## Who reads them

```
irregex  bounds/{roofline,port}          → pmu
         bounds/lowerbound, rungs/…      → probes
gist     bench/apparatus/harness/        → pmu · probes · stats   (via the irregex dependency)
```

One registry, one meter, one significance test, across two repositories. A
second copy would drift, and the moment it did, a class name would quietly
stop meaning the same thing on both sides of the comparison.

`stats.zig`'s bootstrap-CI and Mann-Whitney implementations are unit-tested
under `zig build test` — `build.zig` compiles the module as its own test root,
because nothing else in this package imports it and untested verdict math is
the worst kind of dead code: the kind that is trusted.

## Where the binary went

`gist-bench` — the executable that used to root here and dispatch `bench` /
`verify` / `session` / `certify` / `flagbench` / `sessionprof` — lives in the
sibling `gist` package now, at `gist/bench/apparatus/harness/`. Its session
lane spawns a real `gist serve` daemon and speaks the real socket frame
grammar to it, and this package sits **upstream** of that product: `gist`
depends on `irregex`, so the harness cannot live on this side of the edge.
It still reaches back here for all three instruments.

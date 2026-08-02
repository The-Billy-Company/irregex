# Vendored libsais 2.10.2

The pinned, hermetically-built suffix-array constructor behind the codex
FM-index. `src/kernel/math/succinct/sais.zig` is a thin sentinel adapter over
`libsais()`; there is no fallback implementation and no system `liblibsais` is
ever consulted. `build.zig` compiles this single translation unit from source,
so the build is byte-reproducible on any machine.

## Provenance (pin)

| Field    | Value                                                              |
| -------- | ------------------------------------------------------------------ |
| Version  | **2.10.2**                                                         |
| Upstream | https://github.com/IlyaGrebnov/libsais                             |
| Release  | https://github.com/IlyaGrebnov/libsais/releases/tag/v2.10.2        |
| Tarball  | `v2.10.2.tar.gz`                                                   |
| sha256   | `e2fe778b69dcd9e4a1df57b8eefb577f803788336855b6a5f9fbf22683f3980e` |
| License  | Apache-2.0 — Copyright (c) 2021-2025 Ilya Grebnov — see `LICENSE`  |

Verify the pin:

```sh
curl -fsSL -o v2.10.2.tar.gz \
  https://github.com/IlyaGrebnov/libsais/archive/refs/tags/v2.10.2.tar.gz
shasum -a 256 v2.10.2.tar.gz
# → e2fe778b69dcd9e4a1df57b8eefb577f803788336855b6a5f9fbf22683f3980e
```

## What is vendored (and why this exact layout)

Two files, byte-identical to the tarball:

| Vendored file        | Upstream source      | Why                                    |
| -------------------- | -------------------- | -------------------------------------- |
| `src/libsais.c`      | `src/libsais.c`      | the 8-bit constructor, self-contained  |
| `include/libsais.h`  | `include/libsais.h`  | its declarations                       |

`libsais.c` includes only `libsais.h` and five C99 headers (`stddef.h`,
`stdint.h`, `stdlib.h`, `string.h`, `limits.h`) — no other upstream translation
unit is reachable from the 8-bit entry points, so the wide-alphabet (`libsais16`,
`libsais16x64`, `libsais64`) and BWT-auxiliary units are deliberately omitted.
Codex feeds bytes, and `sais.build` caps at `i32` indices, so the 32-bit 8-bit
unit is the whole reachable surface.

The OpenMP entry points (`libsais_omp` and friends) sit behind
`#if defined(LIBSAIS_OPENMP)` and stay compiled out — measured, not assumed, and
the measurement is the reason. Compiled against Homebrew `libomp` and timed
inside the real codex pipeline, the best parallel arm ran the sort in 5662 ms
against serial libsais at 5949 ms: about **1.05×**, in exchange for a
`libomp`/`libgomp` runtime that is in neither the toolchain nor the ledger and
that every build host, cross-compile target, and CI image would have to carry.
Codex declined it and sharded the phases it owns instead
(`kernel/math/parallel.zig`, pure `std.Thread`, zero dependencies), which is why
the sort is now a *third* of a build that used to be seven eighths. What earns
the pin is the serial path: 5949 ms against 15304 ms for Zig's own `sais.build`,
a 2.57× that costs no link-time dependency at all.

Read the parallel arms as a decline and not as a scaling curve. They came off a
box with other tenants on it, and they do not increase with threads — 4 at
7647 ms, 8 at 10471 ms, 12 at 6512 ms, 16 at 5662 ms — which puts the 8-thread
arm slowest of the four and slower than serial. A table that shape is measuring
the load. `omp-scale.sh` exists to retake it in a quiet window and never caught
one, so there is no trustworthy thread-scaling table for this dependency; what
the evidence supports is only that OpenMP did not buy enough here to pay for
itself, and the shape of its scaling is still an open question if anyone
revisits it.

The harness that priced it built this same translation unit twice from one
`build.zig`, once plain and once with `-DLIBSAIS_OPENMP` linked against Homebrew
`libomp`, then timed the sort inside the real codex pipeline (SA-IS → BWT →
wavelet+RRR → locate) over a 200 MB corpus at min of 2 reps, proving
`sa_sentinel == [n] ++ libsais_sa` byte for byte on every arm so a faster sort
could not be a wronger one.

## Updating

Re-download the next release, verify its sha256, replace the two files, refresh
the pin above and in `build.zig.zon`, then `zig build && zig build test` from
this package root.

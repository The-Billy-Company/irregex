<!--
doc_radar:
  sentinels:
    - file: include/libsais.h
      contains:
        - "#define LIBSAIS_VERSION_STRING  \"2.10.2\""
    - file: LICENSE
      contains:
        - "Apache License"
-->

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
`#if defined(LIBSAIS_OPENMP)` and stay compiled out — measured, not assumed.
Compiled against Homebrew `libomp`, `libsais_omp` buys **1.65×** on the sort and
saturates at 8 threads, and beyond that adds threads without adding speed. That
is the whole offer, and the price is a `libomp`/`libgomp` runtime that is in
neither the toolchain nor the ledger and that every build host, cross-compile
target, and CI image would have to carry. Codex declined it and sharded the
phases it owns instead (`kernel/math/parallel.zig`, pure `std.Thread`,
zero dependencies), which is why the sort is now a *third* of a build that used
to be seven eighths. The pin keeps the code available for the day a second
1.65× is worth a link-time dependency; the harness that priced it is
`spikes/libsais-eval/` (`-Domp=true`).

## Updating

Re-download the next release, verify its sha256, replace the two files, refresh
the pin above and in `build.zig.zon`, then `zig build && zig build test` from
this package root.

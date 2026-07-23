---
doc_radar:
  counts:
    - description: "vendor keeps the hermetic PCRE2 tree"
      glob: pkg/kernels/irregex/vendor/*
      unit: dirs
      equals: 1
  sentinels:
    - description: "PCRE2 is built from the vendored tree, not the system lib"
      file: pkg/kernels/irregex/vendor/pcre2/README.md
      contains: "10.47"
---

# `vendor/` — hermetic third-party sources

Pinned upstream trees built into the kernel so CI and developer machines do
not depend on system packages for match semantics.

| Tree | What | Why vendored |
| ---- | ---- | ------------ |
| [`pcre2/`](pcre2) | PCRE2 10.47 (8-bit + JIT/sljit) | Opt-in `-P` / `--engine auto` — no system `libpcre2` |

Zig wrappers live under `src/kernel/match/regex/pcre2/`; `build.zig` compiles
the C sources as `pcre2Library`. Version bumps: re-pin the tarball sha in
the pcre2 README / build wiring, keep `src/` ↔ `deps/sljit/` layout, and
re-run the PCRE parity gates.

Do not add casual vendor trees here — prefer a hermetic pin with a README
that states version, license, and the Billy-side wrapper path.

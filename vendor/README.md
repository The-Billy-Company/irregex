---
doc_radar:
  counts:
    - description: "vendor keeps the hermetic C floor — one tree per library"
      glob: pkg/kernels/irregex/vendor/*
      unit: dirs
      equals: 2
  sentinels:
    - description: "PCRE2 is built from the vendored tree, not the system lib"
      file: pkg/kernels/irregex/vendor/pcre2/README.md
      contains: "10.47"
    - description: "libsais is built from the vendored tree, not a system lib"
      file: pkg/kernels/irregex/vendor/libsais/README.md
      contains: "2.10.2"
    - description: "both trees are rows in build.zig's declarative C floor"
      file: pkg/kernels/irregex/build.zig
      contains:
        - "vendor/pcre2/src"
        - "vendor/libsais/src"
---

# `vendor/` — hermetic third-party sources

Pinned upstream trees built into the kernel so CI and developer machines do
not depend on system packages for match semantics or index construction.

| Tree | What | Why vendored |
| ---- | ---- | ------------ |
| [`pcre2/`](pcre2) | PCRE2 10.47 (8-bit + JIT/sljit) | Opt-in `-P` / `--engine auto` — no system `libpcre2` |
| [`libsais/`](libsais) | libsais 2.10.2 (8-bit suffix array) | The codex FM-index's suffix sort — no system `libsais` |

Together these are **the C floor**: `build.zig` holds one declarative row per
library (name, include path, sources, feature flags) and links the whole set
onto any module that compiles the engine, each archive built at that module's
own optimize. Adding a library is a row there plus a tree here — never a
call-site sweep.

Both are bound with explicit `extern` declarations rather than `@cImport`
(`src/kernel/match/regex/pcre2/ffi.zig`,
`src/corpus/index/codex/sais.zig`), so no module outside `build.zig` needs
their include paths. Version bumps: re-pin the tarball sha in that library's
README, refresh its `contracts/trust/supply-chain/ledger.toml` row and the
`.lazy` provenance entry in `build.zig.zon`, then re-run the gates the library
backs — the PCRE parity slate, or `zig build test -Dtest-filter='sais:'` and
`zig build codex-scale`.

Do not add casual vendor trees here — prefer a hermetic pin with a README
that states version, license, and the Billy-side wrapper path.

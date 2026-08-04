# `vendor/` — Hermetic Third-Party Sources

`vendor/` holds pinned upstream trees built directly into the kernel, so neither CI nor a developer machine depends on a system package for match semantics or index construction.

irregex vendors exactly two libraries:

- **[`pcre2/`](pcre2)** is PCRE2 10.47, an 8-bit build with JIT/sljit support, backing the opt-in `-P` / `--engine auto` escalation path so no system `libpcre2` is ever consulted.
- **`libsais/`** is libsais 2.10.2, an 8-bit suffix-array construction library backing the codex FM-index's suffix sort, so no system `libsais` is consulted either.

Together these are the C floor. `build.zig` holds one declarative row per library — name, include path, sources, feature flags — and links the whole set onto any module that compiles the engine, with each archive built at that module's own optimize level. Adding a library means adding a row in `build.zig` plus a tree here, never a call-site sweep across the codebase.

Both libraries are bound with explicit `extern` declarations rather than `@cImport`, so no module outside `build.zig` needs their include paths. The PCRE2 wrapper lives in `src/kernel/regex/pcre2/ffi.zig`; the libsais wrapper lives in `src/kernel/math/succinct/sais.zig`.

Bumping a vendored version takes three steps. Re-pin the tarball hash in that library's own README (`pcre2/README.md` or `libsais/README.md`), refresh the matching `.lazy` dependency entry in `build.zig.zon`, then re-run the tests the library backs — the PCRE2 JIT-vs-interpreter parity tests in `src/kernel/regex/pcre2/backend_test.zig`, or `zig build test -Dtest-filter='sais:'` for libsais.

Do not add a casual vendor tree here. Prefer a hermetic pin with its own README stating version, license, and the consumer-side wrapper path.

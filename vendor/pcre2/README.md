# Vendored PCRE2 10.47

The pinned, hermetically-built PCRE2 sources behind gist's opt-in `-P`/`--pcre2`
engine. gist consults **no** system/global `libpcre2`; `build.zig`
(`pcre2Library`) compiles these sources from source, so the build is
byte-reproducible on any machine. The Zig wrapper lives in
`../../src/regex/pcre2/`.

## Provenance (pin)

| Field       | Value                                                              |
| ----------- | ------------------------------------------------------------------ |
| Version     | **10.47** (released 2025-10-21)                                    |
| Upstream    | https://github.com/PCRE2Project/pcre2                              |
| Release     | https://github.com/PCRE2Project/pcre2/releases/tag/pcre2-10.47     |
| Tarball     | `pcre2-10.47.tar.bz2`                                              |
| sha256      | `47fe8c99461250d42f89e6e8fdaeba9da057855d06eb7fc08d9ca03fd08d7bc7` |
| License     | BSD-3-Clause WITH PCRE2-exception (JIT: 2-clause BSD) — see `LICENCE.md` |

Verify the pin:

```sh
curl -fsSL -o pcre2-10.47.tar.bz2 \
  https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.bz2
shasum -a 256 pcre2-10.47.tar.bz2
# → 47fe8c99461250d42f89e6e8fdaeba9da057855d06eb7fc08d9ca03fd08d7bc7
```

## What is vendored (and why this exact layout)

Only the 8-bit library subset needed to compile + match is kept — the canonical
set from PCRE2's own `NON-AUTOTOOLS-BUILD` guide (step 4). Every `.c`/`.h` under
`src/` is byte-identical to the tarball, with three files taken from their
build-time templates exactly as the guide prescribes:

| Vendored file            | Upstream source           |
| ------------------------ | ------------------------- |
| `src/config.h`           | `src/config.h.generic`    |
| `src/pcre2.h`            | `src/pcre2.h.generic`     |
| `src/pcre2_chartables.c` | `src/pcre2_chartables.c.dist` |

`deps/sljit/` is the JIT backend: `src/pcre2_jit_compile.c` `#include`s
`../deps/sljit/sljit_src/sljitLir.c` relative to the `src/` dir, so the
`src/` ↔ `deps/` layout must be preserved. Docs, tests, autotools/CMake build
scaffolding, and the non-8-bit widths are intentionally omitted.

Feature selection (8-bit, Unicode/UTF, JIT, static) is passed as `-D` flags in
`build.zig`, so the vendored `config.h` stays byte-identical to upstream —
updates are a clean re-vendor, never a patch to reconcile.

## Updating

Re-download the next release, verify its signature/sha256, replace `src/` +
`deps/sljit/` with the same file subset, refresh the pin above and the
pin in `build.zig.zon`, then `zig build && zig build test` from this package
root (and the product packages that depend on it).

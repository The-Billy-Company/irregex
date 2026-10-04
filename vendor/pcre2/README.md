---
doc_radar:
  sentinels:
    - file: build.zig.zon
      contains: [ "pcre2-10.49" ]
    - file: src/kernel/regex/pcre2/engine.zig
      contains: [ "pcre2_jit_stack_create_8", "pcre2_jit_stack_assign_8" ]
---

# Vendored PCRE2 10.49

The pinned, hermetically-built PCRE2 sources behind the opt-in `-P`/`--pcre2`
backend a surface can select. This package consults **no** system/global
`libpcre2`; `build.zig` (`pcre2Library`) compiles these sources from source, so
the build is byte-reproducible on any machine. The Zig wrapper lives in
`../../src/kernel/regex/pcre2/`.

## Provenance (pin)

| Field       | Value                                                              |
| ----------- | ------------------------------------------------------------------ |
| Version     | **10.49** (released 2026-09-28)                                    |
| Upstream    | https://github.com/PCRE2Project/pcre2                              |
| Release     | https://github.com/PCRE2Project/pcre2/releases/tag/pcre2-10.49     |
| Tarball     | `pcre2-10.49.tar.gz`                                              |
| sha256      | `929f0b20e62879252a15886b06c89f1edef61a363cbd5826fb041080a5e557ae` |
| License     | BSD-3-Clause WITH PCRE2-exception (JIT: 2-clause BSD) - see `LICENCE.md` |

PCRE2 10.49 fixes [CVE-2026-103111](https://github.com/PCRE2Project/pcre2/security/advisories/GHSA-r9hj-j2rw-4q3m). Our per-thread scratch uses the affected growable JIT stack; keep this floor when updating. The release signature is verified against the [maintainer fingerprint](https://github.com/PCRE2Project/pcre2/blob/master/SECURITY.md), `A95536204A3BB489715231282A98E77EB6F24CA8`.

Verify the pin:

```sh
curl -fsSL -o pcre2-10.49.tar.gz \
  https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.gz
shasum -a 256 pcre2-10.49.tar.gz
# expected: 929f0b20e62879252a15886b06c89f1edef61a363cbd5826fb041080a5e557ae
```

## What is vendored (and why this exact layout)

Only the 8-bit library subset needed to compile + match is kept - the canonical
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
`build.zig`, so the vendored `config.h` stays byte-identical to upstream -
updates are a clean re-vendor, never a patch to reconcile.

## Updating

Re-download the next release, verify its signature/sha256, replace `src/` +
`deps/sljit/` with the same file subset, refresh the pin above and the
pin in `build.zig.zon`, then `zig build && zig build test` from this package
root (and the product packages that depend on it).

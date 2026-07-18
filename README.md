---
doc_radar:
  counts:
    - description: "irregex src/ tiers — the shared floor (corpus · scope · primitives) + the two engines (gist · hydra)"
      glob: pkg/kernels/irregex/src/*
      unit: dirs
      equals: 5
  sentinels:
    - description: "the Zig package identity is irregex"
      file: pkg/kernels/irregex/build.zig.zon
      contains: ".name = .irregex,"
    - description: "the C ABI is the irregex_* session surface (libirregex, include/irregex.h)"
      file: pkg/kernels/irregex/include/irregex.h
      contains: ["irregex_abi_version", "irregex_open", "irregex_search", "irregex_close"]
    - description: "registered in the changelog roster (OSS-package membership)"
      file: pkg/tools/support/chronicle/packages.py
      contains: 'Package("pkg/kernels/irregex"'
    - description: "the irregex primitives tier is a first-class root export"
      file: pkg/kernels/irregex/src/root.zig
      contains: "pub const irregex = struct"
---

# irregex

The **irregular expression engine**: one Zig kernel that treats text as a
*set-shaped* problem — regular-expression **match**, compression-based
**relate**, and engine-side **weave** — and ships the product tools built on
those primitives. Where a regex answers *"does this text match?"*, irregex
also answers *"which of these N intents hit, and where?"*, *"what in this tree
is LIKE this file?"*, and *"shape the answer before it costs tokens"*
([ADR-363](../../../docs/architecture/3-decisions/363-irregex-primitives.md)).

> **Scope:** build-time dev tooling for the coding agents that work _on_
> Billy. It has nothing to do with Billy-the-product.

## The products

| Face | What it is | Docs |
|---|---|---|
| **gist** | the rg-parity code locator CLI — trigram index, ranked search, resident session; the agents' everyday search reflex | [`src/gist/README.md`](src/gist/README.md) |
| **hydra** | compression-as-search — the `similar` / `dups` / `patterns` verbs (LZJD kinship, multi-pattern attribution, loom shaping) | [`src/hydra/README.md`](src/hydra/README.md) |
| **ffi** | the in-process C-ABI warm session (`irregex_open` / `irregex_search` / `irregex_close` over `libirregex`) | [`src/gist/faces/ffi/README.md`](src/gist/faces/ffi/README.md) |

The two CLIs are separate engines over a small shared floor (`src/corpus/`,
`src/scope/`, `src/primitives/`); the `gist` binary name — and every
`gist <pattern>` reflex, flag, and exit code — is unchanged.

## Package layout

| Dir | What |
|---|---|
| `src/corpus/` + `src/scope/` | the shared floor both engines ride — corpus walk/loading + path scoping |
| `src/primitives/` | the shared irregex math — `patterns` (match ∪ attribute), `sketch` (LZJD relate), `loom` (weave) |
| `src/gist/` | the exact-search engine — `kernel/` (engine, trigram index, regex, rank, scan), `session/` (ADR-352 rung 2.5), `faces/` (cli · ffi) |
| `src/hydra/` | the compression-search engine — `engine/` verb drivers + `cli/` binary shell |
| `include/` | `irregex.h` — the flat C ABI (`irregex_*` symbols) |
| `bindings/` | Python (`billy-gist`, subprocess + optional cffi over `libirregex`) and Rust (subprocess) faces |
| `contract/` | `search_api.toml` — the unified SearchRequest/irregex contract (ADR-352) |
| `bench/` | certification + competitive benchmark harness (rgsuite, races, certify, roofline) |

See [`src/README.md`](src/README.md) for the tier-by-tier map and
[`src/gist/README.md`](src/gist/README.md) for the architecture
narrative, competitive benchmarks, and the full rg-parity flag table.

## Build & test

```bash
make install-gist   # build (ReleaseFast) + symlink ~/.local/bin/gist + index
make build-gist     # staticlib + dynlib (libirregex) + irregex.h → zig-out/
make test-gist      # zig build test — unit + differential-fuzz suites
```

One changelog covers the whole package (one version, one release unit):
`CHANGELOG.md` + `changelog.d/` at this root, roster row `gist` in
`pkg/tools/support/chronicle/packages.py`.

---
doc_radar:
  counts:
    - description: "irregex src/ tiers — kernel/ (engine · index · regex · rank · scan · corpus · scope) + primitives/ (patterns · sketch · loom) + faces/ (cli · gist · hydra · ffi) + session/ resident transport (ADR-352 rung 2.5)"
      glob: pkg/kernels/irregex/src/*
      unit: dirs
      equals: 4
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
| **gist** | the rg-parity code locator CLI — trigram index, ranked search, resident session; the agents' everyday search reflex | [`src/faces/gist/README.md`](src/faces/gist/README.md) |
| **hydra** | compression-as-search — the `similar` / `dups` / `patterns` verbs (LZJD kinship, multi-pattern attribution, loom shaping) | [`src/faces/hydra/README.md`](src/faces/hydra/README.md) |
| **ffi** | the in-process C-ABI warm session (`irregex_open` / `irregex_search` / `irregex_close` over `libirregex`) | [`src/faces/ffi/README.md`](src/faces/ffi/README.md) |

Both CLIs ride the same kernel and the same persisted index; the `gist` binary
name — and every `gist <pattern>` reflex, flag, and exit code — is unchanged.

## Package layout

| Dir | What |
|---|---|
| `src/kernel/` | the search kernel every face shares — engine, trigram index, linear-time regex, rank, scan, corpus, scope |
| `src/primitives/` | the irregex tier — `patterns` (match ∪ attribute), `sketch` (LZJD relate), `loom` (weave) |
| `src/faces/` | product surfaces — `cli/` dispatcher, `gist/`, `hydra/`, `ffi/` |
| `src/session/` | the resident-session transport (ADR-352 rung 2.5) |
| `include/` | `irregex.h` — the flat C ABI (`irregex_*` symbols) |
| `bindings/` | Python (`billy-gist`, subprocess + optional cffi over `libirregex`) and Rust (subprocess) faces |
| `contract/` | `search_api.toml` — the unified SearchRequest/irregex contract (ADR-352) |
| `bench/` | certification + competitive benchmark harness (rgsuite, races, certify, roofline) |

See [`src/README.md`](src/README.md) for the tier-by-tier map and
[`src/faces/gist/README.md`](src/faces/gist/README.md) for the architecture
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

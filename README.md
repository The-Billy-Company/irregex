---
doc_radar:
  counts:
    - description: "irregex src/ tiers — the shared floor (corpus · scope · primitives) + the two engines (gist · hydra) + the codex self-index"
      glob: pkg/kernels/irregex/src/*
      unit: dirs
      equals: 6
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
_set-shaped_ problem — regular-expression **match**, compression-based
**relate**, and engine-side **weave** — and ships the product tools built on
those primitives. Where a regex answers _"does this text match?"_, irregex
also answers _"which of these N intents hit, and where?"_, _"what in this tree
is LIKE this file?"_, and _"shape the answer before it costs tokens"_
([ADR-363](../../../docs/architecture/3-decisions/363-irregex-primitives.md)).

> **Scope:** build-time dev tooling for the coding agents that work _on_
> Billy. It has nothing to do with Billy-the-product.

## The products

| Face      | What it is                                                                                                                                 | Docs                                                           |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------- |
| **gist**  | the rg-parity code locator CLI — trigram index, ranked search, resident session; the agents' everyday search reflex                        | [`src/gist/README.md`](src/gist/README.md)                     |
| **hydra** | compression-as-search — the `search` / `quote` / `similar` / `dups` / `patterns` verbs (retrieval by description length, corpus-global quotation, LZJD kinship, multi-pattern attribution) | [`src/hydra/README.md`](src/hydra/README.md) |
| **codex** | the compressed self-index — a corpus stored at entropy-bound size that answers exact `count`/`find` in O(m) and restores itself byte-exact; persisted as the shelf behind `gist codex` + `hydra quote` | [`src/codex/README.md`](src/codex/README.md) |
| **ffi**   | the in-process C-ABI warm session (`irregex_open` / `irregex_search` / `irregex_close` over `libirregex`)                                  | [`src/gist/faces/ffi/README.md`](src/gist/faces/ffi/README.md) |

The two CLIs are separate engines over a small shared floor (`src/corpus/`,
`src/scope/`, `src/primitives/`); the `gist` binary name — and every
`gist <pattern>` reflex, flag, and exit code — is unchanged.

## codex — the index that IS the compression

The kernel's third engine started as a Shannon-flavored claim: _all text is a
number stream; if that stream's information is already indexed, lookup should
run at the lowest time complexity physically possible — and the index itself
should **be** a compression of the stream._ That claim is a theorem
(FM-index: Ferragina–Manzini 2000), and `src/codex/` is its production
implementation:

- **Idea** — a Burrows–Wheeler permutation of the corpus, held in a
  Huffman-shaped wavelet tree over RRR entropy-coded bitvectors, is
  simultaneously ① a lossless code near the k-th order entropy nH_k and ② a
  search structure answering `count(P)` in O(|P|) rank steps — flat in corpus
  size, which is the Ω(m) information-theoretic floor.
- **Implementation** — SA-IS O(n) suffix array → BWT → canonical-Huffman
  wavelet tree → per-level RRR-vs-plain adoption (never loses space), plus
  sampled locate and whole-corpus `restore()`. After build, the text, suffix
  array, and BWT are all freed: residency IS the index.
- **Testing** — every layer differential against a naive oracle (sort-based
  suffix arrays, prefix-popcount ranks, literal scans, `std.mem` searches)
  over degenerate/Fibonacci/binary/all-256-byte corpora plus a seeded
  property-fuzz loop; nothing asserts a value the implementation produced for
  itself.
- **Proof at scale** — `zig build codex-scale` over 128MB of real repo
  source: **1.95 bits/char** for the count-index (below the corpus's own
  measured H₂ of 2.90; raw is 8), `count(P)` flat at **~11µs** from 1MB to
  128MB (**3,727×** a naive scan at 128MB, growing unboundedly with n), and
  the entire 128MB restored byte-exact from the index alone. Persistence
  loads at 0.3% of build cost (29ms at 128MB), reload re-verified against
  the same oracle. Full tables in
  [`src/codex/README.md`](src/codex/README.md); harness in
  [`bench/codex/`](bench/codex/README.md).
- **Product tiers** — the shelf (`gist codex build` persists it under
  `.local/gist-verify/`, 209MB repo → one 76MB `codex.shelf`) backs two
  verbs: **`gist codex count|tally`**, the zero-false-positive
  existence/count tier (`count == 0`
  with a clean freshness walk is a proof of absence, ~100ms cold, no corpus
  I/O), and **`hydra quote`**, the corpus-global relate tier (Ziv–Merhav
  cross-parse: quote any text out of the whole corpus, priced in bits,
  each phrase attributed to a source file — ~0.15 bits/byte for text the
  corpus knows vs ~15 for foreign bytes, a ~90× separation).

## Package layout

| Dir                          | What                                                                                                                                       |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `src/corpus/` + `src/scope/` | the shared floor both engines ride — corpus walk/loading + path scoping                                                                    |
| `src/primitives/`            | the shared irregex math — `bits` (two's-complement identity floor), `patterns` (match ∪ attribute), `sketch` (LZJD relate), `loom` (weave) |
| `src/gist/`                  | the exact-search engine — `kernel/` (engine, trigram index, regex, rank, scan), `session/` (ADR-352 rung 2.5), `faces/` (cli · ffi)        |
| `src/hydra/`                 | the compression-search engine — `engine/` verb drivers + `cli/` binary shell                                                               |
| `src/codex/`                 | the compressed self-index — FM-index (SA-IS · RRR · wavelet): count/find/restore at entropy-bound space, O(m) flat in corpus size          |
| `include/`                   | `irregex.h` — the flat C ABI (`irregex_*` symbols)                                                                                         |
| `bindings/`                  | Python (`billy-gist`, subprocess + optional cffi over `libirregex`) and Rust (subprocess) faces                                            |
| `contract/`                  | `search_api.toml` — the unified SearchRequest/irregex contract (ADR-352)                                                                   |
| `bench/`                     | certification + competitive benchmark harness (rgsuite, races, certify, roofline)                                                          |

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

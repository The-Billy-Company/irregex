# irregex/src

Zig sources for the irregular expression kernel: its two product engines
(gist · hydra) and the codex self-index. Every module is re-exported through
`root.zig` and surfaced via the flat C-ABI in `../include/irregex.h`.
`bench/` holds only the benchmark/verify harness — no engine code lives
there.

## Layout

Two engines and a self-index over a small shared floor. `gist/` owns
everything the exact locator needs and nothing hydra rides; hydra reuses only
the shared math and the corpus substrate; codex stands alone on `sais` + its
own succinct structures.

| Tier          | What lives there                                                                                                                                                |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `corpus/`     | the shared corpus substrate — loading (rg-style binary/skip rules, stdout results contract), the Haystack walk, `getattrlistbulk` bulk stat                     |
| `scope/`      | shared path scoping — `-g <glob>` matching (`glob.zig`) + the `-t <lang>` type table (`types.zig`)                                                              |
| `primitives/` | the shared irregex math (ADR-363) — `bits` (the two's-complement identity floor), `patterns` (match), `sketch` (relate), `loom` (weave)                         |
| `gist/`       | the exact-search engine + the `gist` product faces — nothing here is consumed by hydra's relate math                                                            |
| `hydra/`      | the compression-search engine + the `hydra` binary                                                                                                              |
| `codex/`      | the compressed self-index — SA-IS → BWT → RRR wavelet tree; count/find/restore at entropy space, O(m) flat in corpus size (the Shannon rung under both engines) |

### `gist/` — the exact-search engine

| Folder                | Concern                                                                                                                                              |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gist/kernel/index/`  | **T0** trigram candidate index — n-gram extraction, posting-list build/query, zero-copy `mmap` persistence, + the T3 mtime freshness overlay         |
| `gist/kernel/regex/`  | linear-time regex — Thompson NFA + byte-class DFA + Pike fallback, sound literal analysis, capture VM                                                |
| `gist/kernel/rank/`   | **T4** ranked output — weighted Reciprocal Rank Fusion over intrinsic, language-agnostic signals                                                     |
| `gist/kernel/scan/`   | the no-prefilter fallback — SIMD substring presence + fused work-stealing parallel verify over the live tree                                         |
| `gist/kernel/engine/` | the transport-neutral compiled query — one compile → sound trigram prefilter → per-doc match/count/span kernels that every face executes through     |
| `gist/session/`       | the resident-session transport (ADR-352 rung 2.5) — warm error-returning engine, UDS wire codec, eligibility classifier, freshness watcher           |
| `gist/faces/cli/`     | the `gist` binary face — entrypoint, `--schema`, `index`/`status`/`serve`/`codex`, and the unified search engine (rg-DEFAULT drop-in)                |
| `gist/faces/ffi/`     | the in-process C-ABI search session (ADR-352 rung 3) — `irregex_open`/`irregex_search`/`irregex_close`, streaming Match records to a caller callback |

### `hydra/` — the compression-search engine

| Folder          | Concern                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------- |
| `hydra/engine/` | the relate engine — retrieval core (`lexicon` / `zipper`), verb drivers (`search` / `quote` / `similar` / `dups` / `patterns`) |
| `hydra/cli/`    | the `hydra` binary — thin dispatch (`main.zig`) + the `--schema` capability manifest (`schema.zig`)         |

### `codex/` — the compressed self-index

The Shannon rung: an FM-index whose residency **is** a lossless compression
of the corpus — the index is the book; the book restores from the index.
Idea → proof → production: rung-1 prototype in
`spikes/shannon-self-index/`, graduated here with the O(n) suffix
array, entropy-coded bitvectors, and locate support.

| File                   | Concern                                                                                                                            |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `codex/sais.zig`       | SA-IS linear-time suffix array (Nong–Zhang–Chan) — build-time only, freed after the BWT                                            |
| `codex/rrr.zig`        | Plain + RRR (Raman–Raman–Rao) bitvectors behind one `Bits` seam — O(1) rank at entropy space; `adopt` keeps the smaller per vector |
| `codex/wavelet.zig`    | canonical-Huffman wavelet tree — `occ`/`access` in one descent; per-level RRR adoption lands the tree near nH_k                    |
| `codex/codex.zig`      | the `Codex`: `build` → `count` (O(m), flat in n) / `find` (sampled locate) / `restore` (byte-exact) + checksummed `save`/`load`    |
| `codex/cento.zig`      | the corpus-quotation parse — Ziv–Merhav cross-parse + Shannon phrase pricing over a codex (backs `hydra quote`)                    |
| `codex/shelf.zig`      | a multi-document corpus behind one codex — doc catalog, offsets, freshness anchor; per-file `tally` (backs `gist codex`)           |
| `codex/codex_test.zig` | the adversarial suite — every layer differential vs a naive oracle, plus a seeded property-fuzz loop                               |

Tested against oracles at every layer and proven at scale by
`zig build codex-scale` (`../bench/codex/`): **1.95 bits/char** at 128MB
(below the corpus's measured H₂), count flat at **~11µs** across 1→128MB
(**3,727×** a naive scan), whole-corpus byte-exact restore, load at 0.3% of
build, and a ~90× native-vs-foreign cross-parse separation. Two product
tiers ride it: `gist codex` (exact existence/count, zero corpus I/O) and
`hydra quote` (corpus-global relatedness). Math, tables, and references in
[`codex/README.md`](codex/README.md).

`root.zig` is the package/C-ABI root: it re-exports each tier, pins
`irregex_abi_version`, exposes `irregex_trigram_count` (the parity oracle), and
aggregates every `*_test.zig` so `zig build test` type-checks the whole tree.

See [`../README.md`](../README.md) for the architecture narrative, competitive
benchmarks, and build commands; [`gist/kernel/regex/README.md`](gist/kernel/regex/README.md)
for the regex engine internals.

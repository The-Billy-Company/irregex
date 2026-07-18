# irregex/src

Zig sources for the irregular expression kernel and its two product engines. Every module
is re-exported through `root.zig` and surfaced via the flat C-ABI in
`../include/irregex.h`. `bench/` holds only the benchmark/verify harness — no
engine code lives there.

## Layout

Two engines over a small shared floor. `gist/` owns everything the exact
locator needs and nothing hydra rides; hydra reuses only the shared math and
the corpus substrate.

| Tier          | What lives there                                                                                                                            |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `corpus/`     | the shared corpus substrate — loading (rg-style binary/skip rules, stdout results contract), the Haystack walk, `getattrlistbulk` bulk stat  |
| `scope/`      | shared path scoping — `-g <glob>` matching (`glob.zig`) + the `-t <lang>` type table (`types.zig`)                                           |
| `primitives/` | the shared irregex math (ADR-363) — `patterns` (match), `sketch` (relate), `loom` (weave)                                                    |
| `gist/`       | the exact-search engine + the `gist` product faces — nothing here is consumed by hydra's relate math                                         |
| `hydra/`      | the compression-search engine + the `hydra` binary                                                                                           |

### `gist/` — the exact-search engine

| Folder                 | Concern                                                                                                                                          |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gist/kernel/index/`   | **T0** trigram candidate index — n-gram extraction, posting-list build/query, zero-copy `mmap` persistence, + the T3 mtime freshness overlay        |
| `gist/kernel/regex/`   | linear-time regex — Thompson NFA + byte-class DFA + Pike fallback, sound literal analysis, capture VM                                               |
| `gist/kernel/rank/`    | **T4** ranked output — weighted Reciprocal Rank Fusion over intrinsic, language-agnostic signals                                                    |
| `gist/kernel/scan/`    | the no-prefilter fallback — SIMD substring presence + fused work-stealing parallel verify over the live tree                                        |
| `gist/kernel/engine/`  | the transport-neutral compiled query — one compile → sound trigram prefilter → per-doc match/count/span kernels that every face executes through    |
| `gist/session/`        | the resident-session transport (ADR-352 rung 2.5) — warm error-returning engine, UDS wire codec, eligibility classifier, freshness watcher          |
| `gist/faces/cli/`      | the `gist` binary face — entrypoint, `--schema`, `index`/`status`/`serve`, and the unified search engine (rg-DEFAULT drop-in)                        |
| `gist/faces/ffi/`      | the in-process C-ABI search session (ADR-352 rung 3) — `irregex_open`/`irregex_search`/`irregex_close`, streaming Match records to a caller callback |

### `hydra/` — the compression-search engine

| Folder          | Concern                                                                                                             |
| --------------- | --------------------------------------------------------------------------------------------------------------------- |
| `hydra/engine/` | the relate engine — verb drivers over the shared `primitives/` math (`similar` / `dups` / `patterns` today)            |
| `hydra/cli/`    | the `hydra` binary — thin dispatch (`main.zig`) + the `--schema` capability manifest (`schema.zig`)                    |

`root.zig` is the package/C-ABI root: it re-exports each tier, pins
`irregex_abi_version`, exposes `irregex_trigram_count` (the parity oracle), and
aggregates every `*_test.zig` so `zig build test` type-checks the whole tree.

See [`../README.md`](../README.md) for the architecture narrative, competitive
benchmarks, and build commands; [`gist/kernel/regex/README.md`](gist/kernel/regex/README.md)
for the regex engine internals.

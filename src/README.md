# gist/src

Zig sources for the `gist` code-locator kernel, grouped into three
concern-scoped tiers plus the resident transport. Every module is re-exported
through `root.zig` and surfaced via the flat C-ABI in `../include/irregex.h`.
`bench/` holds only the benchmark/verify harness — no engine code lives there.

## Layout

| Tier          | What lives there                                                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `kernel/`     | the search kernel every face rides — nothing here knows about CLIs or verbs                                                                 |
| `primitives/` | the irregex tier (ADR-363) — set-shaped operations composed *from* the kernel: `patterns` (match), `sketch` (relate), `loom` (weave)         |
| `faces/`      | the product surfaces — the only tier that composes the others end-to-end                                                                     |
| `session/`    | the resident-session transport (ADR-352 rung 2.5) — warm error-returning engine, UDS wire codec, eligibility classifier, freshness watcher   |

### `kernel/` — the shared search kernel

| Folder           | Concern                                                                                                                                     |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `kernel/index/`  | **T0** trigram candidate index — n-gram extraction, posting-list build/query, zero-copy `mmap` persistence                                    |
| `kernel/regex/`  | linear-time regex — Thompson NFA + byte-class DFA + Pike fallback, sound literal analysis, capture VM                                         |
| `kernel/rank/`   | **T4** ranked output — weighted Reciprocal Rank Fusion over intrinsic, language-agnostic signals                                              |
| `kernel/scan/`   | the no-prefilter fallback — SIMD substring presence + fused work-stealing parallel verify over the live tree                                  |
| `kernel/corpus/` | corpus loading (rg-style binary/skip rules, stdout results contract) + the mtime freshness overlay                                            |
| `kernel/engine/` | the transport-neutral compiled query — one compile → sound trigram prefilter → per-doc match/count/span kernels that every face executes through |
| `kernel/scope/`  | shared path scoping — `-g <glob>` matching (`glob.zig`) + the `-t <lang>` type table (`types.zig`)                                            |

### `faces/` — the product surfaces

The `gist` binary (`faces/cli/main.zig`) is a thin dispatcher; each verb's
logic is a sibling module. The bare `gist <pattern> [PATH...]` shorthand (no
verb) is the everyday front door: zero setup, no index required, live-scans
the current tree with ripgrep's own default behavior (gitignore precedence,
piped stdin, exit codes) so it's a true drop-in for an agent's `rg` reflex.

| Folder                | Verb(s)                                                                                                                                                |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `faces/cli/`          | the `main.zig` entrypoint + the `--schema` capability manifest                                                                                           |
| `faces/gist/ripgrep/` | the unified search engine + `index` verb — the `rg`-DEFAULT drop-in over an arbitrary tree, backing the bare shorthand, `gist rg`/`search`, and `--rank` |
| `faces/gist/status/`  | read-only index introspection — the `status` verb (is an index ready, how fresh, how big)                                                                |
| `faces/gist/serve/`   | the resident-session daemon face (`gist serve`)                                                                                                          |
| `faces/gist/client/`  | the thin client that spawns/dials the resident session                                                                                                   |
| `faces/hydra/`        | the `hydra` binary — compression-as-search: `similar` / `dups` / `patterns` verbs over the primitives tier (`main.zig` dispatch + `--schema` manifest)   |
| `faces/ffi/`          | the in-process C-ABI search session (ADR-352 rung 3) — `irregex_open`/`irregex_search`/`irregex_close`, streaming Match records to a caller callback              |

`root.zig` is the package/C-ABI root: it re-exports each tier, pins
`irregex_abi_version`, exposes `irregex_trigram_count` (the parity oracle), and
aggregates every `*_test.zig` so `zig build test` type-checks the whole tree.

See [`../README.md`](../README.md) for the architecture narrative, competitive
benchmarks, and build commands; [`kernel/regex/README.md`](kernel/regex/README.md)
for the regex engine internals.

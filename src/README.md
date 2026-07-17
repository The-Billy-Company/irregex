# gist/src

Zig sources for the `gist` code-locator kernel, grouped into concern-scoped
subfolders (mirrors [`lamina`](../../lamina/README.md) /
[`principia`](../../principia/README.md)). Every module is re-exported through
`root.zig` and surfaced via the flat C-ABI in `../include/gist.h`. `bench/`
holds only the benchmark/verify harness — no engine code lives there.

## Layout

| Folder      | Tier                                                                                                                                                                                                                       |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `index/`    | **T0** trigram candidate index — n-gram extraction, posting-list build/query, zero-copy `mmap` persistence                                                                                                                 |
| `regex/`    | linear-time regex — Thompson NFA + byte-class DFA + Pike fallback, sound literal analysis, capture VM                                                                                                                      |
| `rank/`     | **T4** ranked output — weighted Reciprocal Rank Fusion over intrinsic, language-agnostic signals                                                                                                                           |
| `scan/`     | the no-prefilter fallback — SIMD substring presence + fused work-stealing parallel verify over the live tree                                                                                                               |
| `corpus/`   | corpus loading (rg-style binary/skip rules, stdout results contract) + the mtime freshness overlay                                                                                                                         |
| `engine/`   | the transport-neutral compiled query — one compile → sound trigram prefilter → per-doc match/count/span kernels that BOTH the cold CLI and the warm session execute through                                                |
| `session/`  | the resident-session transport (ADR-352 rung 2.5) — warm error-returning engine, UDS wire codec, eligibility classifier, fail-closed freshness watcher                                                                     |
| `ffi/`      | the in-process C-ABI search session (ADR-352 rung 3) — `gist_open`/`gist_search`/`gist_close` over the same error-returning resident engine, streaming Match records to a caller callback (no subprocess, socket, or exit) |
| `commands/` | the driver surfaces the CLI dispatches to (see below) — the only tier that composes the others end-to-end                                                                                                                  |

`root.zig` is the package/C-ABI root: it re-exports each tier, pins
`gist_abi_version`, exposes `gist_trigram_count` (the parity oracle), and
aggregates every `*_test.zig` so `zig build test` type-checks the whole tree.

## `commands/` — the product surface

The `gist` binary (`commands/cli/main.zig`) is a thin dispatcher; each verb's
logic is a sibling module. Three real verbs — `index` / `status` / `search` —
plus the bare `gist <pattern> [PATH...]` shorthand (no verb) that is the
everyday front door: zero setup, no index required, live-scans the current
tree with ripgrep's own default behavior (gitignore precedence, piped stdin,
exit codes) so it's a true drop-in for an agent's `rg` reflex.

| Folder              | Verb(s)                                                                                                                                                              |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `commands/cli/`     | the `main.zig` entrypoint + the `--schema` capability manifest                                                                                                       |
| `commands/ripgrep/` | the unified search engine + `index` verb — the `rg`-DEFAULT drop-in over an arbitrary tree, backing the bare shorthand, the `gist rg`/`search` aliases, and `--rank` |
| `commands/status/`  | read-only index introspection — the `status` verb (is an index ready, how fresh, how big)                                                                            |
| `commands/scope/`   | shared path scoping — `-g <glob>` matching (`glob.zig`) + the `-t <lang>` type table (`types.zig`)                                                                   |

See [`../README.md`](../README.md) for the architecture narrative, competitive
benchmarks, and build commands; [`regex/README.md`](regex/README.md) for the
regex engine internals.

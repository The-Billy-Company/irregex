# gist/src

Zig sources for the `gist` code-locator kernel, grouped into concern-scoped
subfolders (mirrors [`lamina`](../../lamina/README.md) /
[`principia`](../../principia/README.md)). Every module is re-exported through
`root.zig` and surfaced via the flat C-ABI in `../include/gist.h`. `bench/`
holds only the benchmark/verify harness — no engine code lives there.

## Layout

| Folder      | Tier                                                                                                         |
| ----------- | ------------------------------------------------------------------------------------------------------------ |
| `index/`    | **T0** trigram candidate index — n-gram extraction, posting-list build/query, zero-copy `mmap` persistence   |
| `regex/`    | linear-time regex — Thompson NFA + byte-class DFA + Pike fallback, sound literal analysis, capture VM        |
| `rank/`     | **T4** ranked output — weighted Reciprocal Rank Fusion over intrinsic, language-agnostic signals             |
| `scan/`     | the no-prefilter fallback — SIMD substring presence + fused work-stealing parallel verify over the live tree |
| `corpus/`   | corpus loading (rg-style binary/skip rules, stdout results contract) + the mtime freshness overlay           |
| `commands/` | the driver surfaces the CLI dispatches to (see below) — the only tier that composes the others end-to-end    |

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

| Folder              | Verb(s)                                                                                            |
| ------------------- | -------------------------------------------------------------------------------------------------- |
| `commands/cli/`     | the `main.zig` entrypoint + the `--schema` capability manifest                                     |
| `commands/search/`  | the one `search` verb (index + query) — replaces the old `query`/`regex`/`rank`/`grep` quartet     |
| `commands/ripgrep/` | the `rg`-DEFAULT drop-in over an arbitrary tree — backs the bare shorthand + the `gist rg` alias   |
| `commands/scope/`   | shared path scoping — `-g <glob>` matching (`glob.zig`) + the `-t <lang>` type table (`types.zig`) |

See [`../README.md`](../README.md) for the architecture narrative, competitive
benchmarks, and build commands; [`regex/README.md`](regex/README.md) for the
regex engine internals.

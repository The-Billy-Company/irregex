# gist/src/commands/search

The one search verb — `gist search <pattern> [PATH…]` — and everything behind
it. Replaces the old `query` / `regex` / `rank` / `grep` quartet: they answered
one question ("what matches, and how do you want it shaped"), so the shape is now
a flag, not a verb.

| File           | Role                                                                                                                                                          |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `run.zig`      | The dispatcher: parses argv, then routes to the fastest correct engine — `--rank` → ranked drivers, `--live` → live scan, plain `--show files` → the cold path-only drivers, everything else → the line engine. Re-exports `runIndex`. |
| `args.zig`     | The **native (Set B)** flag vocabulary — the primary, documented interface (`--show`, `--rank`, `--lang`, `--word`, `--live`, `--json`, …) — plus the shared `Options`/`Parsed`/`Sink` types and the orchestration loop. |
| `compat.zig`   | The **legacy (Set A)** ripgrep/grep alias layer — every `-i -w -F -l -c …` short cluster + long spelling, each an alias onto exactly one native option; the fail-loud / no-op discipline; inline-flag + `--replace` template validation. |
| `drivers.zig`  | The cold, index-backed path-only drivers (`runIndex`, `runQuery`, `runRegex`, `runRank`) — the benchmarked mmap-load + candidate-read fast paths. |
| `emit.zig`     | The `path:line:text` line engine (the default `--show lines`, plus `files`/`count`, `--files`, `--json`) — candidate read + line walk + framing, over an explicit candidate set (`grepOverPaths`). |
| `render.zig`   | Output rendering split out of the line engine: the `-o`/`--replace` span rewrite and the `--json` record shape. |
| `live.zig`     | `--live`: the index-free path — walk the tree, feed every live path to the same line engine (the capability the old `gist rg` verb had, re-homed onto one flag). |

The two flag sets are the design's core: Set B reads clean and is what `--help` /
`--schema` document; Set A is muscle-memory compatibility and the substrate for
the ripgrep differential-parity proof. See [`../../../README.md`](../../../README.md).

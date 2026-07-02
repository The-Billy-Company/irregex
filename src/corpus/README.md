# gist/src/corpus

Corpus loading and the freshness overlay — shared by the CLI drivers, the `grep`
verb, and the bench/verify harness.

| File         | Role                                                                                                                                                                                                                                                                                                                  |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `corpus.zig` | Loads every non-binary file under the roots (rg-style: a NUL byte ⇒ binary ⇒ skipped), minus the build/VCS subtrees; also owns the stdout **results contract** (`emitResults`) every search path emits through.                                                                                                       |
| `fresh.zig`  | The mtime **freshness overlay** — keeps a persisted index correct under concurrent commit churn without rebuilding or consulting git: build stamps a wall-clock anchor, a file is fresh iff `mtime ≥ anchor`, so any changed/new/touched file is folded in and re-verified (0 false negatives, read-your-own-writes). |

The freshness guarantee is immune to the rebases and overlapping edits that
defeat `git diff`-based invalidation (~42 ms cold parallel stat-walk).

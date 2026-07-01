# gist/src/commands/grep

The index-backed **`grep`** verb — the line-emitting command an agent actually
reaches for. A true `rg -n --no-heading` drop-in that serves `path:line:text`
from the persisted index (reading only candidate files) instead of a whole-tree
walk. It unifies literal + regex on one engine (a pure literal is its own
required literal, so it rides the same trigram prefilter).

| File           | Role                                                                                                          |
| -------------- | ------------------------------------------------------------------------------------------------------------- |
| `args.zig`     | The ripgrep flag surface an agent types — bundled short flags, long spellings, no-op corpus-policy flags, and loud failure on the flags gist genuinely can't honor (`-P`, `-U`, `--json`). |
| `emit.zig`     | The match/emit loop — line extraction, context (`-A/-B/-C`), counts (`-c`/`--count-matches`), `-o`/`--replace`, `--files`, served from the persisted index (via `index/persist.zig`). |
| `args_test.zig`| Flag-surface parser tests.                                                                                     |

Measured cold vs the `rg -n <pat>` an agent types: selective symbol queries
**5.3–5.8× faster** while emitting the full line output. See [`../../../README.md`](../../../README.md).

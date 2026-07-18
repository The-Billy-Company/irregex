# irregex/src/scope

Shared **path scoping** — the `-t <lang>` / `-g <glob>` / positional-`PATH`
affordances an agent reaches for to confine a search to a subtree. Because irregex
already holds the path list, these prune candidates _before_ touching disk,
which makes scoping make irregex **faster** (rg filters while walking the whole tree).

| File        | Role                                                                                                              |
| ----------- | ----------------------------------------------------------------------------------------------------------------- |
| `glob.zig`  | Gitignore-shaped glob matching (`*` per-segment, `**` across `/`, `!`-exclude) + the `PathFilter` scoping struct. |
| `types.zig` | The language → extension/filename table (`-t go`/`py`/`rust`/…) with `extsForType` / `isKnownType` lookups.       |

Guarded by `glob_test.zig` + the rg line-diff battery.

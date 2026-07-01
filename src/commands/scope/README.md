# gist/src/commands/scope

Shared **path scoping** — the `-t <lang>` / `-g <glob>` / positional-`PATH`
affordances an agent reaches for to confine a search to a subtree. Because gist
already holds the path list, these prune candidates *before* touching disk,
which makes scoping make gist **faster** (rg filters while walking the whole tree).

| File         | Role                                                                                                            |
| ------------ | --------------------------------------------------------------------------------------------------------------- |
| `glob.zig`   | Gitignore-shaped glob matching (`*` per-segment, `**` across `/`, `!`-exclude) + the `PathFilter` scoping struct. |
| `types.zig`  | The language → extension/filename table (`-t go`/`py`/`rust`/…) with `extsForType` / `isKnownType` lookups.      |

Guarded by `glob_test.zig` + the rg line-diff battery.

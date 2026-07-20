---
doc_radar:
  sentinels:
    - description: "PathFilter + type tables remain the scoping surface"
      file: pkg/kernels/irregex/src/corpus/scope/glob.zig
      contains: "PathFilter"
    - description: "language type table stays lookup-driven"
      file: pkg/kernels/irregex/src/corpus/scope/types.zig
      contains: ["extsForType", "isKnownType"]
    - description: "path normalization remains shared with corpus ignore"
      file: pkg/kernels/irregex/src/corpus/scope/paths.zig
      contains: ["stripDot", "rootDepth"]
---

# `src/corpus/scope/` — path selection

Shared **path scoping** — the `-t <lang>` / `-g <glob>` / positional-`PATH`
affordances an agent reaches for to confine a search. Because irregex already
holds the path list, these prune candidates **before** touching disk, which
makes scoping make the search *faster* (rg filters while walking the whole
tree).

## Files

| File | Job |
| ---- | --- |
| `glob.zig` | Gitignore-shaped glob matching (`*` per-segment, `**` across `/`, `!`-exclude) + `PathFilter` |
| `paths.zig` | Shared path normalization, joining, depth, and ASCII-fold helpers |
| `types.zig` | Language → extension/filename table (`-t go` / `py` / `rust` / …) with `extsForType` / `isKnownType` |

## Invariants

- Same tables for cold CLI, warm session, and both product binaries — no
  per-face type lists.
- Guarding: `glob_test.zig` + the rg line-diff battery in the broader suite.

## When to edit

New `-t` language aliases, glob dialect edges, path normalization, or
`PathFilter` composition. Ignore-file discovery stays in `../tree/`.

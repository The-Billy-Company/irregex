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
    - description: "the charter declares corpus facts, not taste"
      file: pkg/kernels/irregex/src/corpus/scope/charter.zig
      contains: ["pub const Charter", "pub fn governing", "pub fn honorNoConfig"]
    - description: "the charter's three keys each reach a real seam"
      file: pkg/kernels/irregex/src/corpus/tree/corpus.zig
      contains: ["if (charter.governing()) |c| if (c.roots.len > 0) {"]
    - description: "charter skips join the walk's skip policy"
      file: pkg/kernels/irregex/src/corpus/tree/haystack.zig
      contains: ["if (charter.governing()) |c| for (c.skip) |name| add(name);"]
    - description: "charter types are --type-add specs applied before argv"
      file: pkg/kernels/irregex/src/surface/exec/cold/argv/grammar.zig
      contains: ["if (charter.governing()) |c| for (c.types) |spec| b.addTypeDef(spec);"]
---

# `src/corpus/scope/` — path selection and corpus declaration

Shared **path scoping** — the `-t <lang>` / `-g <glob>` / positional-`PATH`
affordances an agent reaches for to confine a search — plus the committed
**charter** (`.irregex.toml`) that declares corpus facts shared across every
clone. Because irregex already holds the path list, these prune candidates
**before** touching disk, which makes scoping make the search _faster_ (rg
filters while walking the whole tree).

## Files

| File               | Job                                                                                                      |
| ------------------ | -------------------------------------------------------------------------------------------------------- |
| `glob.zig`         | Gitignore-shaped glob matching (`*` per-segment, `**` across `/`, `!`-exclude) + `PathFilter`            |
| `paths.zig`        | Shared path normalization, joining, depth, ASCII-fold helpers, and the single OOM diagnostic              |
| `types.zig`        | Language → extension/filename table (`-t go` / `py` / `rust` / …) with `extsForType` / `isKnownType`    |
| `charter.zig`      | `.irregex.toml` — the committed corpus declaration (roots, skip, types). Discovered from the working directory upward, resolved once per process, ceilinged at `Reach.corpus` facts. Strict TOML subset parser with loud faults. |
| `charter_test.zig` | Adverse tests: every malformed declaration must be refused, never half-applied                            |

## The charter

ripgrep's `.ripgreprc` conflates taste (`--max-columns`, `--colors`) with
corpus facts (`--glob=!vendor/*`, `--type-add`). The charter is the second
half, split out and committed: three corpus keys (`roots`, `skip`, `types`)
that are equally true for the person, the agent, the daemon, and CI. A fresh
clone gets the same corpus as a seeded one — no per-machine folklore. Roots
resolve relative to the charter's own directory, so `gist` run from a
subdirectory searches the same corpus as from the tree root. `--no-config`
suppresses it for one run.

## Invariants

- Same tables for cold CLI, warm session, and both product binaries — no
  per-face type lists.
- The charter may only declare which files exist, never what counts as a match
  in them (ceilinged at `Reach.corpus`).
- Guarding: `glob_test.zig`, `charter_test.zig`, and the rg line-diff battery
  in the broader suite.

## When to edit

New `-t` language aliases, glob dialect edges, path normalization, charter
key additions, or `PathFilter` composition. Ignore-file discovery stays in
`../tree/`.

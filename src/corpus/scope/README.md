---
doc_radar:
  sentinels:
    - description: "PathFilter owns path scoping; the pure glob matcher lives on the math floor"
      file: pkg/kernels/irregex/src/corpus/scope/filter.zig
      contains: ["pub const PathFilter", "glob.zig"]
    - description: "language type table stays lookup-driven"
      file: pkg/kernels/irregex/src/corpus/scope/types.zig
      contains: ["extsForType", "isKnownType"]
    - description: "path normalization remains shared with corpus ignore"
      file: pkg/kernels/irregex/src/corpus/scope/paths.zig
      contains: ["stripDot", "rootDepth"]
    - description: "the charter declares corpus facts, not taste"
      file: pkg/kernels/irregex/src/corpus/scope/charter.zig
      contains: ["pub const Charter", "pub fn governing", "pub fn honorNoConfig"]
    - description: "did-you-mean lives on the math floor; three planes consume it"
      file: pkg/kernels/irregex/src/kernel/math/misread.zig
      contains: ["pub const Diagnostic", "pub fn nearest", "pub fn keepToken"]
    - description: "the charter's three keys each reach a real seam"
      file: pkg/kernels/irregex/src/corpus/tree/corpus.zig
      contains: ["if (charter.governing()) |c| if (c.roots.len > 0) {"]
---

# `src/corpus/scope/` — which paths count as the corpus

Path eligibility and the committed charter. This package answers _"may this
path be searched or indexed?"_ — never _"does this pattern match?"_. Because
irregex already holds the path list, scoping prunes candidates **before**
`open(2)`, which is why `-t` / `-g` make a search faster (rg filters while
walking the whole tree).

The old `glob.zig` was two packages wearing one name. The **pure matcher**
(gitignores-shaped `*` / `**` / `!`) lives on the math floor at
[`../../kernel/math/glob.zig`](../../kernel/math/glob.zig) so engines and
surfaces can share it without importing corpus policy. What remains here is
the **PathFilter** — how those matches compose into an include/exclude set
for a walk.

| File | Job |
| ---- | --- |
| `filter.zig` | `PathFilter` — include/exclude composition over the math-floor glob matcher |
| `paths.zig` | Shared path normalization, joining, depth, ASCII-fold helpers |
| `types.zig` | Language → extension/filename table (`-t go` / `py` / `rust` / …) |
| `charter.zig` | `.irregex.toml` — committed corpus declaration (`roots`, `skip`, `types`) |
| `charter_test.zig` | Adverse tests: every malformed declaration must be refused |

Did-you-mean (`misread.zig`) left for the math floor — charter, cold argv
preferences, and gist config all consume the same edit-distance helper.

## The charter

ripgrep's `.ripgreprc` conflates taste (`--max-columns`) with corpus facts
(`--glob=!vendor/*`). The charter is the second half, split out and committed:
three keys equally true for the person, the agent, the daemon, and CI.
`--no-config` suppresses it for one run. Ceilinged at `Reach.corpus` — it may
declare which files exist, never what counts as a match in them.

## When to edit

New `-t` aliases, PathFilter composition, charter keys. Ignore-file discovery
stays in [`../tree/`](../tree/). The glob dialect itself is
[`../../kernel/math/glob.zig`](../../kernel/math/glob.zig).

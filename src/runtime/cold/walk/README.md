---
doc_radar:
  sentinels:
    - description: "ignore protocol stays the shared contract for both walkers"
      file: pkg/kernels/irregex/src/gist/faces/cli/search/walk/ignore.zig
      contains:
        - "pub const Ignore"
        - ".gitignore"
---

# gist/faces/cli/search/walk — ignore rules + path helpers

Owns the "what's tracked" boundary the directory walk honors — the same
gitignore / `.ignore` / `.rgignore` dialect ripgrep uses — plus small path
utilities both engines share.

`ignore.zig` is the whole ignore-rule model: parse anchored / negated /
dir-only globs, accumulate them per directory as the walk descends, decide
whether a candidate is ignored. Last matching rule wins; deeper dirs and
`.ignore` / `.rgignore` / `--ignore-file` outrank a shallower `.gitignore`.
Segment-aware `*` / `**` / `?` / `[…]` matching reuses the shared
`scope/glob.zig` matcher, so `-g` scoping and ignore rules speak one dialect.

`paths.zig` holds the hot-path helpers (lowercasing, join) the serial and
parallel walkers both call — kept here so neither engine forks a private copy.

The warm session's O(changed) reconcile ([`session/delta.zig`](../../../../session/delta.zig))
imports this same `Ignore` machinery, so a scoped warm update cannot drift from
`defaultFileSet`.

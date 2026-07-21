---
doc_radar:
  sentinels:
    - description: "the snapshot proves a directory with the same conservative clock rule T3 uses"
      file: pkg/kernels/irregex/src/corpus/index/phantom/treemap.zig
      contains:
        - "needsLiveRead"
        - "GISTTRE1"
---

# `corpus/index/phantom/` — the phantom walk snapshot

`tree.map` is the persisted directory-membership snapshot behind gist's
**phantom walk**: instead of re-enumerating ~5k directories with
`openat`+`getattrlistbulk`+`close` on every cold query (the syscall floor that
dominates walk-bound shapes like `-g`/`-t` filters), a query proves each
recorded directory unchanged with **one `lstat`** — POSIX bumps a directory's
mtime/ctime on any membership change — and serves its child list straight from
the mapping. Only directories whose clocks moved (or that the build never
descended and the live ignore verdict now admits) are listed live.

Soundness split: the snapshot proves **membership** only. File **content**
freshness stays on the file's own clocks exactly as the T3 overlay defines it —
an admitted file is `lstat`ed live before index elision may skip it. Ignore
_rules_ are always read live from disk; the snapshot only says which ignore
files exist (their creation/deletion is a membership change and stales the
directory).

Build: `gist index` (whole-CWD corpora only), self-anchored, atomically
published beside the trigram artifacts. Fail-open everywhere: a missing,
corrupt, or foreign `tree.map` just returns the walk to its live path.

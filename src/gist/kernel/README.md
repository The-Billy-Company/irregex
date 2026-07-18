---
doc_radar:
  counts:
    - description: "exactly five kernel tiers — index, regex, engine, scan, rank"
      glob: pkg/kernels/irregex/src/gist/kernel/*/
      equals: 5
      unit: dirs
  sentinels:
    - description: "the kernel tiers re-export through the package root"
      file: pkg/kernels/irregex/src/root.zig
      contains:
        - 'pub const trigram = @import("gist/kernel/index/trigram.zig");'
        - 'pub const query = @import("gist/kernel/engine/query.zig");'
---

# gist/kernel — the matching kernel

Everything that decides *whether and where* a pattern matches, with no I/O
policy, argv, or process lifecycle. Faces (`../faces/`) and the warm session
(`../session/`) are the only callers; they own transport, the kernel owns
correctness. The tiers compose bottom-up — a candidate index narrows the file
set, a regex engine verifies, byte primitives do the hot scan, one compiled
query fuses them, and ranking shapes the result.

| Tier | Folder | Role |
| --- | --- | --- |
| **T0** | [`index/`](index) | The positional-trigram candidate index — the sound superset filter that lets gist touch only files that can match, plus zero-copy persistence and freshness. |
| **T2** | [`regex/`](regex) | The linear-time Thompson-NFA / byte-class-DFA engine (RE2/ripgrep philosophy), organized by pipeline stage: `syntax` · `analysis` · `compile` · `linear` · `pcre2` · `unicode` · `oracle`. |
| **verify** | [`scan/`](scan) | The byte-level verify primitives — the SIMD + scalar per-file kernels that confirm a candidate at the hardware floor. |
| **query** | [`engine/`](engine) | The transport-neutral compiled query (ADR-352): one deep module both the cold CLI and warm session execute a search intent through. |
| **T4** | [`rank/`](rank) | Turns the verified match set into the ranked, token-compressed list an agent reads — definitions first, generated files demoted. |

There is no code at this root — every tier is a subfolder, re-exported through
[`../../../root.zig`](../../root.zig).

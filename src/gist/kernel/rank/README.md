# gist/kernel/rank

**T4** — turns the verified match set into the ranked, token-compressed list an
agent actually wants (the _one_ line that answers the question first, not 200
unordered call sites).

| File          | Role                                                                                                                                   |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `rank.zig`    | Weighted **Reciprocal Rank Fusion** (Cormack et al. 2009) over the signals below; emits `path:line [def\|use\|gen\|mirror] ×n <line>`. |
| `signals.zig` | Language-agnostic byte features: declaration detection and codegen demotion.                                                           |
| `mirror.zig`  | Narrow cache/VCS snapshot classification, byte fingerprints, and exact canonical-duplicate resolution.                                 |

The def boost lets a declaration outrank its call sites (the win `grep` can't
express); the authored boost sinks codegen and cache/VCS source mirrors below
canonical code. Exact duplicate mirrors name their canonical result. The class
split stays tie-aware, so ranking remains neutral _within_ each class.

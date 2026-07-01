# gist/src/rank

**T4** — turns the verified match set into the ranked, token-compressed list an
agent actually wants (the *one* line that answers the question first, not 200
unordered call sites).

| File          | Role                                                                                                                     |
| ------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `rank.zig`    | Weighted **Reciprocal Rank Fusion** (Cormack et al. 2009) over the signals below; emits `path:line [def\|use\|gen] ×n  <line>`. |
| `signals.zig` | The language-agnostic, byte-level features `rank` fuses — `definesNeedle` (decl vs use) and `isGenerated` (codegen demotion), computed from raw bytes with no parser. |

The def boost lets a match on a declaration line outrank its call sites (the win
`grep` can't express); the authored boost sinks codegen output below real code.
The class split is fused tie-aware so ranking stays neutral *within* a class.

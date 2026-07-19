---
doc_radar:
  sentinels:
    - description: "analysis is sound and conservative — a wrong answer only costs a full scan, never a missed match"
      file: pkg/kernels/irregex/src/gist/kernel/regex/analysis/analysis.zig
      contains: ["pub fn analyzeFirst", "pub fn reachesMatchEol"]
---

# gist/kernel/regex/analysis — sound accelerator analyses

Read-only static analyses that feed the scanner's accelerators. Every one is
**conservative**: a "don't know" degrades to a full scan, never to a missed
match — so the trigram prefilter and first-byte skip can be aggressive without
risking a false negative (the one unforgivable bug).

| File | Role |
| --- | --- |
| `analysis.zig` | Two layers of visitors: AST visitors over `syntax.zig` (required-literal / alternation-cover extraction, anchored-start) that feed the T0 trigram prefilter, and compiled-NFA visitors (`analyzeFirst` first-byte set, `reachesMatchEol`) that feed the scan loop. |
| `prefilter.zig` | The `Prefilter`: given the first-byte set from `analysis.analyzeFirst`, picks a skip strategy (singleton `memchr` · SIMD byte-range · scalar probe) so the Pike scanner jumps over dead spans instead of re-seeding a closure per byte. |
| `analysis_test.zig` | Required-literal, cover-set, and anchored-start extraction cases. |

Imports `../syntax/syntax.zig` for the AST/`State` types; consumed by
`../linear/core.zig` (skip path) and the `../compile/` lowering's callers.

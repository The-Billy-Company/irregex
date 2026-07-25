---
doc_radar:
  sentinels:
    - description: "the compiled-NFA reachability analysis is sound and conservative — a wrong answer only costs a full scan, never a missed match"
      file: pkg/kernels/irregex/src/kernel/match/regex/analysis/reach.zig
      contains: ["pub fn analyzeFirst", "pub fn reachesMatchEol"]
---

# kernel/match/regex/analysis — sound accelerator analyses

Read-only static analyses that feed the scanner's accelerators. Every one is
**conservative**: a "don't know" degrades to a full scan, never to a missed
match — so the trigram prefilter and first-byte skip can be aggressive without
risking a false negative (the one unforgivable bug).

| File                | Role                                                                                                                                                                                                                                                                       |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `analysis.zig`      | The AST literal layer + the public face of the whole analysis module: required-literal extraction, alternation cover set, pure-literal match-equivalence, and the anchored-start predicate (the T0 trigram / seeding accelerators). Re-exports `runs.zig` and `reach.zig`. |
| `runs.zig`          | AST class-run / class-span reductions: `classRunShape` (boolean "≥ min consecutive class members") and the strictly stronger `classSpanShape` window rule, feeding the SIMD class-run kernel (`../../scan/classrun.zig`).                                                  |
| `reach.zig`         | Compiled-NFA reachability visitors over the `State` program: `analyzeFirst` (first-byte set), `reachesMatchEol` (zero-width EOL), and `reachesMatchZeroWidth` (nullable) that feed the scan loop.                                                                          |
| `prefilter.zig`     | The `Prefilter`: given the first-byte set from `analysis.analyzeFirst`, picks a skip strategy (singleton `memchr` · SIMD byte-range · scalar probe) so the Pike scanner jumps over dead spans instead of re-seeding a closure per byte.                                    |
| `analysis_test.zig` | Required-literal, cover-set, and anchored-start extraction cases.                                                                                                                                                                                                          |

Imports `../syntax/syntax.zig` for the AST/`State` types; consumed by
`../linear/program/lower.zig` (which runs every analysis at compile time) and the
`../compile/` lowering's callers.

## When to edit

Required-literal / cover extraction, first-byte sets, or skip strategies.
Wrong answers here must only cost a full scan — never a missed match.

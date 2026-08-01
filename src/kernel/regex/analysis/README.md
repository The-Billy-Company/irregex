---
doc_radar:
  sentinels:
    - description: "the compiled-NFA reachability analysis is sound and conservative — a wrong answer only costs a full scan, never a missed match"
      file: src/kernel/regex/analysis/reach.zig
      contains: ["pub fn analyzeFirst", "pub fn reachesMatchEol"]
    - description: "the forced-crest calculus reads the engine's own AST (the PROOF §3.7a Grammar Contract) — a wrong answer here skips a file that matches, so unlike its siblings it is the one analysis whose failure mode is a missed match"
      file: src/kernel/regex/analysis/swell.zig
      contains: ["pub fn forcedSwell", "syntax.zig"]
---

# kernel/regex/analysis — sound accelerator analyses

Read-only static analyses that feed the scanner's accelerators. Every one is
**conservative**: a "don't know" degrades to a full scan, never to a missed
match — so the trigram prefilter and first-byte skip can be aggressive without
risking a false negative (the one unforgivable bug).

`swell.zig` is the member that has to be read differently. The others make the
scan faster; it decides which files are never opened, so its "don't know" is
`ĝ = 0` (prune nothing) and a _wrong_ answer is a silently missed match rather
than a slow one. It lives here, rather than beside the crest kernel, for exactly
that reason: the calculus must read the same `syntax.Node` AST the matcher
compiles. Deriving ĝ from a second parser is what produced the one real
false negative this engine has shipped (`\<` taken for a literal `<` —
PROOF.md §3.7a), and a module boundary is the only durable fix.

| File                | Role                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `analysis.zig`      | The AST literal layer + the public face of the whole analysis module: required-literal extraction, alternation cover set, pure-literal match-equivalence, and the anchored-start predicate (the T0 trigram / seeding accelerators). Re-exports `runs.zig` and `reach.zig`.                                                                                                                                                                  |
| `runs.zig`          | AST class-run / class-span reductions: `classRunShape` (boolean "≥ min consecutive class members") and the strictly stronger `classSpanShape` window rule, feeding the SIMD class-run kernel (`../../scan/classrun.zig`).                                                                                                                                                                                                                   |
| `reach.zig`         | Compiled-NFA reachability visitors over the `State` program: `analyzeFirst` (first-byte set), `reachesMatchEol` (zero-width EOL), and `reachesMatchZeroWidth` (nullable) that feed the scan loop.                                                                                                                                                                                                                                           |
| `prefilter.zig`     | The `Prefilter`: given the first-byte set from `analysis.analyzeFirst`, picks a skip strategy (singleton `memchr` · SIMD byte-range · scalar probe) so the Pike scanner jumps over dead spans instead of re-seeding a closure per byte.                                                                                                                                                                                                     |
| `swell.zig`         | The **forced-crest calculus**: the smallest per-class run every string matching the AST must contain (`ĝ`), by a `Profile` algebra (forced longest / leading / trailing run, `min_len`, and a per-class "only this class" certificate) folded over concat, alternation, and repetition. `forcedSwell` emits one ĝ per top-level alternative — a disjunction, since a match takes one branch — and feeds the crest sieve's document elision. |
| `analysis_test.zig` | Required-literal, cover-set, and anchored-start extraction cases.                                                                                                                                                                                                                                                                                                                                                                           |
| `swell_test.zig`    | Hand-computed `ĝ` per construct, the disjunction's branch structure and its capacity budget, plus the Sieve Theorem itself checked against the real matcher over 1 500 generated patterns × both engine modes × caseless (`matched ⇒ ¬pruned`).                                                                                                                                                                                             |

Imports `../syntax/syntax.zig` for the AST/`State` types; consumed by
`../linear/program/lower.zig` (which runs every analysis at compile time) and the
`../compile/` lowering's callers.

## When to edit

Required-literal / cover extraction, first-byte sets, or skip strategies.
Wrong answers here must only cost a full scan — never a missed match.

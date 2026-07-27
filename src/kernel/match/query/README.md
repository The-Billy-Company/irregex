---
doc_radar:
  sentinels:
    - description: "the compiled query stays fail-closed and immutable, dispatching through the engine-neutral seam"
      file: pkg/kernels/irregex/src/kernel/match/query/query.zig
      contains: ["pub const CompiledQuery", "error.Unsupported", "pub const Scratch"]
    - description: "the prefilter derivation stays sound for both the fold window and the case-variant OR-set"
      file: pkg/kernels/irregex/src/kernel/match/query/prefilter.zig
      contains: ["pub fn regexPrefilter", "pub fn foldClosedWindow", "pub fn caselessVariants"]
    - description: "the conjunctive cover emits a CNF plan under cost ceilings, and declines rather than weakens"
      file: pkg/kernels/irregex/src/kernel/match/query/cover.zig
      contains: ["pub fn plan", "pub fn planSource", "pub const Limits"]
    - description: "the cover's soundness is brute-forced against the production matcher, not argued"
      file: pkg/kernels/irregex/src/kernel/match/query/cover_test.zig
      contains: ["fn proveSound", "PlanElidesMatch"]
    - description: "the -w rule is a post-match predicate over the shared word oracle"
      file: pkg/kernels/irregex/src/kernel/match/query/word.zig
      contains: ["pub const wordOk"]
---

# match/query — a search intent, compiled

The **shared boundary** ([ADR-352](../../../../../../../docs/architecture/3-decisions/352-gist-unified-search-api.md)).
A `(pattern, fixed, ignore_case, pcre, mode)` spec lowers once into an immutable
matcher, and every face — cold CLI, warm session, FFI, language bindings — draws
its two answers from that one form: the **sound trigram prefilter** that prunes
index candidates, and the per-document **match / line-count** decision. Neither
caller learns which engine backs the query, so none of them can drift on what
matches or on which literals are safe to skip.

| File             | Job                                                                                                                                                                    |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `query.zig`      | `CompiledQuery`: the lowering, the `Scratch` grain a walk worker owns, and the match/count primitives over the `-F` literal fast path or the engine-neutral `Matcher`. |
| `prefilter.zig`  | The literal derivations warm and cold must share verbatim — required/alt cover, the caseless fold window, the case-variant OR-set, and the `-F -i` escape.             |
| `cover.zig`      | The **conjunctive cover**: the whole boolean query a pattern forces, not just its best single literal. See below.                                                      |
| `word.zig`       | The ripgrep `-w` word-boundary rule as a post-match predicate (`wordOk` plus the literal / regex word-span scans), over the same `\b` oracle the engine uses.          |
| `query_test.zig` | Compile / prefilter / match cases checked against an independent oracle.                                                                                               |
| `cover_test.zig` | `matched ⇒ never pruned`, brute-forced over an exhaustively enumerated document space, plus the reachability cases each lowering rule exists for.                      |

`prefilter.zig` and `word.zig` are private to this folder — imported only by
`query.zig`, which re-exports what callers need so the surface stays
`query.<name>`. Both are _soundness_ code: a prefilter that over-claims silently
skips a real match, so neither may be inlined into a caller that could relax it.

## Why it sits above `regex/` and `scan/`

This folder decides **which rung to take**; the folders beside it _are_ the rungs.
Fixed `-F` goes to `../scan/` SIMD, everything else compiles through
`../regex/`, and PCRE2 is entered only when `-P` / `--engine auto` demands
lookaround or backreferences. Adding a rung means teaching `query.zig` to choose
it — never teaching a caller to reach past this seam.

## The conjunctive cover — one literal is not what a pattern proves

`prefilter.zig` answers the _one-literal_ question: which single literal, or
single alternation cover, is mandatory? That question throws away most of what a
pattern proves. `if\s+err\s*!=\s*nil` forces four disjoint literal runs and the
one-literal planner keeps the longest. `func\s+\w+\(` forces `func` _immediately
followed by a whitespace byte_ — but `\s` is not a singleton, so the run stops at
`func` and the adjacency, the most selective fact in the pattern, is never asked
of the index.

`cover.zig` answers the whole question, returning a conjunction of disjunctions
of conjunctions — the shape `trigram.Index.queryPlan` evaluates and the shape
csearch's `regexp/query.go` builds:

```text
plan   ≔ clause ∧ clause ∧ …     every clause is necessary
clause ≔ atom ∨ atom ∨ …         some atom holds
atom   ≔ literal ∧ literal ∧ …   all of these literals' trigrams present
```

Three things make it more than csearch's tree, each measured in
[Layer L](../../../../bench/sieve/README.md):

1. **A small byte class is a choice point, not a wall.** A run of adjacent
   positions is carried across the whole concat spine and survives a partially
   known node by folding in that node's provable head set. `func\s` becomes the
   six 5-byte alternatives rather than `func`; `https?://` becomes the two whole
   schemes rather than a 3-byte boundary trigram, because `x?` is read as the
   finite set `{ε, x}` — the one repetition whose language is finite.
2. **Sliding windows keep every provable constraint.** When a segment's
   cross-product overflows the atom ceiling, every start position is tried at the
   shortest extent clearing the trigram floor. `[0-9a-f]{8}-[0-9a-f]{4}` has a
   16¹²-way whole product, but three of its windows straddle the dash and each
   fits; csearch takes one of the three and stops. Their **conjunction** is what
   a cost-ordered evaluator can afford to ask.
3. **Emitting more is free, because the index picks.** A syntactic planner must
   guess which constraint is worth evaluating. `queryPlan` knows the real posting
   cardinality of every trigram, so this module's job is to emit every _sound_
   necessary condition and let the measured cost model order them and decline the
   ones that cost more than they prune. Widening the choice never widens the
   answer.

### Soundness is the fixed point

Every clause returned is a **necessary** condition: if a document matches, it
contains, for every clause, all the literals of at least one of that clause's
atoms. A clause is emitted only when _every_ atom in it is filterable (each
literal ≥3 bytes) — one unwitnessable alternative would make the disjunction
vacuous, and a vacuous clause evaluated as if it were real elides matches. That
is why `panic|0x` yields no plan at all rather than a plan built on `panic`.

`Limits` are **cost** bounds, never soundness bounds: exceeding any of them makes
the planner emit a weaker clause or none, which only ever widens the candidate
set. Their defaults are the measured knees of the Layer-L sweep
(`--cover-class` / `--cover-atoms` / `--cover-clauses`), not asserted constants.

`cover_test.zig` proves the contract by running the production matcher over every
string in an enumerated document space, in the discipline of the crest Sieve
Theorem — never by arguing about the lowering.

# `src/kernel/query/` — a search intent, compiled

The **shared boundary** for the hosted search API. A `(pattern, fixed,
ignore_case, pcre, mode)` spec lowers once into an immutable matcher, and
every face — cold CLI, warm session, FFI, language bindings — draws its two
answers from that one form: the sound trigram prefilter that prunes index
candidates, and the per-document match / line-count decision. Neither caller
learns which engine backs the query, so none of them can drift on what
matches or on which literals are safe to skip.

The stronger prunings are drawn from here too, and by one call. `winnow`
returns the conjunctive cover plan and the crest sieve's forced swell off a
single `lower.parse`, because the parse is the expensive half and both faces
need both. That it is one function rather than two is a soundness property,
not a tidiness one: cold's `Writ.compile` and the resident session's
`gather.winnowFor` must agree on what a pattern forces, and the way to
guarantee that is to give them nothing to disagree from.

- **`query.zig`** owns `CompiledQuery`: the lowering, the `Scratch` grain a
  walk worker owns, and the match/count primitives over the `-F` literal
  fast path or the engine-neutral `Matcher`.
- **`prefilter.zig`** derives the literals warm and cold must share
  verbatim — required/alt cover, the case-variant OR-set, the `-F -i`
  escape — plus `winnow`, which hands both faces the cover plan and the
  crest swell from one parse. The caseless fold window it re-exports rather
  than owns: that rule moved down beside the caseless SIMD kernel it guards
  (`scan/simd.zig`), so the regex compiler can mine its own gate without
  importing this tier.
- **`cover.zig`** builds the conjunctive cover: the whole boolean query a
  pattern forces, not just its best single literal (see below).
- **`word.zig`** is the ripgrep `-w` word-boundary rule as a post-match
  predicate (`wordOk` plus the literal / regex word-span scans), over the
  same `\b` oracle the engine uses.
- **`query_test.zig`** checks compile / prefilter / match cases against an
  independent oracle.
- **`cover_test.zig`** brute-forces `matched ⇒ never pruned` over an
  exhaustively enumerated document space, plus the reachability cases each
  lowering rule exists for.
- **`zero_width_test.zig`** pins the two zero-width match sequences this
  package reports — `Cursor`'s library sequence and `query`'s walk's grep
  sequence — each against its own outside bar (Python `re`/rust-regex/JS
  for one, ripgrep for the other), so neither can be "fixed" into the
  other.
- **`word_rule_test.zig`** differentials the `-w` rule across `query`'s walk
  and `glean`'s `Cursor`, on both the linear and PCRE2 backends, so a host
  that reads one after the ABI moved from the first to the second gets the
  same spans either way.

`prefilter.zig` and `word.zig` are private to this folder, imported only by
`query.zig`, which re-exports what callers need so the surface stays
`query.<name>`. Both are *soundness* code: a prefilter that over-claims
silently skips a real match, so neither may be inlined into a caller that
could relax it.

## Why It Sits Above `regex/` and `scan/`

This folder decides which rung to take; the folders beside it *are* the
rungs. Fixed `-F` goes to `../scan/` SIMD, everything else compiles through
`../regex/`, and PCRE2 is entered only when `-P` / `--engine auto` demands
lookaround or backreferences. Adding a rung means teaching `query.zig` to
choose it, never teaching a caller to reach past this seam.

## The Conjunctive Cover

One literal is not what a pattern proves. `prefilter.zig` answers the
one-literal question: which single literal, or single alternation cover, is
mandatory? That question throws away most of what a pattern proves.
`if\s+err\s*!=\s*nil` forces four disjoint literal runs and the one-literal
planner keeps the longest. `func\s+\w+\(` forces `func` immediately followed
by a whitespace byte, but `\s` is not a singleton, so the run stops at
`func` and the adjacency, the most selective fact in the pattern, is never
asked of the index.

`cover.zig` answers the whole question, returning a conjunction of
disjunctions of conjunctions, the shape `trigram.Index.queryPlan` evaluates
and the shape csearch's `regexp/query.go` builds:

```text
plan   ≔ clause ∧ clause ∧ …     every clause is necessary
clause ≔ atom ∨ atom ∨ …         some atom holds
atom   ≔ literal ∧ literal ∧ …   all of these literals' trigrams present
```

Three things make it more than csearch's tree, each measured in
[Layer L](../../../bench/rungs/sieve/README.md):

1. **A small byte class is a choice point, not a wall.** A run of adjacent
   positions is carried across the whole concat spine and survives a
   partially known node by folding in that node's provable head set.
   `func\s` becomes the six 5-byte alternatives rather than `func`;
   `https?://` becomes the two whole schemes rather than a 3-byte boundary
   trigram, because `x?` is read as the finite set `{ε, x}`, the one
   repetition whose language is finite.
2. **Sliding windows keep every provable constraint.** When a segment's
   cross-product overflows the atom ceiling, every start position is tried
   at the shortest extent clearing the trigram floor. `[0-9a-f]{8}-[0-9a-f]{4}`
   has a 16¹²-way whole product, but three of its windows straddle the dash
   and each fits; csearch takes one of the three and stops. Their
   conjunction is what a cost-ordered evaluator can afford to ask.
3. **Emitting more is free, because the index picks.** A syntactic planner
   must guess which constraint is worth evaluating. `queryPlan` knows the
   real posting cardinality of every trigram, so this module's job is to
   emit every sound necessary condition and let the measured cost model
   order them and decline the ones that cost more than they prune. Widening
   the choice never widens the answer.

### Soundness Is the Fixed Point

Every clause returned is a necessary condition: if a document matches, it
contains, for every clause, all the literals of at least one of that
clause's atoms. A clause is emitted only when every atom in it is filterable
(each literal ≥ 3 bytes); one unwitnessable alternative would make the
disjunction vacuous, and a vacuous clause evaluated as if it were real elides
matches. That is why `panic|0x` yields no plan at all rather than a plan
built on `panic`.

`Limits` are cost bounds, never soundness bounds: exceeding any of them makes
the planner emit a weaker clause or none, which only ever widens the
candidate set. Their defaults are the measured knees of the Layer-L sweep
(`--cover-class` / `--cover-atoms` / `--cover-clauses`), not asserted
constants.

`cover_test.zig` proves the contract by running the production matcher over
every string in an enumerated document space, in the discipline of the
crest Sieve Theorem, never by arguing about the lowering.

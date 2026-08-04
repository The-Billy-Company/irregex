# `src/kernel/slate/` — many patterns, one walk

Operates on many intents, or a whole result stream, at once, engine-side,
with exact answers — the set-shaped half of the irregex primitives. This is
what backs `relate patterns` and the dragnet/trawl multipattern tiers.

`slate.zig` is the door: it groups the four files below under one name
(`slate.patterns`, `slate.loom`, `slate.muster`, `slate.trawl`), so the tier
is entered the way it is described here rather than as a partial list of its
files.

- **`patterns.zig`** owns `PatternSet`: it compiles N patterns once through
  `kernel/query/query.zig`, with exact per-pattern attribution (`docMask` /
  `lineHits`). A fused `(?:p0)|(?:p1)|…` gate cheaply rejects a document
  that matches nothing, built only when every pattern shares one case /
  Unicode setting and compiles linear; otherwise the set runs confirm-only,
  still exact. The gate can only skip work, never change an answer.
- **`muster.zig`** is the dragnet: a bucketed SIMD sieve (Hyperscan's
  FDR/Teddy split, Wang et al. NSDI 2019) that pools every pattern's
  required literals, scans the bytes once through the shipped Teddy
  kernel, and reports which patterns survived. A pattern whose every
  literal is absent is excluded before the engine ever runs; a pattern
  whose literals are a match equivalence is *decided* by the pass and
  never confirmed at all. It is the narrow-slate engine, winning decisively
  while its 4 groups (32 buckets) stay sparse.
- **`trawl.zig`** is the trawl: one Aho–Corasick automaton (Aho & Corasick,
  CACM 1975) for a slate too wide for the dragnet's SIMD buckets. Past 18
  pooled literals — the measured crossover where the dragnet's four bucket
  groups saturate and the trawl's flat per-byte cost overtakes it —
  `PatternSet.build` hands off to the trawl instead, so per-byte cost stops
  growing with N. `GIST_MUSTER_TIER` forces either side for measurement.
- **`loom.zig`** executes `loom.Plan`, a closed filter → group → sort →
  limit plan over attributed rows, engine-side and before a byte of output
  exists. Every op is total and deterministic (orderings tiebreak on the
  row's full identity), so one plan over one row set has exactly one
  answer.

The two *ordered* faces of a slate — `Chorus` (which patterns occur
anywhere) and `Munch` (which reaches furthest from exactly here) — live in
the regex engine, because they are automaton constructions rather than walk
strategies. They are hoisted to the package root beside `Regex`.

## Invariants

- Both the muster gate and the trawl are **skip-only**: a set's answer
  stays bit-identical to N independent single-pattern searches, whether
  either accelerator runs or not (`patterns_test.zig`, `trawl_test.zig`
  prove it on and off).
- Loom ops are hand-tallied for a total, deterministic result
  (`loom_test.zig`); no "approximately sorted" shortcuts.
- No argv / walk / emit — pure kernels over already-attributed rows.

## When to Edit

New closed ops in the loom vocabulary, attribution shape changes, the
dragnet/trawl handoff threshold, or fused-gate soundness. Verb UX lives in
`surface/face/relate/`; match semantics live in `kernel/regex/`.

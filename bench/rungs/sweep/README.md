---
doc_radar:
  paths_exist:
    - bench/rungs/sweep/bench.zig
    - src/kernel/regex/ast/ast.zig
    - src/kernel/regex/analysis/analysis.zig
    - src/kernel/regex/linear/program/lower.zig
  sentinels:
    - description: "both arms are production code reached through the engine's seal, never a reimplementation"
      file: bench/rungs/sweep/bench.zig
      contains:
        - "gist.regex_analysis"
        - "gist.regex_ast"
        - "gist.regex_parabix"
    - description: "a disagreement is classified, and a worse answer withholds the verdict"
      file: bench/rungs/sweep/bench.zig
      contains:
        - "fn versus"
        - "REGRESSES"
        - "break-even"
    - description: "the compile path sources its literal, cover and anchor facts from the one interned graph"
      file: src/kernel/regex/linear/program/lower.zig
      contains:
        - "ast_mod.analyze(arena, arena, ast"
        - "facts.root().lit"
        - "facts.root().anchored"
---

# bench/rungs/sweep — is the fused fabric actually worth it, consumer by consumer

`zig build sweep-rung` (from the repository root).

The `ast` package claims to answer in **one interned sweep** what
`analysis.zig` and `parabix/admit.zig` each answer in **one recursive walk**.
That claim does not hold or fail as a whole, and this rung exists because the
obvious way to test it gives the wrong answer twice over:

- Timed **per question**, the fabric loses almost everything. `startsAnchored`
  is a four-line recursion costing ~20 ns; no graph construction competes with
  that, and none ever will.
- Timed **as a bundle**, it wins — but a bundle number tells you nothing about
  which call site to change, and hides the fact that the win is not evenly
  earned.

So every row reports both columns, and the verdict is per consumer.

## What it runs

Both arms are production code reached through `regex.zig`'s seal — the
incumbent walkers via `regex_analysis` / `regex_parabix`, the challenger via
`regex_ast`. Nothing here reimplements either side; a bench that rebuilt an arm
would be racing a copy of the engine rather than the engine.

Four consumers, chosen because each has a live recursive answer today to be
raced against:

| Question | Incumbent | Why it is interesting |
|---|---|---|
| `best` | `analysis.literalInfo` | The mandatory literal the trigram prefilter plans on. |
| `cover` | `analysis.requiredAny` | Quadratic today — it calls `literalInfo` at every node it descends through, and `literalInfo` re-walks that node's whole subtree. |
| `anchored` | `analysis.startsAnchored` | The cheapest walk there is. The control: if the fabric ever "wins" this one, the measurement is broken. |
| `star_height` | `parabix.starHeight` | Gates the bit-parallel rung at height ≤ 1, so the answer changes which engine runs. |

## Answers before times

A faster wrong answer is not a result, so each pattern's two answers are
compared before either arm is timed. But "differs" is not one verdict — it is
two, because interning and the algebra both rewrite the shape (dedup,
re-association, class merging, closure collapse) and every rewrite preserves the
**language** while potentially exposing more than the parser's bracketing did.
`Answer.versus` classifies against each question's own quality order:

- a **longer** mandatory literal is a more selective prefilter;
- a cover with a **longer weakest** member is more selective, and having one at
  all beats having none;
- proving an anchor the walker could not is knowledge gained;
- a **lower** star height admits a pattern to a faster rung.

Movement the right way is counted as `better`. Movement the wrong way is a
`REGRESSES` verdict, withholds the row, and exits non-zero (`--strict` makes the
first one fatal, printing both answers). That a gain is *sound* — the longer
literal really is mandatory in every match — is not this rung's claim to make;
that is the language oracle in `src/kernel/regex/ast/ast_test.zig`.

## What it found

Three things, all of which changed what got built:

1. **No consumer transfers alone.** The graph is a fixed cost of ~1.7 µs per
   pattern; the cheapest walker it replaces is 20 ns. Asked one question, the
   fabric loses by 30×, and `--owner gpa` shows a further ~25% of that cost is
   nothing but general-allocator churn — which is why `lower.zig` builds the
   graph in the arena it already holds for the parse tree.
2. **The break-even table is the actual decision instrument.** Ordering
   consumers by walker cost descending and accumulating shows how many have to
   move together before the build is paid for. Two — `cover` and `best` — clear
   it; every consumer after that is free, which is the argument for widening the
   fabric rather than for optimizing it.
3. **Where the build's time goes.** Hash-consing dominates at ~57%, the fused
   sweep is a fifth of it, and the algebra pays for itself by shrinking what the
   sweep runs over. Interning costs ~20 ns per node, spread evenly across
   `Dag.intern` calls — there is no hot spot to remove, only a smaller `Op` to
   design.

The transfer those measurements licensed is in
`src/kernel/regex/linear/program/lower.zig`: `compileOpts` is the one site that
asks for the literal, the cover and the anchor on the same tree, so it builds
one graph and reads all three. `pureLiterals` still walks, because the fabric
has no answer for it yet.

## Flags

| Flag | Default | What |
|---|---|---|
| `--patterns FILE` | built-in slate | One pattern per line, `#` comments. The slate is chosen for asymptotics — shallow patterns where the build has nothing to amortize, alternations that expose the quadratic term, bounded repetitions that interning raises by squaring. |
| `--reps N` | 5 | Timed passes; the fastest is reported, so one scheduler hiccup on a box running ten coworking agents cannot become the number. |
| `--inner N` | 64 | Iterations per pass, since a single answer is faster than the clock is precise. |
| `--owner gpa\|arena` | `arena` | Who owns the DAG and the fact array. Not a tuning knob but a design question: the graph's lifetime is the compile's, and the compile already holds an arena. |
| `--strict` | off | Exit on the first regression rather than tallying. |
| `--json` | off | One object on stdout. |

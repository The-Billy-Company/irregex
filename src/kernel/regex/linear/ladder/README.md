---
doc_radar:
  sentinels:
    - description: "the inner rungs dispatch boolean questions and name which machine answered"
      file: pkg/kernels/irregex/src/kernel/regex/linear/ladder/verdict.zig
      contains: ["pub fn lineMatch", "pub fn docMatch", "pub fn docMatchFused"]
    - description: "the outer rung is a tagged union over both engines, dispatched per line not per byte"
      file: pkg/kernels/irregex/src/kernel/regex/matcher.zig
      contains: ["pub const Matcher = union(Backend)", "pub const Backend = enum { linear, pcre }"]
    - description: "the accelerator tier is one field with a three-valued protocol, a single ordered table, and a per-instance refinement of each rung's question"
      file: pkg/kernels/irregex/src/kernel/regex/linear/ladder/rungs.zig
      contains:
        - "pub const Verdict = enum { hit, miss, unproven }"
        - "const order = [_]Spec{"
        - "pub fn build"
        - "const Model = enum {"
        - "inline fn sliceSafe(rung: anytype) bool"
    - description: "the whole-buffer -U search consults the tier under the same assertion-free guard the DFA sits behind"
      file: pkg/kernels/irregex/src/kernel/regex/linear/pike/search.zig
      contains: ["switch (re.rungs.line(buf))"]
    - description: "the handle carries the tier as ONE field, not one per rung"
      file: pkg/kernels/irregex/src/kernel/regex/linear/program/core.zig
      contains: ["rungs: rungs_mod.Rungs"]
---

# linear/ladder — who answers the question

Dispatch, and **only** dispatch. Three nested versions of the same decision —
_which machine is the cheapest one that can soundly answer this?_ — with no
semantics of their own: every rung answers identically to the Pike VM, and a rung
that cannot decide a haystack falls through instead of guessing.

| File | Rung |
| ---- | ---- |
| [`../../matcher.zig`](../../matcher.zig) | **Which backend** (at the regex package root). Tagged union over linear `Regex` and opt-in PCRE2 `Pcre` (`-P`), dispatched once per line / span — never per byte. |
| `verdict.zig` | **Which rung inside the linear arm.** Cost order: end-of-line certainty → SIMD class-run → accelerator tier → byte-class DFA → Pike VM. |
| `rungs.zig` | **Which accelerator inside that.** Optional machines behind one interface so the handle carries one field. |

The `*Fused` predicates (`docMatchFused`, `countRunFused`) let a caller with its
own per-line loop ask _which_ machine would answer **before** paying a line
split — the reason a whole-buffer scan can skip work a line-oriented one cannot.

Callers of the linear engine never import `verdict.zig`: `../program/core.zig`
adopts `lineMatch`, `docMatch`, and the fused predicates onto `Regex`. `Matcher`
is imported directly, by name, from the surface layer.

## The rung protocol

Three-valued, and it unifies the two kinds of accelerator exactly rather than
papering over their difference:

- A **decider** answers `.hit` or `.miss` completely for the patterns it accepts,
  and declines at _compile_ time by being absent. It may never say "not sure"
  mid-scan.
- A **sieve** answers `.miss` (proven no match) or `.unproven`, and structurally
  cannot say `.hit`, because an over-approximating quotient admits supersets.

Both meanings of `.miss` are "return false", which is why one enum serves both
and the walk needs no per-kind branch. Correctness never depends on a rung being
present: an empty tier is the engine exactly as it was.

Admission lives in `rungs.zig` rather than in any rung, because what a rung is
worth is only visible from outside it. Every decider that can represent the
pattern is built, each prices itself as an `Offer`, and **exactly one is kept** —
they are alternatives, not a pipeline, so a second would cost compile time and
memory to be unreachable. The fallback is an offer too, priced from the
prefilter's expected stride, which is what lets a rung lose to a start skip
instead of merely standing down beside one. The sieve is not in that contest: it
narrows without deciding, so it is offered the winner's per-byte cost and applies
its own survival inequality against it.

## Which question a rung answers

The second axis, and the one where a mistake produces a wrong answer instead of
a crash. `lineMatch` asks _does the pattern match a substring of exactly these
bytes_, with `^`/`$` bound to the slice's own edges. `docMatch` asks the per-line
question _does any `\n`-delimited line of this buffer match_. They coincide only
on a `\n`-free haystack, and nothing in the ladder promises one.

So each rung declares a `Model`. A **byte** rung reads `\n` as an ordinary byte
and carries no anchor, so it serves both entries — `parabix` earns this from its
admission gate, which refuses every assertion and every class containing `\n`. A
**per-line** rung re-seeds at a terminator, which _is_ the document question and
is wrong for a slice; `compose` is one, because its `\n` table row maps every
lane back to start.

That is the rung KIND's model, and holding a whole kind to its worst case cost
real throughput, so an instance may prove better: `compose.lower` checks whether
the reset row is what the DFA would do on a `\n` anyway (unanchored, no `$`
resolved by the second table, and no live lane stepping `\n` into a live or
accepting state) and, when it is, publishes `sliceSafe`. `rungs.zig` looks that
method up by name at comptime, so a rung that never grows one is simply held to
its static model — conservative by construction. Measured worth of the
refinement on the production `lineMatch`
(`spikes/regex-engine-worldclass/probe18.zig`, 64 MiB / 1.74M lines,
arms alternated): **2.13–2.52×** on five slice-safe field patterns, against
controls at 0.94–1.05 where the tier correctly stands down.

`-U` (`pike/search.zig`'s `bufMatch`) is the third caller, and it asks the slice
question about a whole file. It consults the tier under exactly the guard the
DFA already sits behind there — an assertion-free program, where the buffer is
one haystack — and `lower.zig` withholds the tier only from assertion-bearing
multiline, which has no DFA to lower in the first place. Measured **4.84–11.42×**
on flat `-U` patterns (`probe19.zig`, non-matching tails so the scan covers the
whole buffer rather than a prefix).

## Which rungs actually arm

Every rung arms on the population it prices best, and the costed gate stands one
down at _compile_ time wherever a start-skip or the DFA would win — the point of
offers over booleans. Each claim below is a **committed, reproducible proof**
(`zig build <step>`), not a `.local` probe, run against the 207.7 MiB corpus on
this machine:

| Rung      | Proof          | Arms on / Evidence                                                                                                                                                                                                                                                                                                                                                                                 |
| --------- | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `compose` | `compose-rung` | class-alternations, bounded digit/hex runs — every armed row agrees on the whole buffer. **The workhorse:** 6.76–6.82x on the class-alt family (\|Q\| 9–15), 3.3x on hex/digit (\|Q\| 17–22). Declines `uni-prop` (literal skip beats retiring) and `dot-star-chain` (build refuses; the ladder keeps the accelerated DFA). Also on `lineMatch` and `-U` for the instances that prove `sliceSafe`. |
| `parabix` | `parabix-rung` | `emailish` `dot-lead` `alnum-alt` `bounded` `digit-run`, plus `word-gap`/`line-gap` assertions compose cannot serve. **Now armed.** 230,978 document verdicts byte-identical to the shipped ladder; s2p ~13.8 GB/s, full 2.5–5.65 GB/s (1.6–4.7x vs the negative-case DFA). Refuses `nested-star` (star-height 2) and `uni-class` (codepoint class).                                               |
| `sieve`   | `sieve`        | `digit-40` `iso-date` `uuid` — profitable quotients only. **Now armed, and self-declining.** 0 soundness violations over 1.52 B byte-positions; the costed gate declines 4 of 9 (`alnum-alt`, `two-Capitals`, `word-space-word`, weak `alnum`) as `unprofitable` rather than arming into a loss.                                                                                                   |
| `crest`   | `crest`        | literal-free class runs where the trigram extractor yields no requirement. Forced-class-run sieve: 0 false negatives across the corpus + 96,000 randomized (pattern, file) pairs; prunes 84–96%, up to 28.2x. Correctly near-1.0x (stands down) on wide single-class patterns like `word-3`.                                                                                                       |

Ahead of every rung sit the literal populations: an `.exact` literal-set decides
a whole line/buffer in one SIMD/Teddy/Aho scan with no automaton, and a
`.candidate` set (cover union or required literal) rejects a haystack outright
before any rung runs — `../program/lower.zig` builds it, `verdict.zig` dispatches
it. The lazy DFA's per-thread cache admits adaptively, so a pattern that would
thrash a fixed budget quits to the Pike VM instead of churning.

No rung is dormant: every one has a green proof on its own population, and the
costed offers are what let an unprofitable candidate lose to a cheaper rival
rather than arm unconditionally. Re-run the four `zig build` proof steps above to
refresh any figure before quoting it as current.

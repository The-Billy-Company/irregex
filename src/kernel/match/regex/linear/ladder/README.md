---
doc_radar:
  sentinels:
    - description: "the inner rungs dispatch boolean questions and name which machine answered"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/ladder/verdict.zig
      contains: ["pub fn lineMatch", "pub fn docMatch", "pub fn docMatchFused"]
    - description: "the outer rung is a tagged union over both engines, dispatched per line not per byte"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/ladder/matcher.zig
      contains: ["pub const Matcher = union(Backend)", "pub const Backend = enum { linear, pcre }"]
---

# linear/ladder — who answers the question

Dispatch, and **only** dispatch. Two rungs of the same decision — _which machine
is the cheapest one that can soundly answer this?_ — with no semantics of their
own: every rung answers identically to the Pike VM, and a rung that cannot decide
a haystack falls through instead of guessing.

| File          | Rung                                                                                                                                                                                                                                                                 |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `matcher.zig` | **Which backend.** A tagged union over the linear `Regex` default and the opt-in PCRE2 `Pcre` (`-P`), dispatched once per line / per span search — never per byte, so the default's hot loops stay monomorphic. This is the seam the whole output layer programs to. |
| `verdict.zig` | **Which rung inside the linear arm.** In cost order: a zero-width end-of-line certainty (no scan at all) → the SIMD class-run kernel (load bandwidth) → the byte-class DFA (one lookup per byte, whole document fused) → the Pike VM (capped fallback and oracle).   |

The `*Fused` predicates (`docMatchFused`, `countRunFused`) let a caller with its
own per-line loop ask _which_ machine would answer **before** paying a line
split — the reason a whole-buffer scan can skip work a line-oriented one cannot.

Callers of the linear engine never import `verdict.zig`: `../program/core.zig`
adopts `lineMatch`, `docMatch`, and the fused predicates onto `Regex`. `Matcher`
is imported directly, by name, from the surface layer.

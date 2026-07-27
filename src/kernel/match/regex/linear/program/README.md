---
doc_radar:
  sentinels:
    - description: "the handle owns immutable state and adopts its behavior from the neighboring folders by name"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/program/core.zig
      contains: ["pub const Regex", "pub const compile = lower.compile", "pub const Span = span.Span"]
    - description: "compilation folds before it analyzes, and hands back an owned handle"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/program/lower.zig
      contains: ["pub fn compileOpts", "pub fn freeAlts"]
---

# linear/program — what a pattern becomes

The **compiled artifact and the pipeline that produces it**. Everything here is
about a `Regex` at rest: the immutable state a match reads, and the one-time
compile that decides what that state contains.

Nothing in this folder scans a haystack. Answering questions is `../ladder/`'s
job; executing them is `../pike/` and `../dfa/`.

| File            | Role                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `core.zig`      | The public `Regex` handle: the immutable compiled state with its field-by-field contract, `deinit`, the program-walk predicates (`claimsNewline` / `bansByte`), and the decls adopted from every neighbor.                                                                                                                                                                                                                     |
| `lower.zig`     | Compilation: parse → case-fold → Thompson lowering → the accelerator analyses (required literal, alternation cover, pure literals, first set, zero-width reachability) → which engines to build. That last step now decides three things, not one: which determinizer runs (`../symbolic/` or the byte powerset), whether its result is eager or on demand, and which optional rungs `../ladder/rungs.zig` can offer over it. |
| `core_test.zig` | Parser / Pike VM / prefilter / scan-accelerator cases.                                                                                                                                                                                                                                                                                                                                                                        |

## Why the handle and its constructor sit together

The field contract in `core.zig` and the code that establishes it in `lower.zig`
are one invariant read twice — every field's doc comment names the analysis that
fills it, and `deinit` is the other half of the ownership `lower` takes on. They
change together or the handle lies.

The adopted-decl block in `core.zig` is what keeps that split invisible: Zig has
no `usingnamespace`, so each neighbor's entry point is bound by name and callers
still see one type (`Regex.compile`, `re.docMatch`, `Regex.Span` …).

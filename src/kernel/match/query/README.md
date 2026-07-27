---
doc_radar:
  sentinels:
    - description: "the compiled query stays fail-closed and immutable, dispatching through the engine-neutral seam"
      file: pkg/kernels/irregex/src/kernel/match/query/query.zig
      contains: ["pub const CompiledQuery", "error.Unsupported", "pub const Scratch"]
    - description: "the prefilter derivation stays sound for both the fold window and the case-variant OR-set"
      file: pkg/kernels/irregex/src/kernel/match/query/prefilter.zig
      contains: ["pub fn regexPrefilter", "pub fn foldClosedWindow", "pub fn caselessVariants"]
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
| `word.zig`       | The ripgrep `-w` word-boundary rule as a post-match predicate (`wordOk` plus the literal / regex word-span scans), over the same `\b` oracle the engine uses.          |
| `query_test.zig` | Compile / prefilter / match cases checked against an independent oracle.                                                                                               |

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

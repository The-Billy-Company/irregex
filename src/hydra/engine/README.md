---
doc_radar:
  sentinels:
    - description: "the retrieval core is exported and wired into the test root"
      file: pkg/kernels/irregex/src/root.zig
      contains:
        - 'pub const zipper = @import("hydra/engine/zipper.zig");'
        - 'pub const hydra_search = @import("hydra/engine/search.zig");'
    - description: "the lexicon prices fingerprints, not LZ78 phrases (the measured misranking this replaced)"
      file: pkg/kernels/irregex/src/hydra/engine/lexicon.zig
      contains: "winnowing"
    - description: "the zipper is an exact Ziv–Merhav cross-parse over a suffix automaton"
      file: pkg/kernels/irregex/src/hydra/engine/zipper.zig
      contains: "Ziv–Merhav cross-parsing"
---

# `hydra/engine/` — the relate engine

The machinery behind the `hydra` binary, in two layers:

**The retrieval core** — compression-as-search, hand-rolled (no borrowed
compressor, no compressor run at all):

| Module        | Role                                                                                                                                                                                               |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lexicon.zig` | **recall** — a corpus-priced fingerprint index: winnowed 8-gram fingerprints (Schleimer et al. 2003) priced at their corpus information content, −log2(df/N) bits; boilerplate prices at exactly 0 |
| `zipper.zig`  | **precision** — a suffix automaton per candidate doc drives an exact Ziv–Merhav cross-parse: the query's conditional description length in bits (the paper's ΔAb, computed in closed form)         |

`Lexicon.retrieve` composes them: the lexicon nominates candidates from the
index alone (no doc bytes touched), the zipper decides by exact conditional
cost. `lexicon_test.zig` is the proof: short-query retrieval where the
symmetric LZJD sketch provably collapses, ΔAb sidedness/asymmetry, zero-bit
boilerplate, byte-identical determinism.

**The verb drivers** — `verbs.zig` implements `similar`, `dups`, and
`patterns` over the shared floor: the
[`../../primitives/`](../../primitives/README.md) math tier (LZ78 dictionary
sketches, multi-pattern attribution, loom shaping) and the
[`../../corpus/`](../../corpus/README.md) walk. Everything here is
corpus-scale analytics: load once, answer a set-shaped question, keep results
on stdout and diagnostics on stderr.

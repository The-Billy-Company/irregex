---
doc_radar:
  sentinels:
    - description: "similarity keeps sketch · lexicon · zipper"
      file: pkg/kernels/irregex/src/search/similarity/sketch.zig
      contains: "LZJD"
    - description: "lexicon nominates; zipper decides"
      file: pkg/kernels/irregex/src/search/similarity/zipper.zig
      contains: "Ziv"
---

# `src/search/similarity/` — compression kinship

The `relate` engine's math: measure how alike two byte bodies are by how
cheaply one describes the other — no parsers, no language list, no embeddings.

## Files

| File | Job |
| ---- | --- |
| `sketch.zig` | Symmetric relatedness — LZJD over LZ78 phrase-dictionary bottom-k MinHash (`min_phrase=3` noise floor); backs `relate similar` / `dups` |
| `lexicon.zig` | Asymmetric recall — prices winnowed fingerprints at corpus information content (−log₂(df/N)) and nominates candidates by bits already paid |
| `zipper.zig` | Exact decider — suffix-automaton Ziv–Merhav cross-parse charging real code lengths (paper's ΔAb; no compressor subprocess) |

## Pipeline

```text
relate search  →  lexicon nominates  →  zipper decides  (score = coding gain ∈ [0,1])
relate similar →  sketch distances   (atlas warm tier optional)
relate dups    →  sketch pairs below threshold → clusters as connected components
```

Persisted sketches for the warm atlas live in
[`../../index/atlas/`](../../index/atlas/). Lexicon density economics mean
`search` / `pack` rebuild the fingerprint lexicon live (scope with `ROOT...`).

## Distance intuition

`distance = 1 − Jaccard` over LZ78 phrase sketches:

| Distance | Meaning |
| -------- | ------- |
| ≤ 0.05 | Near-exact copy |
| ≤ 0.25 | Same-thing-drifted (`dups` default) |
| ≥ 0.5 | Shares style, not substance |

## When to edit

Metric parameters, winnowing, or ΔAb accounting. Verb dispatch stays in
`cli/relate/`. Proven in `sketch_test.zig` / `lexicon_test.zig`.

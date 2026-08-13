# `src/kernel/codex/` — the FM-index

What if the index over a corpus *was* the compression of that corpus? That is
not a metaphor; it is a theorem, and this package is the FM-index composition
that proves it. A codex holds a text at entropy-bound size while answering
exact substring queries at the information-theoretic time floor, and can
regenerate the text it replaced, byte for byte, from itself alone.

Three homes carry one idea. `src/kernel/math/succinct/` holds the generic
structure math — SA-IS, RRR, the wavelet tree. This package holds the
FM-index composition itself, in `codex.zig`. `../../corpus/index/shelf/`
holds the persisted `SHLF` multi-document artifact the product verbs read.

The Ziv–Merhav cross-parse that quotes a query against this index
(`cento.zig`) lives in the kinship package; that is its product math,
not this package's. The index itself is an index tier, so it sits here with
the other index tiers and the succinct floors it stands on.

## The Layers

- **`../math/succinct/sais.zig`** builds the SA-IS suffix array
  (Nong–Zhang–Chan 2009): an O(n) construction, a sentinel seam over
  vendored libsais.
- **`../math/succinct/rrr.zig`** holds plain and RRR bitvectors behind one
  `Bits` seam, giving O(1) rank at entropy space.
- **`../math/succinct/wavelet.zig`** is the canonical-Huffman wavelet tree
  (σ ≤ 4096) that answers occ/access in one descent.
- **`codex.zig`** is the `Codex` itself: build, then count/find/restore, plus
  save/load. The text, suffix array, and BWT are all freed once build
  returns; only the wavelet tree, a small C table, and the optional locate
  samples stay resident.
- **`../../corpus/index/shelf/shelf.zig`** is the multi-document corpus
  behind one codex: doc catalog, offsets, and freshness.
- **`codex_test.zig`** is the differential and property suite, checking
  every layer against a naive oracle over random, degenerate, and binary
  corpora.

Building an index and asking it three questions is one shape:

```zig
var idx = try codex.Codex.build(gpa, text, .{ .sample_rate = 32 });
defer idx.deinit(gpa);
idx.count("pub fn ");            // occurrences, O(m) — corpus size irrelevant
try idx.find(gpa, "pub fn ");    // ascending match positions
try idx.restore(gpa);            // the entire original text, from the index alone
```

Product faces read this package as the exact face's `codex
build|count|tally|status` verbs and the kinship face's `quote`, both through
the shelf. The cento parse itself is the kinship package's `codex.cento`.

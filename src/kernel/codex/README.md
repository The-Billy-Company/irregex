# `src/kernel/codex/` — the FM-index

_What if the index over a corpus **was** the compression of that corpus?_

That is not a metaphor; it is a theorem, and this package is the FM-index
composition that proves it. A codex holds a text at entropy-bound size while
answering exact substring queries at the information-theoretic time floor —
and can regenerate the text it replaced, byte for byte, from itself alone.

**Three homes, one idea.**

| Home | What lives there |
| ---- | ---------------- |
| `src/kernel/math/succinct/` | Generic structure math — SA-IS, RRR, wavelet |
| **this package** | FM-index composition (`codex.zig`) |
| [`../../corpus/index/shelf/`](../../corpus/index/shelf/) | Persisted SHLF multi-doc artifact the product verbs read |

The Ziv–Merhav cross-parse that quotes a query against this index
(`cento.zig`) lives in the `relate` package — that is relate's product math.
The index itself is an index tier, so it sits here with the other index tiers
and the succinct floors it stands on.

## The layers

| file / home | structure | rôle |
| ----------- | --------- | ---- |
| `../math/succinct/sais.zig` | SA-IS suffix array (Nong–Zhang–Chan 2009) | O(n) construction — sentinel seam over vendored libsais |
| `../math/succinct/rrr.zig` | Plain + RRR bitvectors behind one `Bits` seam | O(1) rank at entropy space |
| `../math/succinct/wavelet.zig` | canonical-Huffman wavelet tree, σ ≤ 4096 | occ/access in one descent |
| `codex.zig` | the `Codex`: build → count/find/restore + save/load | FM composition; text/SA/BWT freed after build |
| [`../../corpus/index/shelf/shelf.zig`](../../corpus/index/shelf/shelf.zig) | multi-document corpus behind one codex | doc catalog + offsets + freshness |
| `codex_test.zig` | differential + property suite | every layer vs a naive oracle |

```zig
var idx = try codex.Codex.build(gpa, text, .{ .sample_rate = 32 });
defer idx.deinit(gpa);
idx.count("pub fn ");            // occurrences, O(m) — corpus size irrelevant
try idx.find(gpa, "pub fn ");    // ascending match positions
try idx.restore(gpa);            // the entire original text, from the index alone
```

Product faces: `gist codex build|count|tally|status` and `relate quote`
(through the shelf). The cento parse is `@import("relate").codex.cento`.

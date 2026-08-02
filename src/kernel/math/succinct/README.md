# `src/kernel/math/succinct/` — structure math

Generic succinct structures the codex composes — not FM-private. Lifted out of
the old monolithic `corpus/index/codex/` so SA-IS / RRR / wavelet are reusable
math on the floor, while the FM composition lives in `src/kernel/codex/` and
the persisted SHLF artifact in `src/corpus/index/shelf/`.

| File | Job |
| ---- | --- |
| `sais.zig` | Suffix-array construction (libsais seam) |
| `rrr.zig` | O(1)-rank bitvectors |
| `wavelet.zig` | Huffman-shaped wavelet tree rank oracle |

The FM-index composition that wires these into a restorable self-index lives in
`src/kernel/codex/`.

# `src/kernel/math/succinct/` — structure math

Generic succinct structures the codex composes, not FM-private ones. They were
lifted out of the old monolithic `corpus/index/codex/` so SA-IS, RRR, and the
wavelet tree are reusable math on the floor, while the FM composition lives in
`src/kernel/codex/` and the persisted `SHLF` artifact lives in
`src/corpus/index/shelf/`.

- **`sais.zig`** wraps the vendored libsais suffix-array construction, the
  O(n) sort (Nong–Zhang–Chan) the codex's suffix array is built from.
- **`rrr.zig`** implements O(1)-rank bitvectors behind one seam, plain words
  or Raman–Raman–Rao block coding, chosen per vector by measured size.
- **`wavelet.zig`** builds the canonical-Huffman wavelet tree that turns a
  sequence of those bitvectors into one rank/access oracle over a small
  alphabet.

Edit here for new succinct structure math: a different suffix-sort seam, a
rank/select variant, anything that is arithmetic over bits rather than an
opinion about a corpus. The FM-index composition that wires these three into
a restorable self-index lives in `src/kernel/codex/`.

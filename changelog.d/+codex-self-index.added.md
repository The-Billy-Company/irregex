`src/index/codex/` — the compressed self-index: an FM-index (SA-IS suffix array →
BWT → canonical-Huffman wavelet tree over RRR-compressed bitvectors) that
holds a corpus at entropy-bound size while answering `count(P)` in O(|P|)
flat in corpus size, `find` at a tunable sampling stride, and `restore()` —
the entire original text, byte-exact, from the index alone. Differential +
property tests against naive oracles at every layer; `zig build codex-scale`
(+ `bench/codex/race.sh`) proves space/time/decodability on ~187MB of real
repo source against gzip/bzip2/zstd/xz.

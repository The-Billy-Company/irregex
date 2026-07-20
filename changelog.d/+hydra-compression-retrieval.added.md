`relate search <text>` — compression-as-search retrieval, hand-rolled. The
relate engine gained two modules under `src/search/similarity/`: `lexicon.zig`, a
corpus-priced fingerprint index (winnowed 8-gram fingerprints à la MOSS,
priced at their corpus information content −log2(df/N) bits — boilerplate is
worth exactly 0), and `zipper.zig`, a per-candidate suffix automaton driving
an exact Ziv–Merhav cross-parse (the "Language Trees and Zipping" ΔAb
computed in closed form — no compressor run, no entropy coder). `retrieve`
composes them: the lexicon nominates, the zipper decides; the score surfaced
is coding gain ∈ [0,1]. The first LZ78-phrase draft was measured misranking
short queries to parse-boundary noise and replaced. Proven by an adversarial
fixture suite (short-query recall where the symmetric LZJD sketch provably
collapses, ΔAb sidedness/asymmetry, zero-bit boilerplate, determinism) and
`bench/races/relate_headtohead.sh` — paraphrase queries gist answers with 0
hits, planted-source top-1 as a hard gate, ~2x one-pass speedup over the
K-token gist emulation.

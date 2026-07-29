---
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/bench/rungs/crest/bench.zig
    - pkg/kernels/irregex/src/kernel/math/crest.zig
    - pkg/kernels/irregex/research/crest/PROOF.md
  sentinels:
    - file: pkg/kernels/irregex/bench/rungs/crest/bench.zig
      contains:
        - "SOUNDNESS VIOLATION"
        - "randomSoundness"
---

# bench/crest — the Crest sieve's production proof harness

`zig build crest` (from `pkg/kernels/irregex/`) links the real engine, walks
the real Billy corpus, and proves the **crest sieve** (`src/kernel/math/crest.zig`,
theory in `research/crest/PROOF.md`) fail-closed:

1. **Soundness** — for every file, matched ⇒ ¬pruned, against the production
   `Regex.docMatch`; one violation exits non-zero.
2. **Pruning** — files removed by the k-int compare on the literal-free
   class-repetition slate where the trigram index prunes 0%.
3. **Speed** — full scan vs sieve+survivors, same matcher both sides.
4. **Ablation** — the total-population "count cousin" at the same ĝ.
5. **Randomized sweeps** — adversarial random patterns in BOTH engine modes
   (byte/ASCII and Unicode), each paired with its own ĝ per the Alphabet
   Contract.
6. **Scan** — the shipped interleaved document scan against an independent
   scalar per-byte reference: throughput both ways, and the answers compared
   on every document. A single differing vector fails the run, so the scan can
   be made faster but not by changing what it computes.

Results land in a `crest.csv` beside the other bench artifacts. The shipped
integration (index sidecar + read-elision oracles) is exercised end-to-end by
the CLI itself: `gist index` persists `crest.bin`, and `gist '[0-9a-f]{12}'`
elides pruned reads — compare against `--no-index` for the before/after.

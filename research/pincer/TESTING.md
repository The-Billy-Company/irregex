# Pincer — testing story

Everything in `PROOF.md` is reproducible from `spikes/anchor-joint-rarity/`.
This file records what was measured, how, and what each instrument can and
cannot establish.

## Instruments

| file | role |
| --- | --- |
| `corpus.py` | builds the corpora and needle slates |
| `probe.zig` | exact selectivity of every selector against the oracle |
| `timeit.zig` | wall clock of the kernel's dual-probe loop, anchor pair as the only variable |
| `report.py` | aggregation, per-needle ratios, degenerate-pick census |

### Build

```bash
cd spikes/anchor-joint-rarity
R=../../../pkg/kernels/irregex/src/kernel/scan/rarity.zig
zig build-exe -O ReleaseFast -femit-bin=probe  --dep rarity -Mmain=probe.zig  -Mrarity=$R
zig build-exe -O ReleaseFast -femit-bin=timeit --dep rarity -Mmain=timeit.zig -Mrarity=$R
```

`probe.zig` imports the **production** `rarity.zig` module rather than a copy, so
the "shipped" row cannot drift from what the kernel actually does. Its
`unigramPair` is a transcription of `simd.zig::indexOfPos`, including the strict
`<` tie-break that produces the `0:1` collapse.

## Corpora

```bash
python3 corpus.py     # → corpus.bin, train.bin, prose.bin, needles.txt
```

- **code** — 214 MB walked from `clients/ libs/ services/`, NUL-containing and
  >4 MB files excluded. Every 5th file is diverted to `train.bin`, so the
  training half is **held out** from the measured half.
- **prose** — 268 MB of English text, split into `prose_a.bin` (haystack) and
  `prose_b.bin` (training). Held out the same way.
- **needles** — 177 real code identifiers; 90 prose words sampled
  **stratified across the frequency spectrum**, not from the head, so the slate
  is not biased toward common or rare words.

The individual file cap matters: a first attempt let one 2.2 GB ML training file
dominate the corpus, which made every statistic a statement about that file.

## What was run

```bash
./probe corpus.bin  needles.txt       code  train.bin    > code.csv
./probe prose_a.bin needles_prose.txt prose prose_b.bin  > prose.csv
python3 report.py code.csv
./timeit corpus.bin  pairs.tsv
./timeit prose_a.bin pairs_prose.tsv
```

## Why the selectivity numbers are exact rather than sampled

A 64-byte kernel block is exactly one `u64` word of a per-offset match
bitvector, so `popCount(B_i & B_j)` **is** the survivor count and
`(B_i & B_j) ≠ 0` **is** the block gate — the kernel's own arithmetic, counted
instead of branched on. Building `n` bitvectors costs `n` SIMD passes and then
prices all `C(n,2)` pairs with no further corpus reads, which is what makes an
exhaustive oracle affordable over 590 million block-scans.

Cross-check: `true_hits` is recomputed independently as `popCount(⋀_k B_k)` —
the AND of *all* offsets — and every selector's survivor count must be ≥ it. A
selector reporting fewer survivors than there are true occurrences would be a
bug in the harness, and none did.

## Adverse tests — the ones that were meant to kill the idea

The measurements that carry weight are the ones that could have gone the other
way.

1. **Cross-distribution.** A joint model fitted on *code* was applied to *prose*
   needles on a *prose* haystack. It degrades honestly — 1.82× vs oracle instead
   of 1.00× — and still beats the shipped selector by 3.8×. Per-needle it has
   real losses (`naughty` 0.02×, `friendly` 0.08× against the plain census),
   which is the expected failure and the reason a static table is not the
   proposal.
2. **Held-out training.** Every table-based selector is fitted on a half it
   never scores against. Without this, `joint` would be self-fitted and its
   1.00× meaningless.
3. **Two compactions, both expected to work, both measured worse than a
   512-byte table** (`PROOF.md` §6). This is the strongest negative result here
   and it changed the design: distance-truncation biases the argmin toward
   unmodelled gaps, and windowing discards the wide pairs that are the whole
   point. Reporting only the 4 MB table would have hidden the fact that it is
   unshippable as-is.
4. **Prefix vs stratified sampling.** Prefix sampling plateaus at 1.37× on code
   regardless of budget — a systematic bias, not noise. Had only prose been
   measured, prefix sampling would have looked sufficient (1.01×).
5. **Regression census, not just averages.** The joint selector is *worse* than
   shipped on 5 of 177 code needles (worst 0.91×). A selector is not allowed to
   hide its losses in an aggregate.
6. **Production control for confounds.** `stepSec` and `pgxpool` — same length,
   same selected offsets, `pgxpool` with 19× more true matches — isolate
   prefilter waste from verification work in the real binary. Without the equal
   length and the inverted match count, the 41% gap would be attributable to
   either.

## What is not yet tested

- **Single-probe fast path.** `density ≤ 48` selects a different loop shape.
  Everything here measures the dual-probe wide tier.
- **End-to-end calibrating selector.** Its selectivity is measured; its wall
  clock is inferred from the joint row minus §7.1 overhead. Calibration has to
  live in the kernel to be timed honestly.
- **Second machine.** All timings are Apple M4. Selectivity is
  machine-independent; throughput is not.
- **Threaded scan.** The 1.7 GB production run is single-file and warm-cache.

## If this graduates

Integration would need, in the kernel's existing idiom:

1. `rarity.zig` widened past the clamp — a pure dynamic-range fix, no new
   concept, and by itself worth 1.73×/2.06× (`PROOF.md` §4).
2. Stratified calibration in `indexOfPos`, gated on buffer size per §7.1,
   composed with the runtime demotion counter already there.
3. A differential test asserting that the recalibrated selector returns
   byte-identical match sets — the `eql` verify already makes correctness
   independent of anchor choice, which is what makes this safe to change at all.
4. A Certificate rung whose literal probes span the needle space rather than
   sampling `pgxpool`, so the blind spot in §5 cannot reopen.
5. A changelog fragment, per the repo's per-package convention.

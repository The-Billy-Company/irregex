# Pincer — testing story

`PROOF.md` §1–§10 is reproducible from `spikes/anchor-joint-rarity/`, and
§7.2.e's integration numbers from `spikes/anchor-plan/`. This file records
what was measured, how, and what each instrument can and cannot establish.

## Instruments

Selector sweep — `spikes/anchor-joint-rarity/`:

| file | role |
| --- | --- |
| `corpus.py` | builds the corpora and needle slates |
| `probe.zig` | exact selectivity of every selector against the oracle |
| `timeit.zig` | wall clock of the kernel's dual-probe loop, anchor pair as the only variable |
| `report.py` | aggregation, per-needle ratios, degenerate-pick census |

Integration — `spikes/anchor-plan/`:

| file | role |
| --- | --- |
| `sweep.zig` | one hit-to-hit kernel sweep under the lazy, static, and calibrated plans; asserts the three hit counts agree before reporting times |
| `probe.zig` | per-needle survivor counts for static / refined / best, i.e. the headroom the improvement test is deciding over |
| `bigab.py` | in-binary CPU A/B across the literal modes, `GIST_NO_CALIBRATE` as the only variable |
| `regexab.py` | the same for a regex carrying a required literal |
| `diffall.py` | 420-invocation output differential, calibrated vs static arm of one binary |

### Build

The spikes live in Billy's machine-local `.local/`, the package in its own checkout
beside it, so a module dependency crosses between the two:

```bash
cd spikes/anchor-joint-rarity
R=../../../../irregex/src/kernel/scan/rarity.zig
zig build-exe -O ReleaseFast -femit-bin=probe  --dep rarity -Mmain=probe.zig  -Mrarity=$R
zig build-exe -O ReleaseFast -femit-bin=timeit --dep rarity -Mmain=timeit.zig -Mrarity=$R
```

The integration spikes import the whole package instead of one module, so they take
its build graph:

```bash
cd spikes/anchor-plan
P=../../../../irregex/src/root.zig
zig build-exe -O ReleaseFast -femit-bin=sweepbin --dep irregex -Mmain=sweep.zig -Mirregex=$P
zig build-exe -O ReleaseFast -femit-bin=probebin --dep irregex -Mmain=probe.zig -Mirregex=$P
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

For the integration (§7.2.e), from `spikes/anchor-plan/`. `adv.txt` is the
adversarial 200 MB buffer — an alphabet of statically-rare bytes — and `bigtree/` a
213 MB synthetic code tree, so the same commands report both the regime calibration
exists for and the ordinary one:

```bash
./sweepbin adv.txt <needle>...          # kernel ground truth, three plans
./probebin adv.txt <needle>...          # static / refine / best survivor counts
python3 bigab.py                        # in-binary CPU A/B, literal modes
python3 regexab.py                      # ditto, regex with a required literal
python3 diffall.py                      # 420-invocation output differential
```

Every arm of the A/B runs the binary **in place** rather than from a copy: copying it
invalidates the code signature on Apple silicon, and the child is then `SIGKILL`ed —
which reads as a suspiciously fast run rather than as a failure, so the harness also
refuses to report on a killed child.

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
  Everything in the selector sweep measures the dual-probe wide tier. The
  integration does interact with it — an adopted calibrated pair declares
  `single = false`, because `singleProbeWorthwhile` prices its probe against the
  static table and cannot judge a byte that is statically rare and locally common —
  which is one of the two reasons `refine` declining is a *good* outcome.
- **Second machine.** All timings are Apple M4. Selectivity is
  machine-independent; throughput is not, and the hardware-independent re-run on the
  Anvil box is still owed for the end-to-end ratios.
- **Threaded scan.** The 1.7 GB production run is single-file and warm-cache. The
  integration A/B forces `-j1` so the paired rows measure one core's work; dropping
  it lets `emitFileSharded` cut the file across cores and reports 8.0–8.2× with
  identical output, which is the same ratio and therefore evidence that the
  once-per-document mint is not being re-paid per shard — but the two arms are not
  compared to each other as a speedup.

## How the integration is tested

1. `calibrate_test.zig` covers `refine` directly: the incumbent is kept when it is
   already optimal, replaced when a materially better pair exists, and — the
   centrepiece — **not** replaced on a uniform alphabet where all 120 pairs share one
   true density, which is the winner's-curse case that caught the purely relative
   margin. Its randomised arm uses a skewed alphabet so genuine wins exist, and
   asserts bounded per-trial regression with aggregate improvement.
2. `anchor_test.zig` holds the defect's own guard — an all-tied needle must never
   select adjacent offsets — plus the table's rank-inversion and lowercase-
   distinguishability invariants.
3. Output equivalence is proven three ways rather than argued: the mined ripgrep
   suite (`bench/conformance/rgsuite/run.py`, 411/411 on both the parallel and serial
   engines), its differential fuzz companion (residual unchanged, and identical with
   `GIST_NO_CALIBRATE=1`, so the one remaining `line-content` case is not this), and
   an in-binary differential over 420 mode×needle×corpus invocations comparing the
   calibrated and static arms of the *same* binary byte for byte.
4. `spikes/anchor-plan/sweep.zig` is the kernel ground truth: one full
   hit-to-hit sweep under the lazy, static, and calibrated plans, asserting the three
   hit counts agree before reporting their times. It is what separates "the kernel
   got faster" from "the CLI got faster", and it is how the un-wired paths were found.

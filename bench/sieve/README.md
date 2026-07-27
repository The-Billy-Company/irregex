---
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/bench/sieve/bench.zig
    - pkg/kernels/irregex/src/kernel/match/regex/linear/sieve/sieve.zig
  sentinels:
    - description: "the harness fails closed on a missed match, on a retired matching document, and on a ladder that disagrees with the full scan"
      file: pkg/kernels/irregex/bench/sieve/bench.zig
      contains:
        - "SOUNDNESS VIOLATION"
        - "DOCUMENT VIOLATION"
        - "LADDER DIVERGENCE"
---

# bench/sieve — the quotient sieve's production proof harness

`zig build sieve` (from `pkg/kernels/irregex/`) links the **real** engine and
the **real** rung, then walks the **real** Billy corpus. The baseline is the
shipped `Dfa.docMatch`, not a reimplementation, and both arms run in the same
process over the same bytes so the ratio survives a box carrying ten coworker
agents.

This rung is the one that can only say **no**, so its harness is shaped
differently from its siblings': the thing that must be proved is not that a
`.hit` is right — there are none — but that a `.miss` is never a lie.

Three claims, each fail-closed:

1. **Soundness, checked twice and at two grains.** Per byte position: whenever
   the search DFA is in a matching state, every conjunct of the quotient must be
   in an accepting block. Per document: end to end against the production
   matcher, not against the DFA the sieve was derived from — deriving the oracle
   from the same object would let a shared mistake pass. One violation anywhere
   in the corpus exits non-zero, because a false reject is a **missed match**,
   the worst failure this engine has.
2. **Selectivity, measured against the estimate that gates it.** Each row prints
   the share of positions that survive beside the compile-time structural
   estimate used to decide whether the sieve arms at all. The bad rows are
   printed rather than dropped: the distribution is genuinely bimodal, and the
   gate exists precisely because of that.
3. **Speed, and the losses too.** The Sheng-resident kernel against the shipped
   `docMatch` over the same bytes in the same run — plus a ladder check _inside_
   the timing loop, so a fast wrong answer can never be reported as a fast one.

## Two numbers worth reading before trusting the third

**Rejection rate does not predict the ladder; documents kept does.** A pattern
can reject 99% of byte positions and still keep 80% of _files_, because matches
cluster and one survivor costs the whole document. Any prefilter calibrated on
position-rejection is measuring the wrong quantity — a lesson this harness
learned the expensive way and now reports both ways.

**The gate declines most patterns, and that is the result, not a shortfall.**
Where the class-run kernel already runs at ~10 GB/s, fronting it with a sieve
_loses_. The rows that would have lost are among the declined ones; a run with
no false arms is the harness passing, not the rung failing to find work.

Novelty is disclaimed in the source header and in
[`research/ceiling/CLOSED.md`](../../research/ceiling/CLOSED.md): the
over-approximating-prefilter contract is Luchaup et al. (INFOCOM 2014), Češka et
al. (arXiv:1904.10786), and Hyperscan's `HS_FLAG_PREFILTER`. What is ours is the
SP-partition harvest from an already-built DFA and the measured decision of when
it is worth arming.

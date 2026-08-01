---
doc_radar:
  paths_exist:
    - bench/rungs/parabix/bench.zig
    - src/kernel/regex/linear/parabix/parabix.zig
  sentinels:
    - description: "the harness fails closed on disagreement and on the gate arming where it must not"
      file: bench/rungs/parabix/bench.zig
      contains:
        - "error.ParabixProofFailed"
        - "ARMED on a pattern the gate must refuse"
        - "corpus documents disagreed"
---

# bench/parabix — the bit-parallel rung's production proof harness

`zig build parabix-rung` (from the repository root) links the **real** engine
and the **real** rung, so both baselines — the full `Regex.docMatch` ladder and
the raw `Dfa.docMatch` beneath it — are the shipped code rather than a
reimplementation. Every row runs both arms over the same buffer, in the same
process, **interleaved round by round** and reported min-of-N: on a box carrying
ten coworker agents, an un-interleaved A/B measures the load, not the kernel.

Four things it establishes, each fail-closed:

1. **Agreement at corpus scale.** Every armed row is run over all ~20.9k host
   corpus documents by both the ladder and the rung; one disagreement exits
   non-zero. (The exhaustive proof is the randomized Pike-VM differential in
   `parabix_test.zig`; this is the same claim at 206 MiB against the engine a
   user actually gets.)
2. **Throughput on a haystack that must be fully retired.** The corpus is the
   wrong buffer to _time_ on — a match anywhere turns a throughput number into a
   measurement of the prefix before it — so each row times a synthetic
   **adversarial near-miss** haystack: text dense in the pattern's own classes
   that never completes a match, forcing both arms through every byte.
3. **The phase ladder.** Each row prints transposition alone, transposition plus
   class streams, then the whole scan, so "the transposition is the cheap half"
   is measured here rather than quoted from PACT 2014.
4. **The refusals, from the bench as well as from the tests.** Rows marked
   refused must produce a named `Decline`; a row that _arms_ where the gate must
   refuse fails the run. Boundary rows are lowered past the gate purely to
   publish how badly the rung loses there — then the gate is re-asserted on the
   line below.

Knobs: `$PARABIX_MIB` sets the throughput buffer (default 64; in-L2 and
streaming sizes measure identically, so this is a runtime knob, not a result),
`$PARABIX_ROUNDS` the min-of-N depth (default 9).

The reference run, the honest-boundary rows, and what did not reproduce from the
research lane are in
[`src/kernel/regex/linear/parabix/README.md`](../../../src/kernel/regex/linear/parabix/README.md).

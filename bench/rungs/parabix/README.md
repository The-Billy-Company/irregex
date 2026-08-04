# bench/parabix — The Bit-Parallel Rung's Production Proof Harness

`zig build parabix-rung` (from the repository root) links the **real** engine
and the **real** rung, so both baselines — the full `Regex.docMatch` ladder and
the raw `Dfa.docMatch` beneath it — are the shipped code rather than a
reimplementation. Every row runs both arms over the same buffer, in the same
process, **interleaved round by round** and reported min-of-N: on a box carrying
ten coworker agents, an un-interleaved A/B measures the load, not the kernel.

Four things it establishes, each fail-closed:

1. **Agreement at corpus scale.** Every armed row is run over every document in
   the host corpus (`corpus.resolveRoots`) by both the ladder and the rung; one
   disagreement exits non-zero. (The exhaustive proof is the randomized Pike-VM
   differential in `parabix_test.zig`; this is the same claim against the
   engine a user actually gets, over whatever is checked out on this host.)
2. **Throughput on a haystack that must be fully retired.** The corpus is the
   wrong buffer to *time* on — a match anywhere turns a throughput number into a
   measurement of the prefix before it — so each row times a synthetic
   **adversarial near-miss** haystack: text dense in the pattern's own classes
   that never completes a match, forcing both arms through every byte.
3. **The phase ladder.** Each row prints transposition alone, transposition plus
   class streams, then the whole scan, so "the transposition is the cheap half"
   is measured here rather than quoted from PACT 2014.
4. **The refusals, from the bench as well as from the tests.** Rows marked
   refused must produce a named `Decline`; a row that *arms* where the gate must
   refuse fails the run. Boundary rows are lowered past the gate purely to
   publish how badly the rung loses there — then the gate is re-asserted on the
   line below.

The banner line reports `kernel here` (`parabix.vectorized`, whether this
target has a byte-transpose unit at all — NEON on AArch64 or SSSE3 on x86) and
`rung armable` (that plus a minted price) as two separate conjuncts, so a
freshly-ported target that compiles but has no calibration cannot read as
armed.

Set `$PARABIX_MIB` for the throughput buffer (default 64; in-L2 and streaming
sizes measure identically, so this is a runtime knob, not a result) and
`$PARABIX_ROUNDS` for the min-of-N depth (default 9).

The reference run, the honest-boundary rows, and what did not reproduce from the
research lane are in
[`src/kernel/regex/linear/parabix/README.md`](../../../src/kernel/regex/linear/parabix/README.md).

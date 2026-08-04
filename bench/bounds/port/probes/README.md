# bench/bounds/port/probes

Byte-faithful, standalone copies of the engine's hot loops — the objects
[`../mca.sh`](../mca.sh) cross-compiles and hands to `llvm-mca`.
Each copy takes raw pointers (not a `Dfa`/corpus type) so it links with zero
host-package dependencies, and brackets its measured region with `# LLVM-MCA-
BEGIN/END` marker comments **inside** the loop body (a marker straddling the
loop header gets stranded by LLVM's loop rotation/versioning).

- **`simd_contains.zig`** copies
  [`../../../../src/kernel/scan/simd.zig`](../../../../src/kernel/scan/simd.zig)'s
  `contains` vector filter — throughput-bound (independent iterations).
- **`dfa_step.zig`** copies the **classed** transition recurrence
  `s = trans_in[s + class[b]]` — 3 loads/byte, the layout every
  non-document DFA consumer walks — latency-bound (loop-carried pointer
  chase).
- **`dfa_mirror.zig`** copies the **byte-indexed** recurrence
  `s = trans_in[s + b]` over the `Dfa.Wide` mirror
  [`../../../../src/kernel/regex/linear/dfa/dfa.zig`](../../../../src/kernel/regex/linear/dfa/dfa.zig)'s
  `docMatch` steps — 2 loads/byte — latency-bound (loop-carried pointer
  chase).

Neither file is a source of truth — [`../probes_test.zig`](../probes_test.zig)
is what makes a copy trustworthy: it asserts each probe is bit-identical to
the real production function over adversarial random inputs, so a divergence
between a copy and its original fails `zig build test` instead of shipping a
silently stale port-optimality certificate. The mirrored probe additionally
fails closed when no pattern on its slate carries a mirror at all, so it can
never pass by having nothing to compare.

The two DFA probes are a **pair on purpose**: the same recurrence over the two
layouts the automaton keeps, which is what lets the certificate say whether the
mirror's win is latency or port pressure instead of assuming. It is port
pressure — see [`../README.md`](../README.md).

---
doc_radar:
  sentinels:
    - description: "simd presence + verify remain the hot scan primitives"
      file: pkg/kernels/irregex/src/kernel/match/scan/simd.zig
      contains: "contains"
    - description: "corpus byte-density table drives anchor selection + the single-probe dispatch"
      file: pkg/kernels/irregex/src/kernel/match/scan/rarity.zig
      contains: "single_probe_max"
    - description: "verify is the fused parallel confirm kernel"
      file: pkg/kernels/irregex/src/kernel/match/scan/verify.zig
      contains: "pub fn"
    - description: "classrun ships the boolean scan, the fused -c line count, and the -o span walker"
      file: pkg/kernels/irregex/src/kernel/match/scan/classrun.zig
      contains:
        - "pub fn scan"
        - "pub fn countLines"
        - "pub fn nextSpan"
---

# `src/kernel/match/scan/` — byte-level verify primitives

The hot per-file kernels that decide whether a candidate matches. This is
the half of the head-to-head that has to out-throughput ripgrep's multi-core
scan. The fused work-stealing walk that _feeds_ these kernels lives in
`surface/exec/cold/engine/parallel.zig`; the resident session drives `verify`
directly.

## Files

| File           | Job                                                                                                                                                                                             |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `simd.zig`     | SIMD substring presence (`contains ≡ std.mem.indexOf`) — memchr-style rare-pair anchor gate for fixed strings, 64-byte blocks gated on a cheap any-lane OR-reduce (movemask only in hit blocks)   |
| `rarity.zig`   | Corpus-derived byte-density table feeding `simd`'s anchor selection + single-probe dispatch (the memchr crate's "rare byte" heuristic, measured over the Billy tree)                              |
| `verify.zig`   | Pure data-parallel candidate-verify kernel + SIMD scan wrappers callers drive                                                                                                                    |
| `teddy.zig`    | Teddy nibble-shuffle multi-literal prefilter for small alternation covers                                                                                                                        |
| `classrun.zig` | Dense-class kernel: a class-repetition pattern (`\w+`, `[a-z]{3,}`) decided as "≥ min consecutive members of a byte set" — range-compare / truffle SIMD membership + word-trick run detection, a streaming whole-buffer `-c` line count (membership + newline masks in one pass), a `-o` span walker (`nextSpan` chunks member runs by the leftmost-first window rule `analysis.classSpanShape` proves — no Pike VM), and a scalar-UTF-8 codepoint resolver so Unicode classes (`\w`) settle high bytes in-kernel. Bypasses the DFA's serial table walk *and* its powerset compile; `analysis.classRunShape` decides eligibility |

## Where it sits on the ladder

A caseful `-F` pattern never builds an automaton — `simd` answers presence.
Regex paths compile elsewhere (`../regex/`) and may still call into verify
for candidate confirmation after trigram / crest elision.

## Gates

Soundness (0 FN / 0 FP vs `rg (?-u)`) and the straggler-balance canary:
`bench/gates/scan_regress.sh`.

## When to edit

SIMD strategy, verify fusion, or hot-loop invariants. Changing _which_ files
are candidates is `index/` + cold engine work, not this package.

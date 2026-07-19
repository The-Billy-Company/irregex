---
doc_radar:
  sentinels:
    - description: "simd presence + verify remain the hot scan primitives"
      file: pkg/kernels/irregex/src/search/match/scan/simd.zig
      contains: "contains"
    - description: "verify is the fused parallel confirm kernel"
      file: pkg/kernels/irregex/src/search/match/scan/verify.zig
      contains: "pub fn"
---

# `src/search/match/scan/` — byte-level verify primitives

The hot per-file kernels that decide whether a candidate matches. This is
the half of the head-to-head that has to out-throughput ripgrep's multi-core
scan. The fused work-stealing walk that *feeds* these kernels lives in
`runtime/cold/engine/parallel.zig`; the resident session drives `verify`
directly.

## Files

| File | Job |
| ---- | --- |
| `simd.zig` | SIMD substring presence (`contains ≡ std.mem.indexOf`) — memchr-style first+last-byte gate for fixed strings |
| `verify.zig` | Pure data-parallel candidate-verify kernel + SIMD scan wrappers callers drive |

## Where it sits on the ladder

A caseful `-F` pattern never builds an automaton — `simd` answers presence.
Regex paths compile elsewhere (`../regex/`) and may still call into verify
for candidate confirmation after trigram / crest elision.

## Gates

Soundness (0 FN / 0 FP vs `rg (?-u)`) and the straggler-balance canary:
`bench/gates/scan_regress.sh`.

## When to edit

SIMD strategy, verify fusion, or hot-loop invariants. Changing *which* files
are candidates is `index/` + cold engine work, not this package.

---
doc_radar:
  counts:
    - description: "primitives keeps bits + crest + parallel (bits/crest carry tests)"
      glob: pkg/kernels/irregex/src/kernel/primitives/*.zig
      unit: files
      equals: 5
  sentinels:
    - description: "crest calculus stays a pure math export"
      file: pkg/kernels/irregex/src/kernel/primitives/crest.zig
      contains: ["pub const Class", "pub fn ghat"]
---

# `src/kernel/primitives/` — shared identity floor

The lowest tier: pure, dependency-free numeric primitives. No I/O, no walk
policy, no CLI. Both engines ride this instead of hand-rolling bit twiddling
or crest lattice math at each call site.

## What lives here

| File           | Job                                                                                                                                                             |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bits.zig`     | Two's-complement bit identities over plain `u64` limb slices: set-bit walks, word-packed sets, popcount/rank, width-edge-safe masks                             |
| `crest.zig`    | Forced-class-run sieve calculus: `Class` / `K` / `Vector` / `Profile`, `ghat`, prune helpers — a sound _necessary_ condition for literal-free class repetitions |
| `parallel.zig` | Shared data-parallel floor: byte-balanced shard `greedyBounds`, the `sliceLen` weight, and the partial-spawn-safe `fanOut` both engines ride                    |

## Why it is separate

SA-IS, RRR, the DFA `ByteSet`, posting codecs, and `PatternSet` all need the
same packed-bit walks. Crest's class lattice order is load-bearing — the
persisted sidecar stores vectors verbatim — so the math has one home and a
theory dossier at [`../../../research/crest/`](../../../research/crest/).

## Invariants

- Identities operate over **caller-owned** slices (not an owning `std.bit_set`).
- Crest soundness rounds **down** only (under-prune, never introduce a false
  negative). Caseless → zero vector; Unicode certifies only ASCII-safe classes.
- `bits_test.zig` checks the packed representation against a `bool`-slice
  oracle; `crest_test.zig` pins lattice / `ghat` edges.

## When to edit

New shared bit ops; crest lattice / Alphabet Contract changes. Never put
file I/O or ignore rules here — that is `corpus/` / `surface/exec/cold/`.

Root re-exports: `irregex.bits`, crest symbols via `src/root.zig`.

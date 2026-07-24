---
doc_radar:
  counts:
    - description: "primitives keeps bits + crest + parallel + ward (bits/crest/ward carry tests)"
      glob: pkg/kernels/irregex/src/kernel/primitives/*.zig
      unit: files
      equals: 7
  sentinels:
    - description: "crest calculus stays a pure math export"
      file: pkg/kernels/irregex/src/kernel/primitives/crest.zig
      contains: ["pub const Class", "pub fn ghat"]
---

# `src/kernel/primitives/` — shared identity floor

The lowest tier: pure, dependency-free primitives — numeric identities plus the
shared data-parallel and reader/writer disciplines. No walk policy, no CLI.
Both engines and the warm session ride these instead of hand-rolling bit
twiddling, Crest class-family math, thread fan-out, or `RwLock` lock/unlock pairs at
each call site.

## What lives here

| File           | Job                                                                                                                                                                                                                                                                                                                                          |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bits.zig`     | Two's-complement bit identities over plain `u64` limb slices: set-bit walks, word-packed sets, popcount/rank, width-edge-safe masks                                                                                                                                                                                                          |
| `crest.zig`    | Forced-class-run sieve calculus: `Class` / `K` / `Vector` / `Profile`, `ghat`, prune helpers — a sound _necessary_ condition for literal-free class repetitions                                                                                                                                                                              |
| `parallel.zig` | Shared data-parallel floor: byte-balanced shard `greedyBounds`, the `sliceLen` weight, and the partial-spawn-safe `fanOut` both engines ride                                                                                                                                                                                                 |
| `ward.zig`     | Shared reader/writer discipline over `std.Io.RwLock`: `Read`/`Write` lease guards + the double-checked reconcile dance (fast shared read, upgrade + refresh on a miss, downgrade) — `readReconciled` (acquires shared, holds nothing on error) and `reconcileHeld` (from a held lease, keeps a lease on every path) — the warm session rides |

## Why it is separate

SA-IS, RRR, the DFA `ByteSet`, posting codecs, and `PatternSet` all need the
same packed-bit walks. Crest's class-family order is load-bearing — the
persisted sidecar stores vectors verbatim — so the math has one home and a
theory dossier at [`../../../research/crest/`](../../../research/crest/).

## Invariants

- Identities operate over **caller-owned** slices (not an owning `std.bit_set`).
- Crest soundness rounds **down** only (under-prune, never introduce a false
  negative). Caseless preserves case-closed certificates and declines unsafe
  folds; Unicode certifies only byte-safe classes.
- `bits_test.zig` checks the packed representation against a `bool`-slice
  oracle; `crest_test.zig` pins class-family / `ghat` edges; `ward_test.zig` proves
  the lease guards exclude and both reconcile faces' (`readReconciled` /
  `reconcileHeld`) fast/miss/race/error paths against a call-counting oracle plus
  a threaded reader/writer invariant.
- `ward.zig` is the one primitive that touches the `std.Io` seam (it wraps
  `std.Io.RwLock`) — still no file I/O, walk policy, or CLI.

## When to edit

New shared bit ops; Crest class-family / Alphabet Contract changes; shared
concurrency disciplines (`ward`). Never put file I/O or ignore rules here —
that is `corpus/` / `surface/exec/cold/`.

Root re-exports: `irregex.bits`, `crest`, and `ward` via `src/root.zig`.

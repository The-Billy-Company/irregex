---
doc_radar:
  counts:
    - description: "primitives keeps bits + crest + parallel + signet + ward (bits/crest/signet/ward carry tests)"
      glob: pkg/kernels/irregex/src/kernel/primitives/*.zig
      unit: files
      equals: 9
  sentinels:
    - description: "crest primitives own the document side (ρ, dominance, the class family) and derive no ĝ — the forced-crest calculus reads the engine's AST from match/regex/analysis/swell.zig, so no second grammar can diverge from the matcher"
      file: pkg/kernels/irregex/src/kernel/primitives/crest.zig
      contains: ["pub const Class", "pub fn crest", "pub fn pruned", "pub const Swell"]
      absent: ["pub fn ghat", "const Parser"]
---

# `src/kernel/primitives/` — shared identity floor

The lowest tier: pure, dependency-free primitives — numeric identities plus the
shared data-parallel, integrity, and reader/writer disciplines. No walk policy,
no CLI. Both engines and the warm session ride these instead of hand-rolling bit
twiddling, Crest class-family math, thread fan-out, artifact checksums, or
`RwLock` lock/unlock pairs at each call site.

## What lives here

| File           | Job                                                                                                                                                                                                                                                                                                                                          |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bits.zig`     | Two's-complement bit identities over plain `u64` limb slices: set-bit walks, word-packed sets, popcount/rank, width-edge-safe masks                                                                                                                                                                                                          |
| `crest.zig`    | Forced-class-run sieve: the `Class` family, the document vector ρ, the dominance test, and the `Swell` disjunction a query sieves by (one ĝ per top-level alternative) — a sound _necessary_ condition for literal-free class repetitions                                                                                                    |
| `parallel.zig` | Shared data-parallel floor: byte-balanced shard `greedyBounds`, the `sliceLen` weight, and the partial-spawn-safe `fanOut` both engines ride                                                                                                                                                                                                 |
| `signet.zig`   | Durable identity of bytes: one domain-separated BLAKE3 digest (`of`/`Scribe`) plus the seal protocol (`sealInto`/`unseal`, and `body`+`verify` for artifacts that map instead of read) every persisted blob shares                                                                                                                            |
| `ward.zig`     | Shared reader/writer discipline over `std.Io.RwLock`: `Read`/`Write` lease guards + the double-checked reconcile dance (`readReconciled` / `reconcileHeld`) — plus `Latch`, an atomic spinlock for threads with no `std.Io` handle (OS watchers, signal-adjacent callbacks) |

## Why it is separate

SA-IS, RRR, the DFA `ByteSet`, posting codecs, and `PatternSet` all need the
same packed-bit walks. Crest's class-family order is load-bearing — the
persisted sidecar stores vectors verbatim — so the math has one home and a
theory dossier at [`../../../research/crest/`](../../../research/crest/).
Integrity had the opposite problem: three artifacts each invented their own
trailer and five more had none, so `signet` is the one answer to "are these the
bytes we wrote" that every persisted format now shares — including the crest
sidecar, whose schema digest is a signet in a different domain than its seal.

## Invariants

- Identities operate over **caller-owned** slices (not an owning `std.bit_set`).
- Crest soundness rounds **down** only (under-prune, never introduce a false
  negative). Caseless preserves case-closed certificates and declines unsafe
  folds; Unicode certifies only byte-safe classes.
- A signet is for bytes that **outlive the process**. Hash-table keys stay on
  `std.hash.Wyhash` (a slot index re-probes; it never needed collision
  resistance), and the FNV in `kernel/kinship/` stays put because it is not a
  checksum — it IS the sketch, so changing it moves every distance in the corpus.
- `bits_test.zig` checks the packed representation against a `bool`-slice
  oracle; `crest_test.zig` pins the class family and the swell's disjunctive
  decision; `signet_test.zig` pins the published BLAKE3 vector and the exact
  domain labels, then proves a seal catches the torn-write shapes layout
  validation cannot see; `ward_test.zig` proves
  the lease guards exclude and both reconcile faces' (`readReconciled` /
  `reconcileHeld`) fast/miss/race/error paths against a call-counting oracle plus
  a threaded reader/writer invariant.
- `ward.zig` is the one primitive that touches the `std.Io` seam (`Ward` wraps
  `std.Io.RwLock`; `Latch` is a plain atomic swap for non-`Io` threads) — still
  no file I/O, walk policy, or CLI.

## When to edit

New shared bit ops; Crest class-family / Alphabet Contract changes; shared
concurrency disciplines (`ward`). Never put file I/O or ignore rules here —
that is `corpus/` / `surface/exec/cold/`.

Root re-exports: `irregex.bits`, `crest`, `signet`, and `ward` via `src/root.zig`.

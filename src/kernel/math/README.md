---
doc_radar:
  counts:
    - description: "math floor zig sources at package root (bits/crest/dag/forest/glob/lease/misread/mix/parallel + tests)"
      glob: pkg/kernels/irregex/src/kernel/math/*.zig
      unit: files
      equals: 14
  sentinels:
    - description: "crest owns the document side (ρ, dominance, class family) and derives no ĝ — forced-crest calculus reads the engine AST from regex/analysis/swell.zig"
      file: pkg/kernels/irregex/src/kernel/math/crest.zig
      contains: ["pub const Class", "pub const Alphabet", "pub fn crest", "pub fn pruned", "pub const Swell"]
      absent: ["pub fn ghat", "const Parser"]
---

# `src/kernel/math/` — the math floor

The lowest kernel tier: pure, product-free arithmetic and the structures it runs
over. No walk policy, no CLI, no regex opinion. Kept physically away from engine
code so bit tricks and sieve calculus cannot grow a dependency on a matcher —
and so a structure with no product opinion stays reachable by every tier above,
rather than being sealed inside the first one that happened to need it.

| File / dir | Job |
| ---------- | --- |
| `bits.zig` | Two's-complement bit identities over `u64` limb slices |
| `mix.zig` | Hash mixing (splitmix64 finalize, FNV-1a constants, `SliceCtx`) |
| `glob.zig` | Pure glob matcher (split out of the old `corpus/scope/glob.zig`) |
| `crest.zig` | Forced-class-run sieve calculus — document vector ρ, dominance, `Swell` |
| `misread.zig` | Damerau–Levenshtein (OSA) + `nearest()` did-you-mean (was under `corpus/scope/`) |
| `forest.zig` | Path-halving disjoint-set forest (was inside kinship clustering) |
| `dag.zig` | Hash-consed DAG over a caller's payload — structural equality as identity, topological id order, `fold`/`descend`/`power` |
| `lease.zig` | Reader/writer leases over `std.Io.RwLock` (was `primitives/ward.zig`) |
| `parallel.zig` | Byte-balanced shard bounds + partial-spawn-safe `fanOut` |
| [`succinct/`](succinct) | SA-IS, RRR, Huffman wavelet — generic structure math for the codex |

## Invariants

- Identities operate over **caller-owned** slices.
- Crest soundness rounds **down** only (under-prune, never false-negative).
- A signet (integrity digest) lives on the wire floor beside framing —
  `corpus/index/frame/signet.zig` — not here; math has no persistence opinion.

## When to edit

New shared bit ops; Crest class-family changes; concurrency leases; succinct
structures; a graph or set structure more than one tier can use. Never file I/O
or ignore rules — that is `corpus/` / `exec/cold/`.

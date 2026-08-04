# `src/kernel/math/` — the math floor

The lowest kernel tier: pure, product-free arithmetic and the structures it
runs over. No walk policy, no CLI, no regex opinion. It is kept physically
away from engine code so bit tricks and sieve calculus cannot grow a
dependency on a matcher, and so a structure with no product opinion stays
reachable by every tier above rather than being sealed inside the first one
that happened to need it.

`math.zig` is the door: it re-exports every file below under one name
(`math.bits`, `math.crest`, `math.succinct.rrr`, …), which is how `root.zig`
and every other kernel tier reach this floor.

- **`bits.zig`** holds two's-complement bit identities over `u64` limb
  slices — set-bit walks and word-packed bit sets.
- **`mix.zig`** is the hash-mixing floor under sketches and hash-table keys
  (splitmix64 finalize, FNV-1a constants, `SliceCtx`).
- **`glob.zig`** is the pure gitignore/rg-shaped glob matcher, split out of
  the old `corpus/scope/glob.zig` so pattern-vs-string math has no walk
  opinion.
- **`crest.zig`** is the forced-class-run sieve calculus: the document
  vector ρ, dominance, and `Swell`, which prune a literal-free pattern the
  trigram index cannot.
- **`misread.zig`** is Damerau–Levenshtein (OSA) plus the `nearest()`
  did-you-mean built on it, moved here from `corpus/scope/`.
- **`forest.zig`** is a path-halving disjoint-set forest — union-find with
  deterministic min-index representatives — lifted out of kinship
  clustering.
- **`dag.zig`** is a hash-consed DAG over a caller's payload: structural
  equality as identity, topological id order, and `fold`/`descend`/`power`
  over the result.
- **`lease.zig`** holds reader/writer leases over `std.Io.RwLock`, the
  double-checked read-mostly reconcile dance, moved here from
  `primitives/ward.zig`.
- **`parallel.zig`** computes byte-balanced shard bounds and a
  partial-spawn-safe `fanOut` — the sharding geometry every parallel lane
  in the package divides work by.
- [`succinct/`](succinct) holds SA-IS, RRR, and the Huffman wavelet tree —
  generic structure math the codex composes.

## Invariants

- Identities operate over **caller-owned** slices.
- Crest soundness rounds **down** only (under-prune, never false-negative).
- A signet (integrity digest) lives on the wire floor beside framing —
  `corpus/index/frame/signet.zig` — not here; math has no persistence
  opinion.

## When to Edit

New shared bit ops; crest class-family changes; concurrency leases;
succinct structures; a graph or set structure more than one tier can use.
Never file I/O or ignore rules — that is `corpus/` / `exec/cold/`.

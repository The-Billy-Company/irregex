---
doc_radar:
  sentinels:
    - description: "crest sidecar stays generation-atomic with the trigram pair"
      file: pkg/kernels/irregex/src/index/crest/sidecar.zig
      contains: ["GISTCRS1", "pub fn decode"]
    - description: "sieve calculus lives in math, not the sidecar"
      file: pkg/kernels/irregex/src/math/crest.zig
      contains: "pub fn ghat"
---

# `src/index/crest/` — persisted crest-vector sidecar

The disk half of the **crest sieve**. Kernel math:
[`../../math/crest.zig`](../../math/crest.zig). Theory:
[`../../../research/crest/PROOF.md`](../../../research/crest/PROOF.md).

One `u16^K` crest vector per indexed doc (16 B), doc-id order, staged under
the same `gens/<id>/` directory and published by the same `pair.gen` flip as
`index.gist` / `paths.list` — so a reader can never pair the table with a
foreign doc-id space.

## Why it exists

Trigrams prove absence of required *literals*. Crest proves absence for
**literal-free class repetitions** (`\d+`, `[a-z]{8}`, …) that trigrams
concede. Together they elide more `open(2)`s without changing answers.

## Files

| File | Job |
| ---- | --- |
| `sidecar.zig` | Codec (`writeInto` / `decode`, fail-closed) + parallel `build` pass |
| `sidecar_test.zig` | Round-trip identity + adversarial malformed-blob suite |

## Invariants

- `decode` is zero-copy over the caller's mapping and returns **null** on any
  disagreement (magic, doc count, lattice arity, element width, length,
  alignment) → the query simply runs without the sieve.
- Soundness rounds down only (under-prune); see math + `research/crest`.
- Consumers: read-elision oracles in
  `runtime/cold/engine/{serial,parallel}.zig`.

## When to edit

On-disk framing, publish atomicity with the trigram pair, or build
parallelism. Changing the lattice / `ghat` math is `src/math/crest.zig` +
the research proof, not this codec alone.

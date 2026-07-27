---
doc_radar:
  sentinels:
    - description: "crest sidecar stays generation-atomic with the trigram pair"
      file: pkg/kernels/irregex/src/corpus/index/crest/sidecar.zig
      contains: ["GISTCRS3", "pub fn decode", "pub fn verify"]
    - description: "sieve calculus lives in the regex analysis layer, not the sidecar — ĝ is derived from the engine's own AST"
      file: pkg/kernels/irregex/src/kernel/match/regex/analysis/swell.zig
      contains: "pub fn forcedSwell"
---

# `src/corpus/index/crest/` — persisted crest-vector sidecar

The disk half of the **crest sieve**. Kernel math:
[`../../../kernel/primitives/crest.zig`](../../../kernel/primitives/crest.zig).
Theory: [`../../../../research/crest/PROOF.md`](../../../../research/crest/PROOF.md).

One `u16^K` crest vector per indexed doc (16 B), doc-id order, staged under
the same `gens/<id>/` directory and published by the same `pair.gen` flip as
`index.gist` / `paths.list` — so a reader can never pair the table with a
foreign doc-id space.

## Why it exists

Trigrams prove absence of required _literals_. Crest proves absence for
**literal-free class repetitions** (`\d+`, `[a-z]{8}`, …) that trigrams
concede. Together they elide more `open(2)`s without changing answers.

## Files

| File               | Job                                                                 |
| ------------------ | ------------------------------------------------------------------- |
| `sidecar.zig`      | Codec (`writeInto` / `decode` / `verify`, fail-closed) + parallel `build` pass |
| `sidecar_test.zig` | Round-trip identity + adversarial malformed-blob suite              |

## Format v3

`GISTCRS3` carries a 64-byte header: explicit format version, class count,
element width, index-bound document count, the semantic-schema **signet**, and
zero-only reserved padding. The body remains `[doc][8]u16` little-endian, and an
artifact signet trails it.

The schema preimage is canonical and architecture-independent. It includes the
ordered class names, all 256 byte-membership masks, the `u16` saturation cap,
the per-element interpretation, and the format version. A cache built under
different semantics therefore fails closed even when its dimensions happen to
match. Older magics are deliberately not upgraded in place; they decode as null
and the existing generation lifecycle rebuilds them.

The trailing seal exists because this is the one table whose corruption story is
a **missed** match: a ρ(d) that rots downward prunes a document that would have
matched, and every layout check still passes. `verify` is separate from `decode`
for the same reason the shard's is — the table is mapped, and a query should pay
for the pages it reads, not for a whole-file digest it did not ask for.

## Invariants

- `decode` is zero-copy over the caller's mapping and returns **null** on any
  disagreement (magic, format version, semantic hash, doc count, class-family
  arity, element width, reserved padding, checked length, alignment) → the
  query simply runs without the sieve. `verify` proves the seal on demand.
- Soundness rounds down only (under-prune); see the kernel + `research/crest`.
- Consumers: read-elision oracles in
  `surface/exec/cold/quarry/elide.zig` and the serial/swarm engines.

## When to edit

On-disk framing, publish atomicity with the trigram pair, or build
parallelism. Changing the class family / `ghat` math is
`src/kernel/primitives/crest.zig` + the research proof, not this codec alone.

---
doc_radar:
  sentinels:
    - description: "crest sidecar stays generation-atomic with the trigram pair"
      file: pkg/kernels/irregex/src/corpus/index/crest/sidecar.zig
      contains: ["GISTCRS2", "pub fn decode"]
    - description: "sieve calculus lives in the regex analysis layer, not the sidecar — ĝ is derived from the engine's own AST"
      file: pkg/kernels/irregex/src/kernel/match/regex/analysis/swell.zig
      contains: "pub fn forcedCrest"
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
| `sidecar.zig`      | Codec (`writeInto` / `decode`, fail-closed) + parallel `build` pass |
| `sidecar_test.zig` | Round-trip identity + adversarial malformed-blob suite              |

## Format v2

`GISTCRS2` carries a 64-byte header: explicit format version, class count,
element width, index-bound document count, SHA-256 semantic-schema hash, and
zero-only reserved padding. The body remains `[doc][8]u16` little-endian.

The hash preimage is canonical and architecture-independent. It includes the
ordered class names, all 256 byte-membership masks, the `u16` saturation cap,
the per-element interpretation, and the format version. A cache built under
different semantics therefore fails closed even when its dimensions happen to
match. `GISTCRS1` is deliberately not upgraded in place; it decodes as null and
the existing generation lifecycle rebuilds it.

## Invariants

- `decode` is zero-copy over the caller's mapping and returns **null** on any
  disagreement (magic, format version, semantic hash, doc count, class-family
  arity, element width, reserved padding, checked length, alignment) → the
  query simply runs without the sieve.
- Soundness rounds down only (under-prune); see the kernel + `research/crest`.
- Consumers: read-elision oracles in
  `surface/exec/cold/engine/{serial,parallel}.zig`.

## When to edit

On-disk framing, publish atomicity with the trigram pair, or build
parallelism. Changing the class family / `ghat` math is
`src/kernel/primitives/crest.zig` + the research proof, not this codec alone.

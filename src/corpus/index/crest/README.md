---
doc_radar:
  sentinels:
    - description: "crest sidecar stays generation-atomic with the trigram pair"
      file: src/corpus/index/crest/sidecar.zig
      contains: ["GISTCRS3", "pub fn decode", "pub fn verify"]
    - description: "sieve calculus lives in the regex analysis layer, not the sidecar — ĝ is derived from the engine's own AST"
      file: src/kernel/regex/analysis/swell.zig
      contains: "pub fn forcedSwell"
---

# `src/corpus/index/crest/` — persisted crest-vector sidecar

The disk half of the **crest sieve**. Kernel math:
[`../../../kernel/math/crest.zig`](../../../kernel/math/crest.zig).
Theory: [`../../../../research/crest/PROOF.md`](../../../../research/crest/PROOF.md).

One `u16^K` crest vector per indexed doc (`K = 16`, so 32 B), doc-id order, staged under
the same `gens/<id>/` directory and published by the same `pair.gen` flip as
`index.gist` / `paths.list` — so a reader can never pair the table with a
foreign doc-id space.

## Why it exists

Trigrams prove absence of required _literals_. Crest proves absence for
**literal-free class repetitions** (`\d+`, `[a-z]{8}`, …) that trigrams
concede. Together they elide more `open(2)`s without changing answers.

## Files

| File               | Job                                                                            |
| ------------------ | ------------------------------------------------------------------------------ |
| `sidecar.zig`      | Codec (`writeInto` / `decode` / `verify`, fail-closed) + parallel `build` pass |
| `sidecar_test.zig` | Round-trip identity + adversarial malformed-blob suite                         |

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
matched, and every layout check still passes. So the seal is **spent at
admission** — `persist.sealedCrest` verifies it before the loader publishes
`crest` / `short_docs`, and a broken seal reads as "no sidecar" like any other
rejection. `verify` stays a separate call from `decode` only so the O(1) layout
refusals run first and a foreign blob is never digested.

That order is what keeps it cheap. The loader already walks every record
straight after (`shortDocs`), and an active sieve walks them again, so the pages
are resident either way and only the digest is new: **0.18 ms** over the
production 345 KB / 21.6k-doc table (BLAKE3, 1.93 GB/s) beside 0.007 ms for the
record pass. The mapped base pair keeps the deferred posture — 44 MB of postings
a query touches a few pages of is the trade `signet.body` exists for.

## Invariants

- `decode` is zero-copy over the caller's mapping and returns **null** on any
  disagreement (magic, format version, semantic hash, doc count, class-family
  arity, element width, reserved padding, checked length, alignment) → the
  query simply runs without the sieve.
- No admitted table is unproven: the loader pairs `decode` with `verify`, so a
  vector that reaches `Swell.prunes` came from a sealed blob. The amend segment
  that overlays it (`../trigrams/codicil.zig`, `GISTCOD2`) is sealed whole for
  the same reason — its recomputed rows prune too.
- Soundness rounds down only (under-prune); see the kernel + `research/crest`.
- Consumers: read-elision oracles in
  `exec/cold/quarry/elide.zig` and the serial/swarm engines.
- **`build` has a second caller that never touches this codec.** The resident
  session computes its own ρ(d) array over the mirror's bytes by calling `build`
  directly (`exec/session/warm/mirror.zig`) — no blob, no seal, no freshness
  gate, because it holds the bytes it measured. That it reuses this pass rather
  than re-looping is deliberate: a resident vector and the on-disk vector for the
  same bytes are then the _same computation_ and cannot drift into disagreeing
  about ρ(d), which is the only way the two tiers could prune differently.

## When to edit

On-disk framing, publish atomicity with the trigram pair, or build
parallelism. Changing the class family / `ghat` math is
`src/kernel/math/crest.zig` + the research proof, not this codec alone.

---
doc_radar:
  sentinels:
    - description: "postings stay the LEB128 + CSR blob codecs"
      file: pkg/kernels/irregex/src/corpus/index/postings/varint.zig
      contains: ["pub fn encode", "pub fn decode"]
    - description: "trigrams consume the native-endian CSR blob layout"
      file: pkg/kernels/irregex/src/corpus/index/postings/persisted_blob.zig
      contains: ["GISTIDX", "pub const MappedRegions", "format_version"]
---

# `src/index/postings/` — compact posting-body codecs

How a posting list of document ids becomes bytes on disk and maps back
zero-copy. The trigram index ([`../trigrams/`](../trigrams)) owns *what* is
indexed; this package owns the wire.

## Files

| File | Job |
| ---- | --- |
| `varint.zig` | LEB128 variable-length integer codec — delta-compressed posting bodies (smallest wire per gap) |
| `persisted_blob.zig` | Persisted index blob layout: header, section offsets, `mmap`-friendly CSR shape (csearch lineage) |

## Invariants

- Encode → decode ≡ identity for every legal gap sequence
  (`varint_test.zig` fuzzes adversarial + boundary values).
- The blob is designed for **partial fault-in**: a cold query should only
  touch the posting groups it needs.
- Layout changes are on-disk format changes — bump magic / generation with
  the trigram persist path in the same PR.

## When to edit

Codec edge cases, CSR header fields, or mmap alignment. If you are changing
*which* docs appear in a posting list, you want `../trigrams/`, not here.

# `src/corpus/index/postings/` — Compact Posting-Body Codecs

How a posting list of document ids becomes bytes on disk and maps back
zero-copy. The trigram index ([`../trigrams/`](../trigrams)) owns _what_ is
indexed; this package owns the wire.

## Files

- **`varint.zig`** is the LEB128 variable-length integer codec that
  delta-compresses posting bodies for the smallest wire size per gap.
- **`persisted_blob.zig`** defines the persisted index blob layout: header,
  section offsets, and the `mmap`-friendly CSR shape (csearch lineage).

## Invariants

- Encode → decode is identity for every legal gap sequence (`varint_test.zig`
  fuzzes adversarial and boundary values).
- The blob is designed for **partial fault-in**: a cold query should only
  touch the posting groups it needs.
- Layout changes are on-disk format changes — bump the magic and generation
  alongside the trigram persist path, in the same PR.

## When To Edit

Edit here for codec edge cases, CSR header fields, or mmap alignment. If you
are changing _which_ docs appear in a posting list, you want
[`../trigrams/`](../trigrams), not here.

---
doc_radar:
  sentinels:
    - description: "frame owns the shared framing primitives"
      file: pkg/kernels/irregex/src/corpus/index/frame/frame.zig
      contains:
        - "pub const Cursor"
        - "pub fn joinNul"
        - "pub fn splitNulExact"
        - "pub fn parsePathTable"
---

# `src/index/frame/` — the wire discipline every persisted artifact shares

One home for the framing primitives the index blobs are built from, so the
formats can't drift on conventions:

- **`putInt` / `Cursor`** — little-endian fixed-width ints, read back through
  a fail-closed byte cursor (`error.Corrupt` instead of reading past the end).
- **`putWords` / `Cursor.words`** — length-prefixed u64-slice payloads.
- **`nulLen` / `joinNul` / `splitNulExact` / `parsePathTable`** — the
  NUL-joined string tables every artifact uses for its path/roots catalogs.

Consumers: the codex + shelf blobs (`../codex/`), the kinship atlas
(`../atlas/`), and the trigram pair loader (`../trigrams/persist.zig`).

Framing only — magic bytes, versions, and checksums stay with each format,
where the corruption story lives. Round-trip and corruption tests ride the
consumers' suites (`persist_test.zig`, `codex_test.zig`, `atlas_test.zig`).

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
    - description: "the tree binding is published, proved, and reportable from one place"
      file: pkg/kernels/irregex/src/corpus/index/frame/frame.zig
      contains:
        - "pub fn boundHere"
        - "pub fn bindingHolds"
        - "pub fn publishBinding"
        - "pub fn socketBindingPath"
    - description: "the freshness anchor declines unless the binding holds"
      file: pkg/kernels/irregex/src/corpus/index/trigrams/fresh.zig
      contains: ["if (!frame.boundHere()) return null"]
    - description: "the phantom snapshot declines unless the binding holds"
      file: pkg/kernels/irregex/src/corpus/index/phantom/treemap.zig
      contains: ["if (!frame.boundHere()) return null"]
    - description: "the content shard declines unless the binding holds"
      file: pkg/kernels/irregex/src/corpus/index/content/shard.zig
      contains: ["if (!frame.boundHere()) return null"]
---

# `src/corpus/index/frame/` — the wire discipline every persisted artifact shares

One home for the framing primitives the index blobs are built from, so the
formats can't drift on conventions:

- **`putInt` / `Cursor`** — little-endian fixed-width ints, read back through
  a fail-closed byte cursor (`error.Corrupt` instead of reading past the end).
- **`putWords` / `Cursor.words`** — length-prefixed u64-slice payloads.
- **`nulLen` / `joinNul` / `splitNulExact` / `parsePathTable`** — the
  NUL-joined string tables every artifact uses for its path/roots catalogs.

Consumers: the codex + shelf blobs (`../codex/`), the kinship atlas
(`../atlas/`), and the trigram pair loader (`../trigrams/persist.zig`).

## The tree binding — which tree does this directory describe?

Every persisted accelerator names files by a path **relative to its build
directory** and proves a name still current by dating that file against a build
anchor. Both halves lie in *silence* when the artifacts belong to another tree:
the relative paths land on unrelated files here, and the foreign anchor — minted
after this tree's files were last touched — "proves" every one of them
unchanged. A `$GIST_DIR` left pointing at a second checkout was enough to serve
that tree's `README.md` bytes as this one's, hide a real hit behind a bogus
freshness proof, and hand the walk a directory that doesn't exist.

So the directory says whose it is. `gist index` publishes `tree.root` (the
absolute, symlink-resolved build directory) **last**, after every other
artifact; `boundHere` re-proves it before the anchor
(`../trigrams/fresh.zig`), the phantom snapshot (`../phantom/treemap.zig`), and
the content shard (`../content/shard.zig`) will load at all. An absent binding
reads as unbound, not as consent. Declining costs acceleration and never
correctness — the live walk never needed any of it — and the next `gist index`
re-binds (an amend that can't prove the directory is ours falls back to a full
build). `gist status` reports the state rather than leaving a caller to wonder
why nothing is ever warm.

`publishBinding`/`bindingHolds` are generic over the binding file, because the
resident daemon has the same question about its socket: `socketBindingPath`
names the hidden `.<socket>.tree` a daemon writes at bind time so a client can
refuse a rendezvous that belongs to another tree (`../../../surface/face/gist/daemon/`).

Framing only — magic bytes, versions, and checksums stay with each format,
where the corruption story lives. Round-trip and corruption tests ride the
consumers' suites (`persist_test.zig`, `codex_test.zig`, `atlas_test.zig`).

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
    - description: "frame owns the file primitives every artifact maps and publishes through"
      file: pkg/kernels/irregex/src/corpus/index/frame/frame.zig
      contains:
        - "pub const Mapping"
        - "pub fn mmapFile"
        - "pub fn writeAtomic"
    - description: "the tree binding is published, proved, and reportable from one place"
      file: pkg/kernels/irregex/src/corpus/index/frame/frame.zig
      contains:
        - "pub fn boundHere"
        - "pub fn bindingHolds"
        - "pub fn publishBinding"
        - "pub fn socketBindingPath"
    - description: "the load protocol runs both gates itself, so no artifact can half-run it"
      file: pkg/kernels/irregex/src/corpus/index/frame/frame.zig
      contains:
        - "pub fn mapArtifact"
        - "if (!boundHere()) return null;"
        - "if (v.anchor_ns > std.Io.Clock.now(.real, io).nanoseconds)"
    - description: "the freshness anchor declines unless the binding holds"
      file: pkg/kernels/irregex/src/corpus/index/trigrams/fresh.zig
      contains: ["if (!frame.boundHere()) return null"]
    - description: "the phantom snapshot loads only through the shared protocol"
      file: pkg/kernels/irregex/src/corpus/index/phantom/treemap.zig
      contains: ["return frame.mapArtifact(View, file_alias, io, {}, decode);"]
      absent: ["mmapFile"]
    - description: "the content shard loads only through the shared protocol"
      file: pkg/kernels/irregex/src/corpus/index/content/shard.zig
      contains: ["return frame.mapArtifact(View, file_alias, io, gpa, decode);"]
      absent: ["mmapFile"]
---

# `src/corpus/index/frame/` — the wire discipline every persisted artifact shares

Not an index. This is the substrate the seven indexes are built on: one home for
the conventions their blobs share, so the formats can't drift on them.

- **`putInt` / `Cursor`** — little-endian fixed-width ints, read back through
  a fail-closed byte cursor (`error.Corrupt` instead of reading past the end).
- **`putWords` / `Cursor.words`** — length-prefixed u64-slice payloads.
- **`nulLen` / `joinNul` / `splitNulExact` / `parsePathTable`** — the
  NUL-joined string tables every artifact uses for its path/roots catalogs.
- **`Mapping` / `mmapFile` / `writeAtomic`** — how an artifact reaches the
  disk. Reads are zero-copy mappings that fault in only the pages a query
  touches; writes are temp-then-rename, because ~10 agents cowork this repo and
  a plain overwrite lets a concurrent reader map a half-written blob.

Consumers: the codex + shelf blobs (`../codex/`), the kinship atlas
(`../atlas/`), the fragment atlas (`../frag/`), the phantom snapshot
(`../phantom/`), the content shard (`../content/`), and the trigram pair loader
(`../trigrams/persist.zig`).

## The tree binding — which tree does this directory describe?

Every persisted accelerator names files by a path **relative to its build
directory** and proves a name still current by dating that file against a build
anchor. Both halves lie in _silence_ when the artifacts belong to another tree:
the relative paths land on unrelated files here, and the foreign anchor — minted
after this tree's files were last touched — "proves" every one of them
unchanged. A `$GIST_DIR` left pointing at a second checkout was enough to serve
that tree's `README.md` bytes as this one's, hide a real hit behind a bogus
freshness proof, and hand the walk a directory that doesn't exist.

So the directory says whose it is. `gist index` publishes `tree.root` (the
absolute, symlink-resolved build directory) **last**, after every other
artifact, and every reader re-proves it before trusting a byte. An absent
binding reads as unbound, not as consent. Declining costs acceleration and never
correctness — the live walk never needed any of it — and the next `gist index`
re-binds (an amend that can't prove the directory is ours falls back to a full
build). `gist status` reports the state rather than leaving a caller to wonder
why nothing is ever warm.

`publishBinding`/`bindingHolds` are generic over the binding file, because the
resident daemon has the same question about its socket: `socketBindingPath`
names the hidden `.<socket>.tree` a daemon writes at bind time so a client can
refuse a rendezvous that belongs to another tree (`../../../surface/face/gist/daemon/`).

## `mapArtifact` — the load protocol, in one place that cannot be half-run

The binding is only half the proof, and for a while both halves were prose. Each
mapped artifact hand-copied the same four steps, and two of them are the kind
that fail _quietly_: prove the binding, map, decode, and refuse a **future-dated
anchor** (an anchor newer than now dates every file in the tree as unchanged, so
one bad clock trusts the whole corpus at once). Omitting either gate does not
lose an optimization — it fabricates output, at real paths, that no live walk
would ever produce. That is a poor thing to leave to a reviewer noticing a
missing line.

`mapArtifact` runs all four itself, so a new artifact inherits the discipline by
naming its decoder. It reads two things back off the view — an `anchor_ns` field
and a `deinit` that releases the mapping — and it takes a
`corpus.ArtifactPath` **type** rather than a path string, so the form that
proves the binding is the form that cannot be aimed anywhere else. The phantom
snapshot (`../phantom/`) and the content shard (`../content/`) are its callers;
each is now a decoder plus one line.

`mapAt` is the same protocol minus the binding, for a caller naming its own path
(a test minting a fixture, a bench harness on a scratch build). The binding is
absent there rather than bypassed: it is a property of the shared artifact
directory, which `mapAt` has no way to name.

The freshness anchor (`../trigrams/fresh.zig`) is not a mapped artifact — it is
eight bytes read directly — so it proves the binding itself and appears in these
assertions separately.

Framing only — magic bytes and versions stay with each format, where its own
shape is described. Integrity does not: every artifact seals with the one digest
in [`../../../kernel/primitives/signet.zig`](../../../kernel/primitives/signet.zig),
so "are these the bytes we wrote" has a single answer instead of a per-format
checksum each loader had to remember to re-check (and three of them, including
the two biggest blobs, never did). `frame_test.zig` covers the protocol's own refusals
(foreign binding, future anchor, torn blob, and no leak when a decode is thrown
away); per-format round-trip and corruption tests ride the consumers' suites
(`persist_test.zig`, `codex_test.zig`, `atlas_test.zig`).

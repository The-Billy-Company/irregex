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
    - description: "home resolves the artifact directory every blob shares"
      file: pkg/kernels/irregex/src/corpus/index/frame/home.zig
      contains: ["pub fn outDir", "pub fn ArtifactPath", "default_out_dir"]
    - description: "signet is the one artifact digest on the wire floor"
      file: pkg/kernels/irregex/src/corpus/index/frame/signet.zig
      contains: ["pub fn of", "pub fn sealInto", "pub fn unseal"]
    - description: "the freshness anchor declines unless the binding holds"
      file: pkg/kernels/irregex/src/corpus/fresh/fresh.zig
      contains: ["if (!frame.boundHere()) return null"]
---

# `src/corpus/index/frame/` — the wire floor

Not an index. Architecturally this sits **just above `fault`**, below every
kernel tier: framing primitives, the one artifact digest, and the artifact
directory. It lives under `corpus/index/` on disk because that is what it
frames, but the ward places it on the floor page so the codex kernel and the
crest sieve can stamp schema with the same signet without importing corpus
knowledge. Deliberately **not sealed** — three peer entry points, not one deep
module.

| File | Job |
| ---- | --- |
| `frame.zig` | Little-endian ints, fail-closed `Cursor`, NUL catalogs, `mmapFile` / `writeAtomic`, tree binding, `mapArtifact` load protocol |
| `signet.zig` | Domain-separated BLAKE3 digest + seal protocol every persisted blob shares |
| `home.zig` | `outDir()` / `ArtifactPath` — where the trigram index, atlas, shelf, freshness anchor, and daemon socket live |

## Framing (`frame.zig`)

- **`putInt` / `Cursor`** — little-endian fixed-width ints, fail-closed reads.
- **`putWords` / `Cursor.words`** — length-prefixed u64-slice payloads.
- **NUL tables** — path/roots catalogs every artifact uses.
- **`Mapping` / `mmapFile` / `writeAtomic`** — zero-copy maps; temp-then-rename
  writes (coworking tree).

Consumers: shelf (`../shelf/`), atlas, frag, phantom, content, trigram pair
loader. Magic/versions stay per-format; integrity does not — every artifact
seals with sibling `signet.zig`.

## Tree binding

`gist index` publishes `tree.root` last; every reader re-proves it before
trusting a byte. An absent binding reads as unbound. `socketBindingPath` names
the hidden `.<socket>.tree` a daemon writes so a client can refuse a foreign
rendezvous (`exec/session/daemon/`).

## `mapArtifact`

Prove binding → map → decode → refuse a future-dated anchor. New artifacts
inherit the discipline by naming a decoder. The freshness anchor
(`../../fresh/fresh.zig`) is eight bytes read directly, so it proves the
binding itself.

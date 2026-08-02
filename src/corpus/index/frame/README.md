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
| `quill.zig` | `writeAtomic`'s streaming twin — a sealed artifact emitted region by region, so a corpus-sized blob is never resident |
| `home.zig` | `outDir()` / `ArtifactPath` — where the trigram index, atlas, shelf, freshness anchor, and daemon socket live |

## Framing (`frame.zig`)

- **`putInt` / `Cursor`** — little-endian fixed-width ints, fail-closed reads.
- **`putWords` / `Cursor.words`** — length-prefixed u64-slice payloads.
- **NUL tables** — path/roots catalogs every artifact uses.
- **`Mapping` / `mmapFile` / `writeAtomic`** — zero-copy maps; temp-then-rename
  writes (coworking tree).
- **`Quill`** (sibling `quill.zig`, re-exported here) — the same atomicity and
  the same seal for an artifact written in pieces. Reach for it whenever the
  finished blob would be large: the content shard is a concatenation of the whole
  corpus, and assembling it to seal it cost the build a second copy of every file
  it had just read.

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

# `src/corpus/index/frame/` — The Wire Floor

Not an index. Architecturally this sits **just above `fault`**, below every
kernel tier: framing primitives, the one artifact digest, and the artifact
directory.

It lives under `corpus/index/` on disk because that is what it frames, but
the ward places it on the floor page so the codex kernel and the crest sieve
can stamp schema with the same signet without importing corpus knowledge.
Deliberately **not sealed** — three peer entry points, not one deep module.

## Files

- **`frame.zig`** carries little-endian ints, a fail-closed `Cursor`, NUL
  catalogs, `mmapFile` / `writeAtomic`, tree binding, and the `mapArtifact`
  load protocol.
- **`signet.zig`** is the domain-separated BLAKE3 digest and seal protocol
  every persisted blob shares.
- **`quill.zig`** is `writeAtomic`'s streaming twin — a sealed artifact
  emitted region by region, so a corpus-sized blob is never resident.
- **`home.zig`** owns `outDir()` and `ArtifactPath` — where the trigram
  index, atlas, shelf, freshness anchor, and daemon socket live.

## Framing (`frame.zig`)

- **`putInt` / `Cursor`** are little-endian fixed-width ints, fail-closed on
  read.
- **`putWords` / `Cursor.words`** carry length-prefixed u64-slice payloads.
- **NUL tables** are the path/roots catalogs every artifact uses.
- **`Mapping` / `mmapFile` / `writeAtomic`** give zero-copy maps and
  temp-then-rename writes, safe on a coworking tree.
- **`Quill`** (sibling `quill.zig`, re-exported here) applies the same
  atomicity and the same seal to an artifact written in pieces. Reach for it
  whenever the finished blob would be large: the content shard is a
  concatenation of the whole corpus, and assembling it in memory just to seal
  it would have cost the build a second copy of every file it had just read.

Consumers are the shelf (`../shelf/`), relate's atlas and frag, phantom, content,
and the trigram pair loader. Magic bytes and versions stay per-format;
integrity does not — every artifact seals with sibling `signet.zig`.

## Tree Binding

`gist index` publishes `tree.root` last; every reader re-proves it before
trusting a byte. An absent binding reads as unbound. `socketBindingPath`
names the hidden `.<socket>.tree` a daemon writes so a client can refuse a
foreign rendezvous (`exec/session/daemon/`).

## `mapArtifact`

The load protocol proves binding, then maps, then decodes, then refuses a
future-dated anchor. New artifacts inherit the discipline by naming a
decoder.

The freshness anchor (`../../fresh/fresh.zig`) is eight bytes read directly,
so it proves the binding itself.

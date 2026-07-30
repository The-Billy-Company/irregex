---
doc_radar:
  sentinels:
    - description: "resident binds facet engines as real methods on the session state"
      file: pkg/kernels/irregex/src/exec/session/warm/resident.zig
      contains:
        - "pub const query = fold.query"
        - "pub const queryLines = present.queryLines"
        - "pub const queryExists = stream.queryExists"
        - "pub const search = stream.search"
        - "pub fn beginRead"
    - description: "mirror is the in-RAM corpus; retrieval is the warm side of exec/retrieval"
      file: pkg/kernels/irregex/src/exec/session/warm/mirror.zig
      contains: ["pub inline fn gatedBody"]
    - description: "the mirror carries ρ(d) for the crest sieve, built by the persisted sidecar's own builder rather than a second loop"
      file: pkg/kernels/irregex/src/exec/session/warm/mirror.zig
      contains: ["crests: []const crest.Vector", "crest_table.build"]
---

# `warm/` — what is held across queries

Two sibling warm engines plus the byte stores they answer from. Nothing here
decides what an answer looks like — that is [`../facet/`](../facet/) — and
nothing here proves the held state still matches disk — that is
[`../reconcile/`](../reconcile/).

| Module          | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `resident.zig`  | `ResidentSession` — gist’s warm state: mirror + trigram index, mutation overlay, freshness seqlock + dirty log, and `beginRead` (the read lease every answer passes through)                                                                                                                                                                                                                                                                                                                                |
| `retrieval.zig` | `RetrievalSession` — relate’s warm sibling for `similar` / `pack`. Holds one repo’s mmap’d trigram index + doc→path table and answers through the shared [`exec/retrieval/`](../../retrieval/) kernel, so warm ≡ cold. Freshness is the persisted index’s build anchor                                                                                                                                                                                                                                      |
| `mirror.zig`    | The in-RAM corpus mirror: unchanged members bind to the persisted `content.shard` mmap; changed/new/binary/oversize docs heap-read with cold’s own per-file treatment. Also holds ρ(d) per doc — the crest vectors the sieve prunes a candidate by with k integer compares and no byte scan — built by the persisted `crest.bin` sidecar’s **own** builder over the mirror’s own bytes, so a resident vector and the on-disk one for the same bytes cannot disagree, and the vectors need no freshness gate |
| `overlay.zig`   | Mutation store — live edits become answerable substitutions without rebuilding the base mirror                                                                                                                                                                                                                                                                                                                                                                                                              |
| `truth.zig`     | Independent filesystem oracle for adversarial tests — never runs the engine                                                                                                                                                                                                                                                                                                                                                                                                                                 |

## Why two engines don’t share a base type

`resident` mirrors corpus **bytes** and reconciles a moving cursor over them;
`retrieval` never holds file contents and reasons about a persisted index’s
build anchor. They share only the reconcile barrier and the watcher.

## Naming

Was `warm/corpus.zig` / `warm/recall.zig`. Renamed so the file says what it
is (`mirror`) and so “recall” stays free for `kernel/kinship/recall/` — the
warm side of the shared retrieval engine is `retrieval.zig`, same-name-
same-concept with [`exec/retrieval/`](../../retrieval/).

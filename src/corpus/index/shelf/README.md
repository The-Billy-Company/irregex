---
doc_radar:
  sentinels:
    - description: "the shelf artifact's whole lifecycle lives in one writer below every face"
      file: src/corpus/index/shelf/shelf.zig
      contains:
        - "pub fn shelfFile"
        - "pub fn persist"
        - "pub fn open"
        - "pub fn staleCount"
---

# `src/corpus/index/shelf/` — the persisted codex shelf

The on-disk SHLF artifact three faces read: `gist codex`, `relate quote` /
`relate index --shelf`, and `irregex provenance`. Split from the FM-index
_math_ in [`../../../kernel/codex/`](../../../kernel/codex/README.md) so the
codebook kernel never grows a persistence opinion, and so no face becomes the
module the other two import.

`shelf.zig` owns path, atomic write, fail-closed read, and the staleness walk
(`staleCount`). Faces call `persist` / `open`; they do not invent a second
format.

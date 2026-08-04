# `src/corpus/index/shelf/` — The Persisted Codex Shelf

`codex.shelf` is the on-disk SHLF artifact three faces read: `gist codex`,
`relate quote` / `relate index --shelf`, and `irregex provenance`.

The FM-index _math_ stays in
[`../../../kernel/codex/`](../../../kernel/codex/README.md), split from
persistence so the codebook kernel never grows a persistence opinion, and so
no face becomes the module the other two import.

## What It Eliminates

A shelf concatenates a corpus (one `\n` sentinel between documents), builds
the codex over the whole, and keeps a catalog mapping each document's path
and starting offset. Once persisted, a later process answers exists / count
/ tally with **zero corpus I/O** — the index alone.

The `\n` separator means a pattern containing no newline can never match
across a document boundary, so a corpus-wide count equals the sum of
per-file counts for every line-shaped query — the only shape the faces
admit.

## Contract With Neighbors

`shelf.zig` owns the path, the atomic write, the fail-closed read, and the
staleness walk (`staleCount`, folded through the family's freshness law in
[`../../fresh/`](../../fresh/README.md)). Faces call `persist` / `open`;
they do not invent a second format.

Unlike the trigram index and content shard, a shelf answer has nothing to
degrade to when it is missing or corrupt — it is exact or it is absent, so
`open` fails closed (`FileNotFound` / `Corrupt`) rather than silently
returning a live-scan substitute. `built_ns` is the wall-clock anchor
captured before the corpus read — the same convention as the trigram
index's T3 anchor — so a caller can state exactly which snapshot an answer
is true of.

# `src/exec/session/` — the resident search session

The warm, in-memory engine behind `gist serve`. Productizes the in-memory bench
path as a real per-repository service: corpus bytes + trigram index held
resident so an eligible request skips the cold subprocess’s startup. Selects
its corpus with cold’s own certified walk
(`exec/cold/engine/serial.zig::defaultFileSet`), ingests each file exactly as
a cold read would, and lowers each query through the shared search core — but
every entry point **returns errors** instead of calling `die()`.

The daemon transport (`daemon/{client,serve}`) lives here too — moved out of
`surface/face/gist/daemon/` because relate and irregex answer-keeps ride the
same socket; it was never gist’s product surface.

## The seven planes

| Folder                    | The question it answers                                                         |
| ------------------------- | ------------------------------------------------------------------------------- |
| [`answer/`](answer)       | What may be asked warm, what comes back                                         |
| [`warm/`](warm)           | What is held **across** queries — resident + retrieval engines, mirror, overlay |
| [`facet/`](facet)         | The four faces one answer can wear (set / count / bytes / stream)               |
| [`reconcile/`](reconcile) | May the session serve the bytes it already holds?                               |
| [`watch/`](watch)         | Can that barrier skip the walk — and how narrowly?                              |
| [`conduit/`](conduit)     | How a request reaches the daemon and an answer gets back                        |
| `gist/src/exec/session/daemon/`       | Dial + serve loop — the transport both faces share                              |
| `gist/src/exec/session/warden/`       | How much memory a resident session may hold, enforced where it allocates        |

## The invariant

`resident matches == gist --no-index matches == rg matches`. It holds because
both the base corpus and every reconcile re-derive their file set from cold’s
own certified walk, and because per-file ingest is cold’s own
(`warm/mirror.zig`). A query is answered from resident bytes only in a
watcher-proven-clean window; otherwise the session reconciles first — **scoped**
via `reconcile/delta.zig` when it can prove the dirty set covers every
divergence, else **full**. Any doubt declines with `freshness_unprovable` and
the client uses the certified cold path.

`rg` appears in that invariant as the **output** oracle, and it is the right one
for what matches come back. It is the wrong one for why this package exists:
ripgrep holds nothing between runs, so it has no residency to get wrong. The
architectural comparator is **zoekt**, the one rival that is also a warm
resident server holding corpus content in memory-mapped shards — and holding
content resident is precisely why zoekt can answer from bytes the tree no
longer has. Measured on a corpus mutated after indexing, it returns a match that
was deleted while missing two that were added (`corpus/fresh/README.md` § What
this package buys). That is the whole reason `reconcile/` and `watch/` are planes
here rather than an optimization: this session is meant to be zoekt's residency
without zoekt's staleness, which costs a proof-of-clean barrier in front of every
warm answer and a decline whenever the proof won't close. csearch is not a
comparator at all on this axis; it is one-shot and holds nothing across queries.

Deep dives live in each plane’s own README.

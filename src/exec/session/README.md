---
doc_radar:
  counts:
    - description: "session planes: answer · warm · facet · reconcile · watch · conduit · daemon"
      glob: pkg/kernels/irregex/src/exec/session/*/
      unit: dirs
      equals: 7
  sentinels:
    - file: pkg/kernels/irregex/contract/search_api.toml
      contains: ["[session]", "eligible_modes", "fail-closed-reconcile", '"lines"']
---

# `src/exec/session/` — the resident search session (ADR-352 rung 2.5)

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

| Folder | The question it answers |
| ------ | ----------------------- |
| [`answer/`](answer) | What may be asked warm, what comes back |
| [`warm/`](warm) | What is held **across** queries — resident + retrieval engines, mirror, overlay |
| [`facet/`](facet) | The four faces one answer can wear (set / count / bytes / stream) |
| [`reconcile/`](reconcile) | May the session serve the bytes it already holds? |
| [`watch/`](watch) | Can that barrier skip the walk — and how narrowly? |
| [`conduit/`](conduit) | How a request reaches the daemon and an answer gets back |
| [`daemon/`](daemon) | Dial + serve loop — the transport both faces share |

## The invariant

`resident matches == gist --no-index matches == rg matches`. It holds because
both the base corpus and every reconcile re-derive their file set from cold’s
own certified walk, and because per-file ingest is cold’s own
(`warm/mirror.zig`). A query is answered from resident bytes only in a
watcher-proven-clean window; otherwise the session reconciles first — **scoped**
via `reconcile/delta.zig` when it can prove the dirty set covers every
divergence, else **full**. Any doubt declines with `freshness_unprovable` and
the client uses the certified cold path.

Deep dives live in each plane’s own README.

<!--
doc_radar:
  paths_exist:
    - pkg/kernels/gist/src/session/resident.zig
    - pkg/kernels/gist/src/session/request.zig
    - pkg/kernels/gist/src/session/protocol.zig
    - pkg/kernels/gist/src/session/watch.zig
  sentinels:
    - file: pkg/kernels/gist/contract/search_api.toml
      contains: ["[session]", "eligible_modes", "fail-closed-reconcile"]
-->

# `src/session/` — the resident search session (ADR-352 rung 2.5)

The warm, in-memory engine behind the `gist serve` daemon. It productizes the
in-memory bench path (`bench/harness/bench.zig::gistMatches`) as a real
per-repository service: the corpus bytes + trigram index are held resident, so
an eligible request answers without re-paying the cold subprocess's process +
index-mmap + candidate-read startup. It reuses the *lower* kernels the CLI is
built on (`index/trigram`, `scan/verify`, `scan/simd`, `regex/core`,
`corpus/fresh`) — but every entry point **returns errors** instead of calling
`die()`, which is exactly why the resident path sidesteps the exit hazard
ADR-352 defers the in-process C FFI on.

| File | Role |
|---|---|
| [`resident.zig`](resident.zig) | `ResidentSession`: in-memory corpus/index, mutation overlay, generation reload, the fail-closed reconcile barrier, and the safe `-l`/`-c` query kernels. |
| [`request.zig`](request.zig) | The eligibility classifier — accepts only the supported argv surface (`-l`/`-c`, `-F`, `-i`, `-e`/`--regexp`, default roots), everything else → `error.Unsupported` (cold fallback). |
| [`protocol.zig`](protocol.zig) | The length-prefixed UDS frame codec (`[u32 len][u8 opcode][payload]`) + fd send/recv, fail-closed on oversized/truncated/unknown frames. |
| [`watch.zig`](watch.zig) | The freshness watcher — a pure accelerator (Linux inotify; reconcile-always baseline elsewhere) that only ever decides *whether the reconcile walk may be skipped*, never correctness. |

## The invariant

`resident matches == gist --no-index matches == rg matches`. It holds by
construction because freshness reuses the cold path's own metadata walk
(`corpus/fresh.zig::changedSince`): a query is answered from resident bytes
directly only in a watcher-proven-clean window; otherwise the session reconciles
the exact changed/new/deleted set against the live filesystem before answering.
A deleted base file (invisible to the change walk) is caught by a per-match
existence check whenever the session is not watcher-clean. Missing/again-future
anchor or a rebuilt index (`pair.gen` drift) surfaces as `error.Stale`, and the
daemon declines so the client uses the certified cold path.

The daemon lifecycle, CLI routing, and clients live in
[`../commands/serve`](../commands/serve) and [`../commands/client`](../commands/client);
the persistent client→daemon performance certificate lives in
[`../../bench/session`](../../bench/session).

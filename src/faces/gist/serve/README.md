<!--
doc_radar:
  paths_exist:
    - pkg/kernels/gist/src/commands/serve/serve.zig
    - pkg/kernels/gist/src/session/resident.zig
  sentinels:
    - file: pkg/kernels/gist/contract/search_api.toml
      contains: ["GIST_SESSION_SOCK", "gistd.sock"]
-->

# `commands/serve/` — the resident daemon (`gist serve`)

Keeps one [`ResidentSession`](../../session/resident.zig) warm behind a
Unix-domain socket so a persistent client answers an eligible query without
re-paying the cold subprocess's process + index-mmap + candidate-read startup —
the mechanism behind the warm session certificate.

- `run(gpa, io, roots, socket_path)` — build the session, arm the freshness
  watcher, bind the socket (unlinking a stale one), then a **serial** accept loop.
  One client's frame loop runs to completion before the next connection; only an
  explicit `shutdown` frame stops the loop. Every unservable request is answered
  `decline`, so a client only ever loses a warm acceleration, never correctness.
- `socketPath(gpa)` — `$GIST_SESSION_SOCK`, else `.local/gist-verify/gistd.sock`.

The wire grammar it speaks is [`session/protocol.zig`](../../session/protocol.zig);
the client that dials it is [`../client`](../client). End-to-end lifecycle is
pinned in [`serve_test.zig`](serve_test.zig).

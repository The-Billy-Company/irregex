<!--
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/gist/faces/serve/serve.zig
    - pkg/kernels/irregex/src/gist/session/resident.zig
  sentinels:
    - file: pkg/kernels/irregex/contract/search_api.toml
      contains: ["GIST_SESSION_SOCK", "gistd.sock"]
-->

# `faces/serve/` — the resident daemon (`gist serve`)

Keeps one [`ResidentSession`](../../session/resident.zig) warm behind a
Unix-domain socket so a persistent client answers an eligible query without
re-paying the cold subprocess's process + index-mmap + candidate-read startup —
the mechanism behind the warm session certificate.

- `run(gpa, io, roots, socket_path)` — build the session, arm the freshness
  watcher, bind the socket (unlinking a stale one), then a **poll-multiplexed**
  accept loop: one `poll` set over the listener plus every connected client, one
  frame served per readable client per wakeup. Queries still execute one at a
  time on the single daemon thread, but an idle persistent client never starves
  a new connection (the old serial loop parked every other agent behind one
  long-lived `Session`); only an explicit `shutdown` frame stops the loop. Every
  unservable request is answered `decline`, so a client only ever loses a warm
  acceleration, never correctness.
- `socketPath(gpa)` — `$GIST_SESSION_SOCK`, else `.local/gist-verify/gistd.sock`.

The wire grammar it speaks is [`session/protocol.zig`](../../session/protocol.zig);
the client that dials it is [`../client`](../client). End-to-end lifecycle is
pinned in [`serve_test.zig`](serve_test.zig).

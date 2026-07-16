<!--
doc_radar:
  paths_exist:
    - pkg/kernels/gist/src/commands/client/client.zig
    - pkg/kernels/gist/src/commands/serve/serve.zig
-->

# `commands/client/` — the CLI's warm fast path

`attempt(gpa, io, argv, socket_path)` is the fail-open bridge from the bare
`gist <pattern>` front door to the resident daemon ([`../serve`](../serve)). It
classifies the argv ([`session/request.zig`](../../session/request.zig)) and only
when the request is one the warm path answers with the **same match set as
cold** — today, `-l`/`--files-with-matches` over the default roots — does it
dial the socket, run the query, and emit the matched paths (deterministically
sorted — a canonicalization of ripgrep's otherwise walk-order `-l` output).
Anything else (ineligible argv, no daemon, a `decline`, any wire hiccup) returns
`.cold` and the caller runs the certified cold path unchanged.

The daemon is a pure accelerator: it never becomes a new source of truth or a new
failure mode, and can always be skipped. `-c` and richer shapes stay cold (the
daemon speaks `count` on the wire as a corpus-wide total for embedders, but the
CLI never claims rg's per-file `-c` layout from it).

**Client I/O deadline.** After connect, every warm `recvFrame` is gated by
`poll(…, client_io_timeout_ms)` (2s). A peer that accepts but never speaks READY
cannot park the CLI — timeout falls through to `.cold`. See `client_test.zig`.

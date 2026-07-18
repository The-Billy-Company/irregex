<!--
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/gist/faces/client/client.zig
    - pkg/kernels/irregex/src/gist/faces/serve/serve.zig
-->

# `faces/client/` — the CLI’s warm fast path

`attempt(gpa, io, argv, socket_path)` is the fail-open bridge from the bare
`gist <pattern>` front door to the resident daemon ([`../serve`](../serve)). It
classifies the argv ([`session/request.zig`](../../session/request.zig)) and only
when the request is one the warm path answers with **cold's own per-file bytes
and exit code** — `-l`/`--files-with-matches` (the sorted path list) and the
bare default line search (`gist <pattern> [-n]`, whose `path:[line:]text` bytes
the daemon pre-renders through the cold Emitter itself and chunk-streams) —
does it dial the socket, run the query, and emit the result. File emission
order is the deterministic `pathLess` canonicalization of cold's parallel
worker-discovery order (the same convention warm `-l` has always used; the
rgsuite oracle certifies the equivalence as `sort_lines(gist) ==
sort_lines(rg)`). Anything else (ineligible argv, no daemon, a `decline`, any
wire hiccup) returns `.cold` and the caller runs the certified cold path
unchanged.

Two environment guards keep the warm answer inside its parity envelope: a
**TTY stdout** declines to cold (interactive cold adds ANSI color + the 16 KiB
long-line cap; the daemon renders the piped frame only — agents and pipes, the
entire warm workload, are unaffected), and a **readable stdin** declines to cold
(a rootless query with data on stdin is a stream search, which the tree daemon
can never answer).

The daemon is a pure accelerator: it never becomes a new source of truth or a new
failure mode, and can always be skipped. `-c` and richer shapes stay cold (the
daemon speaks `count` on the wire as a corpus-wide total for embedders, but the
CLI never claims rg's per-file `-c` layout from it).

**Client I/O deadline.** After connect, every warm `recvFrame` is gated by
`poll(…, client_io_timeout_ms)` (2s). A peer that accepts but never speaks READY
cannot park the CLI — timeout falls through to `.cold`. See `client_test.zig`.

Added a zero-copy emit transport to the warm `gist serve` daemon: a large
`lines` answer now reaches the client as an anonymous shared-memory fd passed
over the UDS `SCM_RIGHTS` control channel instead of being copied through the
socket. After the parallel render, the emit was output-transfer-bound — the
rendered bytes were copied user→kernel→user twice as `chunk` frames — so the
daemon gathers the shards straight into one shm buffer (Linux `memfd_create` +
`F_SEAL_*` · macOS `shm_open`→`ftruncate`→`mmap`→immediate `shm_unlink`, mapping
bounded to the exact length) and hands its fd to the client in a single
`chunk_fd` frame carrying `{length, matched}`; the client mmaps it read-only and
writes it out in one shot, so the answer never traverses the socket.

The path is a negotiated SESSION capability, not a query flag (the flags byte is
full): the client appends a `cap_fd_transport` byte after the version in its
HELLO, and the daemon uses the fd path only when the client advertised it AND the
answer clears `fd_transport_floor` (1 MiB). Fail-open, never a new failure mode —
any shm/`sendmsg` error, a below-floor or unadvertised answer, an old peer (no
caps byte), or a non-shm target transparently falls to the byte-identical `chunk`
frames; a peer that never advertises keeps working unchanged (the Python and Rust
UDS clients answer files/count and simply don't advertise). `GIST_NO_FD_TRANSPORT`
opts the CLI client out for A/B.

Measured warm emit-heavy A/B on macOS (fd vs chunk, same daemon, `the --uncap`):
32 MiB answer (services corpus) 112 → not-copied ≈1.10× to `/dev/null`, and
1.6× (min-time 1.19×) when the output is actually consumed (`| wc -c`); 68 MiB
answer (repo-wide) 528 → 353 ms ≈1.50× piped. The win scales with the emit and
with a real downstream reader, which is the agent-capture workload. The committed
session gate is unregressed (armed geomean 474× vs the 5× floor).

Byte-identity is the whole ballgame and is proven two ways. Within one render the
fd bytes are byte-for-byte identical to that render's `chunk` framing — asserted
deterministically over a single-doc corpus in `serve_test` (plus an explicit
forced-fallback test: an injected shm-create failure drops the fd-eligible answer
onto `chunk` frames and the bytes match). Across the live tree the CLI answers
agree on content: warm(fd) == warm(chunk) == cold(`--no-index`) == `rg`
(sort-normalized, since the parallel render's doc order is unstable across
separate invocations independent of transport; the only gist↔rg gap is gist's
pre-existing dotfile skip). New: `shm.zig` portable buffer, `wire.zig`
`sendWithFd`/`recvFrameWithFd`, the `chunk_fd` opcode + capability negotiation,
`render.renderLinesShm`, and `resident.queryLinesShm`.

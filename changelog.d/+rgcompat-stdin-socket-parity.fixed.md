**`rg` drop-in matches ripgrep's stdin heuristic exactly — the socket fd type is
no longer a silent divergence** (`bench/rgcompat.zig`). ripgrep decides to search
stdin (vs. walking `./`) with `!is_terminal(fd0) && (is_file || is_fifo ||
is_socket)` (grep/cli `is_readable_stdin`). gist's `readableStdin` whitelisted
only regular files and FIFOs, so `sock_producer | gist rg pat` — and, more
commonly, any exec API that wires fd0 to a `socketpair` — fell through to a
directory walk while real `rg` searched the stream. Added `S.IFSOCK` to the
whitelist; the three-type set still excludes a tty and `/dev/null` (a char
device), so bare `rg pat` and `rg pat </dev/null` keep walking `./`.

**Proven byte-identical to `rg` across all four fd types** (socket, pipe,
regular-file, `/dev/null`) via a `socketpair`-backed differential probe: socket
and pipe search the stream (`match here`, rc 0), `/dev/null` and a bare tty walk
the CWD, a redirected regular file searches that one source. Supported-surface
parity over the 330 mined ripgrep tests stays **61/61 = 100%**.

Note: the "`rg foo` appears to hang" failure mode in exec-spawned shells (a
pipe/socket wired to fd0 that never sends data or EOF) is ripgrep's own
documented, unmitigable heuristic — its source calls it "a terrible failure
mode, but there really is no good way to mitigate it" (core/flags/hiargs.rs).
gist now reproduces it faithfully; non-interactive callers should redirect
`</dev/null` exactly as they would for `rg`.

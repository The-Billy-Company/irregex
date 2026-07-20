**`gist` could hang forever with no output.** `readableStdin()` mirrors
ripgrep's own `is_readable_stdin` check (regular file, FIFO, or socket on fd 0
⇒ search stdin instead of walking the tree) — correct against a real shell
pipe, but some sandboxed shell/tool-call harnesses wire fd 0 to a long-lived
socket that never writes a byte and never closes. A blocking `read(2)` against
that blocks indefinitely; an agent-facing tool can't afford that.

`readableStdin()` now classifies fd 0 by stream type (`stdinKind`) and guards
_only a socket_: a socket is admitted to the stdin path — and each chunk of its
read loop is gated — through a 200 ms `poll(2)` deadline, so the pathological
"open forever, silent" control channel times out and falls through to the
directory walk instead of hanging. A FIFO (pipe) or regular file is classified
readable immediately and block-read straight to true EOF with **no** poll guard:
`cmd | gist pattern` is the canonical stream, a slow or paused writer just makes
`read` wait, and the writer's close is the EOF — byte-for-byte ripgrep, with no
delayed-pipe truncation. (An earlier revision poll-guarded FIFOs too, which
dropped a producer whose first bytes arrived after the deadline to the walk — a
delayed-pipe false negative this split eliminates.)

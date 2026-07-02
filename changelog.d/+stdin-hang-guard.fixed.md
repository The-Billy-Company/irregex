**`gist` could hang forever with no output.** `readableStdin()` mirrors
ripgrep's own `is_readable_stdin` check (regular file, FIFO, or socket on fd 0
⇒ search stdin instead of walking the tree) — correct against a real shell
pipe, but some sandboxed shell/tool-call harnesses wire fd 0 to a long-lived
socket that never writes a byte and never closes. A blocking `read(2)` against
that blocks indefinitely; an agent-facing tool can't afford that.

`readableStdin()` now `poll(2)`s a FIFO/socket fd 0 for actual readiness (data
or HUP) with a 200 ms deadline before ever committing to the stdin path — a
real producer signals within milliseconds, so this is unobservable in normal
use; only the "open forever, silent" case now times out and falls through to
the ordinary directory walk instead of hanging. The same bounded poll guards
each iteration of the stdin read loop itself, so a producer that goes silent
*mid-stream* can't hang gist either — whatever arrived before the stall is
still searched. Piped stdin search (`cmd | gist pattern`) is unaffected.

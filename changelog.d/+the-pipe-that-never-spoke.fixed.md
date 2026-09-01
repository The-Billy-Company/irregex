- **A search no longer hangs forever because fd 0 is a pipe nobody is writing
  to.** This was the most common way the tool wedged in an agent shell, and the
  reason was a one-word gap in how stdin was classified.

  We asked what fd 0 *is* and inferred what it would *do*, which is ripgrep's
  rule: a FIFO is a pipe, a pipe has a writer, a writer eventually closes, so a
  blocking read to EOF always terminates. Every step of that holds for a
  pipeline someone typed. None of it holds for a pipe someone merely inherited -
  a harness, a `sleep 20 | …`, an `exec 9<>fifo` - where the write end is held
  open by a process that will never write and never exit. `read(2)` then blocks
  with nothing to wait for, and a query someone ran against a tree becomes a
  process someone has to go and kill. A socket was already guarded against
  exactly this; a FIFO, which is the shape an agent actually hands us, was not.

  The fix is neither a tighter type test nor a deadline on every read. The two
  cases differ in something exact: a real producer eventually delivers a first
  byte, and a dead stdin never delivers one. So the wait is bounded before the
  first byte (2s, `GIST_STDIN_WAIT_MS`) and unbounded after it. A producer that
  is merely late is admitted the instant it speaks; a stream that pauses for
  minutes mid-transfer is still drained to a true EOF, byte-for-byte rg; and a
  silent-forever fd 0 falls through to the directory walk, which is what a
  search with no PATH args meant anyway. It says so on stderr rather than
  quietly answering from the tree.

  Polling every chunk - the older shape, kept only for sockets - could do
  neither half of that. It dropped a producer whose first byte landed at 500ms,
  and it silently truncated one that stalled after speaking. Both are gone.

- **A large piped haystack costs what it is instead of three times what it is,
  and can no longer take the machine with it.** A regular file on stdin already
  told us its length, and we grew a buffer toward that number anyway: 381 MB of
  input cost 1245 MB of RSS, all of it the doubling's slack. Sizing the buffer
  once from the `stat` we were already performing is both the memory fix and the
  faster path.

  Length-unknown streams keep growing, but under a ceiling derived from the
  machine (a quarter of RAM, capped, `GIST_STDIN_MB`), because `cat 8GB | …` was
  an allocation the OOM killer resolved and it took the developer's session with
  it. Crossing the ceiling is a refusal that names itself, never a truncation - a
  haystack cut short answers the wrong question in the one direction nobody can
  see, which is the miss that should have been a hit.

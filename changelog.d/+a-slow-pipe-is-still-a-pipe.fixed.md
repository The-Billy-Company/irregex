- **A slow command on stdin is searched instead of quietly discarded.** The
  first-byte deadline that stopped `gist` hanging on an inherited pipe was set
  at 2 seconds, which is shorter than plenty of real producers take to say their
  first word - a cold `git log -p`, a `curl` over a bad link, a container pull.
  Past it, the pipe's bytes were dropped and the *directory* was searched in
  their place: exit 0, rows that look right, not one of them from what was piped
  in, and nothing on the screen to say the corpus had changed underneath you.

  That was the deadline sized against the caller's patience. It is now sized
  against the worst honest producer - a full minute - which is affordable
  because it bounds the wait for the FIRST byte and nothing after it, and
  because a producer that exits ends the wait early by itself (closing the pipe
  makes it readable, `read` returns 0, and an empty stdin search exits 1 on
  ripgrep's schedule). So the minute is only ever spent on a pipe with a live
  writer that is saying nothing, which is the wedge case and the only one.

  Two things keep that wedge from being a hang. After 2 seconds of silence the
  wait says on stderr that it is still waiting and names the knob that ends it
  (`GIST_STDIN_WAIT_MS`, in milliseconds, `0` meaning "search the tree now") -
  the case `zig build test` hits, since it hands its own test binaries a command
  pipe that is open forever and silent between commands. And the one pipe whose
  silence is *provably* permanent is no longer waited for at all: if this process
  holds the write end (`exec 9<>fifo`), no other writer's exit can ever produce
  the EOF a reader is waiting for, and `F_GETFL` says so outright instead of a
  clock guessing at it.

  A socket on fd 0 keeps its short window unchanged. It is what a sandboxed
  harness wires up as a control channel, it is never how a shell spells a
  pipeline, so nothing anyone typed is judged by it.

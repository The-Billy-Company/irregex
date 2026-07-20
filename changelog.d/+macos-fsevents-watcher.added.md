The resident session now arms a native macOS **FSEvents** watcher — one
recursive stream over the roots driven on a private CFRunLoop thread — so warm
queries take the microsecond clean path during quiescent windows instead of
always paying the corpus-wide freshness reconcile that macOS previously fell
back to (`src/runtime/session/watch.zig`; frameworks wired in `build.zig`). It mirrors
the Linux inotify backend's fail-closed contract: it only ever calls
`markDirty`/`armWatcher`, arms the session solely on a fully-started stream, and
degrades to the reconcile-always baseline if the stream can't start — so
read-your-writes and ripgrep parity are unchanged and soundness never rests on
the watcher.

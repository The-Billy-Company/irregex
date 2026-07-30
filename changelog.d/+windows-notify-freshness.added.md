Windows is now the third exact freshness backend. A resident daemon has to know
the tree moved before it serves an answer about it, and on Windows it knew
nothing: the watcher seam had a Linux arm and a macOS arm, so a Windows daemon
could only degrade to reconciling the whole strip. `notify.zig` subscribes
recursively per root through `NtNotifyChangeDirectoryFileEx` with `WatchTree`,
and drains onto one I/O completion port rather than APCs or per-root events —
completion is thread-agnostic, so `flushSync` can drain packets the background
loop never touched and the causal barrier holds without a thread rendezvous. The
filter is derived from what `reconcile.one` actually compares (name, attributes,
size, both write clocks, security, EA) rather than from the API's default set, so
no field the reconciler would notice arrives unannounced.

Two things it does that no POSIX arm can. A notify record carries the directory
entry's own spelling, so `exact` keys arm on a case-insensitive volume without
the refusal inotify needs there. And the extended record class carries the
changed file's timestamps in-band, so the annals ledger is stamped with that
file's `max(mtime, ctime)` instead of the drain clock's approximation of it —
falling back to the wall clock only for removals, where there is no surviving
file to ask. Buffer overflow marks doubt permanently rather than retrying, which
is the same posture `IN_Q_OVERFLOW` gets on Linux.

The contract cases moved out of `kqueue_test.zig` into a shared `rig.zig` on the
way, so both exact backends are now judged by the same barrier suite — in-place
edit, cross-directory move, case-only rename, deletion, root entry — instead of
each proving whatever its own file happened to test.

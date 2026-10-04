---
doc_radar:
  sentinels:
    - file: src/exec/session/watch/notify.zig
      contains: [ "extended: bool = true", "pending: bool = false", "root.pending = false", "haystack.underSkippedDir(rel, haystack.isPolicySkip)", "directory and haystack.isPolicySkip(std.fs.path.basename(rel))" ]
    - file: src/exec/session/watch/rig.zig
      contains: [ "if (comptime builtin.os.tag == .windows or builtin.os.tag == .linux)", "try std.testing.expect(session.seqlock.armed());", "try std.testing.expect(session.dirty_log.exact);" ]
    - file: src/corpus/fresh/fresh.zig
      contains: [ "haystack.underSkippedDir(path, haystack.isSkipDir)" ]
    - file: src/exec/session/watch/coverage.zig
      contains: [ "haystack.isPolicySkip(name)", "!ig.shouldSkip(key, true, name, false, false)" ]
    - file: src/exec/session/watch/watch_test.zig
      contains: [ "exact: an unignored baseline directory remains admitted and its edits retire held answers", "exact: a declared policy subtree stays excluded and admitted edits still reconcile" ]
    - file: src/exec/session/watch/notify_test.zig
      contains: [ "notify: a foreign request context retires trust without stealing the real request" ]
---

# `watch/` — The Freshness Watcher Backends

The freshness watcher is a pure accelerator for the reconcile barrier: it
keeps a resident session honest about when it may skip the reconcile walk,
and it is never a correctness dependency — a session that cannot arm simply
reconciles every query (fail-closed).

Correctness itself lives in [`../reconcile/`](../reconcile); this folder
only decides *whether, and how narrowly,* that barrier has to walk.

[`watch.zig`](watch.zig) is the facade: the public `Watcher(Session)` type,
the shared per-session state, the comptime backend selection, and the
cross-backend invariants. The rest of the folder holds the backend
implementations it dispatches to, each a set of free functions over that
generic `Watcher`.

## Modules

- **[`watch.zig`](watch.zig)** is the facade — the generic
  `Watcher(Session)`, the shared state, comptime backend selection, and the
  lifecycle, including `shed`, which hands every descriptor back and
  returns the session to the reconcile-always baseline so an idle daemon
  stops taxing the commons its siblings share.
- **[`inotify.zig`](inotify.zig)** is the Linux backend — recursive
  directory watches, the event loop, coverage extension into directories
  created after arming, queue-overflow doubt, and casefold detection (a
  `+F` root stays coarse).
- **[`kqueue.zig`](kqueue.zig)** is the macOS event engine — the kqueue
  descriptor itself and the arming (`startKqueue`), draining a batch under
  the shared consumption lock, per-directory rescan on a membership move,
  and retiring a descriptor whose vnode left. It owns the `EVFILT_VNODE`
  note vocabulary (`vnode_notes`) every watch requests.
- **[`coverage.zig`](coverage.zig)** is the macOS admission walk — it
  selects the macOS watch set from the walk's own `Ignore` policy so the
  descriptor cost stays proportional to the corpus, registers each admitted
  vnode (`EVFILT_VNODE` + `EV_CLEAR`, `vnode_notes`), owns the policy arena
  and the key-space arithmetic, classifies the hidden ignore sources that
  decide admission, and judges which `open(2)` failure may be skipped —
  only a path that vanished, never one the walk still searches (`vanished`).
- **[`budget.zig`](budget.zig)** is the macOS descriptor ceiling — how many
  vnode watches may be held, clamped against the three ceilings the kernel
  enforces (`kern.maxfilesperproc`, a bounded share of `kern.maxfiles`, and
  the raised `RLIMIT_NOFILE`), returning zero (unarmed) rather than a set it
  cannot register.
- **[`notify.zig`](notify.zig)** is the Windows backend — one recursive
  `ReadDirectoryChangesW` subscription per root
  (`NtNotifyChangeDirectoryFileEx` with `WatchTree`), draining onto a single
  I/O completion port. It owns the change filter, the record walk over both
  record classes, and the overflow posture.
- **[`stamp.zig`](stamp.zig)** is the POSIX clock — the wall instant a
  delivery is stamped with, read at delivery rather than at drain so the
  annals compare against instants minted from the same realtime clock. Both
  POSIX arms share it so they cannot drift on what "now" means; Windows
  reads the `FILETIME` its own records carry.
- **[`rig.zig`](rig.zig)** is the test harness — the tree fixture and
  session rig the barrier suite runs on, so all three exact backends are judged
  by the same cases instead of each proving whatever its own file happened
  to test.

Suites: `kqueue_test.zig`, `notify_test.zig`, and `watch_test.zig` sit
beside their subjects. Linux and Windows fixtures require exact subscriptions to arm
before a case proceeds; an unavailable native backend fails the runtime proof.

`kqueue.zig` and `coverage.zig` are two halves of one macOS backend, the
event engine and the admission walk, split so each reads as a single
concern; they reference each other directly (`coverage` announces and
unwinds each watch it registers via `kqueue.note` / `kqueue.retire`,
`kqueue` rescans via `coverage.coverTree`).

The three backends never intersect: every platform-specific function is
gated behind `if (comptime !is_<platform>) return …`, so the whole folder
compiles on every target and the unused backends lower to nothing.

## What Each Platform Can Witness

The three backends are not three spellings of one mechanism; they can
witness different things, and the facade's job is to know which.

Windows subscribes recursively per root. Linux adds a watch to each directory
and covers new subtrees before the next reconcile. macOS registers one
descriptor per admitted vnode, so its admission walk (`coverage.zig`) and
descriptor ceiling (`budget.zig`) keep that cost proportional to the corpus.

Windows is the one that can witness *more* than POSIX rather than less, in
two places worth naming because both remove a refusal rather than adding a
feature.

A notify record carries the changed entry's own spelling, so an `exact`
freshness key arms on a case-insensitive volume — where inotify has to go
coarse, because a `+F` casefold directory reports a name that may not be
the name on disk. And the extended record class carries the changed file's
timestamps in-band, so a delivery stamps the annals ledger with that file's
own `max(mtime, ctime)` instead of the drain clock's approximation of it;
the wall clock is used only for a removal, where there is no surviving file
to ask.

Losing coverage is where they agree exactly: an `IN_Q_OVERFLOW` on Linux,
an overflowed completion buffer on Windows, and a vnode that could not be
re-watched on macOS all mark doubt permanently rather than retrying,
because a watcher that has already missed an unknown set of events cannot
bound what it missed.

We keep each Windows request's identity and record class with its root. The
completion port returns that identity before we read or reuse the buffer; a
foreign packet retires trust without consuming the real request. A batch that
only touches declared policy subtrees leaves the session clean. We track a
birth, death or rename as a change to parent membership too; ordinary content
edits keep their file scope.

Stopping cancels every outstanding request and drains its completion without
re-posting. Only then do we free the buffers and status blocks. Joining the
watcher thread alone does not retire the kernel's writes. A driver that never
acknowledges cancellation can block `stop`; an unexpected cancellation or
port-dequeue failure terminates the process. Returning with a live request
would let the caller destroy its allocator while the kernel still owns it.

## Admission follows the session

We use the cold walk's declared skip policy for resident watches and the annals.
An unignored directory named `node_modules` is still searchable; an edit there
must dirty the session and retire held answers. Persisted index freshness keeps
its existing baseline exclusions. The caller supplies that distinction to the
shared ancestor predicate, which still admits an equally named plain file.

The macOS walk also uses the existing `Ignore` rules. Linux and Windows can
observe extra ignored paths and let reconcile discard them; extra work is safe,
missing an admitted change is not. The shared native rig checks real file edits,
new coverage, parent membership, policy churn and answer retirement. Platform
runtime results certify those promises; compilation alone does not.

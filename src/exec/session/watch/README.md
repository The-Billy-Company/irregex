<!--
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/exec/session/watch/watch.zig
    - pkg/kernels/irregex/src/exec/session/watch/inotify.zig
    - pkg/kernels/irregex/src/exec/session/watch/kqueue.zig
    - pkg/kernels/irregex/src/exec/session/watch/coverage.zig
    - pkg/kernels/irregex/src/exec/session/watch/budget.zig
  sentinels:
    - file: pkg/kernels/irregex/src/exec/session/watch/inotify.zig
      contains: ["pub fn startInotify", "pub fn drainInotifyLocked", "FS_CASEFOLD_FL"]
    - file: pkg/kernels/irregex/src/exec/session/watch/kqueue.zig
      contains: ["pub fn startKqueue", "EVFILT.VNODE", "vnode_notes"]
      absent: ["FSEventStreamCreate"]
    - file: pkg/kernels/irregex/src/exec/session/watch/coverage.zig
      contains: ["pub fn coverRoots", "isIgnoreSource", "EVTONLY", "fn vanished"]
    - file: pkg/kernels/irregex/src/exec/session/watch/budget.zig
      contains: ["pub fn watchBudget", "kern.maxfilesperproc", "kern.maxfiles"]
-->

# `watch/` — the freshness watcher backends

The freshness watcher is a pure **accelerator** for the reconcile barrier
(ADR-372, ADR-352 rung 2.5): it keeps a resident session honest about when it
may skip the reconcile walk, and never a correctness dependency — a session
that cannot arm simply reconciles every query (fail-closed). Correctness itself
lives in [`../reconcile/`](../freshness) — this folder only decides _whether, and
how narrowly,_ that barrier has to walk.

[`watch.zig`](watch.zig) is the facade: the public `Watcher(Session)` type, the
shared per-session state, the comptime backend selection, and the cross-backend
invariants. The rest of the folder holds the backend implementations it
dispatches to, each a set of free functions over that generic `Watcher`.

| Module                         | Plane           | Owns                                                                                                                                                                                                                                                                          |
| ------------------------------ | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`watch.zig`](watch.zig)       | facade          | The generic `Watcher(Session)`, the shared state, comptime backend selection, and the lifecycle — including `shed`, which hands every descriptor back and returns the session to the reconcile-always baseline so an idle daemon stops taxing the commons its siblings share. |
| [`inotify.zig`](inotify.zig)   | Linux           | Recursive directory watches, the event loop, coverage extension into directories created after arming, queue-overflow doubt, and casefold detection (a `+F` root stays coarse).                                                                                               |
| [`kqueue.zig`](kqueue.zig)     | macOS events    | `EVFILT_VNODE` registration, draining a batch under the shared consumption lock, per-directory rescan on a membership move, and retiring a descriptor whose vnode left. Owns the `EVFILT_VNODE` note vocabulary (`vnode_notes`).                                              |
| [`coverage.zig`](coverage.zig) | macOS admission | Selects the macOS watch set from the walk's own `Ignore` policy so the descriptor cost stays proportional to the corpus, owns the policy arena and the key-space arithmetic, classifies the hidden ignore SOURCES that decide admission, and judges which `open(2)` failure may be skipped — only a path that vanished, never one the walk still searches (`vanished`). |
| [`budget.zig`](budget.zig)     | macOS ceiling   | How many vnode watches may be held — clamped against the three ceilings the kernel enforces (`kern.maxfilesperproc`, a bounded share of `kern.maxfiles`, and the raised `RLIMIT_NOFILE`), returning zero (unarmed) rather than a set it cannot register.                      |

`kqueue.zig` and `coverage.zig` are two halves of one macOS backend — the event
engine and the admission walk — split so each reads as a single concern; they
reference each other directly (`coverage` registers via `kqueue.note` /
`kqueue.retire`, `kqueue` rescans via `coverage.coverTree`). The Linux and macOS
sides never intersect: every macOS function is gated behind
`if (comptime !is_macos) return …`, so the whole folder compiles on both targets
and the unused backend lowers to nothing.

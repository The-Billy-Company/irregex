The freshness watcher is now a five-module package behind one facade:
`watch.zig` still owns the public `Watcher(Session)` — the shared per-session
state, the comptime backend selection, and the cross-backend invariants — while
the backends live beside it under `watch/`: `inotify.zig` (the Linux event
loop, coverage extension, and casefold detection), `kqueue.zig` (the macOS
`EVFILT_VNODE` registration, drain, rescan, and retire) + `coverage.zig` (the
macOS admission walk that selects the watch set from the corpus's own `Ignore`
policy) + `budget.zig` (the descriptor ceiling clamped against the limits the
kernel actually enforces). Each backend is a set of free functions over the
generic `Watcher`, so the accelerator's every-note-precedes-markDirty ordering,
its fail-closed arm-exactness, and its coverage-poison contract read as three
cohesive modules instead of one 1,000-line file — with the same public entry
points (`start` / `stop` / `shed` / `flushSync` / `held`) and byte-identical
behavior on both targets. No behavior changed; the file dropped its MONOLITHIC
deferral.

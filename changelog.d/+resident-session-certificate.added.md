`bench/session/` certifies the honest warm-product path: a persistent client
dialing a `gist serve` daemon once over a Unix socket and replaying a slate over
that warm connection (ADR-352 rung 2.5). A new `zig build bench -- session` mode
times the real client→daemon round-trip (daemon on its own thread, one reused
connection); `certify_session.sh` pairs each needle with ripgrep-cold and writes
`session_macro.csv` + `session_meta.json`; `gate_session.py` (`make
bench-gist-session`) enforces the armed-path geomean floor and is report-only on
platforms with no watcher backend (every query pays the reconcile freshness tax).
Even unarmed on macOS it measures **7.2× geomean over ripgrep-cold** — rg
re-walks and re-scans the whole tree each call while the warm client pays only
the reconcile plus an in-RAM index query. `ci_order.sh` runs the committed
session gate alongside the cold ratio gate in the performance phase.

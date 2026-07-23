The cold walk no longer re-enumerates an unchanged tree. `gist index` now
publishes `tree.map` — a self-anchored directory-membership snapshot (names +
kinds, recorded with the query walk's own admission semantics) — and the
parallel engine proves each recorded directory current with ONE `lstat`
(POSIX bumps a directory's mtime/ctime on any direct membership change,
compared conservatively against the snapshot anchor exactly like the T3
freshness overlay), serving its child list straight from the mapping instead
of `openat`+`getattrlistbulk`+`close`. Membership only, fail-open everywhere:
ignore/hidden/glob admission is decided live per entry, a stale or unrecorded
directory (and any subtree behind a changed level) live-lists and resumes
phantom below it, admitted files still `lstat` live before index elision may
skip them, explicit positional roots resolve into the snapshot by name, and a
missing/corrupt/future-dated `tree.map` (or `GIST_NO_PHANTOM=1`) returns the
walk to its live path byte-identically. Walk-bound shapes moved most: on the
Billy corpus `-g '*.go'`/`-t go` races went 2.2× → **7.6–7.8×** over ripgrep,
the whole-matrix span is now 2.3×–16.1× (19/19 wins, floors republished), and
rgsuite holds 409/409 on both engines.

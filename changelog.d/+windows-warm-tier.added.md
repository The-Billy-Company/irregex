Windows gets the warm tier. `portal.resident_sessions` was `comptime false`
there, so every query on Windows answered cold — no resident session, no answer
keep, and the two heaviest `relate` sweeps had no cheaper form to fall back on.
The declared floor moves to `win10_rs4` (1803), which is where Windows shipped
`AF_UNIX`, so the daemon speaks the same socket protocol as every other platform
rather than a second named-pipe transport nobody would keep honest. Four seams
grew a Win32 arm behind their existing `comptime` boundary: readiness waits on
AFD's `IOCTL_AFD_POLL` (the mechanism `wepoll` and libuv use) instead of
`poll(2)`; byte I/O threads through `std`'s socket vtable instead of raw
`read`/`write`; the singleton is a share-mode exclusive open instead of `flock`;
and the spawn is a detached `CreateProcessW` instead of `fork`+`execv`.
Descriptor passing stays POSIX-only — `SCM_RIGHTS` has no portable Win32
equivalent worth the surface — so `portal.fd_passing` split out as its own
predicate and the Windows daemon serves shared-memory or chunk frames instead.
Nothing about the cold path depends on any of it, which is why this is a speed
change rather than a correctness one.

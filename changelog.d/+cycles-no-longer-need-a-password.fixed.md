`pmu.zig` read hardware counters through exactly one backend - Apple's private
`kperf` - and that backend is root-gated. So on any machine where `sudo -n`
doesn't answer, every benchmark in the repo silently fell back to wall-clock. A
24-mechanism profiling baseline came back with zero measured cycle counts, which
meant the ladder auction's cost model couldn't be re-priced and no claim in the
certificate could be stated in cycles/byte.

The gate is not the framework load, which is worth stating because it's the
natural guess. `dlopen` of kperf succeeds fine unprivileged; the refusal is the
first counter call. In xnu every `kpc_*` call routes through `ktrace_read_check()`,
which passes for the blessed pid or for euid 0 and returns `EPERM` for everyone
else, so `kpc_force_all_ctrs_get` is where an unprivileged run actually dies.

The fix isn't privilege. macOS has an unprivileged per-thread counter syscall,
`thread_selfcounts`, that returns retired cycles and instructions for the calling
thread, and it was simply never wired up. `pmu.zig` now tries three backends in
order - `kperf`, then `thread_selfcounts`, then honest wall-clock - so the numbers
the certificate quotes need no password at all. `zig build roofline` reports
3.938 GHz measured and 0.4773 cyc/byte DRAM on an M4 Max with no sudo anywhere in
the picture.

Backends are not interchangeable and the reports no longer pretend they are. The
roofline's `meter:` and `clock:` lines were hardcoded to credit kperf; they now
name whichever backend actually answered, so a number can't quietly change
meaning when the tier underneath it does. Seven tests hold the new backend to its
contract: that a meter is either honestly instrumented or honestly wall-clock,
that counters advance across real work, that they measure work rather than
elapsed time, that a busy neighbor thread can't inflate them, and - the one that
catches a struct-layout drift the coarse IPC bound would miss - that an undersized
read is refused rather than half-filled, since the kernel will otherwise fill only
what fits and report success.

What privilege still buys is kperf's *configurable* events - cache misses, branch
mispredicts, port pressure - and nothing else. For that residual case
`bench/apparatus/privilege/` stages a helper that gets blessed, drops privileges
irrevocably, and execs the benchmark as the invoking user, behind a digest-pinned
sudoers rule on a root-owned path. It is staged and documented rather than
recommended: its README says plainly that the ask that motivated it is now moot,
and that a standing NOPASSWD grant on a machine running ten autonomous agents
isn't worth a convenience none of the current claims need.

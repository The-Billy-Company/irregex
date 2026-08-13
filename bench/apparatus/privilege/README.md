# bench/apparatus/privilege

**Staged, audited, and deliberately declined. Nothing here is installed, and
installing it is not a pending step.**

The short version: **you almost certainly do not need this.** Every number the
certificate quotes in cycles or cycles/byte is now measured with **no privilege
at all**. This directory exists for one residual case — kperf's *configurable*
events — and it is kept staged so that if that case ever arrives the decision is
informed rather than reflexive. It has not arrived: the unprivileged tier made
the original ask moot, so the grant was weighed and turned down. What follows is
the audit that reached that answer, not an install guide.

## What Changed, and Why the Ask Is Mostly Moot

The original problem: `pmu.zig` read counters only through Apple's private
`kperf` framework, which is root-gated, so `sudo -n` failing meant every
benchmark silently fell back to wall-clock and a 24-mechanism profiling baseline
produced zero measured cycles.

The fix was not privilege. macOS has an **unprivileged** per-thread counter
syscall, `thread_selfcounts`, which returns retired cycles and instructions for
the calling thread. `pmu.zig` now tries three backends in order — `kperf`, then
`thread_selfcounts`, then honest wall-clock — so the common case needs nothing:

```bash
$ zig build -Doptimize=ReleaseFast roofline   # no sudo, no password
meter:   thread_selfcounts · THSC_CPI cycles + instructions (unprivileged, per-thread)
…
clock:   3.876 GHz · measured (thread_selfcounts, cycles ÷ ns under memory load)
ceiling: DRAM 81.8 GB/s · L2 106.5 GB/s
         = 0.0474 cyc/byte DRAM · 0.0364 cyc/byte L2 (derived, GHz ÷ GB/s)
```

Measured cycles/byte, unprivileged. The ladder auction's cost model can be
re-priced and the certificate can state cycles/byte without anyone typing a
password.

`-Doptimize=ReleaseFast` is load-bearing, not decoration: the rung's build
posture is `.asked`, Zig defaults to Debug, and a Debug build does not vectorize
the reduction the kernel's whole bandwidth claim rests on. It now refuses before
spending a trial rather than publishing a flat hierarchy, so the bare
`zig build roofline` this section used to quote no longer runs at all. The
argument is [`../../bounds/roofline/README.md`](../../bounds/roofline/README.md);
what matters here is only that the privilege story is unaffected — the counter
backend is the same either way, and it is still unprivileged.

**What the grant in this directory still buys:** kperf's configurable events —
cache misses, branch mispredicts, port-pressure counters. `thread_selfcounts`
gives cycles and instructions only. If you are not currently blocked on a
specific configurable event, stop reading and do not install this.

## Exactly What Needs Root

In xnu, every `kpc_*` counter call routes through one ACL:

```c
/* bsd/kern/kern_ktrace.c — ktrace_read_check(void) */
if (proc_uniqueid(current_proc()) == ktrace_owning_unique_id) return 0;
return _current_task_can_own_ktrace() ? 0 : EPERM;   /* == euid 0 on release kernels */
```

Not the framework load — `dlopen` of kperf succeeds unprivileged. The gate is
the first counter call. Verified directly by `kperf_probe.c`:

```bash
$ ./kperf_probe
kperf_probe: euid=501 pid=24299
  kpc_force_all_ctrs_get -> rc=-1 errno=1 (Operation not permitted)
  RESULT: DENIED — not root and not the blessed pid.
```

That first branch is the important one. `ktrace_owning_unique_id` is the
**blessed pid** — a process root has nominated via the `kperf.blessed_pid`
sysctl. So the benchmark never has to *be* root: root can nominate an ordinary
process and then leave. That is the whole design.

## Why Not the Obvious Rule

```text
<user> ALL=(root) NOPASSWD: /…/irregex/zig-out/bin/<benchbinary>
```

That is a local root escalation, and this repository is the worst possible place
for it: `zig-out/` is build output, rewritten by every `zig build`, and roughly
ten agent processes build in this tree concurrently. Anything that can write that
path gets uninterceptable root. Nothing here names a path under any build
directory.

## Options Weighed

- **Unprivileged `thread_selfcounts`** (shipped, default) has no exposure
  radius — no privilege exists to abuse — is not subvertible by an agent,
  and costs no friction at all.

- **Blessing helper + digest-pinned NOPASSWD** (staged here) grants
  ktrace/kperf ownership for one process: a timing side channel plus a
  sampling facility, not root. It is not subvertible by an agent while the
  install path stays root-owned (see below), at the cost of one
  authenticated install, then a re-install to change the helper.

- **NOPASSWD on the benchmark binary** has an exposure radius of **full root**,
  permanently, and is subvertible **trivially** — any agent writes
  `zig-out/` — for no friction saved.

- **`timestamp_timeout` extended** grants full root for the window, for
  *any* command, and any agent can ride the live timestamp; it costs one
  password per session.

- **Entitlements / code signing** is **not available** at all: on release
  kernels `_current_task_can_own_ktrace()` requires euid 0 outright, and the
  entitlement path is dev/debug-kernel only, so no provisioning profile,
  paid or otherwise, unlocks this.

Rejecting `timestamp_timeout` is worth being explicit about: it looks weaker than
NOPASSWD because it is temporary, but it is *broader*. A live sudo timestamp
authorizes **any** command from that account, so any of the ten agents can spend
it on anything. The digest-pinned helper authorizes exactly one immutable binary,
forever. Narrow-and-permanent beats broad-and-temporary here.

## The Security Model of What Is Staged

`pmu_bless.c` becomes a root-owned binary that a NOPASSWD rule can start. Its
argument is that it **never executes anything as root**:

1. `fork`.
2. The child drops privileges irrevocably — `setgid`, `setgroups`, `setuid` in
   that order — and then *proves* the drop by checking `setuid(0)` fails. It then
   blocks on a pipe.
3. The parent, still root, writes the child's pid to `kperf.blessed_pid`, then
   releases the pipe. Blessing is by pid and survives `exec`, so the child is
   blessed before it runs one instruction of the target.
4. The child `execvp`s the target **as the invoking user**.
5. The parent propagates the child's exit status.

Fail directions are chosen so that every error loses privilege rather than
leaking it:

- **No non-root `SUDO_UID` to drop to** — **refuse**, never exec as root.
- **Cannot drop privileges, or the drop is recoverable** — **refuse**, never
  exec as root.
- **Cannot bless** — **warn and run anyway**, unprivileged. A benchmark must
  not fail to run; it just measures via `thread_selfcounts`.

**What this grant is.** ktrace/kperf ownership for one process at a time: reading
counters, programming counters, configuring kperf sampling. That is a
high-resolution microarchitectural side channel and a sampling facility. It is
much smaller than root. It is not nothing, and anyone who can invoke the helper
can point it at a process of their choosing.

### The Load-Bearing Detail: Path Ownership, Not the Digest

The sudoers rule pins the helper's SHA-256, so replacing the binary makes sudo
refuse it. But `sudoers(5)` warns:

> if the user has write access to the command itself (directly or via a sudo
> command), it may be possible for the user to replace the command after the
> digest check has been performed but before the command is executed. A similar
> race condition exists on systems that lack the `fexecve(2)` system call when
> the directory in which the command is located is writable by the user.

**macOS has no `fexecve(2)`**, so the digest alone does not close that race —
path ownership does. The helper installs root:wheel `0555` inside root:wheel
`0755` `/usr/local/libexec`, so the granted account can write neither the file
nor its directory. `install.sh` **verifies this before compiling anything** and
refuses outright if any component is not root-owned or is group/world-writable.
That check matters: on Intel Macs Homebrew owns `/usr/local`, which would make
the whole arrangement unsound, and the installer fails loudly rather than
quietly shipping a hole. On this machine Homebrew is at `/opt/homebrew`, so
`/usr/local` is pristine and the race is closed.

## Files

- **`pmu_bless.c`** is the helper — ~250 lines, commented to be audited in
  one sitting.
- **`kperf_probe.c`** answers "can this process read counters?" — used to
  verify the grant, and to prove the unprivileged baseline is DENIED.
- **`irregex-pmu.sudoers.in`** is the sudoers template. Placeholders are
  deliberately invalid syntax, so a stray `cp` cannot become a live rule.
- **`install.sh`** runs compile → self-check → render → `visudo -c` →
  install → **verify → revoke on failure**.

## If You Ever Do Install It

Nobody has, and ["Should you install this on a ten-agent
machine?"](#should-you-install-this-on-a-ten-agent-machine) says why not. This is
the procedure should the residual case arrive, not a step anyone is waiting on.

Dry-run everything first. This needs no privileges and installs nothing:

```bash
./bench/apparatus/privilege/install.sh --check
```

It prints the path-ownership audit, the compiled digest, the helper's own
unprivileged `--check`, and the exact rule that would be installed.

Then, if you have decided you need configurable events:

```bash
sudo ./bench/apparatus/privilege/install.sh
```

The installer does not stop at "installed". Because the privileged half cannot
be tested beforehand, it tests it **afterwards** and tears the grant down if any
of it fails:

- passwordless invocation actually works;
- **the digest is enforced, not merely parsed** — it plants a byte-altered copy
  under a rule pinning the original hash and confirms sudo refuses to run it. If
  this sudo parsed digests but ignored them, the rule would be a root escalation,
  so the installer removes it and tells you not to re-install;
- blessing actually delivers counters to an unprivileged process, via
  `kperf_probe`. If not, the rule buys nothing and is removed.

A password never buys a rule that does not work.

## Revoking

```bash
sudo rm -f /etc/sudoers.d/irregex-pmu /usr/local/libexec/irregex-pmu-bless
```

Nothing in the repository depends on it. Every benchmark keeps working and keeps
reporting measured cycles and instructions through `thread_selfcounts`; only
configurable events go away. The `meter:` line in any report always names the
backend actually used, so a revoked grant is visible in the output rather than
silently changing what a number means.

## Should You Install This on a Ten-Agent Machine?

**No.** That is the answer this audit reached and the standing decision on this
machine — not by default, and not on the strength of the original ask. Two
reasons, in order:

1. **It is no longer needed for the stated goal.** The profiling baseline
   produced zero cycles because `pmu.zig` had one root-gated backend, not because
   the machine lacked permission to measure. That is fixed. Cycles/byte are
   measured unprivileged today.
2. **A permanent NOPASSWD rule on a machine running ten autonomous agents is a
   standing capability, and the threat model is unusual.** The digest and path
   ownership mean an agent cannot escalate to root through it. But any of those
   agents can *invoke* it, and blessing hands a process high-resolution
   microarchitectural observation plus a sampling facility. That is a real
   capability to leave lying around for a convenience none of the current claims
   need.

Install it if and only if you hit a specific measurement you cannot make without
configurable events — and prefer the narrower move first: run the helper under an
**interactive** `sudo` for that session and skip the sudoers file entirely. The
helper works identically that way; the NOPASSWD rule only removes the password
prompt, and unattended profiling is the only thing that actually requires it.

/*
 * irregex-pmu-bless — hand this machine's hardware performance counters to ONE
 * unprivileged process, then get out of the way.
 *
 * READ THIS BEFORE YOU AUTHENTICATE ANYTHING. This file becomes a root-owned
 * binary that a NOPASSWD sudoers rule can start without a password. Its whole
 * security argument is that it is short enough to audit in one sitting and that
 * it never, under any argument, executes anything with privileges.
 *
 * WHY IT EXISTS
 * -------------
 * xnu gates every `kpc_*` performance-counter call behind
 * `ktrace_read_check()`, which passes for exactly two callers:
 *
 *     if (proc_uniqueid(current_proc()) == ktrace_owning_unique_id) return 0;
 *     return _current_task_can_own_ktrace() ? 0 : EPERM;   // == euid 0
 *
 * The second is root. The first is the *blessed pid* — a process root has
 * nominated. So the naive arrangement ("let sudo run the benchmark") is not the
 * only one: root can nominate an ordinary process and then leave. That is what
 * this does, and it is why the benchmark never needs to be root and the sudoers
 * rule never needs to name a path inside a build directory that ten agent
 * processes write to.
 *
 * MOST PEOPLE DO NOT NEED THIS. Retired cycles and instructions — everything
 * the certificate actually quotes — are available with NO privilege at all
 * through `thread_selfcounts`, which `bench/apparatus/harness/pmu.zig` uses by
 * default. This helper only buys kperf's *configurable* events (cache misses,
 * branch mispredicts, port-pressure counters). See ../privilege/README.md.
 *
 * WHAT IT DOES, IN ORDER
 * ----------------------
 *   1. fork.
 *   2. The child drops privileges irrevocably and *verifies* it cannot get them
 *      back, then blocks on a pipe.
 *   3. The parent (still root) writes the child's pid to `kperf.blessed_pid`,
 *      then releases the pipe. Blessing is by pid and survives the exec, so the
 *      child is blessed before it runs a single instruction of the target.
 *   4. The child execs the target — as the invoking user, never as root.
 *   5. The parent waits and propagates the child's exit status.
 *
 * THE PRIVILEGE THIS GRANTS is ktrace/kperf ownership for one process: reading
 * counters, programming counters, and configuring kperf sampling. That is a
 * microarchitectural side channel and a sampling facility. It is emphatically
 * NOT root — but it is more than "read my own cycle count", and the README says
 * so plainly rather than selling it as harmless.
 *
 * FAIL DIRECTIONS, chosen deliberately:
 *   * Cannot determine a non-root user to drop to  -> REFUSE. Never exec as root.
 *   * Cannot drop privileges, or can regain them   -> REFUSE. Never exec as root.
 *   * Cannot bless                                 -> WARN and exec anyway. The
 *     target then measures through the unprivileged backend. Losing privilege is
 *     always the safe direction, and a benchmark must never fail to run.
 *
 * Build:  cc -O2 -Wall -Wextra -o irregex-pmu-bless pmu_bless.c
 * Install: ../privilege/install.sh (validates, pins a digest, is idempotent)
 */

#include <errno.h>
#include <grp.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* The sysctl whose setter calls ktrace_set_owning_pid() in xnu. */
#define BLESS_SYSCTL "kperf.blessed_pid"

static const char *self = "irregex-pmu-bless";

static void warn_errno(const char *what) {
  fprintf(stderr, "%s: %s: %s\n", self, what, strerror(errno));
}

static __attribute__((noreturn)) void refuse(const char *why) {
  fprintf(stderr, "%s: refusing: %s\n", self, why);
  exit(2);
}

static void usage(FILE *out) {
  fprintf(out,
          "usage: %s <command> [args...]   run <command> unprivileged, with the PMU\n"
          "       %s --check               report what a privileged run would do\n"
          "       %s --help\n"
          "\n"
          "Grants hardware-counter access to the ONE process it starts. The command\n"
          "runs as the invoking user; this helper never executes anything as root.\n"
          "Most measurements need no privilege at all -- see privilege/README.md.\n",
          self, self, self);
}

/*
 * Who to become. Under sudo, getuid() is already 0, so the real uid cannot tell
 * us; sudo always exports SUDO_UID/SUDO_GID for exactly this purpose. If they
 * are absent or name root, we have no non-root identity to drop to and we stop.
 * Refusing here is what keeps "exec as root" off the table for every input.
 */
static int target_identity(uid_t *uid, gid_t *gid) {
  const char *u = getenv("SUDO_UID");
  const char *g = getenv("SUDO_GID");
  if (u == NULL || *u == '\0')
    return -1;

  errno = 0;
  char *end = NULL;
  unsigned long parsed = strtoul(u, &end, 10);
  if (errno != 0 || end == NULL || *end != '\0' || parsed == 0 || parsed > UINT_MAX)
    return -1;
  *uid = (uid_t)parsed;

  /* A missing or unparsable SUDO_GID falls back to the user's own gid, never 0. */
  *gid = (gid_t)parsed;
  if (g != NULL && *g != '\0') {
    errno = 0;
    end = NULL;
    unsigned long pg = strtoul(g, &end, 10);
    if (errno == 0 && end != NULL && *end == '\0' && pg != 0 && pg <= UINT_MAX)
      *gid = (gid_t)pg;
  }
  return 0;
}

/*
 * Drop root for good. setgid before setuid (the reverse order leaves the group
 * privilege behind), then prove the drop by trying to undo it: on a correct
 * drop, setuid(0) must fail. A helper that execs while it can still become root
 * is the bug this check exists to make impossible to ship unnoticed.
 */
static void drop_privileges_or_die(uid_t uid, gid_t gid) {
  if (setgid(gid) != 0) {
    warn_errno("setgid");
    refuse("could not drop group privileges");
  }
  if (setgroups(1, &gid) != 0 && geteuid() == 0) {
    warn_errno("setgroups");
    refuse("could not reset supplementary groups");
  }
  if (setuid(uid) != 0) {
    warn_errno("setuid");
    refuse("could not drop user privileges");
  }
  if (geteuid() == 0 || getuid() == 0)
    refuse("still root after dropping privileges");
  if (setuid(0) == 0)
    refuse("privileges were recoverable after the drop");
}

/* Nominate `pid` as the ktrace/kperf owner. Returns 0, or errno on failure. */
static int bless(pid_t pid) {
  int value = (int)pid;
  if (sysctlbyname(BLESS_SYSCTL, NULL, NULL, &value, sizeof value) != 0)
    return errno != 0 ? errno : -1;
  return 0;
}

static int check_mode(void) {
  uid_t uid = 0;
  gid_t gid = 0;
  int have_identity = target_identity(&uid, &gid) == 0;

  printf("%s --check\n", self);
  printf("  euid                 : %d%s\n", (int)geteuid(),
         geteuid() == 0 ? " (privileged)" : " (unprivileged)");
  printf("  drop-to identity     : ");
  if (have_identity)
    printf("uid=%d gid=%d (from SUDO_UID/SUDO_GID)\n", (int)uid, (int)gid);
  else
    printf("NONE -- a privileged run would refuse rather than exec as root\n");

  int current = 0;
  size_t len = sizeof current;
  errno = 0;
  int rc = sysctlbyname(BLESS_SYSCTL, &current, &len, NULL, 0);
  printf("  %-21s: ", BLESS_SYSCTL);
  if (rc == 0)
    printf("readable, currently %d\n", current);
  else
    printf("%s\n", strerror(errno));

  if (geteuid() != 0) {
    printf("\n  Expected unprivileged result: the sysctl reports "
           "\"Operation not permitted\".\n"
           "  That is xnu's ktrace ACL refusing, which is the whole reason this\n"
           "  helper exists. Nothing is installed or changed by --check.\n");
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 1 && argv[0] != NULL && argv[0][0] != '\0') {
    const char *slash = strrchr(argv[0], '/');
    self = slash != NULL ? slash + 1 : argv[0];
  }

  if (argc < 2) {
    usage(stderr);
    return 2;
  }
  if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
    usage(stdout);
    return 0;
  }
  if (strcmp(argv[1], "--check") == 0)
    return check_mode();

  if (geteuid() != 0) {
    fprintf(stderr,
            "%s: not privileged (euid %d), so no counters can be granted.\n"
            "%s: run the command directly -- pmu.zig measures cycles and\n"
            "%s: instructions unprivileged. See privilege/README.md.\n",
            self, (int)geteuid(), self, self);
    return 1;
  }

  uid_t uid = 0;
  gid_t gid = 0;
  if (target_identity(&uid, &gid) != 0)
    refuse("no non-root SUDO_UID to drop to; this helper never execs as root");

  int handshake[2];
  if (pipe(handshake) != 0) {
    warn_errno("pipe");
    refuse("could not create the readiness pipe");
  }

  pid_t child = fork();
  if (child < 0) {
    warn_errno("fork");
    refuse("could not fork");
  }

  if (child == 0) {
    close(handshake[1]);
    /* Shed privileges first, so the window in which this process is root
     * contains nothing but these few syscalls and no caller-supplied input. */
    drop_privileges_or_die(uid, gid);

    /* Wait for the blessing. A short read means the parent died before it could
     * bless us; exec anyway and let the target fall back to the unprivileged
     * backend, because failing to run is worse than measuring without kperf. */
    char ready = 0;
    ssize_t n;
    do {
      n = read(handshake[0], &ready, 1);
    } while (n < 0 && errno == EINTR);
    close(handshake[0]);

    execvp(argv[1], &argv[1]);
    warn_errno(argv[1]);
    _exit(127);
  }

  close(handshake[0]);
  int err = bless(child);
  if (err != 0) {
    fprintf(stderr,
            "%s: could not bless pid %d via %s: %s\n"
            "%s: continuing unprivileged -- the target will measure cycles and\n"
            "%s: instructions through thread_selfcounts instead.\n",
            self, (int)child, BLESS_SYSCTL, err > 0 ? strerror(err) : "unknown",
            self, self);
  } else {
    fprintf(stderr, "%s: pid %d holds the PMU; running as uid %d\n", self,
            (int)child, (int)uid);
  }

  /* Release the child whether or not blessing worked. */
  char go = 1;
  ssize_t w;
  do {
    w = write(handshake[1], &go, 1);
  } while (w < 0 && errno == EINTR);
  close(handshake[1]);

  int status = 0;
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) {
      warn_errno("waitpid");
      return 1;
    }
  }
  if (WIFSIGNALED(status)) {
    fprintf(stderr, "%s: target died on signal %d\n", self, WTERMSIG(status));
    return 128 + WTERMSIG(status);
  }
  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

/*
 * kperf_probe — answer one question and exit: can THIS process program and read
 * hardware performance counters?
 *
 * It exists so that installing a privilege grant can be *verified* rather than
 * assumed. Run it two ways:
 *
 *     ./kperf_probe                              -> expect DENIED (EPERM)
 *     sudo -n irregex-pmu-bless ./kperf_probe    -> expect GRANTED
 *
 * The first proves the machine's default posture; the second proves the blessing
 * actually reached an unprivileged process. install.sh runs both, and revokes
 * the grant if the second does not hold — a password should never buy a rule
 * that turns out not to work.
 *
 * It calls the same entry point bench/apparatus/harness/pmu.zig calls, so a
 * GRANTED here means the harness will open counters too.
 *
 * Build: cc -O2 -Wall -Wextra -o kperf_probe kperf_probe.c
 */

#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define KPERF_FRAMEWORK "/System/Library/PrivateFrameworks/kperf.framework/kperf"

/* KPC_CLASS_*_MASK: fixed counters (cycles, instructions) plus configurable. */
#define KPC_CLASS_FIXED_MASK (1u << 0)
#define KPC_CLASS_CONFIGURABLE_MASK (1u << 1)

int main(void) {
  printf("kperf_probe: euid=%d pid=%d\n", (int)geteuid(), (int)getpid());

  void *kperf = dlopen(KPERF_FRAMEWORK, RTLD_LAZY);
  if (kperf == NULL) {
    printf("  RESULT: UNAVAILABLE — kperf did not load: %s\n", dlerror());
    return 3;
  }

  int (*force_get)(uint32_t *) = dlsym(kperf, "kpc_force_all_ctrs_get");
  int (*set_counting)(uint32_t) = dlsym(kperf, "kpc_set_counting");
  uint32_t (*get_counter_count)(uint32_t) = dlsym(kperf, "kpc_get_counter_count");

  if (force_get == NULL) {
    printf("  RESULT: UNAVAILABLE — kpc_force_all_ctrs_get missing from kperf\n");
    return 3;
  }

  /*
   * This is the gate. In xnu, kpc_force_all_ctrs_get -> ktrace_read_check(),
   * which returns EPERM unless the caller is root or the blessed pid. Every
   * other kpc_* read/write sits behind the same check, so this one call is a
   * faithful proxy for "can the harness measure".
   */
  uint32_t forced = 0;
  errno = 0;
  int rc = force_get(&forced);
  if (rc != 0) {
    printf("  kpc_force_all_ctrs_get -> rc=%d errno=%d (%s)\n", rc, errno, strerror(errno));
    printf("  RESULT: DENIED — not root and not the blessed pid.\n");
    printf("          Retired cycles and instructions are still measurable without\n");
    printf("          privilege; only kperf's configurable events need this.\n");
    return 1;
  }

  printf("  kpc_force_all_ctrs_get -> ok (force_all_ctrs=%u)\n", forced);
  if (get_counter_count != NULL) {
    printf("  fixed counters         : %u\n", get_counter_count(KPC_CLASS_FIXED_MASK));
    printf("  configurable counters  : %u\n",
           get_counter_count(KPC_CLASS_CONFIGURABLE_MASK));
  }

  /* Prove it is writable too, not just readable, then put it back. */
  if (set_counting != NULL) {
    errno = 0;
    int wrc = set_counting(KPC_CLASS_FIXED_MASK | KPC_CLASS_CONFIGURABLE_MASK);
    printf("  kpc_set_counting       : %s\n",
           wrc == 0 ? "ok (counters programmable)" : strerror(errno));
    if (wrc == 0)
      set_counting(0);
  }

  printf("  RESULT: GRANTED — this unprivileged process owns the PMU.\n");
  return 0;
}

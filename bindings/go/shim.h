/* The one fault-capture helper every plane's cgo preamble includes.
 *
 * irgx_last_fault reports the last failure on THIS THREAD, and a goroutine is
 * pinned to its thread only for the duration of a cgo call. Reading the fault
 * in a second crossing could land on a different thread and find nothing, or
 * find somebody else's failure. So every engine call that can fail is wrapped
 * in a static shim that takes the status and the detail in ONE crossing.
 *
 * It lives in a header rather than in each preamble because a preamble is its
 * own translation unit: nine copies of this function would be nine things to
 * keep identical, and the one that drifted would silently mis-render a fault.
 * `static` means each unit gets its own copy of the code, which is what a
 * header-only helper is for and costs nothing at this size. */
#ifndef IRGX_GO_SHIM_H
#define IRGX_GO_SHIM_H

#include "irgx.h"

static void capture(int32_t st, irgx_fault *f) {
  f->struct_size = (uint32_t)sizeof(*f);
  f->name = NULL;
  f->path = NULL;
  f->at_space = IRGX_AT_NONE;
  /* A negative status does not imply a detail exists; name stays NULL then.
   * IRGX_STALE is not asked at all: a declinature installs no fault, so the
   * slot would answer with an older call's detail on this thread. */
  if (st < 0 && st != IRGX_STALE && irgx_last_fault(f) != IRGX_MATCH) f->name = NULL;
}

#endif /* IRGX_GO_SHIM_H */

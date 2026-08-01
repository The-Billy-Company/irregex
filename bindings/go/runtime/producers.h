/* The analytic producers, and the request families they read.
 *
 * Three libraries answer the seventeen analytic verbs: `gist_run` for rank,
 * `relate_run` for the kinship, retrieval and sweep verbs, and `blast_run` for
 * the composed ones. Only libirregex is linked here — the substrate that opens
 * the corpus and walks rows. The product producers are resolved by name at RUN
 * time, so a host that links only the libraries it needs still builds, and a
 * weak fallback definition is never used (it would permanently SHADOW a strong
 * symbol from a later-loaded product library).
 *
 * The request families are MIRRORED from `[analytic.params]` in
 * irregex/contract/analytic.toml. Field names and order are the contract's;
 * `struct_size` fails a mismatched layout closed at the callee.
 *
 * cgo compiles each file's preamble as its own translation unit, which is why
 * this is a header rather than more lines in native.go: both native.go and
 * dispatch.go need these declarations. */
#ifndef IRREGEX_GO_PRODUCERS_H
#define IRREGEX_GO_PRODUCERS_H

#include <dlfcn.h>
#include <irregex.h>

/* similar · dups · clusters · echoes · concepts · fragments · distinct.
 * `target` NULL = the corpus-wide sweep. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const uint8_t *target;
  size_t target_len;
  uint32_t channel; /* IRREGEX_CHANNEL_* */
  uint32_t unit;    /* IRREGEX_UNIT_*    */
  double max_distance;
  double min_echo;
  uint32_t min_grade; /* IRREGEX_GRADE_*: withhold anything weaker */
  uint32_t min_size;
  uint32_t min_lines;
  uint32_t top;
} relate_kinship_params;

/* recall · pack · quote — free text priced against the corpus. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const uint8_t *query;
  size_t query_len;
  uint32_t top;
  uint32_t reserved;
} relate_retrieval_params;

/* patterns · pattern_counts — N patterns, one walk, exact attribution. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const irregex_text *patterns;
  size_t npatterns;
  const uint8_t *under; /* optional glob scope; NULL = the whole corpus */
  size_t under_len;
  uint32_t top;
  uint32_t reserved;
} relate_sweep_params;

/* context · family · provenance · blast — an exact PatternSet narrows a
 * candidate set, then the compression kernel reasons INSIDE it. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const uint8_t *text;
  size_t text_len;
  const irregex_text *patterns;
  size_t npatterns;
  double max_distance;
  double min_echo;
  uint32_t budget;
  uint32_t top;
} blast_compose_params;

/* rank — the definition-first view of an exact query (gist_run). Mirrored
 * here so this translation unit never needs <gist.h>. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const uint8_t *pattern;
  size_t pattern_len;
  uint32_t top;
  uint32_t reserved;
} gist_rank_params;

/* One signature, three producers: an analytic entry takes an open corpus, an op,
 * that op's params family, an optional cancel token, and hands back a cursor. */
typedef int32_t (*irregex_producer)(irregex_engine *engine, uint32_t op,
                                    const void *params, irregex_cancel *cancel,
                                    irregex_rows **out);

/* Reachable is not callable. RTLD_DEFAULT searches everything the process has
 * loaded — including libraries this module did not choose — so finding a symbol
 * named `relate_run` does not establish that it speaks for THIS engine. Every
 * producer takes an OPEN ENGINE, and an engine is only interpretable by the copy
 * of the engine code that made it: the corpus, its arenas, and its process-global
 * caches all belong to one image. A producer that statically compiled its own
 * copy has an identical struct layout and entirely separate state, so handing it
 * a foreign handle segfaults rather than declining, and nothing in the ABI says
 * which copy a producer speaks for.
 *
 * So ask the producer's own image whether it can resolve the engine's opener. An
 * image that shares the engine resolves it, directly or through the dependency it
 * links it from; an image carrying a private copy cannot, because a private copy
 * is not exported. The invariant is stated positively, names no library, and
 * lifts itself the moment a producer links the engine instead of duplicating it —
 * which is why every library WE ship passes it untouched. It earns its keep for
 * the ones we don't: these are published packages now, and the process namespace
 * is open. Fail closed to the cold tier; never hand a stranger the handle. */
static inline irregex_producer irregex_go_producer(const char *name) {
  void *found = dlsym(RTLD_DEFAULT, name);
  if (found == NULL) return NULL;
  Dl_info info;
  if (dladdr(found, &info) == 0 || info.dli_fname == NULL) return NULL;
  void *image = dlopen(info.dli_fname, RTLD_LAZY | RTLD_NOLOAD);
  if (image == NULL) return NULL;
  int shares = dlsym(image, "irregex_engine_open") != NULL;
  dlclose(image); /* drops only the reference RTLD_NOLOAD took */
  return shares ? (irregex_producer)found : NULL;
}

/* Go cannot call a C function pointer; this hands the call back to C. */
static inline int32_t irregex_go_produce(irregex_producer f, irregex_engine *engine,
                                         uint32_t op, const void *params,
                                         irregex_cancel *cancel,
                                         irregex_rows **out) {
  return f(engine, op, params, cancel, out);
}

#endif /* IRREGEX_GO_PRODUCERS_H */

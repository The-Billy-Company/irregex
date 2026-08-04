# `runtime`

Everything that touches the analytic kernel from Go lives here: the transports
and the fallback ladder between them. That means the cgo declarations against
`libirgx`, the analytic dispatch (product producers resolved via `dlsym`), the
generic row decoder, the child-process runner, and the error mapping that
decides which of those answers a query.

Product verb packages (gist `exact`/`index`, relate, blast `compose`) hold
vocabulary; this package holds mechanism.

## The Ladder

One verb, two tiers, one answer:

1. **In-process** (`dispatch.go`, `//go:build cgo && irgx_ffi`) - the
   product's `*_run` symbol against a warm `irgx_engine`, when that library
   is linked into the process. Preferred, allocation-lean, cancellable.
2. **Child process** (`cold.go` + `plan.go` + `decode.go`) - the certified
   `gist` / `relate` / `blast` binary, its NDJSON raised back into rows of the
   same schema.

A tier that cannot answer **declines**, and a declinature is not an error.
`Probe()` reports which tiers this process actually has; `IRGX_NO_FFI=1`
forces the child tier.

## The Engine-Sharing Guard

**Reachable is not callable.** Every analytic producer takes an **open
engine**, and an engine is only interpretable by the copy of the engine code
that made it: the corpus, its arenas, and its process-global caches all belong
to one image. `dlsym` with `RTLD_DEFAULT` searches everything the process has
loaded, including libraries this module never chose, so finding a symbol named
`relate_run` does not establish that it speaks for *this* engine. Hand a
foreign handle to a producer carrying its own statically compiled copy and it
segfaults - identical struct layout, entirely separate state - rather than
declining.

So `irgx_go_producer` asks the producer's own image whether it can resolve
the engine's opener: `dladdr` for the defining image, `dlopen(…, RTLD_NOLOAD)`
for a handle to just that image, then `dlsym` for `irgx_engine_open`. An
image that shares the engine resolves it, directly or through the dependency it
links it from; an image with a private copy cannot, because a private copy is
not exported. The invariant names no library and **lifts itself** the moment a
producer links the engine rather than duplicating it, which is why every library
we ship passes it untouched. It earns its keep for the ones we don't: these are
published packages, and the process namespace is open.

### Proving the Engine-Sharing Guard

`TestRoutingFollowsReachability` cannot prove this pair on its own - this module
links only the substrate, so with no product library loaded both of its columns
are false and the assertion holds vacuously. The guard's two real cases need a
second dylib the suite cannot link, so prove them against real images:

```c
/* probe.c — the guard, verbatim from producers.h */
static void *guard(const char *name) {
  void *found = dlsym(RTLD_DEFAULT, name);
  if (found == NULL) return NULL;
  Dl_info info;
  if (dladdr(found, &info) == 0 || info.dli_fname == NULL) return NULL;
  void *image = dlopen(info.dli_fname, RTLD_LAZY | RTLD_NOLOAD);
  if (image == NULL) return NULL;
  int shares = dlsym(image, "irgx_engine_open") != NULL;
  dlclose(image);
  return shares ? found : NULL;
}
```

**Refusal** - build a dylib that exports `relate_run` and links nothing:

```c
int32_t relate_run(void *e, uint32_t op, const void *p, void *c, void **o) { return 0; }
```

`dlopen` it, then `guard("relate_run")` must return `NULL`.

**Admission** - load the substrate first (as every binding does), then the real
producer, and `guard` must return the symbol:

```sh
cc -shared -o libfake.dylib fake.c && cc -o probe probe.c
./probe irregex/zig-out/lib/libirgx.dylib relate/zig-out/lib/librelate.dylib relate_run
```

Loading the substrate first is not incidental: the product dylibs currently bake
a **relative** rpath into the build tree's `.zig-cache`, so a bare `dlopen` of
`librelate.dylib` from an arbitrary directory fails to find
`@rpath/libirgx.dylib` on its own.

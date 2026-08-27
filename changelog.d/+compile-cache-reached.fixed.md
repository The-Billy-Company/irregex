- `compile` actually reaches the compile cache now. The cache existed and was
  never called: `compile` built a `Pattern` directly, so `_cached` was live code
  only for the module-level verbs. A compile costs ~57us where a cache hit costs
  ~2.5us, which is not a micro-optimization — it is the difference between
  `compile(p).search(s)` inside a loop being free and being unusable. That is
  the single most common shape a port lifts out of `re`, which caches for the
  same reason, so the one call anybody writes first fell off a cliff. Measured
  over 2000 repeated compiles of one pattern: 114.8ms before, 5.0ms after.

  Routed both `compile` and `_prepared` through one `_compiled` helper so the
  module-level verbs and the public entry point cannot disagree about caching
  again. Sharing a `Pattern` between callers is what the object was built for —
  it holds a pool of per-thread handles precisely so the handle's
  single-threaded contract survives being shared.

  Fixing that surfaced a second bug behind it. `TEXTUAL` admits `bytearray`,
  which has no hash and so cannot key an LRU, so the module-level verbs raised
  `TypeError: unhashable type` for a pattern `compile` took happily. An
  unhashable pattern is one to compile uncached, not one to refuse; `_compiled`
  now tests hashability and falls back to a direct construction.

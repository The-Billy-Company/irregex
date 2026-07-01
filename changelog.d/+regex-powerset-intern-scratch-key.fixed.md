**DFA compilation no longer churns the allocator on every subset-map probe, so
compiling a pathological pattern is ~9× faster** (`src/regex/powerset.zig`). The
determinizer interns each transition target into the subset map ~`states×ncls×2`
times; a genuine blow-up probes it ≈86k times before bailing at `max_states`.

- **`intern` now probes with a reusable scratch key** and heap-allocates a
  permanent key **only when the state proves genuinely new** — one alloc per
  interned state, not one alloc+free per probe. On a real fuzzer-surfaced
  cap-busting pattern this drops allocations from ≈86k to **4184** (≈ `nstates`),
  and per-compile time from **~175ms → ~19ms** ReleaseFast (~5s → ~0.37s Debug).
- Because interning duplicates is the common case in *any* determinization, the
  win applies to every DFA compile, not just the pathological bail path.

Proven with a before/after timing harness and pinned by a new deterministic
regression guard (`powerset_test.zig`): a counting allocator asserts a
cap-busting compile allocates `< 2×max_states` — it would jump ~20× if
alloc-per-probe ever returns. Full regex suite (177 tests, incl. the differential
Pike-VM fuzz oracle) stays green — no correctness change.

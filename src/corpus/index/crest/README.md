# `src/corpus/index/crest/` — Persisted CREST/Ridge Sidecar

The disk half of the **crest sieve**. Kernel math lives in
[`../../../kernel/math/crest.zig`](../../../kernel/math/crest.zig); theory
lives in [`../../../../research/crest/PROOF.md`](../../../../research/crest/PROOF.md).

Each indexed document contributes a top-`q` run spectrum over the fixed
48-predicate dictionary. Production writes `q=4`; query compilation defaults
to `q=1` until held-out evidence licenses promotion. The sidecar is staged
under the same `gens/<id>/` directory and published by the same `pair.gen`
flip as `index.gist` / `paths.list`.

## Why It Exists

Trigrams prove absence of required _literals_. Crest proves absence for
**literal-free class repetitions** (`\d+`, `[a-z]{8}`, …) that trigrams
concede.

Together they elide more `open(2)`s without changing answers.

## Files

- **`builder.zig`** computes exact q=4 spectra in parallel.
- **`sidecar.zig`** owns the fail-closed v6 codec and borrowed `View`.
- **`columnar.zig`** executes sparse gathers or dense SIMD filtering.
- **`planner.zig`** is the calibrated integer cost gate; `runtime.zig`
  applies it without making correctness depend on calibration.
- **`sidecar_test.zig`** proves q1/q4 round trips, overflow recovery,
  scalar/columnar parity, and adversarial refusal.

## Format V6

`GISTCRS6` stores predicate-major, rank-minor columns. Each column has a dense
`u8` base; values above 255 live in a sorted sparse `(doc_id, u16)` overflow
span named by the column directory. The 192-byte header binds document count,
`q`, shape, semantic schema, adaptive dictionary, and the index/path build
identity. A BLAKE3 artifact signet trails the body.

The schema preimage is canonical and architecture-independent. It includes
the ordered class names, all 256 byte-membership masks, the `u16` saturation
cap, the per-element interpretation, and the format version. A cache built
under different semantics therefore fails closed even when its dimensions
happen to match.

Older row-major magics are deliberately not upgraded in place; they decode as
null and the generation lifecycle rebuilds them.

The trailing seal exists because this is the one table whose corruption story
is a **missed** match: a ρ(d) that rots downward prunes a document that would
have matched, and every layout check still passes. `decode` therefore spends
the seal before publishing a `View`; a broken seal reads as "no sidecar".

## Invariants

- `decode` is zero-copy and returns **null** on any disagreement: format,
  schema/dictionary/build identities, q/shape/offsets, overflow ordering, or
  artifact seal.
- No admitted table is unproven. The ranked amend segment
  (`../trigrams/codicil.zig`, `GISTCOD3`) is sealed whole and rebuilt into an
  owned v6 view when overlaid.
- Soundness rounds down only (under-prune); see the kernel and
  `research/crest`.
- `runtime.apply` uses the calibrated planner when all three cost coefficients
  are present; absent or malformed calibration preserves the always-sieve
  behavior. Candidate filtering is sparse-gather below 25% density and dense
  SIMD otherwise.
- The resident session deliberately keeps live q=1 vectors: it owns the bytes,
  so it needs neither persisted columns nor a freshness binding.

## When To Edit

Edit here for on-disk framing, publish atomicity with the trigram pair, or
build parallelism. Changing the class family or the `ghat` math belongs in
`src/kernel/math/crest.zig` plus the research proof, not this codec alone.

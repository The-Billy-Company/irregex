# bench/rungs

**Per-mechanism production proofs.** One folder per accelerator this package
ships, each proving that specific mechanism earns its place under a real
workload. These are the rungs of the ladder the certificate climbs
([`src/kernel/regex/linear/ladder/`](../../src/kernel/regex/linear/ladder/README.md)),
and each folder is self-contained: link the real engine, race the real rung
against the real fallback, and fail closed on any disagreement before
reporting a speed number.

One of them points inward rather than outward. `automata/` races the DFA
against itself — one layout choice at a time, over the same automaton in the
same process — because a mechanism that lives inside the transition loop
cannot be attributed by racing the loop as a whole.

## The Rungs

- **[`automata/`](automata/README.md)** races the machine algebra against
  itself: automaton shape, and one layout choice priced against its
  predecessor.
- **[`crest/`](crest/README.md)** proves Layer E, the crest-sieve
  prune/speedup claim, with its own [`evidence/`](crest/evidence/README.md)
  release package.
- **[`sieve/`](sieve/README.md)** proves the quotient sieve's per-position
  soundness and Layer L's index-quality claim against csearch.
- **[`sliver/`](sliver/README.md)** proves the sub-trigram sliver tier and
  races this engine against zoekt and csearch at multi-GB scale.
- **[`shuffle/`](shuffle/README.md)** proves the transformation-composition
  rung — a byte-class DFA re-expressed as a SIMD reduction.
- **[`parabix/`](parabix/README.md)** proves the bit-parallel
  within-document scan rung.
- **[`sweep/`](sweep/README.md)** asks whether the interned-AST fused sweep
  is worth it, consumer by consumer, with the break-even table that decides.
- **[`patternid/`](patternid/README.md)** measures whether widening a
  determinizer's state key to a per-pattern bitmask multiplies states.
- **[`price/`](price/README.md)** mints, verifies, and regret-tests every
  coefficient the ladder's auction bids with.
- **`census/`** (`bench.zig`, read-only, no separate README) reads a
  `Regex`'s own admission evidence and prints which decider armed for every
  certificate probe class.

## Contract With The Ladder

Every rung here answers one question the ladder's auction
(`ladder/rungs.zig`) needs settled before it can trust that mechanism's bid:
does it agree with the fallback on every document, and is its price a
measurement rather than a guess. `price/` is the exception that proves the
others — it does not race a mechanism, it mints the coefficients the other
rungs' costed offers are priced in, so a rung's win margin here is real
cyc/B rather than a literal transcribed from bench prose.

A rung earning a place in the auction is therefore two separate proofs, and
this folder keeps them separate on purpose: this rung's own README proves
*this mechanism agrees with the engine and beats what it fronts*; `price/`
proves *the number it beats it by is measured, not invented*.

## What Moved Out

The dragnet/trawl tiers (`src/kernel/slate/`) are implemented here but
**raced in the kinship face**, whose Layer K is the multi-pattern claim: one
arm times this engine per byte against Vectorscan, the other times that
face's multi-pattern verb end to end. A rung lives with the certificate that
reads it, so the arm moved to the package that can run both halves; this
folder no longer carries a `multipattern/` sibling.

## When To Add A Rung

Add a folder here when a new mechanism needs its own agreement-plus-speed
proof against the production engine — not when a mechanism only needs a
model in `price.zig`, which belongs beside the other coefficients in
`price/mint.zig` instead. A new rung's bench links `@import("irregex")`
directly, never a reimplementation, and reports both the disagreement count
(must be zero) and the speed it earns before its coefficients are trusted.

# bench/rungs/price — The Currency The Auction Settles In

`zig build ladder-price` (from the repository root). Default runs `verify`
and `regret`; `mint` is opt-in.

The ladder's auction was structurally real and numerically invented. Every
machine that can represent a pattern published a cost, the cheapest won, and the
fallback bid like everyone else — but the costs were literals lifted out of bench
prose (`30_000` for any DFA, `4_400`/`8_000` for composition,
`9_000 + stripe_ops/8` for Parabix, `0.40 × a DFA` for the sieve). A literal
cannot be re-measured, cannot be wrong in a way anything notices, and cannot
tell a nine-state automaton from a nine-thousand-state one. This lane is what
makes [`ladder/price.zig`](../../../src/kernel/regex/linear/ladder/price.zig) a
measurement rather than a transcription.

## Three Verbs, And The Third Is The One That Matters

- **`mint`** times each coefficient alone against a fixed synthetic haystack,
  min-of-N, and prints the `Calibration` literal to paste back — two-point
  linear fits where a cost has both an intercept and a slope
  (`skip_verify`, `anchor_line`). It never fails; minting is how a number gets
  in.
- **`verify`** re-times them and reports drift outside ±45%, failing when a
  committed number is no longer this machine's.
- **`regret`** ignores the model. It builds every machine each slate pattern
  admits, measures each, and reports `chosen ÷ measured-fastest`, failing when
  the auction's pick is more than 1.25× slower than the best available.

`mint` is deliberately not the default, for the same reason the lint plane's
verifier may not produce the proofs it judges: a step that silently re-mints what
it was asked to check is laundering rather than gating.

Regret is the verb that earns the lane. Coefficients can each verify clean and
still compose into a bad decision, and only a run of every alternative would
notice. It is how the two real mispricings here were found — an anchored pattern
bid as a dense walk (**2.82×**, fixed by splitting `anchor_scan`/`anchor_line`
out of `dfa_step`) and a one-literal settle quoted at a three-needle Teddy price
(**12×**, fixed by splitting the settle coefficients by backend). Worst regret
across the slate is now **1.00×**.

## Which Host A Calibration Speaks For

A `Calibration` carries `hosts`, a list of `builtin.cpu.model.name` prefixes
it claims — `apple_` covers every M-series part, `raptorlake` covers only that
one. [`price.active`](../../../src/kernel/regex/linear/ladder/price.zig) walks
the minted rows in order and selects the first whose `fitsHost()` matches this
build's CPU model, falling back to `unmeasured` when none does.

This replaced a switch on `builtin.cpu.arch`, which was a wider claim than
anyone had checked: every AArch64 target read the Apple row, so a Graviton, an
Ampere part, and a Raspberry Pi all bid an M4 Max's numbers as if they shared
its ratios. Selecting on the CPU model instead means a target with no `-mcpu`
lands on `generic`/`x86_64` and matches nothing — a portable artifact never
bids numbers from whichever machine happened to compile it.

Two rows are minted today: `apple_m4` (an M4 Max, aarch64-macos) and
`raptorlake` (an Intel Core i5-13500, x86_64-linux). The i5 is a hybrid part —
P-cores at 4.8 GHz, E-cores at 3.5 — so `bench.zig` calls
[`pmu.requestPerformanceQos()`](../../apparatus/harness/README.md) before
timing anything and prints whether the pin took. A clock sampled on one core
class and coefficients timed on the other differ by 1.37× with nothing in the
output saying so, which is a wrong number rather than a missing one.

`raptorlake.compose32` is `0.000` on purpose, not an unmeasured hole: the
32-lane composition needs `TBL`'s two-register form, which has no SSSE3
counterpart, so `lanes.widest` caps at 16 and the machine cannot be built
there at all. `price.zig`'s
`zeroCoefficientsAreUnbuildableMachines` test is what holds that claim
against `lanes.armed`, so a zero coefficient can never silently read as a free
machine.

## Why It Is Cheap

Everything is fail-closed and nothing is heavy: an 8 MiB synthetic haystack per
probe, a handful of small patterns, no corpus load, no multi-gigabyte table. The
most expensive single thing in the lane is the footprint sweep's 1.4 MB
determinization of `\p{L}{6}[0-9]{6}`. The whole slate mints in about 1.2 s, and
the default gate — verify plus regret — takes about 1.8 s.

Four design choices carry that, and the trust in what it prints:

- **The clock is measured in-process**, through `assay`'s shared cadence rather
  than a second timing implementation. A target with no in-process cycle counter
  mints nothing and says so — which is exactly why `price.unmeasured` withholds
  `measured`, and why a vector rung consults that flag before it bids.
- **The haystack draw is flat over `a`–`y`**, so "this scan ran to the end" is a
  property of the alphabet rather than a hope about the pattern. The obvious
  realism upgrade — draw from the corpus's own measured byte shape — was tried
  and refuted: `dfa_step` moved 2% (inside the clock's noise) while `dfa_line`
  and `anchor_line` destabilized by 2.7× and 2.3×, because a haystack that is a
  fifth spaces puts variance on the very axis those two are separated over. The
  experiment is recorded in `probe.zig` rather than deleted.
- **A slope is fit across a slate of shapes, never read off one pattern.**
  `parabix_op` used to be a single pattern's stripe-op count divided into its
  measured cycles; `mint.zig` now runs eight shapes — from `^[a-z]+[0-9]+wxy$`
  to `^\b[a-z]+[0-9]+$` — and least-squares fits the coefficient across all of
  them, so one pattern's noise cannot masquerade as the slope. `build_per_table_byte`
  does the analogous thing on the build side: it walks a slate of table shapes
  and stops at the first that actually determinizes on this host, rather than
  assuming one hand-picked pattern compiles everywhere.
- **There is one instrument, not two.** A run builds a single `probe.Rig` — the
  allocator, the clock, and the round count — and every number in both tables is
  timed through it, which is what lets a regret row be compared against the
  coefficient it was minted from. The arms themselves are one generic
  `probe.Pass` over whichever machine is being timed, so the DFA, composition,
  Parabix, and lazy-DFA probes are the same measurement pointed at different
  kernels rather than four hand-written timing loops that could drift apart. A
  timing bug has exactly one place to live.

## The Tables It Prints

- **The footprint sweep.** Six patterns spanning a 19,000× table-size range,
  printed every run. It was built to fit a residency curve and refuted one
  instead: 1.4 MB and 216 B both walk at ~1.18 cyc/B on the Apple row. It stays
  because a host that really is cache-sensitive would show the knee here before
  anything silently mispriced, and the run says so if the spread ever exceeds
  1.60×. The range stops at 1.4 MB because that is where the engine stops, not
  where the slate ran out of ideas — `\p{L}{6}[0-9]{6}` is the largest of these
  that still fits `powerset.max_states`, the one ceiling `force_dfa` does not
  waive.
- **The coefficient table.** One row per field of `Calibration`, generated by
  reflection over the struct — so a coefficient added to the plane appears here
  without an edit, and one that could not be reached on this host is reported as
  unreachable rather than defaulted to zero. `hosts`, `machine`, `minted`, and
  `measured` are provenance, not quantities, and are skipped by the same
  reflection rather than printed as bogus rows.
- **The regret table.** One column per `rungs.Selection` member, also taken from
  the enum rather than listed. That is not hypothetical tidiness: the `settled`
  outcome arrived after this lane shipped, and it got a column instead of being
  judged in silence off the side of the table.

Each regret cell is `measured/bid` — both numbers, because the interesting
failure is a row where they disagree wildly and the **order** survives. That is a
mis-scaled model with a correct auction, and it is a different bug from a
well-scaled model picking wrong.

## Knobs

- **`PRICE_ROUNDS`** (default `9`) sets timed rounds per probe. Nine rather
  than five because three coefficients are *separations* — a slope across two
  measured points — and a difference carries both points' error.
- **`band`** (default `0.45`) is verify's drift band. Generous on purpose:
  this laptop routinely carries ten coworking agents, and a band tight enough
  to catch a 5% modeling error fails on contention alone, which is the failure
  mode that gets a gate switched off. Regret catches the errors that matter;
  this band catches a number that has changed **kind**.
- **`regret_ceiling`** (default `1.25`) is how much slower than measured-best
  the auction's pick may be.
- **`knee`** (default `1.60`) is how far the footprint sweep may spread before
  one `dfa_step` stops being the honest model.

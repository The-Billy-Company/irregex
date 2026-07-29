---
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/bench/rungs/price/bench.zig
    - pkg/kernels/irregex/bench/rungs/price/mint.zig
    - pkg/kernels/irregex/bench/rungs/price/probe.zig
    - pkg/kernels/irregex/bench/rungs/price/regret.zig
    - pkg/kernels/irregex/src/kernel/regex/linear/ladder/price.zig
  sentinels:
    - description: "three verbs, and the one that mints is deliberately not the default"
      file: pkg/kernels/irregex/bench/rungs/price/bench.zig
      contains:
        - "const Verb = enum { verify, mint, regret, all };"
        - "if (verb != .regret) failures += try coefficients("
        - "if (verb != .mint) failures += try auction("
    - description: "the coefficient table and the pasteable literal are both generated from the plane's own struct, so a field cannot arrive unmeasured or unprinted"
      file: pkg/kernels/irregex/bench/rungs/price/bench.zig
      contains:
        - "inline for (comptime std.meta.fieldNames(price.Calibration)) |name|"
        - "const arm_columns = std.enums.values(rungs.Selection);"
    - description: "the regret arms are sized from the Selection enum rather than a literal, which is how the settled outcome got a column instead of being judged off the side of the table"
      file: pkg/kernels/irregex/bench/rungs/price/regret.zig
      contains:
        - '[@typeInfo(rungs.Selection).@"enum".fields.len]?Arm'
    - description: "the probe clock is the shared assay cadence, not a second timing implementation"
      file: pkg/kernels/irregex/bench/rungs/price/probe.zig
      contains: ["assay", "pub const Clock"]
    - description: "the probe haystack draw is flat over a safe alphabet, and the corpus-shaped alternative is recorded as refuted rather than left as an open idea"
      file: pkg/kernels/irregex/bench/rungs/price/probe.zig
      contains: ["const alphabet_len = 'y' - 'a' + 1;", "Byte skew is not"]
---

# bench/rungs/price — the currency the auction settles in

`zig build ladder-price` (from `pkg/kernels/irregex/`). Default runs `verify`
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

## Three verbs, and the third is the one that matters

| Verb     | What it does                                                                                                                                                                                                                            | Fails when                                                  |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `mint`   | Times each coefficient **alone** against a fixed synthetic haystack, min-of-N, and prints the `Calibration` literal to paste back. Two-point linear fits where a cost has both an intercept and a slope (`skip_verify`, `anchor_line`). | never — minting is how a number gets in                     |
| `verify` | Re-times them and reports drift outside ±45%.                                                                                                                                                                                           | a committed number is no longer this machine's              |
| `regret` | Ignores the model. Builds **every** machine each slate pattern admits, measures each, and reports `chosen ÷ measured-fastest`.                                                                                                          | the auction's pick is >1.25× slower than the best available |

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

## Why it is cheap

Everything is fail-closed and nothing is heavy: one 8 MiB synthetic haystack, a
handful of small patterns, no corpus load, no multi-gigabyte table. The most
expensive single thing in the lane is a determinization of `\p{L}{12}`. The whole
slate mints in under three seconds and the default gate runs in about twenty.

Two design choices carry most of that:

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

## The tables it prints

- **The footprint sweep.** Six patterns spanning a 19,000× table-size range,
  printed every run. It was built to fit a residency curve and refuted one
  instead: 1.4 MB and 216 B both walk at ~1.18 cyc/B. It stays because a host
  that really is cache-sensitive would show the knee here before anything
  silently mispriced, and the run says so if the spread ever exceeds 1.60×.
- **The coefficient table.** One row per field of `Calibration`, generated by
  reflection over the struct — so a coefficient added to the plane appears here
  without an edit, and one that could not be reached on this host is reported as
  unreachable rather than defaulted to zero.
- **The regret table.** One column per `rungs.Selection` member, also taken from
  the enum rather than listed. That is not hypothetical tidiness: the `settled`
  outcome arrived after this lane shipped, and it got a column instead of being
  judged in silence off the side of the table.

Each regret cell is `measured/bid` — both numbers, because the interesting
failure is a row where they disagree wildly and the **order** survives. That is a
mis-scaled model with a correct auction, and it is a different bug from a
well-scaled model picking wrong.

## Knobs

| Knob             | Default | What                                                                                                                                                                                                                                                                                                                                |
| ---------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PRICE_ROUNDS`   | 9       | Timed rounds per probe. Nine rather than five because three coefficients are _separations_ — a slope across two measured points — and a difference carries both points' error.                                                                                                                                                      |
| `band`           | 0.45    | Verify's drift band. Generous on purpose: this laptop routinely carries ten coworking agents, and a band tight enough to catch a 5% modeling error fails on contention alone, which is the failure mode that gets a gate switched off. Regret catches the errors that matter; this band catches a number that has changed **kind**. |
| `regret_ceiling` | 1.25    | How much slower than measured-best the auction's pick may be.                                                                                                                                                                                                                                                                       |
| `knee`           | 1.60    | How far the footprint sweep may spread before one `dfa_step` stops being the honest model.                                                                                                                                                                                                                                          |

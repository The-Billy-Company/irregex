---
doc_radar:
  sentinels:
    - description: "the floor's two load-bearing widths and the target it is measured on"
      file: pkg/kernels/irregex/src/kernel/regex/linear/parabix/plane.zig
      contains: ["pub const width: usize = 128;", "pub const stripe: usize = 8;", "pub const on_neon"]
    - description: "the class compiler's two budgets, past which the DFA is the better rung"
      file: pkg/kernels/irregex/src/kernel/regex/linear/parabix/stencil.zig
      contains: ["pub const max_classes: usize = 6;", "pub const max_gates: usize = 40;"]
    - description: "the gate refuses at compile time, and every refusal names itself"
      file: pkg/kernels/irregex/src/kernel/regex/linear/parabix/admit.zig
      contains: ["pub const Decline = enum", "star_height", "unicode", "pub fn starHeight"]
    - description: "the marker chain's three operations — advance, keep, and MatchStar closure"
      file: pkg/kernels/irregex/src/kernel/regex/linear/parabix/parabix.zig
      contains: ["fn markers", "plane.addIn", "pub fn matchScalar"]
---

# linear/parabix — the bit-parallel within-document scan rung

**A DFA runs at load _latency_; this runs at ALU throughput.** A table walker
holds one automaton state and asks the L1 cache "where does this byte take me?"
once per byte — a loop-carried load whose dependence chain is as long as the
text. Invert it: hold a _marker stream_ (one bit per haystack position, "some
prefix of the pattern matched up to here") and a pattern step becomes a shift
and a mask over 1024 positions at once. Nothing is gathered, nothing is loaded
per byte, and the dependence chain is as long as the **pattern**.

Prior art: Cameron, Lin, Herdy, Wu, Amiri, Lin, Hull et al., [_Bitwise Data
Parallelism in Regular Expression Matching_](https://dl.acm.org/doi/10.1145/2628071.2628079)
(PACT 2014), and the [icGrep](https://github.com/icgrep) line of work at Simon
Fraser University. The byte-to-bit transposition, the character-class bit-plane
compilation, and `MatchStar` are all theirs. **No novelty is claimed here** —
this is a Billy-native rebuild of a published technique, and the adoption
verdict is written the way `research/ceiling/CLOSED.md` words one: the idea was
anticipated in the literature, the _engineering_ is ours, and the interesting
question is not whether it is new but whether it holds up in this tree. It
partly does; the honest table is below.

## The four files

| File          | What it owns                                                                                                                                                                                               |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `plane.zig`   | The inversion itself: `transpose` turns 128 bytes into the eight _basis planes_, plane k carrying bit k of every byte. Also the seam threading — `shiftIn`/`addIn` carry a marker across a block boundary. |
| `stencil.zig` | A byte set as a boolean circuit over those planes, by folding Shannon expansion. `[a-z]` is a handful of `and`/`or` gates; a scattered set pays for its scatter, which is correct.                         |
| `admit.zig`   | The gate. Lowers an AST to a fixed-size, allocation-free `Program` — or refuses, naming the reason.                                                                                                        |
| `parabix.zig` | The front door and the marker chain: advance (`(m & c) << 1`), keep (`?`), and closure (`MatchStar`, `(((m & c) + c) ^ c) \| m`, where the hardware carry chain does what a fixpoint loop would iterate).  |

Two widths are load-bearing and neither is a knob. **128-bit blocks**, because
that is the NEON register and because PACT 2014 measured the one bad case
getting _slower_ at 256. **`u128` as the marker type**, because AArch64 has no
`movemask` for Parabix's published long-stream addition but does have carry
flags, so a `u128` add lowers to `adds`/`adc`. The class circuits run in vector
registers and only the marker chain converts; that split is the whole port.

`stripe = 8` (1024 bytes transposed at once) _is_ measured, and against its own
first design: the register file argues for 4, but gate dispatch is scalar work
that a spilled vector load is cheaper than, and class throughput went
3.44 → 5.11 → 6.42 → 7.62 GB/s across stripes of 1, 2, 4, 8 before going flat at
16 while the transposition itself degraded out of L1.

## The gate — a DECIDER, refusing at compile time

The rung is a null field on any pattern it should not serve, so a refused
pattern never reaches the kernel; once armed it is **total**, and its answer is
the Pike VM's. Every reason is a named `Decline` with a witness test.

| Refusal                      | Why                                                                                                                                                                                                      |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `target`                     | Not little-endian AArch64. The claim was measured here; elsewhere the field is null and the ladder is unchanged.                                                                                         |
| `star_height`                | **Nested Kleene** — the published collapse (0.061 B/cycle), refused rather than merely slow.                                                                                                             |
| `unicode`                    | A codepoint class is multi-byte; membership is not a function of one byte's eight bits, so the basis-plane model does not apply.                                                                         |
| `unicode_assertion`          | A Unicode word boundary needs a decoded scalar/property stream. The byte-word superinstruction is sound only in ASCII mode, and a scalar gap loop measured below Pike, so it is not a costable fallback. |
| `newline_class`              | A class carrying `\n` would let one match span two lines and break the equivalence between a whole-buffer scan and the per-line model.                                                                   |
| `nullable`                   | The pattern can match the empty string, which `eol_empty` owns.                                                                                                                                          |
| `group_repeat`, `nested_alt` | A quantifier over something other than a single class, or an alternation below the top level — outside the marker model.                                                                                 |
| `too_complex`, `uncostable`  | Past the fixed-size program's capacity, or representable but above the operation ceiling — the parent gets the reason, not a false "unsupported" verdict.                                                |

Rivalry is no longer a refusal. The rung once declined whenever a cheaper
machine was already armed (`accel` / `class_run` / `literal`); under the
costed-offer admission (`../ladder/rungs.zig`) it instead builds its program,
publishes the stripe-operation count `stripeOps` derives, and lets the ladder
keep whichever offer is cheapest per byte. So it now **admits** the finite class
runs and ASCII assertions it used to refuse — the `step`/`opt`/`star` and
`word_boundary`/`line_start`… superinstructions in `Op` — and simply loses the
offer to a start-skip or the class-run kernel where one reads a twentieth of the
bytes. The refusals above are the shapes the marker model genuinely cannot
represent, not the ones another rung merely wins.

## Measured — Apple M4 Max, 64 MiB adversarial near-miss per row

`zig build parabix-rung`. Both baselines are the **shipped** engine in the same
process, interleaved round by round, min-of-9. `B/cyc` is normalized to
4.512 GHz against the pre-registered 0.277 baseline; the in-run clock was
3.85–3.91 GHz for this table. On a box carrying ten coworker agents that clock
can halve, which understates the absolute column while leaving the **ratio**
columns intact — the bench says so on its own summary line when it happens, and
the ratios are the load-invariant claim.

| row           | pattern                          | B/cyc     | vs ladder                        | vs DFA |
| ------------- | -------------------------------- | --------- | -------------------------------- | ------ |
| `digit-run`   | `[0-9]{4}-[0-9]{2}`              | **1.291** | 3.42×                            | 3.45×  |
| `chain3`      | `[a-z]+[0-9]+[a-z]+`             | 1.127     | 3.19×                            | 3.19×  |
| `counted`     | `[a-z]{4}[0-9]{2}[a-z]{4}`       | 1.102     | 3.11×                            | 3.11×  |
| `dot-lead`    | `.{4}[a-z]+[0-9][a-z]`           | 0.988     | 2.83×                            | 2.82×  |
| `chain5`      | `[a-z]+[0-9]+[a-z]+[0-9]+[a-z]+` | 0.971     | 2.76×                            | 2.76×  |
| `alnum-alt`   | `[A-Za-z]+[0-9]+[A-Za-z]+`       | 0.961     | 2.72×                            | 2.73×  |
| `ident-pair`  | `[a-z]+_[0-9]+_[a-z]+`           | 0.950     | 2.69×                            | 2.70×  |
| `emailish`    | `[a-z]+@[a-z]+\.[0-9]+`          | 0.854     | 2.43×                            | 2.41×  |
| `bounded`     | `[a-z][a-z0-9]{7,15}[0-9]`       | 0.729     | 2.10×                            | 2.11×  |
| `classrun`    | `[a-z]{6,}`                      | 1.304     | **0.31× ← boundary, gate holds** | 4.94×  |
| `memchr-skip` | `z[a-z]+[0-9]+`                  | 1.035     | **0.07× ← boundary, gate holds** | 0.08×  |

**The honest boundary.** The last two rows are lowered _past_ the gate, purely
to publish where this rung loses: against the class-run kernel it is 3.2× slower,
and against a singleton first byte that `memchr` skips, **14× slower**. Both are
refused by the real gate — the row below each in the bench output proves it. A
rung with no losing row is hiding one.

**Phase ladder** (`chain3`): transposition alone 14.06 GB/s (3.12 B/cyc), plus
class streams 7.55 GB/s (1.67 B/cyc), whole scan 5.08 GB/s. Transposition is the
cheap half; the class phase is where the throughput actually goes — and the
section below is about what that phase does *not* spend it on, because the first
answer written here was wrong.

## What did not survive contact

The research lane measured **3.3–4.5 B/cycle**; in-tree, on the same shapes,
this is **0.73–1.29 B/cycle** — about 3× short. The gap is not the haystack
(1 MiB in-L2 and 64 MiB streaming measure identically, so it is not memory
bound) and not the transposition (which reproduces at 3.1 B/cyc). It is the class
phase. Two things about that phase are counter-intuitive enough that both have
now been got wrong once, so they are recorded here rather than rediscovered.

**It is not the gate interpreter.** The first diagnosis written here blamed one:
"a gate whose two operand references are runtime values cannot keep its basis in
registers, so each gate pays ~16 vector loads and 8 stores around 8 ALU ops."
That is true of `.fallback` circuits and irrelevant to every row of the table
above. Each class in the measured family is a single byte or a couple of
contiguous ranges — `one`, `ranges1`, `ranges2` — and **every catalogue shape
returns from `Circuit.eval` before the gate loop**, so `Scratch` and the per-gate
dispatch are dead code for these patterns. An emitter aimed at them would
specialize something the benchmark never executes.

**It is the grain, not the operand refs.** The class phase does spill, heavily,
and specializing the constants does not stop it. Compile a comptime-specialized
`between` with every bound baked in — no dynamic refs left at all — and at stripe
grain it still spills, per block of haystack:

| class | shape | vector ops | spills, stripe grain | spills, block grain |
|---|---|---|---|---|
| `[0-9]` | `ranges1` | 6 | 0.5 | 0 |
| `[a-z]` | `ranges1` | 13 | 6 | 0 |
| `[A-Za-z]` | `ranges2` | 20 | 8 | 0 |
| `[0-9A-Z_a-z]` | `ranges4` | 34 | 25 | 0 |

The cause is register capacity: `plane.Wide` is eight q-registers, so a `[8]Wide`
basis is 64 of a 32-register file before a single class output is held live beside
it, where `[8]Basis` at block grain is eight. Vector work per block is identical
across grains (1.00–1.02×) — the grain moves spill traffic and nothing else. On
the real build the striped path carries **3,224 spill instructions against 6,446
vector ops**, where `Parabix.block` carries 22 against 1,099. (Method:
`zig build-obj -O ReleaseFast -femit-asm` over `src/root.zig`, then count
instructions per `.cfi` proc with stack-relative accesses split out. No
benchmark, so these are static counts, not cycles.)

**So the lane is harder than "write a specialized emitter".** Specializing the
constants is necessary and not sufficient: the table above is already fully
specialized and still spills. The other half is the grain, and that half is
**closed** — `plane.zig` records the register-file argument being derived,
benched and lost, because gate dispatch is scalar work that a spilled vector load
is cheaper than. Whoever opens this lane should budget against both halves and
should not expect 3× from specialization alone. The coefficient this all feeds,
and the number a reopening has to beat, is recorded in
`research/ceiling/CLOSED.md` entry 1.

What the rung _does_ deliver against the engine users actually get is
**2.1–3.4× the shipped ladder** across the admitted family, byte-identical on
188,334 corpus document verdicts and 23,220 randomized differential verdicts
against the Pike VM.

## Correctness — three oracles, weakest first

`parabix_test.zig` holds `transpose` to its scalar definition, a compiled
circuit to `ByteSet.has` over random sets, and the whole rung to the **Pike VM**
over randomized patterns and haystacks at line grain and document grain, with
block and stripe boundaries deliberately straddled. Beneath the Pike
differential sits `matchScalar` — the marker semantics read straight off the
instruction list, quadratic and obviously correct — so a disagreement localizes
to the block machinery rather than to the lowering.

# linear/parabix — the bit-parallel within-document scan rung

**A DFA runs at load latency; this runs at ALU throughput.** A table walker holds one automaton state and asks the L1 cache "where does this byte take me?" once per byte — a loop-carried load whose dependence chain is as long as the text. Invert it: hold a *marker stream* (one bit per haystack position, "some prefix of the pattern matched up to here") and a pattern step becomes a shift and a mask over 1024 positions at once. Nothing is gathered, nothing is loaded per byte, and the dependence chain is as long as the *pattern*.

Prior art is Cameron, Lin, Herdy, Wu, Amiri, Lin, Hull et al., [Bitwise Data Parallelism in Regular Expression Matching](https://dl.acm.org/doi/10.1145/2628071.2628079) (PACT 2014), and the [icGrep](https://github.com/icgrep) line of work at Simon Fraser University. The byte-to-bit transposition, the character-class bit-plane compilation, and `MatchStar` are all theirs.

No novelty is claimed here — this is an in-tree rebuild of a published technique, and the adoption verdict is written the way `research/ceiling/CLOSED.md` words one: the idea was anticipated in the literature, the engineering is ours, and the interesting question is not whether it is new but whether it holds up in this tree. It partly does; the honest boundary is below.

## The Four Files

`plane.zig` owns the inversion itself: `transpose` turns 128 bytes into the eight *basis planes*, plane *k* carrying bit *k* of every byte, and `shiftIn`/`addIn` carry a marker across a block boundary.

`stencil.zig` compiles a byte set into a boolean circuit over those planes, by folding Shannon expansion. `[a-z]` is a handful of `and`/`or` gates; a scattered set pays for its scatter, which is correct.

`admit.zig` is the gate. It lowers an AST to a fixed-size, allocation-free `Program`, or refuses, naming the reason.

`parabix.zig` is the front door and the marker chain: advance (`(m & c) << 1`), keep (`?`), and closure (`MatchStar`, `(((m & c) + c) ^ c) | m`, where the hardware carry chain does what a fixpoint loop would iterate).

Two widths are load-bearing and neither is a knob. 128-bit blocks are load-bearing because that is the NEON register and because PACT 2014 measured the one bad case getting slower at 256. `u128` as the marker type is load-bearing because AArch64 has no `movemask` for Parabix's published long-stream addition but does have carry flags, so a `u128` add lowers to `adds`/`adc`. The class circuits run in vector registers and only the marker chain converts; that split is the whole port.

A stripe of 8 (1024 bytes transposed at once) is measured, and against its own first design. The register file argues for 4, but gate dispatch is scalar work that a spilled vector load is cheaper than: class-stream throughput on the headline pattern went 3.44 → 5.11 → 6.42 → 7.62 GB/s across stripes of 1, 2, 4, 8, then flattened at 16 while the transposition itself got worse (14.0 → 12.3 GB/s) as the working set left L1.

## The Admission Gate

The rung is a null field on any pattern it should not serve, so a refused pattern never reaches the kernel; once armed it is total, and its answer is the Pike VM's. Every reason is a named `Decline` with a witness test.

- **`target`.** Not little-endian AArch64. The claim was measured here; elsewhere the field is null and the ladder is unchanged.
- **`star_height`.** Nested Kleene — the published collapse, measured at 0.061 B/cycle — refused rather than merely slow.
- **`unicode`.** A codepoint class is multi-byte; membership is not a function of one byte's eight bits, so the basis-plane model does not apply.
- **`unicode_assertion`.** A Unicode word boundary needs a decoded scalar/property stream. The byte-word superinstruction is sound only in ASCII mode, and a scalar gap loop measured below Pike, so it is not a costable fallback.
- **`newline_class`.** A class carrying `\n` would let one match span two lines and break the equivalence between a whole-buffer scan and the per-line model.
- **`nullable`.** The pattern can match the empty string, which `eol_empty` owns.
- **`group_repeat`, `nested_alt`.** A quantifier over something other than a single class, or an alternation below the top level — both outside the marker model.
- **`too_complex`, `uncostable`.** Past the fixed-size program's capacity, or representable but above the operation ceiling. The parent gets the reason, not a false "unsupported" verdict.

Rivalry is no longer a refusal. The rung once declined whenever a cheaper machine was already armed (`accel` / `class_run` / `literal`); under the costed-offer admission (`../ladder/rungs.zig`) it instead builds its program, publishes the stripe-operation count `stripeOps` derives, and lets the ladder keep whichever offer is cheapest per byte.

So it now admits the finite class runs and ASCII assertions it used to refuse — the `step`/`opt`/`star` and `word_boundary`/`line_start`… superinstructions in `Op` — and simply loses the offer to a start-skip or the class-run kernel where one reads a twentieth of the bytes. The refusals above are the shapes the marker model genuinely cannot represent, not the ones another rung merely wins.

## Measured Performance

`zig build parabix-rung` races this rung against two baselines, the shipped `Regex.docMatch` ladder and the bare `Dfa.docMatch`, in the same process, interleaved round by round, min-of-9, over an adversarial near-miss haystack per row. `B/cyc` is normalized to 4.512 GHz against the pre-registered 0.277 baseline; the in-run clock varies with machine load, which understates the absolute column while leaving the ratio columns — both arms, same buffer, interleaved — intact.

Across the admitted flat class-chain family (`digit-run`, `chain3`, `counted`, `dot-lead`, `chain5`, `alnum-alt`, `ident-pair`, `emailish`, `bounded`, plus the assertion-carrying `word-gap` and `line-gap` rows the bench also races), the rung's own run measured 2.1–3.4× the shipped ladder and a comparable margin over the bare DFA.

Two rows are lowered past the gate on purpose, to publish where this rung loses rather than hide it: against the class-run kernel — which answers at load bandwidth by reading a twentieth of the buffer — it measured roughly 3× slower, and against a singleton first byte that `memchr` skips entirely, an order of magnitude slower. Both are refused by the real gate; a rung with no losing row is hiding one.

The phase ladder on the headline shape splits transposition alone at roughly 14 GB/s (about 3 B/cyc) from transposition plus class streams at roughly 7.5 GB/s (about 1.7 B/cyc), with the whole scan landing lower still. Transposition is the cheap half; the class phase is where the throughput actually goes, and the next section is about what that phase does not spend it on, because the first answer written here was wrong.

## The Class-Phase Register Ceiling

The research lane measured 3.3–4.5 B/cycle; in-tree, on the same shapes, this rung measures roughly 0.7–1.3 B/cycle — about 3× short. The gap is not the haystack (an in-L2 buffer and a streaming one measure identically, so it is not memory bound) and not the transposition (which reproduces the paper's number). It is the class phase, and two things about that phase are counter-intuitive enough that both have now been got wrong once, so they are recorded here rather than rediscovered.

It is not the gate interpreter. The first diagnosis written here blamed one: a gate whose two operand references are runtime values cannot keep its basis in registers, so each gate pays roughly sixteen vector loads and eight stores around eight ALU ops. That is true of `.fallback` circuits and irrelevant to every row of the measured table above, because each class in the measured family is a single byte or a couple of contiguous ranges, and every catalogue shape returns from `Circuit.eval` before the gate loop runs at all. `Scratch` and the per-gate dispatch are dead code for these patterns; an emitter aimed at them would specialize something the benchmark never executes.

It is the grain, not the operand references. The class phase spills heavily, and specializing the constants does not stop it. A comptime-specialized `between` circuit with every bound baked in, no dynamic refs left at all, still spills at stripe grain: `[0-9]` pays half a spill per block, `[a-z]` pays six, `[A-Za-z]` pays eight, and `[0-9A-Z_a-z]` pays twenty-five, where all four pay zero at block grain. The cause is register capacity — `plane.Wide` is eight q-registers, so a `[8]Wide` basis is sixty-four of a thirty-two-register file before a single class output is held live beside it, where `[8]Basis` at block grain is eight. Vector work per block is identical across grains, so the grain moves spill traffic and nothing else.

So the lane is harder than "write a specialized emitter." Specializing the constants is necessary and not sufficient, because a fully specialized circuit still spills. The other half is the grain, and that half is closed: `plane.zig` records the register-file argument being derived, benched, and lost, because gate dispatch is scalar work that a spilled vector load is cheaper than. Whoever reopens this lane should budget against both halves rather than expecting the whole 3× from specialization alone; the coefficient it feeds, and the number a reopening has to beat, is recorded in `research/ceiling/CLOSED.md` entry 1.

## Correctness

`parabix_test.zig` holds three oracles, weakest first: `plane.transposeScalar` checks the transposition against its own scalar definition, a compiled circuit is checked against `ByteSet.has` over random sets, and the whole rung is checked against the Pike VM over randomized patterns and haystacks at line grain and document grain, with block and stripe boundaries deliberately straddled.

The line-grain differential asserts at least 100 admitted patterns and at least 5,000 verdicts, so a run that admitted nothing cannot pass silently; the document-grain differential asserts at least 50 documents. Beneath the Pike differential sits `matchScalar`, the marker semantics read straight off the instruction list, quadratic and obviously correct, so a disagreement localizes to the block machinery rather than to the lowering.

`bench/rungs/parabix/bench.zig` adds a fourth, corpus-scale check outside the unit tests: every admitted row runs over every document the resolved corpus holds and compares against the shipped ladder, a single disagreement failing the run. That corpus is whatever `gist.corpus.resolveRoots` resolves on the machine running the bench, so its document count is a property of the checkout, not a fixed figure this file can pin.

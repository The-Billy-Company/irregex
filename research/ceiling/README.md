# Ceiling — How Fast A Scan Can Go, And Which Roads Are Shut

The other dossiers in `research/` each defend something built. This one defends a number and a map: the speed limit our scanning engines actually run into, why it is the limit, and which routes past it have been tried and closed. It exists so the same dead ends are not rediscovered annually.

Unlike `crest/`, `gist/research/gist/`, and `relate/research/relate/`, no road here defends a shipped novel technique. The shipped accelerator tier (composition, transposed bitstreams, the class-run sieve) applies known ideas to escape the bound this document measures. Read each road below as the investigation record that led to those rungs, not as a description of the engine's current form.

## The Limit, Measured

The measurement is one probe over a 64 MiB haystack, every pattern chosen to miss so that `docMatch` must retire every byte and an early return cannot flatter the number, on an Apple M4 Max P-core.

Throughput is the measurement; bytes/cycle is a derived figure, so read the GB/s column and treat bytes/cycle as a band. A later lane measured this box's actual clock at 3.27–3.92 GHz under contention rather than the 4.512 GHz nominal these numbers were first normalized against. Every ratio in this dossier is unaffected, because every row was measured on the same machine, but any single absolute bytes/cycle figure was understated by 15–38% and has been re-derived here.

- **A start-acceleration skip** (`memchr`-style) reaches 40.0–40.6 GB/s, 10.2–12.4 bytes/cycle, but that row is the top of a 30× range rather than a fixed value: the same code path measures 7.667 bytes/cycle on the rare byte `{z}` and 0.302 on the common byte `{e}`, and an armed skip on two common letters measures 0.256, slower than arming nothing. The arming predicate counts start bytes and never asks how often they occur, so which end of that range you land on is currently decided by a byte count rather than by rarity.
- **No skip available**, a 9-state table DFA, reaches 1.250 GB/s. A 73-state DFA over the same shape reaches 1.245 GB/s, essentially identical.
- **No skip, on-demand determinization** reaches 0.623 GB/s.

The two no-skip rows being equal across an eight-fold difference in automaton size is the whole finding, and it is a ratio, so the clock correction leaves it untouched. 1.25 GB/s is 2.6–3.1 cycles/byte, close to one L1 load-to-use latency. The loop `state = trans[state + class[byte]]` cannot issue the next load until the previous one lands, so the cost is the serial dependency chain and not the table; shrinking the automaton or improving the table layout cannot help. Only a change of bound type, from latency-bound to throughput-bound, moves this number.

That prediction has since been tested directly, and it held. The engine grew a byte-indexed mirror of the transition tables that folds the class column into the row and deletes one load per byte, precisely the better table layout the prediction says cannot help on the serial chain, and it does not: `bench/bounds/port` measures 4.59 ns/step classed against 4.62 mirrored, because `class[byte]` depends on the document byte rather than on `state` and was never on the critical path. The same mirror is worth about 1.28× on the shipped document walk, which bursts four lines in lockstep, exactly the change of bound type the prediction names as the only thing that moves the number.

For calibration, a reference table DFA measures 0.15 bytes/cycle on Skylake (Langdale), so this engine is already roughly 2.1–2.5× better than the naive baseline. The claim is that we are at the wall, not behind it.

## What The Bound Change Bought

Two rungs have since been built to escape the dependency chain: one turns the step into a register shuffle instead of a load, and the other avoids stepping at all.

- **Transformation composition** reaches 1.94 bytes/cycle, because `(f∘g)[i] = f[g[i]]` is one `vqtbl` instruction, and re-associating the fold this way is a reduction rather than a scan.
- **Transposed class bitstreams** reach 0.73–1.29 bytes/cycle, because there is no per-byte state at all; 128 bytes advance as 8 planes.
- **The table DFA** measured above stays at 0.32–0.38 bytes/cycle.

The escape is real and worth 2–6×, and the two rungs hit different ceilings once out: composition stops at the `TBL4` instruction once the automaton exceeds 31 states, while the bitstream path is currently held to roughly a third of its own limit by a class-circuit interpreter and wants an emitter. Neither is anywhere near L1 latency any more, which is the point: the wall this dossier measures is real, and it is specific to the one loop, not to matching in general.

## The Two Regimes, And Why The Ladder Is Shaped This Way

The roughly 32× gap between the accelerated and unaccelerated rows is the single most important fact about scan performance here, and it explains the dispatch ladder better than any argument about automaton quality. When a literal is long enough to arm a skip, the engine is in `memchr` territory and nothing else matters. When the pattern is literal-free, a class repetition like `[0-9a-f]{12}` or `\p{Greek}{3}`, no skip can arm, the trigram index reports every document as a candidate, and the scan pays full freight.

That literal-free cell is attacked at two stages that multiply rather than compete. The document stage is `crest/`, shipped, pruning whole files with integer compares and no byte scan (96.4% pruned on `[0-9a-f]{12}`). The scan stage is the ladder's accelerator tier: three optional rungs that each escape the dependent load rather than shorten it, admitted per pattern and absent when they cannot help.

Closing that second stage produced one result worth keeping above every throughput number in this dossier: the rungs' arming rate matters more than their peak. Composition arms on most realistic field patterns and is the tier's whole measured value; the bitstream rung's admission window turned out to be a strict subset of composition's, and the sieve's own best pattern never reaches it because the class-run kernel takes that shape first. A rung that is 12× faster on patterns nobody writes is worth less than one that is 6× faster on patterns everybody writes, and only integration could see that, not the research phase or the build phase.

## What The Field Has Reached

An adversarial survey with a kill mandate found three nearly disjoint performance peaks in the field, and nobody is simultaneously feature-complete and at the throughput frontier. `memchr`'s AVX2/AVX-512 rare-byte scan reaches roughly 14–30 bytes/cycle when one rare byte exists; this engine's accelerated path reaches 8.87–8.99; Sheng16 reaches 0.98 for automata of 16 states or fewer; Parabix-style bitstream engines reach 0.63–1.6 but collapse on nested Kleene; and this engine's unaccelerated path, at 0.277, sits above the reference table DFA's 0.15 but below everything that has left the table-DFA model entirely. Roughly one byte per cycle is the accepted wall for a general table DFA, and it is microarchitectural rather than asymptotic: every published general 100–10,000-state DFA that beats it does so by leaving the model, through a shuffle table, a literal skip, or bitstreams.

Completeness tells the same disjoint-peaks story from the other side. No surveyed engine combines full Boolean intersection and complement, real captures, unbounded lookaround, bounded repetition without blowup, Unicode, and Hyperscan-class multi-pattern throughput; the closest points are completeness without speed, speed without completeness, and balanced single-pattern automata. The full survey, including the completeness table and the Unicode and benchmarking caveats, is in [`PRIOR_ART.md`](PRIOR_ART.md).

## Which Routes Past The Limit Are Shut

[`CLOSED.md`](CLOSED.md) records three proposed escapes and what actually closed each one, always separating the novelty verdict (was this published already) from the adoption verdict (does it earn its keep here), because those two questions have independent answers.

Cascade decomposition into parallel prefix scans was refereed on the theorem that throughput is governed by automaton depth rather than state count; measured, depth tracks state count almost exactly, so the idea died on its own premise rather than on a citation. What survived is a real result: transformation composition, the same morphism with nothing decomposed, measured 1.94 bytes/cycle against a same-machine 0.276 baseline. A follow-up lane later found the depth-versus-state-count gap had been measured with the wrong denominator, closed it with equality using a saturating-counter factor, and then re-priced the front-end this would need against the shipped Parabix ladder; the realizable population in this corpus is five distinct patterns, and none of them clears the current budget by enough to justify a new rung.

A unified register algebra for counting and captures was found already published three times over, under the names copyless cost-register automata and the single-use restriction, and the composition it proposed for tagged captures turns out to be false rather than merely known: tagged determinization requires register replication that counting-set automata must forbid. It was declined on the census, not the citations, because the pathological bounded-gap shape it would fix barely appears in this corpus.

The quotient sieve, a conjunction of small SP-partition quotients as a sound gather-free prefilter, lost its priority claim to three independent prior publications but kept its engineering case; it measured zero soundness violations over 671 million byte-positions and 2.5–3.0× the full DFA's kernel speed, and it is the one entry on the page marked to be built.

## Where The Compiler Cost More Than The Algorithm

[`LOWERING.md`](LOWERING.md) records three places where identical semantics, spelled two ways, cost 1.6–2× or more purely in how LLVM lowers them: a `@Vector(8, u128)` bitstream that scalarizes into 16 GPR operations on AArch64 where `@Vector(128, u8)` compiles to one vectorized instruction, a composition-rung table whose throughput improved monotonically as its stripe width grew past the point where register pressure says stop, and an adjacent-field table read that cost two loads per byte until the fields were folded into one `readInt(u64)`. Every bytes/cycle number elsewhere in this dossier is a property of an algorithm and a spelling together, and the spelling is not free.

## Companion Documents

[`PRIOR_ART.md`](PRIOR_ART.md) answers what the field has achieved, at what throughput, with what feature set, and where the plane is genuinely empty.

[`CLOSED.md`](CLOSED.md) answers which routes past the limit were tried and shut, each with the citation that shuts it and the residue still open.

[`LOWERING.md`](LOWERING.md) answers where the compiler cost more than the algorithm did, each a spelling of identical semantics that LLVM lowers 1.6–2× apart.

## Where The Production Code Lives

The tier that admits a rung and the order it consults them in lives at [`../../src/kernel/regex/linear/ladder/`](../../src/kernel/regex/linear/ladder/). The three escapes, each with its own measured limit, live at [`../../src/kernel/regex/linear/shuffle/`](../../src/kernel/regex/linear/shuffle/), [`../../src/kernel/regex/linear/parabix/`](../../src/kernel/regex/linear/parabix/), and [`../../src/kernel/regex/linear/sieve/`](../../src/kernel/regex/linear/sieve/).

The two determinization drivers and their bounds live at [`../../src/kernel/regex/linear/dfa/`](../../src/kernel/regex/linear/dfa/). The document-stage sieve is [`../../src/kernel/math/crest.zig`](../../src/kernel/math/crest.zig), documented in full in the sibling [`crest/`](../crest) dossier. The certificate whose `regex-classcount` row is the 100%-candidate hole named above lives in the sibling `gist` repository's `bench/certificate/`.

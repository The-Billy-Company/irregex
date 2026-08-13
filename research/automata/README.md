# Automata — The Machine Algebra, And Beating `regex-automata`

Everything in this engine that constructs, determinizes, reduces, or reverses a finite automaton is one subject, and today it is scattered across six folders that each own a slice of it. This dossier does two things: it states where that subject belongs as a package, and it opens the competitive program against the reference implementation of the same subject, BurntSushi's Rust [`regex-automata`](https://docs.rs/regex-automata), cloned for study at `upstream/regex/` (gitignored; `git clone --depth 1 https://github.com/rust-lang/regex`).

The competitive posture is not imitation. The crate is the best engineering in this field and it is also, in its author's own annotations, a pile of admitted approximations: a non-minimal alphabet he flags as future work, a minimizer he calls slow and ships disabled, a literal extractor he calls "a black art", a memory pool he says he is "not entirely happy with". Those are the seams. Where this engine diverges it must be because a better answer was measured, and the divergence gets written down.

## Where The Package Belongs

The package starts at [`src/kernel/regex/linear/automata/`](../../src/kernel/regex/linear/automata/README.md), one level deeper than this section originally proposed, for a reason worth recording rather than quietly editing away.

Hoisting it out as `src/kernel/automata/`, a peer of `regex/`, looked appealing on the theory that automata theory is alphabet-agnostic and the Aho-Corasick machine in `scan/` is an automaton too. It is the wrong call. Every construction here consumes `syntax.State`, the one NFA instruction type, and the whole purpose of sealing `kernel/regex` behind `regex.zig` is that a second grammar inside this tree once disagreed with the first about `\<` and silently pruned two thirds of a matching corpus. Hoisting the constructions out would either drag `syntax/` with them or force a package below the seal to import through it, so the theory stays behind the same door as the grammar it is a theory of.

The first real occupant then decided the depth. The operations shared by nature rather than by accident are shared between the two determinization roads, and both of those live under `linear/`, as does the `Dfa` type they produce. A folder hoisted to `regex/automata/` would have to import downward into `linear/dfa/dfa.zig` for the type it operates on, inverting the layering to buy nothing. So the package lands where its dependencies already are, and its membership rule is one sentence: a file belongs there when it operates on an automaton and cannot say which road produced it.

That is deliberately narrower than "shared". It admits `freeze.zig` (the three ordered layout passes, previously transcribed once per road) and the refinement core discussed below; it excludes `program/`'s Thompson lowering, which produces an automaton rather than operating on a finished one. `dfa.zig`'s own path in particular stays pinned, since it is recorded inside the frozen benchmark manifests under the face package's `bench/certificate/artifact/`, which are evidence rather than source.

## The Shape It Grows Into

The cut, still mostly proposed rather than landed, is by layer rather than by feature. `automata/` would own the machine algebra: what a machine is, how it is built from an AST, how it is determinized, how it is reduced, how it is reversed. The existing folders keep the executors: the byte loops, the SIMD kernels, the cost policies that decide when to build what.

```text
automata/
  automata.zig      the door
  alphabet/         what a transition is indexed BY
                    byte-class refinement · minterm partition · the UTF-8→minterm decoder
  build/            AST → machine
                    Thompson lowering · codepoint Thompson · reversal
  determinize/      machine → deterministic machine
                    the gap predicate · set subset construction · predicate subset
                    construction · priority-ordered construction · one-pass-with-effects
  reduce.zig        machine → the machine it MEANS
                    Moore row refinement · column coincidence (landed, one file)
```

Most of that has not been done, and it earns its way in one occupant at a time. What exists today holds the operations that pay for the boundary the moment they move: `determinize/`'s shared layer, minus the two constructions that are genuinely different algorithms, plus `reduce.zig`. The remaining boxes are a hypothesis about where the code wants to live, and a relocation with no measurement behind it is a diff, not an improvement.

## Why `reduce.zig` Is One File, Not Two

The natural first guess was one core with two stopping conditions: Moore refinement for minimization, and the same machinery climbed further for the sieve's over-approximation. That guess is wrong, and finding out why is the useful part.

Partitions of a DFA's state set with the substitution property, meaning `p ≡ q` implies `δ(p,b) ≡ δ(q,b)` for every byte, form a lattice under refinement (Hartmanis & Stearns, *Algebraic Structure Theory of Sequential Machines*, 1966). Moore refinement descends that lattice, splitting from the accept partition down to the Myhill-Nerode congruence, whose quotient is the minimal DFA for the same language. The sieve's harvest ascends it instead, unioning from one merged pair up to the least closed partition above it, so its quotient accepts a superset: a machine that can refute but never confirm. Opposite direction, opposite extremum, so different machinery: refinement wants a signature hash per pass, closure wants a disjoint-set forest, and the sieve deliberately refuses to respect the accept partition at all. A shared core would be an enum switch over two disjoint loops agreeing on a predicate and nothing else, so `sieve/quotient.zig` stays where it is.

The core that did land is a different, better one. A finished dense table is over-refined in two axes rather than one: rows, where no suffix separates two states, and columns, where no state routes two byte classes differently. Merging rows is what makes columns coincide, so the two only compose in that order, which is a real reason for one file where "two stopping conditions" was not. `automata/reduce.zig` owns both, and `symbolic/minimize.zig` folded into it. Neither RE2 nor `regex-automata` has the sieve's half at all; `minimize.rs` exists, ships disabled, and has no over-approximating sibling, so this engine ships one more idea than either, just not as a separate function.

The policy halves stay where they are. The Sheng width budget and the stationary-distribution selectivity estimate are about one rung's economics rather than lattices, so they belong beside the kernel they gate.

## What This Engine Already Has

Three constructions in this engine have no counterpart in `regex-automata` at all: the predicate alphabet, the SP quotient, and the two register-resident rungs described in the ceiling dossier.

- [`compile/compile.zig`](../../src/kernel/regex/compile/compile.zig) is Thompson AST-to-NFA lowering over bytes.
- [`compile/onepass.zig`](../../src/kernel/regex/compile/onepass.zig) is the one-pass property, that no epsilon path converges twice, and the deterministic-with-side-effects table it licenses.
- [`linear/dfa/subset.zig`](../../src/kernel/regex/linear/dfa/subset.zig) is byte-class refinement by transition set, the assertion-resolving epsilon-closure, subset interning, and the visit meter.
- [`linear/dfa/powerset.zig`](../../src/kernel/regex/linear/dfa/powerset.zig) is eager determinization to fixpoint, with premultiplication and start acceleration.
- [`linear/dfa/lazy.zig`](../../src/kernel/regex/linear/dfa/lazy.zig) is on-demand determinization with a cache-generation reset policy and a sticky decline.
- [`linear/symbolic/`](../../src/kernel/regex/linear/symbolic) is determinization over a predicate alphabet of minterms, then a product with a UTF-8 decoder to land back on a byte table.
- [`linear/automata/reduce.zig`](../../src/kernel/regex/linear/automata/reduce.zig) is both of a finished table's over-refined dimensions: Moore row refinement, then column coincidence.
- [`linear/caliper/`](../../src/kernel/regex/linear/caliper) is priority-ordered determinization with match dominance, leftmost-first spans at one table lookup per byte, plus program reversal.
- [`linear/sieve/quotient.zig`](../../src/kernel/regex/linear/sieve/quotient.zig) is the SP-lattice harvest and its conjunction selection.
- [`linear/shuffle/`](../../src/kernel/regex/linear/shuffle) is the transformation monoid: a byte becomes a map on the whole state set, folded by a SIMD shuffle.
- [`linear/parabix/`](../../src/kernel/regex/linear/parabix) is bit-parallel simulation, one marker bit per position, a pattern step as a shift and a mask.
- [`linear/pike/`](../../src/kernel/regex/linear/pike) is the NFA simulation that stands behind all of it as oracle and fallback.

A fourth advantage is structural rather than a new construction: this engine's boolean determinizer interns on the unordered NFA-state set, while `regex-automata` always keeps priority order, so for a yes/no search this engine's automaton can be strictly smaller on the same pattern. The price is a second, ordered construction when a span is actually asked for, which is what `caliper/` is for.

## Companion Documents

[`PRIOR_ART.md`](PRIOR_ART.md) traces what `regex-automata` actually does mathematically and every bound its own author concedes, from its alphabet's range-boundary compromise through its ordered-state determinization to its disabled Hopcroft minimizer.

[`CLAIM.md`](CLAIM.md) states what is ours, what is intended to be taken, and the mechanism for each, one falsifiable claim per section, ordered by whether a single function's profile can prove it rather than by the size of the prize.

[`TESTING.md`](TESTING.md) describes the per-function harness each claim needed, why a whole-binary race against `rg`, `csearch`, and `zoekt` cannot attribute a win to one construction, and the oracle that makes every claim here cheap to trust: any determinized construction that disagrees with the Pike VM simulation on any input is wrong, full stop.

## Where Things Stand

The instrument for every claim in `CLAIM.md` is [`bench/rungs/automata/`](../../bench/rungs/automata/README.md), and understanding came first, then measurement, then the move: the consolidation above is a pure relocation and waited, while the claims below are what the dossier is actually for.

Two claims of authorship stand without a scoreboard, because they are claims about construction rather than speed: the SP-quotient sieve as a deliberately non-language-preserving refutation gate, and determinization over a predicate alphabet transcribed back to bytes, which follows D'Antoni and Veanes rather than Cox and is, as far as this search found, the only symbolic-automata implementation in a production grep.

Of the nine claims of intent, two landed on measured numbers. Renumbering DFA states so a match test becomes one bound compare instead of a dependent second load reaches a geometric mean of 1.10–1.16× over the eager tier's rows, and the coarser alphabet this engine already builds measures 2.32× fewer classes, a 2.38× smaller transition table, and 4.8–5.1× faster determinization than `regex-automata`'s own minimized build across 27 patterns.

Two claims split rather than landing or dying outright. The shared refinement core for minimization and the sieve's over-approximation does not exist as one parameterized engine, because the two climb the same lattice in opposite directions with opposite correctness conditions; what did land is a different, real result, one file collapsing a finished table's row redundancy and column redundancy together, live on the symbolic road and measured as not worth its own build cost on the byte road. Reverse-inner literal search turned out to be two claims wearing one name: the prefilter half was already shipped before the claim was written, while the half that bounds a boolean search by the literal's found offset rather than rescanning from byte zero was not, and building it reached a 16.30× geometric mean with a 0.98× worst case on documents built to give it nothing to work with.

Five claims were retired by measurement rather than by argument, and each is kept rather than deleted because a claim killed by evidence is the cheapest kind of progress in a lane like this one. An EOI column to halve a duplicated table dies because cost tracks the bytes a walk actually touches, not the table's total area. A sparse closure clear dies because a wide NFA and a narrow closure turn out to be close to structurally impossible together in this engine's constructions. A skip out of every interior dwell, not just the unanchored start, has a premise that is genuinely true, and still loses to the shipped multi-lane walk because no interior skip can outrun the line length `\n` caps it at. Serializable finished tables die because the median automaton in this engine's own slate is cheaper to redetermine than to load off disk. And a corpus-priced literal-prefilter dispatcher, replacing a cascade keyed only on needle count, is retired on the currency rather than the premise: the specific statistic this engine already computes for the sieve answers backwards on 9 of the 11 rows it was measured against.

The full mechanism, every number, and the reasoning behind each verdict live in `CLAIM.md`, which is explicitly allowed to delete its own entries.

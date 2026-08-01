---
doc_radar:
  sentinels:
    - description: "the regex engine is one sealed deep module — the automata package lives INSIDE that seal, not beside it"
      file: contract/irregex.ward
      contains:
        - "seal kernel/regex through regex.zig"
    - description: "the consolidation started, and its door states the membership rule that keeps it from becoming a junk drawer"
      file: src/kernel/regex/linear/automata/README.md
      contains:
        - "cannot say which road"
        - "Shared *by nature*"
    - description: "the single transcription of the zero-width assertions, shared by every determinizer — the reason a machine algebra can be factored out at all"
      file: src/kernel/regex/linear/dfa/subset.zig
      contains:
        - "pub const Gap"
        - "pub fn passes"
        - "fn refineBySet"
    - description: "the language-preserving end of the lattice, and the file that owns BOTH of a finished table's over-refined dimensions"
      file: src/kernel/regex/linear/automata/reduce.zig
      contains:
        - "Moore's partition refinement"
        - "The order is load-bearing"
    - description: "the coarser end of the same lattice"
      file: src/kernel/regex/linear/sieve/quotient.zig
      contains:
        - "pub const max_conjuncts"
---

# Automata — the machine algebra, and beating `regex-automata`

Everything in this engine that constructs, determinizes, reduces, or reverses a
finite automaton is one subject, and today it is scattered across six folders
that each own a slice of it. This dossier does two things: it states where that
subject belongs as a package, and it opens the competitive program against the
reference implementation of the same subject — BurntSushi's Rust
[`regex-automata`](https://docs.rs/regex-automata), cloned for study at
`upstream/regex/` (gitignored; `git clone --depth 1 https://github.com/rust-lang/regex`).

The competitive posture is not imitation. The crate is the best engineering in
this field and it is also, in its author's own annotations, a pile of admitted
approximations — a non-minimal alphabet he flags as future work, a minimizer he
calls slow and ships disabled, a literal extractor he calls "a black art", a
memory pool he says he is "not entirely happy with". Those are the seams. Where
we diverge it must be because we measured a better answer, and the divergence
gets written down.

## This folder

| File                             | Question                                                                                                  |
| -------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `README.md`                      | What the subject is, where the package goes, and what we already have.                                    |
| [`PRIOR_ART.md`](PRIOR_ART.md)   | What `regex-automata` actually does, mathematically, and every bound its author concedes.                  |
| [`CLAIM.md`](CLAIM.md)           | What is ours, what we intend to take, and the mechanism for each — one falsifiable claim per row.          |
| [`TESTING.md`](TESTING.md)       | How each claim is proven or killed, and what the engine-level race arm had to refuse to assume.            |

## Where the package goes

Inside the package seal, and it starts at
[**`src/kernel/regex/linear/automata/`**](../../src/kernel/regex/linear/automata/README.md)
— which is one level deeper than this section originally proposed, for a reason
worth recording rather than quietly editing away.

I considered `src/kernel/automata/`, hoisted out as a peer of `regex/`, on the
theory that automata theory is alphabet-agnostic and the Aho-Corasick machine in
`scan/` is an automaton too. It is the wrong call. Every construction we have
consumes `syntax.State`, the one NFA instruction type, and the whole purpose of
`seal kernel/regex through regex.zig` is that a second grammar inside this tree
once disagreed with the first about `\<` and silently pruned two thirds of a
matching corpus. Hoisting the constructions out would either drag `syntax/` with
them or force a package below the seal to import through it. The theory belongs
behind the same door as the grammar it is a theory of.

Then the first real occupant decided the depth. The operations that are shared by
nature rather than by accident are shared between the **two determinization
roads**, and both of those live under `linear/`, as does the `Dfa` type they
produce. A folder hoisted to `regex/automata/` would have to import *downward*
into `linear/dfa/dfa.zig` for the type it operates on, inverting the layering to
buy nothing. So the package lands where its dependencies already are, and the
membership rule is stated in one sentence at its door: **a file belongs there when
it operates on an automaton and cannot say which road produced it.**

That is deliberately narrower than "shared". It admits `freeze.zig` (the three
ordered layout passes, previously transcribed once per road) and claim C5's
refinement core; it excludes `program/`'s Thompson lowering, which *produces* an
automaton rather than operating on a finished one. The wider hoist sketched below
stays a proposal, and it should not be executed on tidiness grounds — `dfa.zig`'s
path in particular is pinned inside the frozen benchmark manifests under
`gist/bench/certificate/artifact/`, which are recorded evidence rather than source.

### The shape it grows into — proposed, not landed

The cut is by layer, not by feature.
`automata/` owns the **machine algebra**: what a machine is, how it is built
from an AST, how it is determinized, how it is reduced, how it is reversed. The
existing folders keep the **executors**: the byte loops, the SIMD kernels, the
cost policies that decide when to build what. Give it an interface small enough
to state in one sentence — *hand me an NFA program and an alphabet policy, get a
deterministic table* — and the executors become thin loops over tables.

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

Three subfolders, one leaf, and a door, inside the Rule of Five. What it hollows out is
real: `dfa/` keeps the immutable automaton and its two driver policies,
`caliper/` keeps the two-jaw search, `sieve/` keeps the selectivity gate and the
Sheng kernel, `symbolic/` collapses to its eligibility facade. Each of those
becomes a consumer of one deep module instead of a co-owner of a scattered one.

Most of that has not been done, and it earns its way in one occupant at a time. The
folder that exists holds the operations that pay for the boundary the moment they
move — `determinize/`'s shared layer, in effect, minus the two constructions that
are genuinely different algorithms — plus `reduce.zig`, which C5 both built and
resized. The remaining boxes are a hypothesis about where the code wants to
live, and a relocation with no measurement behind it is a diff, not an
improvement.

### `reduce.zig` is the discovery in the mapping, and it is not the one drawn here

The box above said *Moore refinement · the SP-lattice harvest*: one core, two stopping
conditions. That is the wrong shape, and finding out why is the useful part.

The partitions of a DFA's state set with the **substitution property** — if
`p ≡ q` then `δ(p,b) ≡ δ(q,b)` for every byte — form a lattice under refinement
(Hartmanis & Stearns, *Algebraic Structure Theory of Sequential Machines*,
1966). Every SP partition induces a well-defined quotient automaton on the
blocks. At the fine end of that lattice sits the coarsest partition that still
separates accepting from non-accepting behavior: the Myhill-Nerode congruence,
whose quotient is the minimal DFA accepting exactly the same language. That is what
Moore refinement computes. Climb **past** that point to a
strictly coarser SP partition and the quotient accepts a **superset** — a
machine that can refute but never confirm. That is what `quotient.zig` harvests
for the sieve.

One lattice, two consumers — and **opposite directions is the whole problem, not the
symmetry it looks like**. Moore *descends* the lattice, splitting from the accept
partition down to the greatest closed partition below it; SP closure *ascends*,
unioning from one merged pair up to the least closed partition above it. Opposite
extremum, therefore different machinery: refinement wants a signature hash per pass,
closure wants a disjoint-set forest. And the sieve deliberately refuses to respect the
accept partition, which is exactly what buys its over-approximation. A shared core
would be an enum switch over two disjoint loops that agree on a predicate and nothing
else, so `sieve/quotient.zig` stays where it is.

**The core that did land is a better one, and the second dimension is where it came
from.** A finished dense table is over-refined in two axes, not one — rows (no suffix
separates two states) and columns (no state routes two byte classes differently) — and
merging rows is what makes columns coincide, so the two only compose in that order.
That one-way dependency is a real reason for one file, where "two stopping conditions"
was not. `automata/reduce.zig` owns both; `symbolic/minimize.zig` is gone into it.

Neither RE2 nor `regex-automata` has the sieve's half at all — `minimize.rs` exists,
ships disabled, and has no over-approximating sibling. We still ship one more idea than
they do; we just do not ship it as one function.

The *policy* halves stay where they are. The 16-state Sheng width budget and the
stationary-distribution selectivity estimate are about one rung's economics, not
about lattices; they belong next to the kernel they gate.

## What we already have

Read this as the base to build on, not as a consolation prize. Our automata
surface today, and what each piece already implements:

| Where                       | Mathematics                                                                                                                     |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `compile/compile.zig`       | Thompson AST→NFA lowering over bytes.                                                                                           |
| `compile/onepass.zig`       | The one-pass property (no ε-path converges twice), and the deterministic-with-side-effects table it licenses.                    |
| `linear/dfa/subset.zig`     | Byte-class refinement by transition **set**; the assertion-resolving ε-closure; subset interning; the visit meter.               |
| `linear/dfa/powerset.zig`   | Eager determinization to fixpoint, premultiplication, start acceleration.                                                        |
| `linear/dfa/lazy.zig`       | On-demand determinization with a cache-generation reset policy and a sticky decline.                                             |
| `linear/symbolic/`          | Determinization over a **predicate alphabet** (minterms), then a product with a UTF-8 decoder to land back on a byte table.      |
| `linear/automata/reduce.zig` | Both of a finished table's over-refined dimensions: Moore row refinement, then column coincidence.                                 |
| `linear/caliper/`           | Priority-ordered determinization with match dominance — leftmost-first spans at a table lookup per byte — plus program reversal. |
| `linear/sieve/quotient.zig` | The SP-lattice harvest and its conjunction selection.                                                                           |
| `linear/shuffle/`           | The transformation monoid: a byte becomes a map on the whole state set, folded by a SIMD shuffle.                                |
| `linear/parabix/`           | Bit-parallel simulation: one marker bit per position, a pattern step as a shift and a mask.                                      |
| `linear/pike/`              | The NFA simulation that stands behind all of it as oracle and fallback.                                                          |

Three of those have no counterpart in `regex-automata` at all: the predicate
alphabet, the SP quotient, and the two register-resident rungs. A fourth is a
quiet structural advantage — our boolean determinizer interns on the
**unordered** NFA-state set, while theirs always keeps priority order, so for a
yes/no search our automaton can be strictly smaller than theirs on the same
pattern. We pay for that with a second, ordered construction when a span is
asked for, which is what `caliper/` is.

## Sequencing

Understanding first, then measurement, then the move — and that order held. The
consolidation is a pure relocation, so it waited; the improvements are what the
dossier is for. `CLAIM.md` orders them by provability-in-isolation rather than by
size of the prize, because a win you cannot attribute to one function is a win you
cannot defend against the next regression.

Where that has got to, so this file stops being a plan and starts being a record:
one claim **landed** on measured numbers (C1, the match-first partition, 1.10–1.16×
geomean), one **measured and confirmed** against the crate itself (C6 — 2.32×
coarser alphabet, 2.38× smaller table, 4.8× faster determinization over 27
patterns), and **two retired by the harness built for the first** (C2 and C3, each
on a premise that turned out to be false). The instrument is
[`bench/rungs/automata/`](../../bench/rungs/automata/README.md); the numbers and the
reasoning live in `CLAIM.md`, which is allowed to delete its own entries.

# Testing — how each claim dies

The evidence surface we have races **binaries**:
the face package's `bench/dominance/races/regex.sh` puts that binary against
`rg`, `csearch`, and `zoekt` on a pattern slate and reports wall-clock. That is the right instrument
for the product claim and the wrong one for this lane. A binary race cannot tell me whether a win came from the
determinizer, the alphabet, the prefilter, or the fact that we walk the corpus
differently. Every claim in [`CLAIM.md`](CLAIM.md) is a claim about *one
function*, so the instrument has to be one function.

## The arm

**[`bench/rungs/automata/`](../../bench/rungs/automata/README.md)** — built, and
following the convention every other rung already uses: a `bench.zig` beside the
thing it measures. It reports shape and search cost today; build cost is the part
still missing, and C3 is the claim that needs it.

Two premises it refuses to assume, both learned the hard way on the first run.
**Documents must be match-free**, because a boolean scan returns at the first hit
— the first version of this harness reported four-digit-precision zeros and a
`nan` geomean, which is what timing a match position looks like. And **`seen`, the
count of distinct states the walk actually entered, has to be a column**, because
a pattern that determinizes to 512 states can spend every byte in one of them; a
wide `dfa` column reads like evidence of a wide traversal and is not.

Three things it must report, per pattern in the slate:

1. **Shape** — NFA states, byte classes, DFA states, table bytes. No timing. This
   is what proves or kills C6, and it is the cheapest number in the lane: their
   class count comes from a tiny Rust harness against the clone, ours from the
   builder directly.
2. **Build cost** — nanoseconds to a usable automaton, separated into
   lowering / closure / interning / refinement. C3 and C5 live or die here, and
   the split matters more than the total, because a Moore pass that pays for
   itself in table size still has to fit the build budget.
3. **Search cost** — nanoseconds per byte on a fixed haystack, with the automaton
   already built. C1, C2, and C4 are all claims about this number and nothing
   else.

Timing before and after, on the same slate, on the same machine, per function.
Whole-suite reruns do not attribute.

## The oracle, and why it is not optional

Every claim except C4, C7, and C9 must produce a **byte-identical automaton** or a
**byte-identical answer**. That gives each one a mechanical falsifier:

| Claim | Oracle                                                                                                  |
| ----- | ------------------------------------------------------------------------------------------------------- |
| C1    | Same DFA modulo the ID permutation: same class count, same state count, same accepted language.          |
| C2    | Same accept/reject on a corpus including every `$`, `\z`, `\b`, and CRLF shape in the conformance slate. |
| C3    | Byte-identical `trans_in`, `trans_fin`, and `match_hi`. Not "equivalent" — identical.                    |
| C5    | Language equality against the pre-minimization DFA, plus state count strictly lower or equal.            |
| C6    | Nothing to falsify but the number itself; the automaton does not change.                                 |

Behind all of them sits the Pike VM. It is the differential oracle for every
determinized construction here, and the differential fuzz harness that already
exists is the thing that makes these claims cheap to trust: any construction that
disagrees with the NFA simulation on any input is wrong, full stop.

For C5 specifically, language equality between two DFAs is decidable and cheap —
build the product automaton, look for a reachable state where acceptance
disagrees. That check should be a test, not a fuzz campaign, because minimization
is exactly the transformation where a subtle bug produces a machine that is right
on every input you thought to try.

## The sieve's asymmetry is a different oracle

`reduce/` will host two stopping points on one refinement engine, and they have
**opposite** correctness conditions. Minimization must preserve the language
exactly. The sieve quotient must only over-approximate: every string the real
automaton accepts, the quotient must also accept, and the converse must be
allowed to fail. One engine, two contracts, and a bug that swaps them is silent
in one direction and catastrophic in the other — a sieve that under-approximates
prunes matching documents, which is the failure mode
[`../crest/PROOF.md`](../crest/PROOF.md) exists to make impossible.

So the unification lands with a test per direction, asserted on the same
patterns:

- minimized DFA accepts `s` **iff** the original does;
- quotient accepts `s` **whenever** the original does, and the test slate must
  contain cases where it accepts strings the original rejects — otherwise the
  test is not exercising the approximation at all, and a sieve that silently
  became a minimizer would pass.

## Against the clone

The comparison harness is a small Rust binary against `upstream/regex/` that reports
their shape numbers and their per-byte search cost on the identical slate. Two
rules for it:

- **Their config has to be stated.** Their DFA is non-minimal by default and their
  alphabet is non-minimal always. Racing our minimized table against their
  default is a fair product comparison and an unfair algorithmic one. Report
  both: default-config and `minimize(true)`, because the second is the honest
  algorithmic bar and the first is what the world actually runs.
- **Correctness parity comes first.** A shape or speed number on a pattern where
  we disagree with them about the match is not a number, it is a bug report. The
  conformance slate gates the race.

## What "beating them" has to mean

Not the geometric mean alone. Three separable questions, each answerable:

1. **Shape** — do we build a smaller automaton for the same language? (C2, C5, C6)
2. **Build** — do we get to a usable automaton faster? (C3, C5)
3. **Search** — do we spend fewer nanoseconds per byte once built? (C1, C2, C4)

A win on shape that loses on build is a real trade to reason about, not a failure.
A loss on any of the three that we cannot explain mechanically is the signal to
stop optimizing and go read, because an unexplained loss is a missing piece of
understanding and the next three optimizations will be built on top of it.

## Where the numbers land

In this dossier, cited into `bench/`. C1's numbers are in
[`CLAIM.md`](CLAIM.md) and reproducible with `zig build automata-rung`. Then
folded into the certificate ledger so a regression cannot pass quietly — the same
discipline the `crest` and `sieve` rungs already carry. A claim proven once and
left unguarded becomes false without telling anyone.

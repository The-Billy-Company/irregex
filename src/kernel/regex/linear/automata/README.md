# linear/automata — operations neither road owns

Operations on a finished automaton that belong to **neither road that builds one**.

There are two roads to a DFA here, and they are genuinely different algorithms
rather than two spellings of one:

- **`../dfa/`** — the byte road. Powerset construction over a bitset subset of a
  Thompson NFA (`subset.zig`, `powerset.zig`), plus the lazy tier (`lazy.zig`).
- **`../symbolic/`** — the codepoint road. Determinization over scalar ranges,
  minimized there, then crossed with a UTF-8 decoder and transcribed to bytes.

Ask the kinship engine how alike they are and it will tell you they are each
other's nearest kin in the whole 21,806-file tree and *still* only weakly
similar — which is the right answer. They are not duplicates waiting to be
merged.

## The Membership Rule

A file belongs here when it operates on an automaton and **cannot say which road
produced it**. That is a sharper test than "shared", and it is what keeps this
folder from becoming a junk drawer:

- Shared *by accident* — both roads happen to call it, but it is about one road's
  representation. Stays with that road.
- Shared *by nature* — it takes finished tables and a shape, and the roads are
  indistinguishable from inside it. Lives here.

## What Is Here

**`freeze.zig`** — the last operation on any determinization. It takes the dense
id-indexed tables both roads produce and applies the four layout passes that only
a *finished* automaton admits, in the one order they can run in:

1. **Match-first renumbering** — permute states so every accepting one precedes
   every non-accepting one, collapsing a per-state `is_match[s]` array into a
   single `match_hi` bound. This is claim C1 in
   [`research/automata/CLAIM.md`](../../../../../research/automata/CLAIM.md); it
   landed at 1.10–1.16× geomean on the scalar walk.
2. **The start state's dwell** — read off the start row, which needs state
   *identity*, so it has to precede premultiplication. The rule itself is
   `dwell.zig`'s; `freeze` only decides when to ask.
3. **Widening** — mirror both tables into the byte-indexed `Dfa.Wide` layout the
   document walk steps, so a raw byte indexes a row and the class load in front of
   the transition load disappears. Like the dwell it needs state *identity*, and
   for the same reason it must precede premultiplication: widening a raw id is one
   multiply by the mirror's stride, where widening a premultiplied offset would
   mean dividing back out of `ncls` first. Skipped when the mirror would exceed
   `Wide.budget`, and for the shapes that never walk it.
4. **Premultiplication** — rewrite every state value to its row offset, so the hot
   loop's index folds into addressing. The mirror is premultiplied by its own
   stride rather than by `ncls`, which is the one place the two layouts' offsets
   are not interchangeable.

It also carries the determinization's `visits` count out onto the automaton, so
mean closure width is observable after the fact rather than only from inside the
eager budget. That instrument is what retired claim C3.

**`dwell.zig`** — the states a scan sits still in, and the bytes that get it out.
Reading a byte that returns the automaton to the state it was already in changed
nothing, so a scanner may skip that byte; the bytes that *don't* return it are the
state's **exit set**, and a narrow exit set is one you can `memchr` your way out of.
The module answers exactly one question — *which bytes leave this state, and is that
set selective enough that skipping beats stepping* — over both the pre-freeze view
(state ids, match flags in a side array) and the frozen one (premultiplied offsets,
match status as the C1 bound), from a single transcription of the rule.

It qualifies twice over: the exit set is read off transition rows, which cannot say
which road filled them, and both drivers plus the frozen automaton want the same
answer. Before it existed the rule lived in `../dfa/subset.zig`, where the symbolic
road had to reach across a boundary for it.

**The engine still asks it about the start state only, and that is now a measured
decision rather than an unfinished one.** `survey` exists so the same rule can be
asked about *every* state, which is what claim C4 proposed skipping out of. The
census said the premise held — ~97% of a document's bytes sit in an interior state
with a narrow exit set — so `bench/rungs/automata` built the skip and timed it
against the multi-lane `docMatch` the engine actually runs. At the waived bar it is
0.41× geomean, because `\n` must stay pinned into every interior exit set and so caps
the stride at one line. Break-even is a ≈30-byte stride against a
`min_profitable_stride` of 32, so the threshold calibrated on the start case was
already right. C4 is retired; `survey` remains as the instrument that retired it.

**A bar is calibrated against a walker, not against a corpus, so the span engine
needs its own.** `min_profitable_span_stride` restates the same question for the
caliper's two-jaw walk (`../caliper/`), whose byte costs several times what a
premultiplied boolean step does. What a skip trades away — a `memchr` call plus
a re-entry closure — is the same either way, so break-even scales with the
walker's per-byte cost alone. Borrowing the boolean number withheld the skip
from every pattern beginning with a merely-uncommon byte, which is most of them.
The multiple is not fixed: the span walk went from ~13× a boolean byte to ~6× when
its cells became offsets, which is why `dwell.zig` records the measurement the
constant came from and says to re-derive rather than re-divide.

**`reduce.zig`** — collapsing a finished determinization down to the automaton it
*means*. A determinizer stops when it runs out of **reachable** states, and reachable
is not **distinguishable**; both roads overshoot, for different reasons. A finished
dense table is therefore over-refined in two dimensions, and this file owns both
because they are one question asked of the two axes: **rows** (two states are
indistinguishable when no suffix separates them — Moore's refinement, i.e. the
Myhill–Nerode congruence) and **columns** (two byte classes are indistinguishable when
no state routes them differently, i.e. their table columns coincide outright).

**The order is load-bearing and only runs one way**, which is the whole reason the two
halves are one file rather than two passes a caller sequences. Merging states is what
makes whole columns coincide — two classes that separated only the states that just
merged now route identically — so rows first, then columns. Reversed, both dimensions
stay over-refined: column merging can never create a row merge, because it does not
change which suffixes distinguish a state.

It qualifies for this folder the same way `freeze` does — it reads dense tables and a
class partition, and cannot tell which road filled them. `../symbolic/minimize.zig` is
gone into it, and `../symbolic/transcribe.zig` now calls it for both dimensions.

**The byte road calls it for neither, and that is a measured decision.** This is claim
**C5**, and the honest half of its verdict is that the pass works, the table gets
smaller, and the walk does not care — C2's law again, one order of magnitude up.
`../dfa/powerset.zig` says so at the point where it declines, with the numbers; the
`reduce` section of `bench/rungs/automata` re-prices both passes and re-times both
tables every run, so the claim reopens on evidence if a future lowering ever hands this
determinizer a shape that pays.

**What does not belong here, and why it looks like it does.** The sieve's
`../sieve/quotient.zig` also computes closed partitions of a finished automaton, which
reads like the same engine with a different stopping rule. It is the **dual**, and the
two cannot share a core: both live on the lattice of δ-closed partitions, but Moore
*descends* it (start at the accept partition, split until closed) where SP closure
*ascends* it (start from one merged pair, union until closed). Opposite direction,
opposite extremum, therefore different machinery — refinement wants a signature hash
per pass, closure wants a disjoint-set forest. And the sieve deliberately does *not*
respect the accept partition, which is precisely what makes its quotient a sound
over-approximation. "The coarsest exact automaton" and "a sound crude one" are two
answers, so they are two files.

**What it may not become.** `dwell.zig` is named for the structure it computes, not
the speedup it produces, and that is deliberate. A module named for an *effect* —
`accel.zig` — has a membership rule that admits everything: the prefilter kernels
accelerate, the trigram index accelerates, parabix accelerates, the shuffle rung
accelerates, the sieve accelerates. Each would have an honest claim to the name and
the file would end up owning all of them. So the admission test here is structural:
does it answer *which bytes leave a state?* Executing a skip is
`../../analysis/prefilter.zig`'s job, and a thing that merely goes faster is not a
dwell.

## Why It Is Three Files

Because three is what belongs here. A folder holding a real boundary with a few
occupants is honest where one holding five shallow ones is not, and the membership rule
is what keeps the count down: `reduce.zig` got in because a quotient cannot tell a byte
automaton from a transcribed codepoint one, and `../sieve/quotient.zig` — which computes
closed partitions of a finished automaton, and reads like the same engine — stayed out
because it is the dual rather than a mode.

Three things that look like candidates and are not:

- **`../sieve/quotient.zig`**, for the reason above, spelled out in both its header and
  `reduce.zig`'s.

- **`../dfa/dfa.zig`**, the automaton type itself, is shared by both roads and by
  every executor — but its path is pinned inside the frozen benchmark manifests
  under [`bench/certificate/artifact/`](../../../../../bench/certificate/artifact).
  Those are recorded evidence, not source, and moving a file to make a folder
  tidier is not a reason to rewrite them.
- **`../program/`**, the Thompson lowering, produces the NFA rather than operating
  on a finished automaton, so the membership rule excludes it.

The start-state skip's derivation moved out of the byte determinizer into
`linear/automata/dwell.zig` and the concept is now named for its structure rather
than its effect: a **dwell** is a state the scan sits still in, and its **exit set**
is the bytes that get it out.

The rename is the point, not cosmetics. The old vocabulary was "acceleration"
(`startAccel`, `Dfa.accel`, `matchAccel`), which names an *effect* — and a module
named for an effect has a membership rule that admits everything, since the
prefilter kernels, the trigram index, parabix, the shuffle rung, and the sieve all
accelerate and each would have an honest claim to the file. Naming it for the
question it answers, *which bytes leave this state*, makes the admission test
structural: executing a skip stays with `analysis/prefilter.zig`, and a thing that
merely goes faster is not a dwell. The rule is written into the file and into
`linear/automata/README.md` so it cannot drift back.

`dwell.zig` also answers the question the old code could not. The rule now has one
transcription over two views of an automaton — pre-freeze (state ids, match flags in
a side array) and frozen (premultiplied offsets, match status as C1's bound) — so
`survey` can ask it about *every* state, and `min_profitable_stride` is an argument
rather than a constant, which is what separates "no state has a narrow exit set"
from "narrow, but the corpus prior says stepping is cheaper".

That instrument is what the new `automata-rung -- dwell` section reports, and it is
how claim C4 got settled. On documents built to *enter* an interior `.*` dwell and
sit in it, `a.*b` spends **97.5%** of its bytes in a state with a narrow exit set
and elides **0.0%** of them today — every refusal the profitability bar, none the
automaton's shape. That reading says build it, so the section grew a cost arm that
does; C4 is retired on the timing rather than the census.

Behavior is unchanged — the engine still derives the start state's dwell only, on
the same patterns, with the same exit sets.

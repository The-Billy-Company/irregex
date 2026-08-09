`math.refine` - the coarsest partition a transition table cannot tell apart.
Hand it a delta, a coloring, and a plan; get back the blocks that no input word
separates. That is DFA minimization when the color is acceptance, an LR table's
action-bisimulation when it is a reduce decision, and behavior classes whenever
the color means something else.

It ships **both** engines, and the reason is a measurement that contradicts the
asymptotics. Moore is O(n²k), Hopcroft O(nk log n), so the argument reads as
settled. On a blown-up quotient - wide and shallow, which is the shape a
determinizer actually hands you - Moore settles in 2 to 6 passes and beats
Hopcroft by 3 to 5x at every size up to 65,536 states, because a splitter queue
and an inverted delta are overhead a shallow partition never amortizes. On a
chain, where the coarsest stable partition is the discrete one and can only be
reached one state at a time, Moore pays a full n·k sweep per state and loses by
2,634x at 16,384 states.

Neither threshold is guessable from a paper, so `.auto` does not guess one: it
runs Moore and escalates to Hopcroft - from the partition Moore already reached,
not from scratch - only once Moore has spent more passes than log₂ n, which is
the point where its constant-factor advantage has already been paid back. That
lands within 3.2x of Hopcroft on the chain while staying on Moore everywhere
else. The `Engine` that actually ran is in the result rather than hidden, because
a caller measuring a regression needs to know which one answered.

Having both is also how each is checked. `refine_test.zig` adds a third route -
the textbook pairwise marking algorithm, O(n³k), too slow to ship and too simple
to be wrong - and all three must agree state for state, which is the property an
implementation that over-splits fails distinguishably from one that under-splits.

A missing transition goes to an implicit sink rather than being skipped, and that
is a correctness decision rather than a convenience. A state with no transition
on `a` and a state that loops on `a` are distinguishable; treating the hole as
"no constraint" merges them and silently yields a machine accepting more than it
was given. Both engines agree byte for byte because both see the same sink.

Measured in `bench/rungs/partition/`, whose generator carries the trap worth
naming: a *random* delta looks like the obvious benchmark and is worthless, since
nothing merges, every state ends alone, and the board times queue overhead
against a refinement that never happened. Its quotient is known by construction
instead, and the rung's own tests hold it to that.

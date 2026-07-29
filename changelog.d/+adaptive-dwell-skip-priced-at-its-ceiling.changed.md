The automata rung can now price a runtime-feedback mechanism *before* anyone builds it,
and the first thing it priced turned out not to be worth building.

A `memchr` skip out of every interior dwell — not just the unanchored start, where the
engine already arms one — was retired earlier by measurement, with a loose end written
down. Every loss came from a build-time prior predicting a stride the document then
contradicts: two states with the same exit set get the same prediction, so `a.*b` won
while `foo.*bar` lost by 10x. The named fix was a skip that measures its own realized
stride and disarms itself. That residual is now answered without writing it.
`automata-rung -- dwell` grew an *adaptive ceiling* arm that hands the mechanism its
measurement free and without error, then times the decision it would converge on.
Anything real is bounded by that, so a losing bound settles it.

The headroom is real and the mechanism is learnable, which is what makes the result
worth keeping rather than a foregone conclusion. Splitting every armed skip by whether
it alone cleared the 32-byte bar shows `a.*b.*c` losing at 0.54-0.56x armed
unconditionally while **77.8%** of its bytes sit under skips that individually pay. And the per-state
mean strides — `8 70` inside `a.*b`, `8 8 61` inside `a.*b.*c`, `4 4` inside
`foo.*bar` — show the dispersion separates *which* dwell rather than hiding inside one,
so a per-state counter is a sufficient statistic for the decision.

It still loses. Keeping exactly the states whose own realized stride pays reads
**0.55-0.56x geomean against the shipped multi-lane `docMatch`** across four fresh
runs, a stable 1.36-1.43x better than arming everything when both are measured in the
same run, and a ~1.8x regression all the same. The one pattern that won unconditionally
gets *worse* (1.11-1.18x down to 0.81-0.84x), because disarming its 8-byte state removed
a skip that beat stepping even below the bar.

The reason is structural rather than a tuning miss: the skip lives in the scalar walk,
~2.2x behind the shipped lanes, so **adaptivity can choose better states but cannot
relocate the walk it runs in.** With nothing armed at all the arm still reads 0.78-0.81x
of the scalar walk, because merely asking "is this state armed" costs per byte. A free,
perfect *per-pattern* oracle — allowed to decline the skip entirely and fall back to the
shipped path — reads only 1.04-1.06x over the same rows, on a slate hand-built to
flatter the mechanism.

So the only version left worth wanting is a skip built *inside* the shipped lanes, where
it would be competing against a SIMD substring kernel already doing the same job better.
The instruments stay as the evidence: `strideProfile` reports each skip's realized stride
split by whether that skip alone paid, and the per-state arm times the kept subset. Both
are numbers a future attempt has to beat before writing a line of it.

Nothing in the shipped engine changed. This is measurement, and the measurement says a
mechanism should not be built.

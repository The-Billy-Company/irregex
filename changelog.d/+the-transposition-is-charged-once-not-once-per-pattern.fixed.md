Parabix is now priced as two costs instead of one. `Calibration` gained
`parabix_base` beside `parabix_op`, and the scan model reads
`parabix_base + parabix_op x (stripe_ops - transpose_ops) / stripe_width`
rather than one slope through the origin.

Every admitted program pays the same transposition to get the bytes into bit
planes - `104 x plane.stripe` operations, now named `admit.transpose_ops`
instead of living as a literal inside `stripeOps` - and then pays for the
marker operations its pattern actually asked for. The old model summed those
two into `stripe_ops` and fit a single slope through zero, which forces one
number to stand for two costs with different physics. The fit then splits the
difference: it over-charges the programs that are mostly transposition and
under-charges the ones that are mostly markers.

The two coefficients are not close, and they are not in the same proportion on
both cores. On Raptor Lake the transposition is the dearer half by a factor of
five (`1.208` against `0.223`); on the M4 they are near parity (`0.492` against
`0.543`), because `tbl` does in one instruction what SSSE3 spends a sequence
on. A single slope cannot express that, so the same arithmetic that read
correctly on one machine had to read wrong on the other - which is the whole
argument for a per-core calibration restated as a bug.

The auction found it rather than the arithmetic looking suspicious.
`\b[a-z]{4}[0-9]{4}` was priced 29% dear on x86 and lost to a fallback that
measurement says it beats. That is what the regret gate is for: a model can be
wrong in a way no coefficient looks wrong, and only the pick reveals it.

`probe.separate` was generalized from the two-point line it had been to an
ordinary least squares fit over N points, since separating an intercept from a
slope needs more than two observations to mean anything. Both callers that were
already passing two points get the identical answer - for `n = 2` the fit is
the line through them. The mint now arms a slate of eight programs and fits
across whichever of them the target can actually build.

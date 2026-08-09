`irgx_needles_compile` seats every needle or none, and now says so. The header
described `*refused` as a count of the needles the machine declined, which reads as
a partial-set model: compile forty terms, get back some smaller working set, check
how many were dropped before trusting a negative answer. There is no such mode. A
needle the machine will not seat refuses the whole call, and `*refused` is written
only on that refusal, carrying the INDEX of the needle that caused it.

The wrong sentence was load-bearing, which is the part worth recording. Two of the
three bindings implemented the fiction rather than the ABI: Go grew a
`Needles.Refused() int` and Python a `Needles.refused` property, each reading the
slot on the SUCCESS path, where the engine never writes - so both were accessors
that could only ever return zero, and both were documented as the thing to check
before believing a miss. Go's tests then guarded on them, producing four
conditionals that could not fire and two that would have SKIPPED the assertion if
they had. Rust read the ABI instead of the prose and got it right.

Both accessors are gone. The refusal now names its culprit where a caller will
actually meet it: `irgx.error.index` in Python, the error text in Go. Go keeps its
own pre-crossing check for an empty needle - not for the message, but because
`unsafe.StringData("")` need not return a real address and pinning that panics
before the engine sees anything - and therefore passes NULL for a slot its own
guard has already pre-empted, which the header permits.

`irgx_munch_*` and the slate verbs ARE genuinely partial. That distinction is the
reason the fiction was plausible, and it is why this fragment names the one plane
it applies to.

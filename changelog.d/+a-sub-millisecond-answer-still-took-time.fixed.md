`TestColdSurfacesStats` failed the moment the resolver let it run, and it was
right to.

The verb summary counts whole milliseconds, so a recall over a three-file
fixture reports `"ms":0`, and the cold tier handed that straight back as
`Stats.Elapsed` - a zero duration for an answer that demonstrably cost a process
spawn. The in-process tier reports nanoseconds for the same verb, so the two
tiers disagreed about whether any time had passed, which is the one thing a
ladder of tiers is not allowed to do.

The child's measured wall clock is the floor under `Elapsed` now. A summary that
does report time still wins, because it is the finer account of where the time
went; when it reports nothing, the caller gets what it actually waited instead
of a zero.

The test was not touched.

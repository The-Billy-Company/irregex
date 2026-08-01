A verification lane nearly certified this tree as immune to an environment
variable on the strength of a run that never executed, so the trap is now written
down in the README under "Build and test", where someone reaching for
`-Dtest-filter` will actually meet it.

The mechanism turned out to be the opposite of what I first assumed, which is
half the reason it is worth documenting. My working theory was that environment
variables are *not* part of Zig's build cache key, so a changed variable was
being ignored. Measuring it says the reverse: they *are* in the key. `-Dtest-filter`
reaches the harness as `BRIGADE_FILTER`, an environment variable set on the run
step in `addShards`, and Zig hashes a run step's environment along with its argv.
A new environment therefore always executes. What bites is the second visit -
every environment you have already used has a durable cache entry, so going back
to one replays it: step skipped, nothing run, exit 0 in about the time a no-op
build takes.

That is precisely the shape of an immunity probe. Run the suite with the variable
set, then run it again without to confirm, and the confirming leg revisits an
environment it has already been in - so it is a replay, and green by construction.
The failure is in the third step of the experiment, not the first, which is why it
survived review.

The tell is not the exit code and not the test count. A cached run still reports
`19/19 tests passed` under `--summary all`; the only thing that distinguishes a
replay from an execution is the word `cached` where an executed step prints
`success <n>ms`. Anything reading a test count as proof of execution is reading
the wrong field.

So the README now says to drive the compiled test binary directly for this class
of question - it sits under no build-cache layer and executes every time - with
`BRIGADE_TIMES=1` as the per-test evidence that it did, and a note that
`--verbose` only prints the binary's path on a run that was not cached, which is
its own small instance of the same trap.

Measured rather than transcribed: A, B, A', B' over one probe variable gives
`success 3ms`, `success 3ms`, `cached`, `cached`, all four exit 0 and all four
claiming 19/19 passed. The same four legs against the binary directly execute
every time. It reproduces identically in the gist package, which takes this
harness from here.

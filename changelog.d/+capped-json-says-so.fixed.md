A `--json` stream cut short by the agent-output ceiling now says so in the record
stream, instead of just ending early.

The soft ~25k-token cap is one of the deliberate places gist diverges from
ripgrep, and for a human it's loud: the moment it fires, stderr carries the
`output truncated at` line plus the `-l` / `-c` / `--uncap` follow-ups. But the
protocol's terminator - the trailing `summary` record - was written through the
same budgeted seam as the match rows, and it's written *last*, so it was the
first record a spent budget refused. A capped run therefore ended on an `end`
record, exit 0, no `summary`. An agent doing `gist --json pat > out.json` and
reading stdout back got a short stream with nothing in it to say so, and no way
to tell a truncated answer from a crashed one. That's the same failure the stream
contract already guards for `-l` captures, one format over.

Two changes. The terminator is written past the ceiling rather than through it,
because it's bounded metadata (one record, a few hundred bytes) rather than a
result row, which is the argument the chrome discount already makes for escapes
nobody reads - and going past keeps the *rows* cut in exactly the same place,
where reserving headroom would have moved every capped run's boundary. And when
the run was cut, the record carries `"truncated":true`, so a consumer reading
`matches` off it knows the tally describes a prefix.

That field only ever appears in a case ripgrep can't produce, since ripgrep has
no ceiling; an uncut run is byte-for-byte what it was, which the 411-test rg
suite and a byte-exact `--json` diff both confirm. The flag is read from the
budget inside the emitter rather than threaded in from its four callers, since by
the time any of them reaches the terminator the cut is already decided, so a
parameter could only ever disagree.

The stream contract gate now asserts all of it on both engines: capped runs
terminate on a flagged summary with every record still whole, and an uncut run
carries no such field. It caught its own first draft passing vacuously, because
the timing harness exports `GIST_UNCAP=1` and uncap outranks an explicit token
budget.

Worth saying what this was not: I went in expecting a match-dropping bug, after
`gist -o` tree-wide reported 4,387 rows where ripgrep reported 680,661. That was
the cap doing its job, and my own `2>/dev/null` throwing away the sentence
explaining it. With `--uncap` the two are byte-identical, sorted, tree-wide.

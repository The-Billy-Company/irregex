Both entries below are the same mistake in two places: the fact was already in
hand, and we inferred instead of reading it.

`stat` told us fd 0 was a FIFO, and we inferred from the type that reading it
terminates - true of a pipeline you typed, false of one an agent handed you,
and the difference is a search that never returns. The same `stat` told us a
regular file's length, and we grew a doubling buffer toward that number anyway,
at three times the memory it needed.

Nothing new had to be measured for either fix. Both facts come off the one
`stat` this code was already performing.

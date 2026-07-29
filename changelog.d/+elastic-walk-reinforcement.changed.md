The walk's worker pool is now a starting bet the walk may revise. A `-uu` sweep
of this repo (54 GiB once `.local`'s build artifacts and `.git` fold in) ran at
the six-worker macOS ceiling and left most of an M4 Max idle on reads: 102.7 s at
six workers against 81.3 s at twelve, with the extra time going nowhere but I/O
wait. Nothing in the flags said so up front, which is why the ceiling had been
tuned against the walks it was measured on - and it is right for those. A warm
indexed scan answers in 40 ms and is FASTEST at six (2 workers 73.5 ms, 4 48.4,
5 46.3, 6 40.6, 8 43.7, 12 47.6, 16 56.9), because that walk is namei-bound and
more threads only add vnode contention.

So the crew starts at `defaultWorkerCount` and hires. `crew.Crew` owns the
roster; any worker that finishes a directory calls `consider`, which widens only
when the walk has run past `patience_ns` (500 ms) AND the outstanding front holds
at least two directories per hired worker. Elapsed time is the discriminator
because queue depth is not: a front thousands deep is ordinary on any wide tree,
where 500 ms of walking is something no interactive query on this corpus does.
The front test is what keeps a walk with one enormous file left from hiring hands
that cannot touch it. `-j`, `GIST_WORKERS`, and a transform run's own `ncpu`
fan-out pin the ceiling to what the caller asked for; the file-set walk
(`roster.collectFileSet`) is fixed-width by construction, since it reads no bytes
and so has no I/O latency to hide.

The ceiling is the machine's FAST core count, not `ncpu`: `portal.performanceCores`
reads `hw.perflevel0.logicalcpu`, and a symmetric machine (every non-Darwin host,
an Intel Mac) keeps ripgrep's scale-to-`ncpu` model. On this box that is 12 of 16,
and the four efficiency cores are what the number buys you out of - against the
twelve-worker run, the full-16 pool was 1.9% faster in wall time (79.7 s vs 81.3 s)
for 62% more system time (310.7 s vs 191.7 s), which on a laptop running ten other
agents is a loss.

Measured on the reported case, one run each: 102.7 s at the old fixed six, 74.7 s
elastic (1.38x), hiring 6 -> 12 as reported by `GIST_TRACE=walk`. System time is
unchanged from the six-worker run (171 s vs 167.6 s), so the win is latency the
pool was already paying, not new work. What hiring costs is one read scratch per
new hand and nothing else - peak resident over the same `.local` sweep is 2208 MiB
elastic against 2166 MiB pinned to six, a 2% difference against a 24 MiB scratch
delta, so a wider crew does not hold a wider working set. Output is byte-identical to the fixed-width
run over the whole 54 GiB sweep, and the interactive walks stay at six workers -
`GIST_TRACE=walk` says `6 workers (from 6)` for both a warm whole-repo scan and a
scoped one, so the topology those measurements pinned is untouched.

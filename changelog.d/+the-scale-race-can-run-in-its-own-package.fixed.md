`bench/rungs/sliver/scale_race.py` could not start. It reached for its verdict
math at `bench/certificate/report/stats.py`, and the certificate is a `gist`
concern that went to `gist` in the split - so the `sys.path` entry pointed at a
directory this package does not have, and the script died on `No module named
'stats'` before parsing an argument. Nothing downstream could fix it either:
`gist` depends on this package, not the reverse, so there is no import path back.

The statistical core - Type-7 quantiles, bootstrap-CI medians, and the
tie-corrected Mann-Whitney dominance call - now lives at
`bench/apparatus/stats.py`, beside the Zig instruments it mirrors, for the same
reason those are there: a rung in this package has to be runnable from this
package. The certificate keeps its own copy, and the bodies are byte-identical,
so a class judged here and a class judged over there still mean the same thing.

`bench/apparatus/test_stats.py` is the guard against that stopping being true.
Its expectations come from the definitions - what Type-7 says the median of an
even-length sample is, and what a fail-closed verdict has to do with identical
distributions - rather than from a run of the module beneath it, because a twin
checked only against itself can drift while both halves keep agreeing.

Also fixed while proving the script ran: the race artifact recorded the corpus
as whatever absolute path was passed, which published a home directory into a
committed file. `--corpus-label` now records what the corpus *was*, defaulting
to the directory's leaf name, which cannot carry one.

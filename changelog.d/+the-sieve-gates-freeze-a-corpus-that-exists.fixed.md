The two prefilter parity gates under `bench/rungs/sieve/` froze their corpus
from four path literals baked into the script. Three of the four are not
directories this package has, and `git ls-files` does not complain about a
pathspec that matches nothing — it just returns fewer files. So `warm_parity.sh`
was silently measuring 355 files from the one slice that survived while its
source said it was measuring four, and had that last slice been renamed too the
list would have gone empty, piped straight into `rsync`, and the gate would have
reported every arm agreeing about nothing.

`GIST_SIEVE_CORPUS` declares the slices instead: a space-separated path list,
relative to the corpus root, defaulting to `src bench` so a bare clone measures
itself (438 tracked files). `cover_parity.sh` reads the same knob, so the two
gates freeze the same tree unless you tell them otherwise; it keeps its own
degradation to the whole tree, while the warm gate — which had no fallback at
all — now enumerates before it copies and refuses an empty resolution outright,
naming what it was asked for. Every arm agrees trivially on an empty corpus, and
a benchmark that measures nothing is worse than one that will not run.

Verified on a bare clone with the artifact home scrubbed from the environment:
`cover_parity.sh` proves 21 cases and narrows 5 classes, `warm_parity.sh` proves
27 cases with the cover plan narrowing 5 patterns and the sieve 7 more, geomean
1.49x end-to-end. `GIST_SIEVE_CORPUS=/definitely/not/here` and a list naming only
paths this tree lacks both exit 1 with the refusal rather than a green run; an
explicit `GIST_SIEVE_CORPUS=bench` freezes 101 files in both gates, so the knob
is load-bearing and the two agree about what it means.

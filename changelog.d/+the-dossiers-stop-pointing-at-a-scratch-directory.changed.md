The crest and pincer dossiers cited a per-experiment scratch directory for
their evidence, one that lived inside the private monorepo this package was
extracted from. A reader outside that repo cannot open any of it, so every one
of those citations was a dead pointer that also advertised a tree nobody else
has. The claims now stand on their own: each pointer is replaced by what the
spike actually established, in numbers already carried by the dossier or by the
spike's own results.

So crest's lineage no longer says "see the classrun-formula spike"; it says the
Python reference sieve cleared 240,000 random `(regex, text)` pairs against
Python `re`, 51,463 of them prunable, with zero false negatives, and that the
count-cousin ablation separated the two designs by ~22× on `[0-9a-f]{8}` (92.9%
pruned by the run against 4.2% by the population at the same threshold). The
Ridge extension says 5,224 oracle checks, sound on every one and 98.2% exactly
tight, plus a 160,000-pair sieve suite with no false negatives. Pincer's
provenance paragraph now describes the instruments themselves - the held-out
corpus split, the popcount oracle over per-offset match bitvectors, the sweep
that refused to report until three plans agreed on the hit count - rather than
naming four files you cannot read.

The harder half was the two `TESTING.md` files, which are reproduction guides.
A summary cannot replace a procedure, so where the procedure is gone they now
say so out loud instead of printing a command that cannot run. Crest's §5
oracle and both pincer spikes were pre-production Python and Zig scratch, and
none of it shipped; what did ship is named in its place - `crest_test.zig` and
`bench/rungs/crest/` for the sieve, `anchor_test.zig` and `calibrate_test.zig` for the
anchor defect and the calibration improvement test. One real gap is stated
rather than papered over: nothing in this tree re-times the kernel under the
lazy, static, and calibrated plans, so pincer's 17.6-17.9× bare-sweep row rests
on a dated measurement.

No measurement moved. `.local/` stays this repo's scratch convention, and the
`.local/crest-evidence/` output path is untouched.

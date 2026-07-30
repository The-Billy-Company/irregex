Every candidate prefilter now sweeps the per-branch alternation cover when a
pattern has no pure-literal equivalence set, so a class-led alternation like
`[A-Z]+_TYPE|[a-z]+_kind` gets the same one fused whole-buffer Teddy sweep a
pure-literal alternation already got. Previously each site declined and the
engine re-scanned for those same literals once per line. `maskLiterals` is now
the single place that ranks which set is sound to sweep with, because the bug was
that three sites each derived it themselves: the line-mode mask, the `--json`
mask, and `--json`'s solo-shard jump — which fans one large file's record stream
across cores and so had gone unnoticed entirely. Confirming the cover once per
buffer instead cut the line-mode shape's CPU 1.6x (0.577s to 0.359s over
llvm/lib) and the solo-shard shape's 1.9x (0.182s to 0.096s over a 107 MB
single file, 0.99–1.02x on pure-literal and single-class-run controls), match
volume held fixed and each measured against a binary differing in that one line.
rg parity holds at 411/411 on both engines, plus 42/42 unsorted on the solo file
— unsorted because the cover changes how much body the jump skips between hits,
and the incremental `line_number` count and the shard merge order are what would
show it. The cover is withheld under `-i` and `-U`, where a match need not
contain its bytes verbatim.

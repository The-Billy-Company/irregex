Five kernel doc comments cited a scratch directory that only ever existed on
one machine. A reader outside that machine got a filing location instead of a
reason, which is the worst of both: the claim reads as measured, and the
measurement is unreachable.

Each citation is now the summary it should always have been. The calibration
gate says its two rates were taken through the shipped code paths with the page
cache pre-warmed, and that R_scan is an absent rare needle so every block
filters out. The 17.6-17.9x hit-to-hit sweep says it is the `fileLit` loop
shape clocked inside the kernel, best of 3, with the hit count asserted equal
across arms - so nobody reads it as a CLI wall clock that also paid intake,
walk and emit. The joint-correction table says its training split is held out
by construction rather than after the fact. The rarity range says its oracle is
brute force over every offset pair, not a heuristic standing in for one. The
span walker's 3.2 ns/byte says what was walked and that three patterns agreed,
and the boolean walk's ~0.25 it is measured against is now bracketed by a proof
you can run: `zig build automata-rung -- burst` reports 0.23-0.36 ns/byte for
the doc walk on a match-free document. The ladder's per-instance slice proof
says it is a same-`Regex` A/B with the answers checked equal inside the timing
loop, over a named 64 MiB corpus.

Not one number moved and no code moved. The figures were always right; they
just used to point somewhere you could not follow.

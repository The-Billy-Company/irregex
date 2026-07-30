Selector quality is now a measured dimension of the benchmark suite instead of a
property nothing in the suite could name.

The anchor-pair collapse that just got fixed was running inside the certificate the
whole time and no row reported it, because every literal probe was labelled by how
many true matches it had — `rare` or `common` — and that single label carries two
independent costs. `pgxpool` was the only "rare literal", and it is a lucky needle:
`pg` is a genuinely rare digraph, so it selects a good offset pair and looks fast.
The whole class was represented by its best case. Meanwhile the degenerate needles
*were* being timed (`func`, `error`) but wore the label `common`, so their slowness
was charged to true-match volume rather than to the prefilter failing. The suite
could not distinguish "slow because there is real work" from "slow because the
prefilter collapsed", and that is the only reason a 41% inversion survived in a
shipped binary with a benchmark suite pointed straight at it.

So `select` now names the prefilter's signal rather than the match count:
`selective` (a discriminating rare byte exists), `degenerate` (every byte ties, so a
marginal-rarity selector has nothing to choose on), `head-rare` / `tail-rare` (one
rare byte at a known end). Eight new rows in the CLI-shape matrix and seven new
classes in the no-index scanner lane fill it in: a degenerate low-match trap
(`stepSec`) against a length-matched well-selecting control (`pgxpool`), same-class
runs over each byte class that ties (`dialect`, `PENDING`, `1234567`, `}));`), and a
`zeroing` / `dataviz` pair carrying the same rare byte at opposite ends so an
implementation that quietly prefers one end of the needle has somewhere to show up.
A degenerate needle with few matches is the load-bearing one, and the reason is
narrow: there is no real work to blame its slowness on, so only the prefilter is
left. All 27 shapes hold parity (gist-idx == gist-noidx == rg).

The trap is only readable as a ratio against its control, and only from pairwise
interleaved samples — that caveat is written into both probe sets because it is easy
to get wrong in the direction of a false alarm. Whichever needle is timed first pays
a colder page cache, worth ~10-15 ms on a ~190 ms cell, which is enough to cross the
alarm line: back-to-back blocks on a healthy binary gave 1.031 with the trap first,
0.984 with the control first, and a cold start reached 1.384 — indistinguishable
from the 1.41 defect signature. Interleaved against each other, the same binary is
1.007. Dividing two rows of a results table is not a measurement of this.

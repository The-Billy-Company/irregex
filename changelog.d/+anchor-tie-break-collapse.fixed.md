The literal filter stopped picking the worst pair of bytes it could find, and the
decision now lives in one module instead of being inlined in the scan loop.

`indexOfPos` filters 64-byte blocks on two byte equalities at two needle offsets.
Which two is the filter's only variable cost - everything else per block is fixed -
and it was being chosen by ranking bytes on their individual corpus rarity and
taking the two rarest. That prices a conjunction as `P(a)·P(b)`, which assumes the
two probes are independent draws. Text is the worst possible case for that
assumption: the correlated unit is the word, so byte correlation peaks at exactly
the short distances a needle offers.

Then the density table made it much worse. `rarity.zig` stored `min(255, P·32768)`,
so 20 of the 26 lowercase letters saturated at the same value; for a lowercase
identifier every byte tied, and the old strict `<` tie-break never displaced its
initialisers, so it returned offsets `0` and `1`. The adjacent pair. The single most
correlated choice available, and the one case where a two-byte conjunction buys
almost nothing over one byte. That fired on 122 of 177 code needles and 78 of 90
prose needles, which made the "two rarest bytes" selector *worse than the fixed
first+last it replaced*, in both regimes, on every summary statistic.

The clamp itself is fixed separately (see the rarity-table dynamic-range entry).
**Those two wins are redundant, not additive - do not multiply them.** Priced across
all four corners, the table was the larger defect: fixing only the tie-break takes
survivors from 4.61x to 2.55x of the best-possible pair, fixing only the table takes
it to 1.49x, and doing both lands at 1.50x. This entry is what keeps the failure
*graceful* if a future census ever re-introduces ties, rather than a second
multiplier on top.

It was visible in the shipped binary without a patch: `stepSec` (7 bytes, 464 real
hits) ran **41% slower** than `pgxpool` (7 bytes, 8,856 real hits). Far more actual
work, less time, because `pg` is a rare digraph and `st` is not.

Selection moved to `kernel/scan/anchor.zig`, and ties now resolve toward the widest
separation rather than falling out of a comparison. Ties mean the table has no
opinion, and separation is the one correlation-reducing axis available without a
model, so there is no magic constant in it. Measured over the 213 MB code corpus on
eight all-tied needles, anchor pair as the only variable: **2.07x geometric mean**,
best case 4.27x (`internal`, 40.7ms to 9.5ms), and the worst cases move from ~5 GB/s
to ~22 GB/s.

One needle regresses 1.52x, and it is the most useful row in the table. `namespace`
was genuinely better on the adjacent pair, because `na` is a rarer digraph than
`n`-then-`e`-at-8. So separation is a tie-break and not a selectivity model; it is
worth 2x on average and cannot be trusted per needle. Only measured pair statistics
reach the best-possible pair, and the compact ways of shipping those were tried and
lost - both are written down in `research/pincer/` so nobody re-runs them.

Byte-exactness is unchanged and structurally so: the anchor pair decides which
filter runs, never which positions match, and every survivor is still `memcmp`
verified. The measurement harness fails closed if two anchor choices ever disagree
on a hit count, and none did.

One more slip, caught before it shipped and recorded in the code so it cannot come
back: an early draft sorted the returned pair by offset for tidiness, which put the
common byte in the probe slot and silently cost the single-load fast path 1.42x on
the needles that had earned it. Rarity decides which slot a byte takes. Never sort
that pair.

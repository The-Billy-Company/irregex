The `burst` ladder has been reporting that twelve lanes beat the shipped four by
~1.17x on the rows whose documents drive the automaton across states, and that the
engine could not capture it because nothing at freeze time predicts whether a
given document will wander - a `burst_control` block proves that part properly, by
re-running the same automata over a document their own class rejects and watching
every one of them flip. So the `win`/`ship` gap sat there as standing evidence of
headroom out of reach.

It was not headroom. It was the document. Every line in the ladder's corpus is
exactly 80 bytes, and a burst runs to the shortest lane's line end - so with all
lanes the same length the minimum over N remainders does not fall with N at all,
and width is free in the only place it is ever charged. Real source is not shaped
like that. Over ~100k non-empty lines of this repository the expected minimum is
22.5 bytes at four lanes, 12.2 at eight, 8.1 at twelve, 5.8 at sixteen, so a wider
walk trades overlap for bytes it spends in the per-line `trans_fin` tail instead.

The ladder now runs both geometries: `uniform`, which every prior number was taken
over, and `source`, whose line lengths are drawn from that measured distribution.
On `source` the ordering is monotone in width at every single row - four lanes is
the fastest arm on the wanderers and the parked rows alike, and twelve loses 1.35x
exactly where it had looked like a 1.14x win. There is no dispatch a perfect
oracle could make that beats always choosing four, which retires the open question
rather than answering it: `burst_control` still shows the choice is undecidable at
freeze time, and that no longer matters to anyone.

No production behavior changed by this fragment. `docMatchDense` already fixed
`lanes = 4`, and four is the measured optimum on both carves rather than the
compromise the comments apologized for. The larger consequence is in the sibling
fragment: once the ladder could see a realistic document, the thing worth fixing
turned out not to be the width but the carve that made width matter.

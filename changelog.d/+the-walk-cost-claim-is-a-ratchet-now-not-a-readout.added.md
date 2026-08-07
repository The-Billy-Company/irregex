Layer J refuses to certify at all when a live walk owns more than **2.5x** ripgrep's
memory on its worst measured corpus.

The walk-cost figure was measured, rendered from its artifact, and completely unguarded:
`audit()` - the function whose whole job is refusing to splice when the layer's claims
do not hold - never received `walkcost` as an argument. So the per-entry arena
materialization could come back in full and Layer J would splice happily, publishing a
larger number inside a well-formed table. That is not hypothetical; it is what already
happened once, in the direction of a stale figure rather than a live regression.

The ceiling is set to catch the regression it exists for, not to pin the current
measurement. The growth it guards against measured **6.01x** while it was live; the fix
lands between 0.69x and 1.79x depending on the tree. It is deliberately no tighter than
that, because the denominator is another engine - ripgrep's own walk footprint moves 3.5x
across the two real corpora on record (31.8 -> 110.4 MiB), so a ratio pinned near the
worst observation would fault on corpus shape rather than on a defect.

It judges gist's **worst** corpus, which is the same one `_walkcost` puts in its headline,
so the gate and the rendered prose cannot disagree about which measurement is the claim.
It binds without `--race`, so a narrow mint is still guarded even where the surrounding
section does not render. And the bound is disclosed in the certificate rather than
enforced silently, in both directions: a mint carrying the artifact prints the threshold
beside the ratio, and a mint carrying none says in prose that the ratchet has nothing to
bind and the claim is unguarded on that mint.

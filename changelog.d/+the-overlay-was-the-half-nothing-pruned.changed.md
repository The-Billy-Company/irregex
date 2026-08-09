The resident session now prunes the half of its walk that nothing was pruning.

A warm answer walks two sets: the base mirror, and the overlay — every file
edited or created since the index was built. Giving warm the cold tier's cover
plan and crest sieve fixed the base half and left the other one visited in full,
so the two halves of one walk were deciding what deserves to be read by
different rules.

The index genuinely cannot speak for overlay docs — they changed since the
build, which is exactly what the postings no longer describe. The crest sieve
can, and this is the first place warm prunes something cold cannot. Cold's ρ(d)
vectors are persisted, so its oracle must refuse any file whose timestamps fail
to prove it unchanged; and having read such a file, cold may as well search it.
A resident overlay entry inverts that: `readDocOwned` already holds the bytes
and already scans them once for the first-NUL offset, so ρ(d) costs a second
pass over a body in cache, 32 B held, and then amortizes over later queries. It
is `crest.crest`, the same call the persisted sidecar's builder makes per
document, so a resident vector and the on-disk one for the same bytes cannot
drift into disagreeing about ρ(d).

Three faces get it, because the sieve now rides `Candidates` instead of being
dropped once the base ids were compacted: the `-l`/`-c` fold, the doc gather
behind the lines renderer and the FFI record stream, and `--rank`. Under `-v`
the rule is deliberately different — a pruned overlay doc is still FOLDED, since
every line it holds is selected; it is merely not SCANNED, the invert twin of the
`is_cand` short-circuit the base walk already took. Skipping it outright would
lose real output, so that is the case the new test mutates to prove it fails.

MEASURED HONESTLY: this is a consistency fix, not a speedup. Against the
previous binary over 67.5 MiB of real source, at overlay sizes from 0 to 1000
files, scoped and rootless, it is a coin flip — 20 of 40 interleaved pairs, a
1.009x median ratio — and the reconcile that now computes ρ(d) per changed file
is unmoved within the same noise. The reason is structural and worth writing
down: the overlay is BOUNDED by construction. It holds the mutation set since
the last build, and a divergence large enough to matter makes the session reload
or decline rather than accumulate, so the sieve can only ever save the scan of a
modest number of documents — well under the noise floor of process spawn plus
the freshness walk. What is proven is correctness: a mutation-tested unit test
in both directions, and byte-parity with both the previous binary and the
`--no-index` live oracle at every overlay size tried.

Separately, the no-index tier stopped writing a candidate it was about to throw
away. `tier=none` — the literal-free class repetition the trigram index concedes
entirely — used to enumerate a u32 per document and then compact the array in
place, one wasted write per document on the exact path the sieve exists for.
Enumeration and sieve are now one pass. The allocation is still the corpus-sized
upper bound (the survivor count is not known until the walk ends); what shrinks
is the traffic through it. Both `.index` trace lines are emitted exactly as
before, so the grammar the certificate reads is unmoved.

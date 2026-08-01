Every test that builds its own directory tree now states the corpus scope it
grades against, instead of inheriting whatever the operator's machine says is
not part of a corpus. Fourteen of them were failing or panicking outright when
it did. And when the resident suite does not get the warm answer it claims, it
now fails and says which declinature fired, instead of panicking on a union
accessor.

The one that started it: `resident_test.zig`'s `a covered root stays warm` is
the guard against over-declining. It writes `src/keep.zig` into a fixture under
`/tmp` and queries with that `src` directory as an explicit root, proving the
warm path answers a root the mirror covers rather than refusing every rooted
query wholesale. A `<GIST_DIR>/skips.list` naming `src` prunes the fixture's own
directory, so the root genuinely is not covered, the session correctly declines,
and the test then reaches for `.got` on a union whose `.declined` arm is active
and dies with `access of union field 'got' while field 'declined' is active`.
Nothing in that message mentions a corpus, a root, or a skip list. `GIST_SKIP`
does it too, and so does a charter `skip`, because all three feed one overlay.

Two defects, and they want separate cures.

The panic is the cheaper one. Every warm face returns `fault.Answer(T)`, a union
whose other arm is a typed refusal, and forty-four sites in that file reached
straight past it. A refusal is a legitimate answer the engine can give, so
reaching for `.got` is not an assertion at all - it is a bet, paid out as a
crash that names an accessor rather than the thing that happened. One helper,
`warm`, now stands in front of all forty-four: it returns the payload, or prints
`expected a warm answer, got declinature .freshness_unprovable` and fails. The
tests that expect a refusal still read `.declined` outright; that arm is the
claim they are making, and it was never the problem.

The scope is the real one. Renaming the fixture directory is not a fix - it
picks a name today's skips.list happens not to name - so the skip overlay got
the same split the output budget got when `GIST_UNCAP` leaked into the two
budget tests. `resolveSkipOverlay` returns the overlay in force, resolving
`GIST_SKIP` + charter + `skips.list` on first ask exactly as the first walk
always did, and that is all it does. `installSkipOverlay` binds a stated
`SkipOverlay` and reads nothing. `stateSkipOverlay` is the two composed with the
previous overlay handed back for restoring, because a fixture that states its
own scope must not leave the process describing a corpus the next caller never
asked for. Production is untouched: no shipping path calls install, so every
walk still resolves lazily through the same `list()` it always did.

That seam is also the thing the C ABI was missing. An embedder standing the
engine up over a corpus it chose itself could previously only state a skip
policy by editing the host process's environment, which is the same complaint
`assay.install`'s `lenses: ?u32` override already answers for the trace mask.

Verified. Before: the test panics under a `skips.list` naming `src`, under one
naming `src lib tests docs`, and under `GIST_SKIP=src`; it passes with no
`GIST_DIR`, an empty one, a nonexistent one, and one naming something else.
After: all eight pass. The assertion is not weaker - point the fixture's own
overlay at `src` and it still fails, now with the declinature named. Production
was A/B'd by building one probe against the old and the new resolution and
driving forty-six skip decisions plus six path decisions through twenty-four
environments (each source alone and in every combination, an empty list, a
missing list, a `skips.list` that is a directory, CRLF, comment and blank lines,
a 9 KB single line, a 64-name list against the 32-name cap, and a malformed
charter): the two outputs are the same 2602 lines, same sha256, and the probe is
sensitive enough to tell those environments apart in ten distinct ways.

Sweeping for the rest of the class found thirteen more, all the same shape and
all fixed the same way: the eight cases of the exact-watch rig, its kqueue
ignore-rule case, `vouch_test`'s one-epoch-one-corpus digest, `bulkstat`'s
skip-dir differential, `haystack_test`'s nested-gitignore precedence, and
`loadpar`'s serial parity - each of which writes a `sub/`, `nested/`, or
`childdir/` and grades an oracle that still counts what the walk was told to
prune. The whole 1101-test suite now passes under a `GIST_DIR` whose skips.list
names twenty-two common source directory names, and under a `GIST_SKIP` naming
the same twenty-two, where thirteen tests failed and one panicked before.

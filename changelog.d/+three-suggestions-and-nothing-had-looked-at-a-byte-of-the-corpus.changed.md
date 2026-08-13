The no-match hint channel renders probed evidence now, not the pattern's spelling.

A `-n 'KEY_THREAD_ID|__all__|globals\(\)' attrs.py` search used to answer with three
suggestions, and all three were wrong. `-i` because the pattern has uppercase, on
a file holding no case variant of any branch. `-F` because `\(` contains a
metacharacter, when the backslash next to it is what makes it literal. `-uu`
because gitignored files were excluded, on a path the caller had named
explicitly. The one fact worth saying - the string is in `attrs.gen.py`, one
directory entry over - was not sayable, because every line on this channel was a
pure function of the pattern text and a pure function of the pattern text cannot
know whether its advice helps.

`Shape` is still what the query says. `Evidence` is what the corpus says, and the
renderer only reads the second. The `-i` line is now a counterfactual: the
caseless match runs over the same resident bytes, and `caseless_dead` retires the
suggestion when it also finds nothing, which is where most of the old noise
lived. A dead literal reports where it stopped being alive rather than that it is
absent, since `KEY_T` is here on 2 lines locates a rename to the character. Each
branch of an alternation is probed on its own, so a bundle of three questions no
longer collapses into one answer. And scope-versus-corpus goes to a new
`quarry/witness.zig`, which asks the trigram index the walk already prunes with
and then reads the candidates back to confirm them - so "try a wider scope"
carries a scope to widen to, and never names a file that has since stopped
holding the bytes.

The probes ride bytes the run already paid for, on a run that already came back
empty, and the index side is capped at a handful of confirming reads. Every arm
fails open independently: no index, an unreadable candidate, or a scope too large
to materialize drops its own hint and leaves the others standing. Tested as
rendered bytes over hand-built corpora, one case per claim, plus the inverse
cases that must stay silent - a caseless retry that would find nothing, a literal
with no live prefix, a scope that really does hold every branch.

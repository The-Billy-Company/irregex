`version_parity.py` discovers mirrors by walking for a marker rather than
keeping a list, which is the right instinct - a mirror added next year is
covered the day it is written. But a mirror is only guessed at: a line carrying
`x-release-please-version` and a version number. Release notes defeat that,
because their whole subject is versions and the machinery that moves them, so an
entry describing a bot bumping the engine to `0.3.0` and naming the marker in
the same sentence looks exactly like a stale mirror.

`changelog.d` was already skipped for this reason; `CHANGELOG.md` was not, and
nothing noticed until the 1.0.0 fold turned 237 fragments into one file. The
second fault it raised was the tell that the rule was backwards: it wanted
`CHANGELOG.md` added to release-please's `extra-files`, which would have the bot
rewriting past releases' numbers. Towncrier owns that file and the bot is
deliberately kept out of it, so the notes are now skipped before and after the
fold.

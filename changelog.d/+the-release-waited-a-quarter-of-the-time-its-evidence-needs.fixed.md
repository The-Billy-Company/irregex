`release.yml`'s preflight will not publish until `release-ready` is green on the
exact commit the tag names. That is the right gate, and it was given a quarter of
the time it needs.

The tag arrives within a minute of the release PR merging, and `release-ready`
aggregates the slate that runs on that merge commit: 31 minutes on `main` today,
and the check does not even appear in the API until the jobs under it finish. The
shared action's default patience is 15 minutes, so preflight polled for a check
that could not exist yet, gave up, and failed the release on a commit whose CI
went green shortly after. Nothing was wrong with the build - the release just
stopped waiting before its evidence arrived.

It now waits an hour, polling every 30 seconds, under a 75-minute job ceiling.
Still bounded, deliberately: a slate that is genuinely stuck fails the release
rather than publishing without a verdict.

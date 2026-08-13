The release PR is where a release is assembled: release-please writes the version
onto it, the fold folds the fragments into `CHANGELOG.md`, and the mint refreshes
the artifacts that carry the version in their bytes. Then main moves on, and none
of that work is rebased.

Folding deletes the fragments it folded. So the first commit on main to edit one
of those files puts the branch and its base in modify/delete disagreement - and
GitHub will not compute a merge ref for a conflicting PR, which means no
`pull_request` workflow runs on it at all. Not failing; not running. The PR sits
there with no verdict to show, `release-ready` can never appear, and the tag that
would carry the release has nothing to wait for. Worse, the pushes that cause it
are the ones release-please declines to notice: it rebuilt the branch only when
the release notes changed, and a `ci` or `docs` commit carrying a fragment writes
no note.

The branch is now rebuilt on every push while the PR is open (`always-update`,
which upstream documents for exactly this - "pull requests must not be
out-of-date with the base branch"). Both jobs that maintain the PR are idempotent,
so meeting a branch they already handled is a sentence rather than an error, and
each cancels a superseded run of itself rather than losing a push to it.

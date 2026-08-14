CI cancelled its own evidence on `main`. The concurrency group keyed on the ref
and cancelled unconditionally, which is right on a branch whose runs are drafts -
a force-push should kill the run it obsoleted rather than race it - and wrong on
`main`, where every commit is a candidate to be released and the run is the only
record of whether it may be.

`release.yml` will not publish a tag unless `release-ready` concluded success on
that exact commit, which is the check that makes a green release meaningful. But
`release-ready` gathers its dependencies under `if: always()`, so it reports on
jobs that never finished as readily as on jobs that failed. So the next push to
main revoked the previous commit's verdict: a still-running job ended
`cancelled`, `release-ready` read that as a failure, and preflight declined a
release with nothing wrong with it. On a tree several people push to, that is
not a rare race; it is most releases, and it looks exactly like a real test
failure until you notice the conclusion is `cancelled` rather than `failure`.

Caught it on `gist`, whose v1.2.0 tag was green on the pull request and then lost
the release commit's `python (3.14)` job to three docs commits landing behind the
merge. Every repository in the family had the same line, so every one has the
same fix: pushes to main no longer cancel each other and each commit keeps its
own answer, while pull request branches still supersede as before.

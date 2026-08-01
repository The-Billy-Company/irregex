Opening a warm engine over a repository root crashed instead of answering.

`loadDir` remembered which directories it had loaded by the exact string it
was handed, but buckets rules under a normalized key. The walk root is `""`
to `init` and `"."` to a walker that names its own root, so one directory
loaded twice and its rules landed in the `""` bucket twice. The compiled `""`
tier borrows that bucket's slice, and the second append reallocates it, so
every path judged afterwards read freed memory. Release builds got away with
it because nothing had reused the block yet; any build with safety on took
the segfault, which is what a host linking the library gets.

Directories are now deduplicated by the same normalized key their rules are
bucketed under, so a directory loads once however it is spelled. The tier
also checks that it still describes the bucket it was compiled from before
trusting it, and falls back to the linear fold if not: rules are only ever
appended, so a length disagreement is enough to see the drift, and the two
paths return the same verdict.

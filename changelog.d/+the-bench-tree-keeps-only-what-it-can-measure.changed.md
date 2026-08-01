`bench/` keeps only the buckets whose subject is the kernel. The conformance
slate and the corpus fetcher moved to the sibling `gist` package, because what
they oracle is a compiled `gist` binary and this package does not build one —
four of its parity gates had been looking for that binary in this repo's
`zig-out`, where it will never appear.

What stays is what this package can actually run: `rungs/` (per-mechanism
production proofs), `bounds/` (distance from a stated limit), and
`apparatus/harness/` (the `gist-bench` binaries, PMU counters, bootstrap
statistics, and the 12-class probe registry that both repos' lanes read, so a
competitor race there and an engine rung here still map 1:1 by class name).

`apparatus/roots.sh` stays too, and now also names the checkout that owns the
`relate` binary. It is deliberately duplicated rather than shared: it answers
"where am I, and who is next to me," which only a package can answer about
itself, and the two copies resolve differently on purpose.

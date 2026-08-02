Every CI job now checks out one repository: this one. The Python, Go and Rust
suites all reached sideways into a sibling clone before, so a public library's
tests could not be run by the public.

Three separate reaches, one cause. The Python cffi mirror declared `gist_open`,
`gist_search`, the cursor family and all three `<face>_run` producers, so its
header-parity gate needed gist.h, relate.h and blast.h to check them; those
declarations belong to the libraries that export them and now travel with them,
leaving this mirror to answer to `include/irgx.h` alone. The Rust crate mirrored
gist's published names and tool boundary, whose parity test read gist's
`contract/surface.toml`; both are in `gist::contract` now, next to the contract.
The Go ladder's `TestMain` refused to run the package without a producer binary,
and this repository builds none, so the binary it asked for was gist's.

The tests that genuinely need a child moved to the repositories that build one:
the row-and-stats comparison to gist's `exact`, the span oracle against
`gist --json` to gist's Python suite, the kinship oracle to relate's bindings.
What is left here is the ladder's own reasoning, which spawns nothing.

The path resolvers lost their sibling fallback with the tests that wanted it. A
gate that can satisfy itself from whatever happens to be cloned next to it is a
gate on the neighbor, and relate's `kinship.toml` is vendored here anyway.

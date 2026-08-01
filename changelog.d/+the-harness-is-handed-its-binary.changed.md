The Go runtime tests no longer discover their engine by filesystem archaeology.
A `TestMain` resolves what the package needs once, and a package with no binary
fails outright instead of skipping its way to `ok`.

The two `t.Skipf("no relate binary")` guards this replaces are the shape that
hid a dead rung in the resolver: discovery quietly returned nothing, every test
that wanted a child skipped, and the package reported `ok` over a seam nothing
had touched. A skip is a claim the thing was optional. `Binary` staying a
*discovering* affordance is right for a library consumer, who genuinely has no
other way to find the engine, but a test knows something the library cannot -
which build it is judging - and a missing binary during a test run is a broken
environment, not an optional capability. Package-level failure is the honest
severity for that.

One skip survives, and it is the other kind. `TestTiersAgree` is a cross-tier
oracle, and the default build is pure Go because the in-process analytic tier is
opt-in behind `-tags irregex_ffi`, so a `go get` consumer never tries to link a
libirregex that cannot exist in the module cache. One tier present is nothing to
compare, and no amount of building or installing changes that - only rebuilding
the test binary with the tag does. Its message now says exactly that, so nobody
later reads it as the same rot.

Verified by pointing `RELATE_BIN` at a path that is not a file: the package
fails, exits 1, and runs zero tests. The old shape, in that same environment,
printed `ok`.

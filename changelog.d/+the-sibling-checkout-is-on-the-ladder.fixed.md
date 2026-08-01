The Go binary resolver ascended from the working directory looking for two
things: `zig-out/bin/<name>`, and that same path nested under the kernel bucket
of the monorepo these four packages were extracted from. The second can never
resolve here - a dead rung, and one an earlier scrub missed.

What it never had is the rung that matters now. The packages are flat siblings,
so a process running in `irregex` that wants `relate` is looking at
`../relate/zig-out/bin/relate`, and nothing on the ladder could see it.
`Binary` fell through to PATH, found nothing, and four Go tests across two repos
skipped themselves: `TestTiersAgree` and `TestColdSurfacesStats` here,
`TestContextPicksOnlyMatchingFiles` and `TestFamilyNarrowsToMatching` in blast.
The Python binding has had the sibling rung all along, which is why its suite ran
everything while Go's quietly ran less.

The ladder is now Python's `_locate_root`, spelled in Go: the env override, a
built `zig-out/bin/<name>` anywhere up the tree, then the sibling checkout that
owns the name - believed only when it carries the `build.zig` that makes it that
package rather than a directory sharing its name - then PATH. Own build ahead of
sibling on purpose: the checkout you are standing in is the one you just
rebuilt, and a sibling's `zig-out` may hold something older. No rung dates what
it finds, so pin an exact build with the env override when the difference
matters.

A failure now names every path it looked at, in order, instead of listing three
things you could try. That is the whole reason this took two investigations to
find.

`irgx.runtime.shell._resolve` gained a fourth rung: a binary a *product's own*
wheel bundled at `<name>/bin/<name>[.exe]`, checked through
`importlib.resources` after the explicit `GIST_BIN`/`RELATE_BIN`/`BLAST_BIN`
override and a sibling dev checkout's `zig-out/bin/<name>`, and before the
plain `PATH` lookup. Nothing about the existing three rungs moved — an
override still wins outright, and a dev checkout still wins over a packaged
copy — so a contributor who never sees the new rung sees no change at all.

The rung exists for the products this substrate underlies, not for this
package itself: `gist-search`, `relate-search`, and `blast-search` each ship a
per-platform wheel that bundles its own CLI now (`hatch_build.py` in each of
those repositories), and until this change nothing in the shared resolver knew
to look inside one. Without it, "the wheel bundles the binary" and "the
binary is findable" were two separate, unconnected claims — a `pip install
gist-search` would still raise `GistNotFoundError` the moment its first verb
shelled out, because the resolver had no fourth place to check. `irregex`
carries no bundled binary of its own and never will (it ships a shared
library, not a CLI), so this package's own behavior is unchanged; it is
purely the shared place three sibling products' bundling now has a matching
lookup for.

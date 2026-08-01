The Python substrate's cffi mirror still named the engine `gist_engine_open`
after the engine moved down here as `irregex_engine_open`, so every in-process
call through it raised `AttributeError` on a symbol libgist has never exported.
Nothing caught it because cffi resolves an ABI-mode symbol lazily and the tier
that would have made the call was skipping for want of `cffi` in a standalone
checkout — a rename hiding behind a dark test plane.

The mirror now spells the engine, cancel token and all three `…_run` producers
the way the headers do, and a new gate compares the two texts directly: every
function the mirror declares must be declared by a reachable header with the
same return type and the same parameter types, names ignored. It fails closed
naming the header it wanted, since a mirror checked against a header that isn't
there is not checked at all. Proven by mutation on four axes — the pre-move
spelling, a wrong engine type in a parameter, a wrong return type, and that
renaming a *parameter* is correctly ignored.

Two smaller repairs alongside it. `_resolve_lib` now finds a package's shared
library in that package's own tree, the same ancestor-then-sibling rule
`_locate_root` already used for binaries; it had a special case withholding
exactly that hop from `gist`, which made sense when the loader lived in gist and
was backwards once it became substrate here. And the wrong-library refusal test
discovers a stand-in extension module from the interpreter's own search paths
instead of assuming `_ctypes` is a separate file — it is statically linked on the
CPython builds uv ships, so the test could not run there at all.

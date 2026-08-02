`check-linux` and `check-windows` were passing without looking at the engine,
and I only found out because I wrote a third one and it failed to catch a bug I
had just watched a real build catch.

Both steps built an `addObject` rooted at `src/root.zig`. Zig analyzes what a
compilation reaches, and an object that exports nothing reaches almost nothing:
the module's `pub` decls are lazy, so Sema stopped near the top and the step
went green. The proof is a side-by-side. With the arch-shaped `lanes.native`
regression in place, `zig build -Dtarget=aarch64-linux-gnu -Dcpu=baseline-neon`
- the real library - failed with the `shufflePair` compile error, while the
cross-check object for the same target passed on a cold cache. A portability
gate over code it never read.

The shipped `libirgx` is rooted at `src/surface/ffi/exports.zig`, not at
`root.zig`, for its own unrelated reason (an `export fn` is emitted by every
compilation that reaches it, so the shims live in the artifact's root to avoid
duplicate symbols in `libgist`/`librelate`/`libblast`). That turns out to be
exactly what a check needs too: `export fn` is what forces Sema down into the
kernels. All three cross-checks now build the same two-module shape the artifact
does - the engine over `root.zig`, the object over the export surface importing
it - so they analyze what the library analyzes.

They stay green at the new depth, which is the part I was least sure of.
Deepening a gate that was never really running usually means finding out what it
would have been saying; here it means the Linux and Windows legs were fine all
along and only the gate was hollow.

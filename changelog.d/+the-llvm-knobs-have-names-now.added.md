Codegen is something you can turn from the command line instead of by editing
the build graph. Zig ships no rc file and rejects `-mllvm` on purpose, so
`build.zig` is the only configuration file there is; three of the four tiers of
LLVM control now have names on it, and the fourth is documented rather than
folklore.

`-Dframe-pointer` keeps the chain a sampling profiler walks, which ReleaseFast
otherwise throws away (a no-op on aarch64-darwin, whose ABI pins the register
regardless). `-Dlto=thin|full` turns on cross-language inlining over the Zig↔C
seam for the shipped libraries and the lab executables; it is off by default
because it moves real optimization work into the link that every edit then pays
for. On a Darwin target it refuses outright and says why, rather than letting
the driver fail three steps later with "using LLD to link macho files is
unsupported" - LTO needs a link-time pass pipeline, only LLD hosts one, and Zig
links Mach-O itself. Cross-compiling is unaffected. Both knobs live in one value
that every module and artifact is handed, so one added later cannot silently
miss them.

`zig build ir` is the new instrument: one object, three views of the same
compilation into `zig-out/llvm/`. The post-pipeline `.ll` answers what vector
width a rung really got and which call did not inline, the `.s` is what
`bench/bounds/port/mca.sh` already hands to `llvm-mca`, and the `.bc` is the
handoff to an external `opt` and back in as an input file, which is the only way
to run a pass pipeline of your own choosing. `-Dir=<file>` picks the root; the
default is the C-ABI surface rather than `src/root.zig`, because Zig analyzes
lazily and a library root that exports nothing lowers to nothing.

`CONTRIBUTING.md` gains the tier below all of that - `-fopt-bisect-limit`,
`--verbose-llvm-cpu-features`, and the bitcode round-trip - since none of it has
a `std.Build` surface to hang an option on.

It also records the option that deliberately does not exist. `-fno-llvm` reads
like the last tier, and on x86_64 the self-hosted backend really is the quicker
debug path, but on aarch64 in 0.16 it is not: three lines of Zig whose only
weight is `std.debug.print` take 0.91 s through LLVM and 175.7 s without it,
and the warm run is the slower of the two, so nothing amortizes. That is a trap
with an inviting name, so it gets a table and a recheck-on-Zig-bump note
instead of a `-D` flag somebody would reasonably set.

One latent trap went with it: the ReleaseFast library twin the production rungs
compile against was missing the engine's `build_options`, so a lane that touched
`version_string` would have failed on a missing import rather than on anything
it did.

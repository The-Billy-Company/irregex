Every published x86_64 artifact - the `manylinux_2_17_x86_64` wheel, the
`win_amd64` DLL, the `macosx_11_0_x86_64` dylib - contained 55 `pshufb`
instructions under a declared floor of generic x86_64. `pshufb` is SSSE3.
Generic x86_64 is SSE2. So the tag promised one thing and the bytes needed
another, and the machines that would have found out are the old AMD parts the
tag was widest for.

LLVM did not miss it; LLVM was never asked. It checks every instruction *it*
selects against the subtarget and checks nothing inside an `asm` block, where
the template is a string on its way to the assembler. The shuffles in
`scan/lanes.zig` and `scan/classrun.zig` picked their arm with
`switch (builtin.cpu.arch) { .x86_64 => … }`, and an architecture is not a
feature - x86_64 has meant SSE2 and nothing more since 2003.

Each arm now asks for the feature it actually needs, which is comptime and free
at run time:

    if (comptime builtin.cpu.has(.x86, .ssse3)) return asm ("pshufb …");

`math/bits.zig`'s NEON movemask fold and `lanes.zig`'s two-register `tbl` got the
same treatment. Neither was live - aarch64's baseline includes NEON, so the arch
test happened to be true wherever it was reached - but both were the same latent
shape, and the two leaf helpers with no fallback now `@compileError` off-feature
instead of trusting whoever calls them next.

Then the floors got written down. The wheel matrix names a `-Dcpu` per target
rather than inheriting Zig's default: `baseline` on aarch64, whose baseline
already has every vector path the engine uses there, and `x86_64_v2` on x86_64,
which is SSSE3 plus SSE4.2 plus POPCNT, is Nehalem and Bulldozer and up, and is
the floor Red Hat picked for all of RHEL 9. It costs Core 2, whose SSE stops at
4.1. It does not cost anything that runs the current wheel, because the current
wheel already needs SSSE3 to survive its first shuffle.

The wheel was not the only thing shipping. Four more channels build this engine,
and each one had inherited a floor rather than named one:

* The **Go module** carries a committed static archive per platform, because Go
  has no `build.rs` and a consumer cannot compile Zig at install time.
  `libirgx_linux_amd64.a` held 52 `pshufb` under a triple that promised SSE2.
* The **Rust crate** vendors an archive per target for the same reason, and it
  is the rung a normal `cargo add` actually links.
  `vendor/x86_64-unknown-linux-gnu/libirgx.a` held the same 52.
* `build.rs`'s **source rung** passes an explicit `-Dtarget`, which quietly opts
  out of native CPU detection - so someone compiling on their own modern box was
  getting the target's SSE2 baseline. Before this fix that produced the wrong
  instructions; after it, it would have produced the scalar fallback on hardware
  that had the real one. Both are the same missing sentence.
* `hatch_build.py`'s **source rung** had the same shape, via `IRGX_ZIG_CPU`.

All five now read from one rule, and the two vendored sets were rebuilt at the
floors they now declare: 199 `pshufb` and zero `ymm` on x86_64, which is v2
exactly - present because it is promised, and stopping where the promise does.
Every archive still passes the link probe the vendoring scripts already ran, and
the Go and Rust suites pass against the rebuilt bytes.

Only two of those targets were ever wrong, which is worth saying plainly: Zig's
default CPU for `x86_64-macos` already includes SSSE3 (every Intel Mac has it),
while its `x86_64-linux` and `x86_64-windows` defaults do not. Depending on that
difference is not the same as declaring it, and the macOS artifacts were correct
by luck rather than by contract.

Checked rather than assumed, on the real C-ABI surface at each posture: baseline
x86_64 now emits zero SSSE3 and v2 emits 201 `pshufb`; aarch64 is untouched at
183 `tbl` and 44 `addp`; and the whole suite passes built for `x86_64-macos` and
run under Rosetta at *both* `baseline` and `x86_64_v2`, so the scalar fallback
the fix newly reaches is executed and correct rather than merely compiled.

One tier is knowingly left on the floor. At `x86_64_v3` the same surface emits
9,841 `ymm` instructions against v2's 23k `xmm` ones - AVX2 is worth about
double, and ripgrep gets it on every modern chip through runtime dispatch. A
static v3 wheel would refuse to boot on anything before 2013, so the way to have
that width is runtime dispatch over a v2 floor, and the engine does not do that
yet. Naming it here beats it being invisible.

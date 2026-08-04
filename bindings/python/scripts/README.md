# Build Scripts

## `build_wheels.py`

This script builds the platform wheel matrix from one machine. Zig
cross-compiles, so every target is produced by the same host from the same
sources, with no CI fan-out and no emulation.

Build the whole matrix, or narrow it, from `bindings/python`:

```bash
python3 scripts/build_wheels.py                # every target
python3 scripts/build_wheels.py --only native  # the one matching this host
python3 scripts/build_wheels.py --list         # what the matrix covers
```

Wheels land in `dist/`. A target that fails is reported at the end and does not
stop the others, so one broken toolchain does not cost you the rest of the
matrix. Running it requires `zig` on PATH, and either `uv` or `python3 -m
build`.

- **`macos-arm64`** builds at the `aarch64-macos.11.0` Zig triple, tagged
  `macosx_11_0_arm64`, at the `baseline` CPU floor.
- **`macos-x86_64`** builds at `x86_64-macos.11.0`, tagged
  `macosx_11_0_x86_64`, at the `x86_64_v2` floor.
- **`linux-x86_64`** builds at `x86_64-linux-gnu.2.17`, tagged
  `manylinux_2_17_x86_64`, at the `x86_64_v2` floor.
- **`linux-aarch64`** builds at `aarch64-linux-gnu.2.17`, tagged
  `manylinux_2_17_aarch64`, at the `baseline` floor.
- **`windows-x86_64`** builds at `x86_64-windows-gnu`, tagged `win_amd64`, at
  the `x86_64_v2` floor.

Every target names an explicit minimum platform version in its triple, and its
tag says the same number. That pairing is the point: letting Zig inherit the
host's macOS SDK produces a library that refuses to load on an older machine
than the one that built it, under a tag promising it would. glibc 2.17 is the
manylinux2014 floor; Zig links against exactly that version rather than the
host's, which is what makes a manylinux wheel built on a laptop a real thing
rather than a claim.

The `-Dcpu` floor is the other half of that same promise, because a wheel tag
names an OS and an architecture but has no way to name an instruction set.
`aarch64`'s baseline already carries NEON, which is everything the engine's
vector paths use on that architecture, so there is nothing to raise. `x86_64`'s
baseline is SSE2, which is genuinely too low for the scan kernels' `pshufb`
(SSSE3), so those targets ship at `x86_64_v2` (SSSE3, SSE4.2, POPCNT) — the same
floor RHEL 9 chose for an entire distribution. The tier above that, `v3`, is
where AVX2 lives and is worth roughly double the throughput, but a static `v3`
wheel would refuse to run on anything older than 2013; getting that width
without that cost needs runtime dispatch on top of a `v2` floor, which the
engine does not do yet.

## How It Fits with the Build Hook

The script owns the Zig invocation; `hatch_build.py` stays a packaging step. It
passes four environment variables:

- **`IRGX_PREBUILT_LIB`** is the library to bundle. The hook copies it instead
  of invoking Zig itself.
- **`IRGX_WHEEL_PLATFORM`** is the platform tag to stamp. The host's own tag
  would be a lie when cross-building.
- **`IRGX_ZIG_TARGET`** is the triple, so the hook knows which OS's file
  layout and library name to expect.
- **`IRGX_ZIG_CPU`** is the CPU floor to build at. Left unset, the hook falls
  back to the same rule the matrix above encodes: `baseline` for an `aarch64`
  target, `x86_64_v2` for an `x86_64` one.

Building a wheel directly with `uv build` and none of those set is the
local-development path: the hook runs `zig build` itself and derives this
machine's tag.

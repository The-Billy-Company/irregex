# Build scripts

## `build_wheels.py`

Builds the platform wheel matrix from one machine. Zig cross-compiles, so every
target is produced by the same host from the same sources, with no CI fan-out
and no emulation.

```bash
python3 scripts/build_wheels.py                # every target
python3 scripts/build_wheels.py --only native  # the one matching this host
python3 scripts/build_wheels.py --list         # what the matrix covers
```

Wheels land in `dist/`. A target that fails is reported at the end and does not
stop the others, so one broken toolchain does not cost you the rest of the
matrix.

| Target | Zig triple | Wheel tag |
|---|---|---|
| `macos-arm64` | `aarch64-macos.11.0` | `macosx_11_0_arm64` |
| `macos-x86_64` | `x86_64-macos.11.0` | `macosx_11_0_x86_64` |
| `linux-x86_64` | `x86_64-linux-gnu.2.17` | `manylinux_2_17_x86_64` |
| `linux-aarch64` | `aarch64-linux-gnu.2.17` | `manylinux_2_17_aarch64` |
| `windows-x86_64` | `x86_64-windows-gnu` | `win_amd64` |

Requires `zig` on PATH, and either `uv` or `python3 -m build`.

Every target names an explicit minimum platform version in its triple, and its
tag says the same number. That pairing is the point: letting Zig inherit the
host's macOS SDK produces a library that refuses to load on an older machine
than the one that built it, under a tag promising it would. glibc 2.17 is the
manylinux2014 floor; Zig links against exactly that version rather than the
host's, which is what makes a manylinux wheel built on a laptop a real thing
rather than a claim.

## How it fits with the build hook

The script owns the Zig invocation; `hatch_build.py` stays a packaging step. It
passes three environment variables:

| Variable | Meaning |
|---|---|
| `IRGX_PREBUILT_LIB` | The library to bundle. The hook copies it instead of invoking Zig itself. |
| `IRGX_WHEEL_PLATFORM` | The platform tag to stamp. The host's own tag would be a lie when cross-building. |
| `IRGX_ZIG_TARGET` | The triple, so the hook knows which OS's file layout and library name to expect. |

Building a wheel directly with `uv build` and none of those set is the
local-development path: the hook runs `zig build` itself and derives this
machine's tag.

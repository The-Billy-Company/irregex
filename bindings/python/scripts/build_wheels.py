#!/usr/bin/env python3
"""Build the platform wheel matrix from one machine.

Zig cross-compiles, which is the whole reason this is cheap: every target below
is produced by the same host, from the same sources, with no CI fan-out and no
emulation. Each wheel differs only in the shared library inside it and the
platform tag on the outside.

    python3 scripts/build_wheels.py                 # every target
    python3 scripts/build_wheels.py --only native   # the one matching this host
    python3 scripts/build_wheels.py --list          # what the matrix covers

Wheels land in ``dist/``. A target that fails is reported and does not stop the
others, so one broken toolchain does not cost you the rest of the matrix.

Every target names an explicit minimum platform version in its Zig triple, and
its wheel tag says the same number. Letting Zig inherit the host's macOS SDK
would produce a library that refuses to load on an older machine than the one
that built it, under a tag promising it would.

**The native target produces two wheels, not one.** Every target gets the
portable ``py3-none-<tag>`` wheel, which is ctypes over the stdlib and installs
on any interpreter. The one target this machine *is* additionally gets a
``cp312-abi3-<tag>`` wheel carrying the C accelerator, which needs the target's
own Python headers and so cannot be cross-built. pip prefers the accelerated
wheel wherever it fits and falls back to the portable one everywhere else - a
free-threaded build, PyPy, an architecture no release machine runs - so
publishing both is what makes the accelerator an optimization rather than a
narrowing of who can install this at all. Run the script once per architecture
you want accelerated; the portable half of the matrix still comes from one host.
"""

from __future__ import annotations

import argparse
import os
import platform
import runpy
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
ENGINE = PROJECT.parent.parent


@dataclass(frozen=True)
class Target:
    name: str
    #: The Zig triple, with an explicit minimum OS version.
    zig: str
    #: The wheel platform tag, which must agree with that minimum.
    tag: str
    #: Where Zig installs the shared library under --prefix.
    artifact: str
    #: The ``-Dcpu`` subtarget: the instruction floor this wheel may use, and
    #: therefore the oldest CPU it runs on. Named per target rather than left to
    #: Zig's default, because the default is a decision either way and an
    #: unwritten one cannot be reviewed.
    cpu: str
    #: ``(sys.platform, machine)`` this target is the native one for.
    host: tuple[str, str] | None = None


_DYLIB = "lib/libirgx.dylib"
_SO = "lib/libirgx.so"
_DLL = "bin/irgx.dll"

# glibc 2.17 is the manylinux2014 floor and still the widest useful baseline;
# Zig links against exactly that version rather than the host's, which is what
# makes a manylinux wheel from a macOS laptop a real thing rather than a claim.
# macOS 11 is where arm64 begins, so it is the floor there and pip rejects any
# tag below it for that architecture. Windows names its floor for the same
# reason the others do, and picks Windows 10 RS4 because that is what
# `build.zig`'s own `check-windows` drift gate compiles against - a wheel and
# the gate that guards it should describe one platform. The tag cannot say so
# (`win_amd64` carries no version), which makes writing it here the only place
# the promise exists.
#
# On the CPU floors. A wheel tag says which OS and architecture it runs on and
# has no way to say which *instructions*, so that half of the promise is kept
# here or nowhere. aarch64's baseline already includes NEON, which is every
# vector path the engine has on that architecture, so there is nothing to
# raise. x86_64's baseline is SSE2 and that is genuinely too low: the scan
# kernels want `pshufb`, which is SSSE3. So x86_64 ships at v2 - SSSE3, SSE4.2,
# POPCNT - which is Nehalem (2008) and Bulldozer (2011) and up, and is the same
# floor RHEL 9 chose for an entire distribution. The one thing it costs is
# Core 2 / Penryn, whose SSE stops at 4.1.
#
# The tier above, v3, is where AVX2 lives, and it is worth roughly double: the
# same C-ABI surface emits 9.8k ymm instructions against 23k xmm ones at v2
# (`zig build ir -Dtarget=… -Dcpu=…` prints the assembly either way). It is not
# here because a static v3 wheel would refuse to run on anything before 2013,
# and the way to have that width without that cost is runtime dispatch on top
# of a v2 floor, which the engine does not do yet.
MATRIX = (
    Target(
        "macos-arm64",
        "aarch64-macos.11.0",
        "macosx_11_0_arm64",
        _DYLIB,
        "baseline",
        ("darwin", "arm64"),
    ),
    Target(
        "macos-x86_64",
        "x86_64-macos.11.0",
        "macosx_11_0_x86_64",
        _DYLIB,
        "x86_64_v2",
        ("darwin", "x86_64"),
    ),
    Target(
        "linux-x86_64",
        "x86_64-linux-gnu.2.17",
        "manylinux_2_17_x86_64",
        _SO,
        "x86_64_v2",
        ("linux", "x86_64"),
    ),
    Target(
        "linux-aarch64",
        "aarch64-linux-gnu.2.17",
        "manylinux_2_17_aarch64",
        _SO,
        "baseline",
        ("linux", "aarch64"),
    ),
    Target(
        "windows-x86_64",
        "x86_64-windows.win10_rs4-gnu",
        "win_amd64",
        _DLL,
        "x86_64_v2",
        ("win32", "AMD64"),
    ),
    Target(
        "windows-arm64",
        "aarch64-windows.win10_rs4-gnu",
        "win_arm64",
        _DLL,
        "baseline",
        ("win32", "ARM64"),
    ),
)


def native_target() -> Target | None:
    """The matrix entry this machine is the native host for, if any.

    Resolved by name rather than by building without ``-Dtarget``: a host build
    inherits the machine's SDK, and then the wheel's tag and the library's real
    minimum version are two independent guesses at the same number.
    """
    here = (sys.platform, platform.machine())
    return next((t for t in MATRIX if t.host == here), None)


def build_library(target: Target, prefix: Path) -> Path:
    # Stripped, because nobody `pip install`s a library to debug its internals.
    # On ELF the DWARF outweighs the code about four to one, so this is the
    # difference between an 11 MB wheel and a 2 MB one; Mach-O is already small
    # because its debug info lives in a separate `.dSYM` that never ships here.
    command = [
        "zig",
        "build",
        "-j1",
        "-Doptimize=ReleaseFast",
        "-Dstrip=true",
        f"-Dtarget={target.zig}",
        f"-Dcpu={target.cpu}",
        "--prefix",
        str(prefix),
    ]
    subprocess.run(command, cwd=ENGINE, check=True)
    built = prefix / target.artifact
    if not built.is_file():
        raise RuntimeError(f"zig build produced no {target.artifact}")
    return built


def build_wheel(target: Target, library: Path, outdir: Path, *, accel: bool = False) -> None:
    env = os.environ | {
        "IRGX_PREBUILT_LIB": str(library),
        "IRGX_WHEEL_PLATFORM": target.tag,
        "IRGX_ZIG_TARGET": target.zig,
        # Unused on this path, which hands over a library already built above,
        # but it keeps this matrix the single table: a source build triggered
        # with the same environment resolves the same floor.
        "IRGX_ZIG_CPU": target.cpu,
        # Never `auto` from here. Each wheel this script makes is one of the two
        # deliberately, so a machine that quietly lost its compiler publishes a
        # failure rather than a second portable wheel wearing the same name.
        "IRGX_ACCEL": "1" if accel else "0",
    }
    if shutil.which("uv"):
        command = ["uv", "build", "--wheel", "--out-dir", str(outdir)]
    else:
        command = [sys.executable, "-m", "build", "--wheel", "--outdir", str(outdir)]
    subprocess.run(command, cwd=PROJECT, check=True, env=env)


def chosen_targets(only: list[str] | None) -> list[Target]:
    if not only:
        return list(MATRIX)
    picked: list[Target] = []
    for name in only:
        if name == "native":
            here = native_target()
            if here is None:
                raise SystemExit(
                    f"no matrix target for {sys.platform}/{platform.machine()}; "
                    f"name one of {', '.join(t.name for t in MATRIX)}"
                )
            picked.append(here)
            continue
        found = next((t for t in MATRIX if t.name == name), None)
        if found is None:
            raise SystemExit(f"no target named {name!r}")
        picked.append(found)
    return picked


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--only", action="append", metavar="NAME", help="build just these targets, or 'native'"
    )
    parser.add_argument("--list", action="store_true", help="print the matrix and exit")
    parser.add_argument("--outdir", default=str(PROJECT / "dist"), help="where wheels land")
    parser.add_argument(
        "--native-archives", type=Path, help="retain the same build's static libraries for Rust/Go"
    )
    args = parser.parse_args()

    here = native_target()
    if args.list:
        for target in MATRIX:
            mark = " (native)" if target is here else ""
            print(
                f"{target.name:16} zig={target.zig:24} cpu={target.cpu:10} tag={target.tag}{mark}"
            )
        return 0

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    failures: list[tuple[str, str]] = []
    strip = None
    if args.native_archives:
        vendor = runpy.run_path(str(ENGINE / "bindings/rust/scripts/vendor_libraries.py"))
        strip = vendor["find_tool"]("llvm-strip", "LLVM_STRIP")
        if not strip:
            raise SystemExit("llvm-strip is required to retain native archives")

    for target in chosen_targets(args.only):
        print(f"\n=== {target.name} ({target.zig}) -> {target.tag} ===", flush=True)
        try:
            with tempfile.TemporaryDirectory(prefix=f"irregex-{target.name}-") as staging:
                library = build_library(target, Path(staging))
                if args.native_archives:
                    archive = Path(staging) / "lib/libirgx.a"
                    destination = args.native_archives.resolve() / target.name / archive.name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(archive, destination)
                    subprocess.run([strip, "--strip-debug", str(destination)], check=True)
                build_wheel(target, library, outdir)
                # One library, two wheels: the accelerator is a second file
                # beside the same `.dylib`/`.so`, so the Zig build above is not
                # paid twice.
                if target is here:
                    print(f"--- {target.name}: accelerated wheel ---", flush=True)
                    build_wheel(target, library, outdir, accel=True)
        except (subprocess.CalledProcessError, RuntimeError, OSError) as exc:
            print(f"FAILED {target.name}: {exc}", file=sys.stderr)
            failures.append((target.name, str(exc)))

    print("\n=== wheels ===")
    minted = sorted(outdir.glob("*.whl"))
    for wheel in minted:
        print(f"  {wheel.name}")
    if failures:
        print("\n=== failed targets ===")
        for name, why in failures:
            print(f"  {name}: {why}")
    if bad := accel_shortfall(minted, here, args.only):
        print(f"\n=== refusing this matrix ===\n  {bad}", file=sys.stderr)
        return 1
    return 1 if failures else 0


def accel_shortfall(minted: list[Path], here: Target | None, only: list[str] | None) -> str | None:
    """Why this matrix must not be published, or ``None`` if it may be.

    A matrix of nothing but ``py3-none`` wheels is the one bad release this
    script can produce while exiting 0, and it has: 2.0.0 and 2.1.x went out
    portable-only, so every ``pip install`` got ctypes. That path is *correct* -
    same answers, same exit codes - so nothing downstream breaks and nobody
    notices, while it pays ~1.7us of argument marshaling per call and forfeits
    the literal prefilter. Measured on one consumer's real workload it turned a
    1.2x win over stdlib ``re`` into an 11x loss. A silent 13x is not a
    packaging detail, so this refuses rather than reports.

    Two ways to get there, both quiet. The host may not be in the matrix at all,
    in which case ``target is here`` never fires and no accelerated wheel is even
    attempted. Or its build may fail while the portable wheel beside it succeeds,
    which lands in ``failures`` as one target among many rather than as the thing
    that gutted the release.

    A deliberately narrow ``--only`` is not a release and is left alone; the
    check is about what a full matrix promises.
    """
    if only or not minted:
        return None
    if any("-abi3-" in wheel.name for wheel in minted):
        return None
    if here is None:
        return (
            f"no accelerated wheel: this host ({sys.platform}/{platform.machine()}) is not in "
            f"the matrix, so none was attempted. Build the accelerated half on a host that is "
            f"({', '.join(t.name for t in MATRIX)}), or publish from one."
        )
    return (
        f"no accelerated wheel: the {here.name} build produced only a portable py3-none wheel. "
        f"Run `python3 scripts/build_accel.py` and read its error - the accelerator needs this "
        f"interpreter's own headers, so a missing compiler or Python-dev package is the usual "
        f"cause. Publishing without it silently downgrades every consumer to ctypes."
    )


if __name__ == "__main__":
    raise SystemExit(main())

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
"""

from __future__ import annotations

import argparse
import os
import platform
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
    #: ``(sys.platform, machine)`` this target is the native one for.
    host: tuple[str, str] | None = None


_DYLIB = "lib/libirregex.dylib"
_SO = "lib/libirregex.so"
_DLL = "bin/irregex.dll"

# glibc 2.17 is the manylinux2014 floor and still the widest useful baseline;
# Zig links against exactly that version rather than the host's, which is what
# makes a manylinux wheel from a macOS laptop a real thing rather than a claim.
# macOS 11 is where arm64 begins, so it is the floor there and pip rejects any
# tag below it for that architecture.
MATRIX = (
    Target("macos-arm64", "aarch64-macos.11.0", "macosx_11_0_arm64", _DYLIB, ("darwin", "arm64")),
    Target("macos-x86_64", "x86_64-macos.11.0", "macosx_11_0_x86_64", _DYLIB, ("darwin", "x86_64")),
    Target(
        "linux-x86_64", "x86_64-linux-gnu.2.17", "manylinux_2_17_x86_64", _SO, ("linux", "x86_64")
    ),
    Target(
        "linux-aarch64",
        "aarch64-linux-gnu.2.17",
        "manylinux_2_17_aarch64",
        _SO,
        ("linux", "aarch64"),
    ),
    Target("windows-x86_64", "x86_64-windows-gnu", "win_amd64", _DLL, ("win32", "AMD64")),
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
    command = [
        "zig",
        "build",
        "-Doptimize=ReleaseFast",
        f"-Dtarget={target.zig}",
        "--prefix",
        str(prefix),
    ]
    subprocess.run(command, cwd=ENGINE, check=True)
    built = prefix / target.artifact
    if not built.is_file():
        raise RuntimeError(f"zig build produced no {target.artifact}")
    return built


def build_wheel(target: Target, library: Path, outdir: Path) -> None:
    env = os.environ | {
        "IRREGEX_PREBUILT_LIB": str(library),
        "IRREGEX_WHEEL_PLATFORM": target.tag,
        "IRREGEX_ZIG_TARGET": target.zig,
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
    args = parser.parse_args()

    here = native_target()
    if args.list:
        for target in MATRIX:
            mark = " (native)" if target is here else ""
            print(f"{target.name:16} zig={target.zig:24} tag={target.tag}{mark}")
        return 0

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    failures: list[tuple[str, str]] = []

    for target in chosen_targets(args.only):
        print(f"\n=== {target.name} ({target.zig}) -> {target.tag} ===", flush=True)
        try:
            with tempfile.TemporaryDirectory(prefix=f"irregex-{target.name}-") as staging:
                library = build_library(target, Path(staging))
                build_wheel(target, library, outdir)
        except (subprocess.CalledProcessError, RuntimeError, OSError) as exc:
            print(f"FAILED {target.name}: {exc}", file=sys.stderr)
            failures.append((target.name, str(exc)))

    print("\n=== wheels ===")
    for wheel in sorted(outdir.glob("*.whl")):
        print(f"  {wheel.name}")
    if failures:
        print("\n=== failed targets ===")
        for name, why in failures:
            print(f"  {name}: {why}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

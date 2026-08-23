"""Hatchling build hook: put the native parts in the wheel, and tag it honestly.

A wheel that contains a ``.dylib`` is not ``py3-none-any``. Claiming otherwise
produces a file that pip will happily install on Linux and that will fail at
``import`` time, which is the worst possible place to discover the mistake. So
this hook builds (or accepts) the shared library, forces it into the wheel under
``irgx/lib/``, and sets the platform tag to match.

**Two kinds of wheel come out of this file**, and the difference is one
optional file:

``py3-none-<platform>``
    The engine plus a pure-Python ctypes binding. Any Python 3, no CPython ABI,
    this platform only. Cross-built for the whole matrix from one machine, which
    is why the project ships prebuilt wheels at all.

``cp312-abi3-<platform>``
    The same, plus :mod:`irgx._accel` - a stable-ABI C extension that carries
    the nine verbs this binding crosses the FFI with once per text. Limited API,
    so one binary serves 3.12 and every version after it. It needs the target's
    own Python headers, which is exactly what a cross-build does not have, so it
    is produced only when the build host *is* the target. pip prefers it over
    the portable wheel wherever both exist, and the package runs identically
    without it (see :mod:`irgx._engine`).

Environment variables:

``IRGX_PREBUILT_LIB``
    A library that is already built. The hook copies it instead of invoking
    Zig. This is what ``scripts/build_wheels.py`` uses, so the matrix script
    owns the Zig invocation and this hook stays a packaging step.

``IRGX_WHEEL_PLATFORM``
    The platform tag to stamp, e.g. ``manylinux_2_17_x86_64``. Required when
    cross-building, since the host's own tag would be a lie.

``IRGX_ACCEL``
    ``auto`` (default) builds the accelerator when the host is the target and
    skips it otherwise. ``1`` requires it and fails the build if it cannot be
    compiled - which is what CI wants, since a wheel that quietly lost its
    accelerator looks exactly like one that never had it. ``0`` declines.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import sysconfig
import tempfile
from pathlib import Path
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

# How to compile the accelerator lives beside the C source it is about, so this
# hook and `scripts/build_accel.py` cannot drift into building it two ways.
sys.path.insert(0, str(Path(__file__).resolve().parent / "accel"))
import toolchain  # noqa: E402

# Zig's install layout per OS: where the shared library lands under --prefix,
# and what it must be called inside the package for ctypes to find it.
_LAYOUT = {
    "windows": ("bin/irgx.dll", "irgx.dll"),
    "macos": ("lib/libirgx.dylib", "libirgx.dylib"),
    "linux": ("lib/libirgx.so", "libirgx.so"),
}


def _os_of(zig_target: str | None) -> str:
    if zig_target:
        for name in _LAYOUT:
            if name in zig_target:
                return name
        raise RuntimeError(f"cannot tell which OS {zig_target!r} is; expected macos/linux/windows")
    return toolchain.host_os()


def _zig_cpu(zig_target: str) -> str:
    """The instruction floor to build `zig_target` at.

    ``IRGX_ZIG_CPU`` overrides, which is how ``scripts/build_wheels.py`` keeps
    one table for the whole matrix. The fallback is the same rule that table
    encodes: aarch64's baseline already carries NEON and needs no raising,
    while x86_64's baseline is SSE2 and the scan kernels want SSSE3.
    """
    override = os.environ.get("IRGX_ZIG_CPU")
    if override:
        return override
    return "baseline" if zig_target.startswith("aarch64") else "x86_64_v2"


def _engine_root(start: Path) -> Path:
    """The Zig package root, found by walking up for ``build.zig``."""
    for parent in (start, *start.parents):
        if (parent / "build.zig").is_file():
            return parent
    raise RuntimeError(
        "cannot find the irregex Zig sources (no build.zig above "
        f"{start}). Building this wheel from an sdist needs either the engine "
        "sources or IRGX_PREBUILT_LIB pointing at a built library."
    )


class IrregexBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        if self.target_name != "wheel":
            return

        zig_target = os.environ.get("IRGX_ZIG_TARGET")
        which_os = _os_of(zig_target)
        _, installed_name = _LAYOUT[which_os]

        prebuilt = os.environ.get("IRGX_PREBUILT_LIB")
        if prebuilt:
            source = Path(prebuilt).resolve()
            if not source.is_file():
                raise RuntimeError(f"IRGX_PREBUILT_LIB={prebuilt!r} is not a file")
        else:
            source = self._build_with_zig(zig_target, which_os)

        build_data["pure_python"] = False
        build_data["infer_tag"] = False
        include = build_data.setdefault("force_include", {})
        include[str(source)] = f"irgx/lib/{installed_name}"

        accel = self._build_accel(zig_target, which_os)
        python = "py3-none"
        if accel is not None:
            include[str(accel)] = f"irgx/{accel.name}"
            python = f"cp{toolchain.ABI3_FLOOR[0]}{toolchain.ABI3_FLOOR[1]}-abi3"
        build_data["tag"] = f"{python}-{self._platform_tag()}"

    def _build_accel(self, zig_target: str | None, which_os: str) -> Path | None:
        """Compile ``accel/irgx_accel.c``, or answer ``None`` to ship without it.

        Every reason to skip is a legitimate one - a cross-build, a machine with
        no compiler, a deliberate ``IRGX_ACCEL=0`` - and none of them costs the
        wheel anything but speed, because the ctypes transport answers the same
        questions the same way. ``IRGX_ACCEL=1`` turns each of them into a build
        failure instead, which is what a release job wants: a wheel that quietly
        lost its accelerator is indistinguishable from one that never had it.
        """
        want = os.environ.get("IRGX_ACCEL", "auto").lower()
        required = want in ("1", "true", "yes", "require")
        if want in ("0", "false", "no", "off"):
            return None

        why = None
        if not toolchain.SOURCE.is_file():
            why = f"there is no {toolchain.SOURCE}"
        elif not toolchain.is_native(zig_target, which_os):
            why = (
                f"{zig_target} is not this host "
                f"({toolchain.host_arch()}-{toolchain.host_os()}), and an extension "
                f"has to be compiled against its own target's Python headers"
            )
        if why is not None:
            if required:
                raise RuntimeError(f"IRGX_ACCEL=1, but {why}")
            return None

        # Held on the instance for the same reason the library staging is: the
        # file has to outlive `initialize` for hatchling to read it back.
        self._accel_dir = tempfile.TemporaryDirectory(prefix="irregex-accel-")
        out = Path(self._accel_dir.name) / toolchain.filename()
        failed = toolchain.compile(out)
        if not failed:
            return out
        if required:
            raise RuntimeError(
                "IRGX_ACCEL=1, but no compiler produced the accelerator:\n  " + "\n  ".join(failed)
            )
        return None

    def _build_with_zig(self, zig_target: str | None, which_os: str) -> Path:
        if shutil.which("zig") is None:
            raise RuntimeError(
                "zig is not on PATH. Install Zig to build this wheel from source, "
                "or set IRGX_PREBUILT_LIB to a library you already have."
            )
        root = _engine_root(Path(self.root).resolve())
        # Held on the instance so the directory outlives `initialize` and is
        # still there when hatchling reads the file it force-included.
        self._staging = tempfile.TemporaryDirectory(prefix="irregex-wheel-")
        prefix = Path(self._staging.name)
        command = ["zig", "build", "-Doptimize=ReleaseFast", "--prefix", str(prefix)]
        if zig_target:
            # Naming a target also opts out of native CPU detection - Zig falls
            # back to that target's baseline, and x86_64's baseline is SSE2,
            # below the SSSE3 the scan kernels want. So a target implies a
            # floor. `scripts/build_wheels.py` sets both; a bare source build
            # names neither and keeps Zig's native detection, which is right.
            command += [f"-Dtarget={zig_target}", f"-Dcpu={_zig_cpu(zig_target)}"]
        subprocess.run(command, cwd=root, check=True)

        relative, _ = _LAYOUT[which_os]
        built = prefix / relative
        if not built.is_file():
            raise RuntimeError(f"zig build finished but produced no {relative} under {prefix}")
        return built

    @staticmethod
    def _platform_tag() -> str:
        """The tag to stamp: the caller's, or this machine's corrected for macOS.

        ``sysconfig`` describes the *interpreter*, and on macOS it describes it
        twice over. A universal2 CPython reports ``macosx-10-9-universal2``
        whatever it runs on, because the interpreter genuinely holds both
        slices; the library beside it holds one, since Zig builds one
        architecture. And ``10_9`` is not a tag pip accepts for arm64 at all -
        arm64 macOS starts at 11.0 - so a straight substitution would produce a
        wheel that installs nowhere. This path is the local-development
        fallback; ``scripts/build_wheels.py`` always passes the tag explicitly.
        """
        override = os.environ.get("IRGX_WHEEL_PLATFORM")
        if override:
            return override
        tag = sysconfig.get_platform().replace("-", "_").replace(".", "_")
        if not tag.startswith("macosx_"):
            return tag
        _, major, minor, arch = tag.split("_", 3)
        if arch == "universal2":
            arch = platform.machine()
        if arch == "arm64" and int(major) < 11:
            major, minor = "11", "0"
        return f"macosx_{major}_{minor}_{arch}"

    def finalize(self, version: str, build_data: dict[str, Any], artifact_path: str) -> None:
        for slot in ("_staging", "_accel_dir"):
            staging = getattr(self, slot, None)
            if staging is not None:
                staging.cleanup()
                setattr(self, slot, None)

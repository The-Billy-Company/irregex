"""Hatchling build hook: put the native library in the wheel, and tag it honestly.

A wheel that contains a ``.dylib`` is not ``py3-none-any``. Claiming otherwise
produces a file that pip will happily install on Linux and that will fail at
``import`` time, which is the worst possible place to discover the mistake. So
this hook does three things: build (or accept) the shared library, force it into
the wheel under ``irregex/lib/``, and set the platform tag to match.

The Python side is pure - it is ctypes, not a C extension - so the tag is
``py3-none-<platform>``: any Python 3, no CPython ABI, this platform only.

Two environment variables drive a cross-build:

``IRREGEX_PREBUILT_LIB``
    A library that is already built. The hook copies it instead of invoking
    Zig. This is what ``scripts/build_wheels.py`` uses, so the matrix script
    owns the Zig invocation and this hook stays a packaging step.

``IRREGEX_WHEEL_PLATFORM``
    The platform tag to stamp, e.g. ``manylinux_2_17_x86_64``. Required when
    cross-building, since the host's own tag would be a lie.
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

# Zig's install layout per OS: where the shared library lands under --prefix,
# and what it must be called inside the package for ctypes to find it.
_LAYOUT = {
    "windows": ("bin/irregex.dll", "irregex.dll"),
    "macos": ("lib/libirregex.dylib", "libirregex.dylib"),
    "linux": ("lib/libirregex.so", "libirregex.so"),
}


def _os_of(zig_target: str | None) -> str:
    if zig_target:
        for name in _LAYOUT:
            if name in zig_target:
                return name
        raise RuntimeError(f"cannot tell which OS {zig_target!r} is; expected macos/linux/windows")
    return {"darwin": "macos", "win32": "windows"}.get(sys.platform, "linux")


def _engine_root(start: Path) -> Path:
    """The Zig package root, found by walking up for ``build.zig``."""
    for parent in (start, *start.parents):
        if (parent / "build.zig").is_file():
            return parent
    raise RuntimeError(
        "cannot find the irregex Zig sources (no build.zig above "
        f"{start}). Building this wheel from an sdist needs either the engine "
        "sources or IRREGEX_PREBUILT_LIB pointing at a built library."
    )


class IrregexBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        if self.target_name != "wheel":
            return

        zig_target = os.environ.get("IRREGEX_ZIG_TARGET")
        which_os = _os_of(zig_target)
        _, installed_name = _LAYOUT[which_os]

        prebuilt = os.environ.get("IRREGEX_PREBUILT_LIB")
        if prebuilt:
            source = Path(prebuilt).resolve()
            if not source.is_file():
                raise RuntimeError(f"IRREGEX_PREBUILT_LIB={prebuilt!r} is not a file")
        else:
            source = self._build_with_zig(zig_target, which_os)

        build_data["pure_python"] = False
        build_data["infer_tag"] = False
        build_data["tag"] = f"py3-none-{self._platform_tag()}"
        build_data.setdefault("force_include", {})[str(source)] = f"irregex/lib/{installed_name}"

    def _build_with_zig(self, zig_target: str | None, which_os: str) -> Path:
        if shutil.which("zig") is None:
            raise RuntimeError(
                "zig is not on PATH. Install Zig to build this wheel from source, "
                "or set IRREGEX_PREBUILT_LIB to a library you already have."
            )
        root = _engine_root(Path(self.root).resolve())
        # Held on the instance so the directory outlives `initialize` and is
        # still there when hatchling reads the file it force-included.
        self._staging = tempfile.TemporaryDirectory(prefix="irregex-wheel-")
        prefix = Path(self._staging.name)
        command = ["zig", "build", "-Doptimize=ReleaseFast", "--prefix", str(prefix)]
        if zig_target:
            command.append(f"-Dtarget={zig_target}")
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
        override = os.environ.get("IRREGEX_WHEEL_PLATFORM")
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
        staging = getattr(self, "_staging", None)
        if staging is not None:
            staging.cleanup()
            self._staging = None

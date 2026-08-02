"""Test fixtures, and the one piece of setup the suite needs.

Running from a source checkout, the package has no bundled library yet - that
is placed by the build hook when a wheel is made. So point ``IRGX_LIB`` at
the engine's own build, using exactly the override a user would. Running against
an installed wheel, the bundled library is present and nothing here fires, which
is what makes the same suite valid in both places.
"""

from __future__ import annotations

import os
from pathlib import Path

_TESTS = Path(__file__).resolve().parent
_PACKAGE = _TESTS.parent / "irgx"
_ENGINE = _TESTS.parents[2]

_NAMES = ("libirgx.dylib", "libirgx.so", "irgx.dll")


def _point_at_the_engine_build() -> None:
    if os.environ.get("IRGX_LIB"):
        return
    if any((_PACKAGE / "lib" / name).is_file() for name in _NAMES):
        return
    for folder in ("lib", "bin"):
        for name in _NAMES:
            candidate = _ENGINE / "zig-out" / folder / name
            if candidate.is_file():
                os.environ["IRGX_LIB"] = str(candidate)
                return


_point_at_the_engine_build()

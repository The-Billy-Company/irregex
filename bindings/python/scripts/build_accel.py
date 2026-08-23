#!/usr/bin/env python3
"""Compile the accelerator into the source tree, for developing against it.

A checkout runs on ctypes until somebody builds this, which is correct - the
package must work without it - but it also means a source checkout measures the
slow transport and exercises half of what ships. So:

    python3 scripts/build_accel.py            # build it in place
    python3 scripts/build_accel.py --clean    # remove it and go back to ctypes

The output lands beside the package as ``irgx/_accel.abi3.so`` (``.pyd`` on
Windows), which is gitignored and which ``irgx._abi`` finds by plain import.
``IRGX_NO_ACCEL=1`` declines it per process without deleting it, which is how
the suite runs the whole surface on both transports.

How to compile is ``accel/toolchain.py``'s, the same module the wheel hook asks,
so a binary built here cannot differ from the one that ships.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT / "accel"))

import toolchain  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clean", action="store_true", help="remove it instead of building it")
    args = parser.parse_args()

    out = PROJECT / "irgx" / toolchain.filename()
    if args.clean:
        out.unlink(missing_ok=True)
        print(f"removed {out}")
        return 0

    failed = toolchain.compile(out, loud=True)
    if failed:
        raise SystemExit("could not build it:\n  " + "\n  ".join(failed))

    # Proving it imports is the point. A compiled file the interpreter refuses
    # to load is exactly the failure this script exists to surface, and the
    # package is designed to hide it - it would fall back to ctypes without a
    # word, which is right at runtime and useless while developing.
    check = subprocess.run(
        [sys.executable, "-c", "from irgx import _engine; print(' '.join(_engine.native()))"],
        cwd=PROJECT,
        capture_output=True,
        text=True,
    )
    if check.returncode != 0:
        raise SystemExit(f"built {out.name}, but importing it failed:\n{check.stderr}")
    print(f"\nbuilt {out}\nnative verbs: {check.stdout.strip()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

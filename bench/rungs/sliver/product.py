#!/usr/bin/env python3
"""Where the product binary is, now that this package does not build one.

The lanes beside this file measure *this* package's engine, but the only thing
that can exercise it end to end is the shipped CLI — and that CLI moved to its
own checkout when the kernel split into four. A path pinned under this repo's
`zig-out/` resolved to nothing the moment that landed, and a lane that carries
one dies at its first subprocess with a missing-file traceback rather than
saying which binary it wanted. Both lanes here asked the same question, so
they ask it in one place.

Resolution order is tightest pin first. `$<PREFIX>BIN` names an exact build,
which is what a mint wants: a committed number should be traceable to the bytes
that produced it. Failing that, the sibling checkout's release build beside this
one — the binary you just built is the binary you meant. Failing that, whatever
is installed, so an ad-hoc run works without ceremony.
"""

from __future__ import annotations

import functools
import os
import shutil
from pathlib import Path

PKG = Path(__file__).resolve().parents[3]
SIBLING = PKG.parent / "gist" / "zig-out" / "bin" / "gist"


@functools.cache
def gist_cli() -> str:
    """The product executable these lanes drive, or a diagnosis of why there is none.

    Resolved once per process: a matched pair that measured two different builds
    would be measuring nothing, and re-probing per invocation is how that
    happens on a tree somebody is rebuilding underneath the run.
    """
    if pinned := os.environ.get("GIST_BIN"):
        return pinned
    if os.access(SIBLING, os.X_OK):
        return str(SIBLING)
    if found := shutil.which("gist"):
        return found
    raise SystemExit(
        "this lane needs the `gist` CLI, which this package no longer builds.\n"
        f"  tried: $GIST_BIN, then {SIBLING}, then PATH\n"
        "  fix:   (cd ../gist && zig build -Doptimize=ReleaseFast)  —  or set GIST_BIN"
    )

#!/usr/bin/env python3
"""What the accelerator is worth, measured against ctypes and against ``re``.

Both transports in ONE process, interleaved, min-of-N. That shape is the point:
the two are chosen at import, so the obvious way to compare them is two runs -
and on a loaded machine two runs measure the machine. Here the same handle is
asked the same question through :data:`irgx._abi.ACCEL` and through
:data:`irgx._engine._FALLBACK` in the same loop, so whatever the box is doing it
is doing to both.

``re`` is measured beside them, because the number that matters to somebody
choosing this package is not "how much did the C extension save" but "is the
linear-time guarantee still free on a short string".

    python3 scripts/build_accel.py       # this measures nothing without it
    python3 scripts/bench_transport.py
    python3 scripts/bench_transport.py --repeat 15   # on a busy machine
"""

from __future__ import annotations

import argparse
import re
import sys
import timeit
from functools import partial
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT))
sys.path.insert(0, str(PROJECT / "tests"))  # conftest points IRGX_LIB at zig-out

import conftest  # noqa: F401,E402
import irgx  # noqa: E402
from irgx import _abi, _engine  # noqa: E402
from irgx._pool import Compiled  # noqa: E402

SHORT = "call 555-1234 now"
LINE = "the quick brown fox jumps over the lazy dog"
PAGE = LINE * 24  # ~1 KiB, a paragraph
DOC = LINE * 1520  # ~64 KiB, a source file

#: ``(label, pattern, text, verb, args-after-the-handle)``. Every case is a
#: question asked once per text, which is the only kind the accelerator carries.
CASES = (
    ("is_match  hit,   17 B", r"\d{3}-\d{4}", SHORT, "is_match", lambda t: (t, 0)),
    ("is_match  miss,  43 B", r"\d{3}-\d{4}", LINE, "is_match", lambda t: (t, 0)),
    ("find_all  1 match", r"(\w+)@(\w+)", "mail bob@host today", "find_all", lambda t: (t, 0, 0)),
    ("find_all  9 matches", r"\w+", LINE, "find_all", lambda t: (t, 0, 0)),
    ("find_all  ~1 KiB", r"\w+", PAGE, "find_all", lambda t: (t, 0, 0)),
    ("find_all  ~64 KiB", r"\w+", DOC, "find_all", lambda t: (t, 0, 0)),
    ("captures  3 groups", r"(\w+)@(\w+)", "mail bob@host today", "captures", lambda t: (t, 5, 2)),
)


def fastest(fn, number: int, repeat: int) -> float:
    """Nanoseconds per call, best of ``repeat``.

    The minimum rather than the mean, because every source of noise on a shared
    machine only ever makes a call slower - so the fastest observation is the
    closest thing to the cost with the noise removed.
    """
    return min(timeit.repeat(fn, number=number, repeat=repeat)) * 1e9 / number


def stdlib_asking(verb: str, compiled: re.Pattern, text: str):
    """The cheapest way to make ``re`` answer what ``verb`` answers.

    Built in its own scope rather than inline in the loop, so each closure holds
    its own ``compiled`` and ``text`` instead of whatever the loop variable is
    pointing at when ``timeit`` finally calls it. That distinction is invisible
    here - every callable is consumed in the iteration that made it - right up
    until somebody collects them into a list first, and then it silently
    measures the last row three times.
    """
    if verb == "is_match":
        return lambda: compiled.search(text) is not None
    if verb == "captures":
        # `span(0)` and not the match object: the accelerated verb hands back
        # spans, so timing `re` without the attribute access it takes to get
        # them would be flattering it by the thing being measured.
        return lambda: compiled.search(text).span(0)
    return lambda: [m.span() for m in compiled.finditer(text)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repeat", type=int, default=9, help="rounds per measurement")
    args = parser.parse_args()

    live = _engine.native()
    if not live:
        raise SystemExit("no accelerator here; build one with scripts/build_accel.py")
    print(f"library : {_abi.LIBRARY}")
    print(f"native  : {' '.join(live)}\n")
    print(f"{'case':24} {'accel':>10} {'ctypes':>10} {'re':>10} {'speedup':>9} {'vs re':>8}")
    print("-" * 76)

    for label, pattern, text, verb, shape in CASES:
        if verb not in live:
            continue
        held = Compiled(pattern.encode(), 0)
        # `partial` rather than a lambda over the loop variables, for the reason
        # `stdlib_asking` exists: it binds the handle and the arguments now.
        asked = (held.ptr.value, *shape(text))
        contenders = (
            partial(getattr(_abi.ACCEL, verb), *asked),
            partial(_engine._FALLBACK[verb], *asked),
            stdlib_asking(verb, re.compile(pattern), text),
        )
        number = 200 if len(text) > 10_000 else 20_000
        # Interleaved: one round of each, `repeat` times over. A slow round
        # lands on all three rather than on whichever ran while the box was busy.
        accel, ctypes_, stdlib = (fastest(fn, number, args.repeat) for fn in contenders)
        print(
            f"{label:24} {accel:9.0f}n {ctypes_:9.0f}n {stdlib:9.0f}n "
            f"{ctypes_ / accel:8.2f}x {stdlib / accel:7.2f}x"
        )

    print(
        "\nspeedup = ctypes / accel (what the extension bought)."
        "\nvs re   = re / accel (>1 means irgx is faster than the stdlib here)."
    )
    # Not decoration: every number above came from calling a transport directly,
    # which is the one way to time it and also the one way to time something the
    # package never actually routes to. This is the same work asked the ordinary
    # way, so a table of fast wrong answers cannot be reported as a result.
    sanity = irgx.findall(r"\w+", "a bc def")
    assert sanity == ["a", "bc", "def"], sanity
    print(f"\nsanity  : {sanity}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

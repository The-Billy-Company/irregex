#!/usr/bin/env python3
"""What a caller of the public surface pays, measured against ``re``.

:mod:`scripts.bench_transport` measures the seam - the accelerated verb against
its ctypes twin - and answers "what did the C extension buy". That is the wrong
question for somebody choosing this package, who never calls a transport. They
call ``pattern.search(text)`` and get a :class:`irgx.Match`, and between the two
sits a Python frame, a thread-local read, a type check and an object build that
the seam bench cannot see.

So this measures the surface: the same question asked of ``irgx`` and of ``re``,
the way a caller writes it, with the compile hoisted out of the loop for both.
Every row is also decomposed, because on a short text the interesting number is
not the total but which layer holds it::

    engine   what the seam call costs on its own (the accelerated verb, direct)
    surface  the total, through the public verb
    above    surface - engine: the Python side, which is what a C-type
             `Pattern`/`Match` could take and nothing else can

Interleaved and min-of-N for the reason ``bench_transport`` is: the contenders
run one round each, ``repeat`` times over, so a busy scheduler lands on all of
them rather than on whichever was running when the box got loaded.

    python3 scripts/build_accel.py         # this measures the ctypes path without it
    python3 scripts/bench_surface.py
    python3 scripts/bench_surface.py --repeat 15 --only search
"""

from __future__ import annotations

import argparse
import re
import sys
import timeit
from collections.abc import Callable, Iterator
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT))
sys.path.insert(0, str(PROJECT / "tests"))  # conftest points IRGX_LIB at zig-out

import conftest  # noqa: F401,E402
import irgx  # noqa: E402
from irgx import _abi, _engine  # noqa: E402

LINE = "the quick brown fox jumps over the lazy dog, and call 555-1234"
PAGE = LINE * 17  # ~1 KiB, a paragraph
DOC = LINE * 275  # ~17 KiB, a source file

#: ``(verb, pattern, subject-label, subject)``. The verb names which question is
#: asked; :func:`asking` builds both spellings of it.
CASES = (
    ("bool", "fox", "line", LINE),
    ("bool", "fox", "17 KiB", DOC),
    ("bool", r"\d{3}-\d{4}", "line", LINE),
    ("bool", "zebra", "17 KiB miss", DOC),
    ("search", "fox", "line", LINE),
    ("search", r"\d{3}-\d{4}", "line", LINE),
    ("search", r"\w+ing|\w+ox", "17 KiB", DOC),
    ("match", r"the \w+", "line", LINE),
    ("fullmatch", r"[\w\s,.\-]+", "line", LINE),
    ("group", r"(\w+) (\w+) (\w+)", "line", LINE),
    ("findall", r"\w+", "line", LINE),
    ("findall", r"\w+", "1 KiB", PAGE),
    ("findall", r"\w+", "17 KiB", DOC),
    ("findall", r"[a-z]+", "line", LINE),
    ("findall", r"(\w+)=(\d+)", "pairs", "a=1 bb=22 ccc=333 " * 8),
    ("finditer", r"\w+", "line", LINE),
    ("finditer", r"\w+", "17 KiB", DOC),
    ("sub", r"\s+", "line", LINE),
    ("sub", r"\s+", "1 KiB", PAGE),
    ("split", r"\s+", "line", LINE),
    ("compile", r"(\w+)=(\d+)", "-", ""),
)


def crossings(
    verb: str, held: irgx.Pattern, text: str
) -> tuple[tuple[str, tuple[object, ...]], ...]:
    """Every accelerated call ``verb`` makes on this row, in order.

    Summed, these are the row's ``engine`` column - the work that happens on the
    far side of the boundary no matter who calls it - so ``above`` is the Python
    surface and nothing else. Getting this wrong in the flattering direction is
    the easy mistake: ``groups()`` crosses twice (the span, then the capture
    pass) and charging it once would bill the second crossing to Python.
    """
    if verb in ("fullmatch", "compile"):
        # `fullmatch` crosses at `munch_scan`, which the accelerator does not seat,
        # and `compile` is the crossing. Neither has a floor to quote here.
        return ()
    handle = held._pool.handle()  # noqa: SLF001 - measuring the layer, not using it
    groups = held.groups
    if verb in ("bool", "search", "match"):
        return (("find_first", (handle, text, 0)),)
    if verb == "group":
        found = held.search(text)
        at = found.start() if found else 0
        return (("find_first", (handle, text, 0)), ("captures", (handle, text, at, groups)))
    if verb == "findall":
        return (
            (("texts", (handle, text, 0, True)),)
            if groups == 0
            else (("group_texts", (handle, text, 0, groups, True)),)
        )
    if verb in ("finditer", "sub", "split"):
        # All three walk the whole sequence once and then work per match in
        # Python - `sub` and `split` additionally slice and join, which has no
        # crossing at all.
        return (("find_all", (handle, text, 0, 0)),)
    raise ValueError(f"no such verb: {verb}")


def fastest(fn: Callable[[], object], number: int, repeat: int) -> float:
    """Nanoseconds per call, best of ``repeat``.

    The minimum rather than the mean: every source of noise on a shared machine
    only ever makes a call slower, so the fastest observation is the closest
    thing to the cost with the machine removed.
    """
    return min(timeit.repeat(fn, number=number, repeat=repeat)) * 1e9 / number


def asking(verb: str, pattern: str, text: str) -> tuple[Callable[[], object], ...]:
    """``(irgx, re)`` closures for ``verb``, each spelled the way a caller would.

    Both compiles happen here rather than in the timed callable, because a
    caller compiles once and searches many times and this measures the search.
    Each closure holds its own pattern and text rather than reading a loop
    variable, so collecting them into a list first cannot silently measure the
    last row twice.
    """
    if verb == "compile":
        # The one row where the compile IS the question. Both caches are purged
        # each call, because a caller who compiles the same source twice is
        # measuring a dict and every other row already hoisted the compile out.
        def mine() -> object:
            irgx.purge()
            return irgx.compile(pattern)

        def stdlib() -> object:
            re.purge()
            return re.compile(pattern)

        return (mine, stdlib)
    ours, theirs = irgx.compile(pattern), re.compile(pattern)
    if verb == "bool":
        # `re` has no boolean verb, so its cheapest spelling of the question is
        # the one a caller writes. Ours is the verb named after it.
        return (lambda: ours.is_match(text), lambda: theirs.search(text) is not None)
    if verb == "search":
        # The span and not the object: a `Match` nobody reads is a benchmark of
        # allocation, and the caller who wanted one wanted the offsets.
        return (lambda: ours.search(text).span(), lambda: theirs.search(text).span())
    if verb == "match":
        return (lambda: ours.match(text).span(), lambda: theirs.match(text).span())
    if verb == "fullmatch":
        return (lambda: ours.fullmatch(text).span(), lambda: theirs.fullmatch(text).span())
    if verb == "group":
        return (lambda: ours.search(text).groups(), lambda: theirs.search(text).groups())
    if verb == "findall":
        return (lambda: ours.findall(text), lambda: theirs.findall(text))
    if verb == "finditer":
        return (
            lambda: [m.span() for m in ours.finditer(text)],
            lambda: [m.span() for m in theirs.finditer(text)],
        )
    if verb == "sub":
        return (lambda: ours.sub("-", text), lambda: theirs.sub("-", text))
    if verb == "split":
        return (lambda: ours.split(text), lambda: theirs.split(text))
    raise ValueError(f"no such verb: {verb}")


def engine_floor(verb: str, pattern: str, text: str) -> tuple[Callable[[], object], ...]:
    """One timeable closure per crossing ``verb`` makes, or empty on ctypes.

    Each Pattern is parked in a default argument rather than merely referenced in
    the body: the handle is freed when its owner dies, so a closure holding only
    the address calls into freed memory the moment this frame returns - and a
    default costs nothing per call, where a body reference would have to be read.
    """
    if _abi.ACCEL is None:
        return ()
    held = irgx.compile(pattern)
    live = _engine.native()
    made = []
    for name, asked in crossings(verb, held, text):
        if name not in live:
            return ()
        call = getattr(_abi.ACCEL, name)
        made.append(lambda _owner=held, _call=call, _asked=asked: _call(*_asked))
    return tuple(made)


def rows(only: str | None) -> Iterator[tuple[str, str, str, str]]:
    for verb, pattern, label, text in CASES:
        if only is None or only == verb:
            yield verb, pattern, label, text


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repeat", type=int, default=11, help="rounds per measurement")
    parser.add_argument("--only", help=f"one verb: {', '.join(dict.fromkeys(c[0] for c in CASES))}")
    args = parser.parse_args()

    live = _engine.native()
    print(f"library : {_abi.LIBRARY}")
    print(f"native  : {' '.join(live) if live else 'none - ctypes transport'}\n")
    head = f"{'verb':9} {'pattern':18} {'subject':12}"
    print(f"{head} {'irgx':>9} {'re':>9} {'vs re':>7} {'engine':>8} {'above':>8}")
    print("-" * 88)

    for verb, pattern, label, text in rows(args.only):
        ours, theirs = asking(verb, pattern, text)
        floor = engine_floor(verb, pattern, text)
        # A compile is ~1000x a search, so it gets its own count rather than
        # spending a minute proving what 500 rounds already show.
        number = 500 if len(text) > 8_000 or verb == "compile" else 20_000
        # Interleaved: one round of each contender, `repeat` times over.
        mine = fastest(ours, number, args.repeat)
        stdlib = fastest(theirs, number, args.repeat)
        seam = sum(fastest(fn, number, args.repeat) for fn in floor) if floor else None
        shown = f"{seam:7.0f}n {mine - seam:7.0f}n" if seam is not None else f"{'':8} {'':8}"
        print(
            f"{verb:9} {pattern:18} {label:12} {mine:8.0f}n {stdlib:8.0f}n "
            f"{stdlib / mine:6.2f}x {shown}"
        )

    print(
        "\nvs re  = re / irgx (>1 means irgx is faster here)."
        "\nengine = the same seam call made directly; above = the Python surface over it."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

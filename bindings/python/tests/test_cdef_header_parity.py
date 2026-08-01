"""Every function the cffi mirror declares must be spelled as its header spells it.

`irregex.contract.abi.CDEF` is a hand-maintained mirror of the C headers, and cffi
resolves an ABI-mode symbol lazily — so a stale name in the mirror is invisible
until the call, and invisible *entirely* if the tier that would make the call is
skipped for want of a library. That is exactly how the mirror kept declaring
`gist_engine_open` for a while after the engine moved down into the substrate as
`irregex_engine_open`: nothing compared the two texts.

This gate compares them: for every function in the mirror, the union of the
reachable headers must declare one of that name, with the same return type and
the same parameter types (names ignored — those are documentation). Reading fails
closed, naming the header it wanted, because a mirror checked against a header
that isn't there is not checked at all.
"""

from __future__ import annotations

import functools
import re
from pathlib import Path

import pytest

from irregex.contract import abi as contract

# Which header each package publishes. The mirror spans all four: the substrate's
# own plus every producer it may describe (see ANALYTIC_CDEF).
HEADERS = ("irregex", "gist", "relate", "blast")

_COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)
_LINKAGE = re.compile(r'extern\s*"C"|[{}]')
_TOKEN = re.compile(r"[A-Za-z_]\w*|\*+|\[\]|\.\.\.")
_DECL = re.compile(r"^(?P<ret>[\w\s*]+?)\b(?P<name>\w+)\s*\((?P<params>.*)\)$", re.S)


def _header_path(pkg: str) -> Path:
    """`include/<pkg>.h`, in this checkout or the sibling that publishes it.

    The same ancestor-then-sibling rule `contract_path` uses, for the same
    reason: the four packages sit next to each other and no counted depth names
    them all.
    """
    here = Path(__file__).resolve()
    homes = (f"include/{pkg}.h", f"{pkg}/include/{pkg}.h")
    for base in here.parents:
        for home in homes:
            if (candidate := base / home).is_file():
                return candidate
    return here.parents[3] / homes[1]


def _types(params: str) -> tuple[str, ...]:
    """The parameter list reduced to its types, one flat token stream.

    A parameter's trailing identifier is its name — documentation, not contract —
    so it is dropped, while a lone `void` or a type-only parameter is kept whole.
    """
    out: list[str] = []
    for param in params.split(","):
        tokens = _TOKEN.findall(param)
        if len(tokens) > 1 and re.fullmatch(r"[A-Za-z_]\w*", tokens[-1]):
            tokens = tokens[:-1]
        out.extend(tokens)
    return tuple(out)


def _preprocessor_free(source: str) -> str:
    """Drop `#...` directives, continuations included.

    They carry no semicolon, so a `#define` above a declaration would otherwise
    land in the same chunk as the declaration and hide it — which is how the
    first draft of this gate managed to miss `irregex_status_message`, and how
    `extern "C" {` hid whichever declaration happens to come first.
    """
    kept, continuing = [], False
    for line in source.splitlines():
        if continuing or line.lstrip().startswith("#"):
            continuing = line.rstrip().endswith("\\")
            continue
        kept.append(line)
    return _LINKAGE.sub(" ", "\n".join(kept))


def _functions(source: str) -> dict[str, tuple[str, tuple[str, ...]]]:
    """`{name: (return type, parameter types)}` for every function declared."""
    found: dict[str, tuple[str, tuple[str, ...]]] = {}
    for statement in _preprocessor_free(_COMMENT.sub(" ", source)).split(";"):
        text = " ".join(statement.split())
        if not text or text.startswith("typedef") or "(" not in text:
            continue
        if (match := _DECL.match(text)) is None:
            continue
        found[match["name"]] = (" ".join(match["ret"].split()), _types(match["params"]))
    return found


@functools.cache
def _declared() -> dict[str, tuple[str, tuple[str, ...]]]:
    """Every function the reachable headers declare, keyed by name."""
    merged: dict[str, tuple[str, tuple[str, ...]]] = {}
    for pkg in HEADERS:
        path = _header_path(pkg)
        if not path.is_file():
            pytest.fail(
                f"include/{pkg}.h not found (looked at {path}). The mirror cannot be "
                f"checked against a header that is not there; check out {pkg} beside "
                f"this repo."
            )
        merged |= _functions(path.read_text(encoding="utf-8"))
    return merged


@functools.cache
def _mirrored() -> dict[str, tuple[str, tuple[str, ...]]]:
    return _functions(contract.CDEF + contract.ANALYTIC_CDEF)


def test_the_mirror_declares_something() -> None:
    """Guard the extractor itself: a regex that matches nothing would pass silently."""
    mirrored = _mirrored()
    assert len(mirrored) > 15, f"only parsed {len(mirrored)} functions out of the mirror"
    assert "irregex_engine_open" in mirrored
    assert len(_declared()) > 15


@pytest.mark.parametrize("name", sorted(_mirrored()))
def test_every_mirrored_function_matches_its_header(name: str) -> None:
    declared = _declared()
    assert name in declared, (
        f"the cffi mirror declares {name}, which no reachable header does. Either it "
        f"was renamed (the mirror is stale) or it never existed (cffi will resolve it "
        f"lazily and fail at the call site instead of here)."
    )
    want_ret, want_params = declared[name]
    got_ret, got_params = _mirrored()[name]
    assert got_params == want_params, (
        f"{name}: the mirror takes {got_params}, the header declares {want_params}"
    )
    assert got_ret == want_ret, (
        f"{name}: the mirror returns {got_ret!r}, the header declares {want_ret!r}"
    )

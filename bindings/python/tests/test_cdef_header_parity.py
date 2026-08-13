"""Every function the cffi mirror declares must be spelled as its header spells it.

`irgx.contract.abi.CDEF` is a hand-maintained mirror of the C headers, and cffi
resolves an ABI-mode symbol lazily — so a stale name in the mirror is invisible
until the call, and invisible *entirely* if the tier that would make the call is
skipped for want of a library. That is exactly how the mirror kept declaring
a face-prefixed `engine_open` for a while after the engine moved down into the
substrate as `irgx_engine_open`: nothing compared the two texts.

This gate compares them: for every function in the mirror, `include/irgx.h` must
declare one of that name, with the same return type and the same parameter types
(names ignored — those are documentation). Reading fails closed, naming the
header it wanted, because a mirror checked against a header that isn't there is
not checked at all.

**One header, on purpose.** This gate reads `include/irgx.h` and nothing else,
because the mirror it checks declares `irgx_*` and nothing else. A producer
symbol belongs to the library that EXPORTS it, so a `<face>_run` is declared in
that face's own header, mirrored in that face's own native module, and gated
against that header in its own repo. The result is that this suite needs no
sibling checkout to run —
anyone can clone this repo alone and get the same verdict — and no product's
release can be blocked on the engine's, nor the engine's on a product's.
"""

from __future__ import annotations

import functools
import re
from pathlib import Path

import pytest
from irgx.contract import abi as contract

# The one header this package publishes, and the only one this gate reads. The
# stem is not the package name — this package is `irregex` and publishes
# `irgx.h`, the same split the C prefix and the Python import name carry.
HEADER = "include/irgx.h"

_COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)
_LINKAGE = re.compile(r'extern\s*"C"|[{}]')
_TOKEN = re.compile(r"[A-Za-z_]\w*|\*+|\[\]|\.\.\.")
_DECL = re.compile(r"^(?P<ret>[\w\s*]+?)\b(?P<name>\w+)\s*\((?P<params>.*)\)$", re.S)


def _header_path() -> Path:
    """`include/irgx.h`, found by walking up from this file.

    An ancestor walk rather than a counted depth, so the suite keeps working if
    it is run from a different directory or moved a level. It never looks
    sideways: the header this mirror answers to is published by this repo, and
    a gate that could satisfy itself from a sibling checkout would be a gate on
    whatever happened to be next to it.
    """
    here = Path(__file__).resolve()
    for base in here.parents:
        if (candidate := base / HEADER).is_file():
            return candidate
    return here.parents[3] / HEADER


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
    first draft of this gate managed to miss `irgx_status_message`, and how
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
    """Every function this package's header declares, keyed by name."""
    path = _header_path()
    if not path.is_file():
        pytest.fail(
            f"{HEADER} not found (looked at {path}). The mirror cannot be checked "
            f"against a header that is not there."
        )
    return _functions(path.read_text(encoding="utf-8"))


@functools.cache
def _mirrored() -> dict[str, tuple[str, tuple[str, ...]]]:
    return _functions(contract.CDEF + contract.ANALYTIC_CDEF)


def test_the_mirror_declares_something() -> None:
    """Guard the extractor itself: a regex that matches nothing would pass silently.

    Named anchors rather than a bare count, because a count is a guard that has to
    be re-based every time the surface legitimately moves — as it did when the
    product halves of this mirror went to the packages that own them — and one
    re-based by reflex stops guarding anything. These four span the mirror's
    sections (engine, status, row cursor, schema), so a parse that silently
    matched a fraction of the text still fails.
    """
    mirrored = _mirrored()
    for anchor in (
        "irgx_engine_open",
        "irgx_status_message",
        "irgx_rows_next",
        "irgx_schema_digest",
    ):
        assert anchor in mirrored, f"the extractor found no {anchor} in the mirror"
    assert len(_declared()) > len(mirrored), (
        "irgx.h should declare more than the mirror does — it also carries the "
        "regex API, which this cffi tier does not use"
    )


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

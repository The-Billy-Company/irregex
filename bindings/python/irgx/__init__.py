"""irregex - a linear-time regex engine for Python, with no compiler required.

The engine is written in Zig and ships inside the wheel as a shared library
loaded with :mod:`ctypes`. There is no build step at install time, no Zig
toolchain, and no separate binary to put on ``PATH``.

The surface mirrors :mod:`re` closely enough to port most code by changing the
import::

    import irgx

    for m in irgx.finditer(r"\\w+", "naive cafe"):
        print(m.span(), m.group())

Three things differ from :mod:`re`, and each is deliberate:

* Matching is **linear time** in the length of the text. There is no
  catastrophic backtracking, and correspondingly no lookaround or
  backreferences in the default grammar. Pass ``pcre=True`` for those and
  accept a backtracking engine.
* Flags are **keyword arguments**, not an or-ed bitmask, and include options
  ``re`` has no spelling for: ``fixed``, ``word``, ``smart_case``.
* There is a type :mod:`re` has none of: :func:`compile_set` asks *which* of N
  patterns are in a text, in one pass, keeping the attribution an alternation
  would have thrown away.
"""

from __future__ import annotations

import functools
import importlib.metadata as _metadata
from collections.abc import Callable, Iterator
from typing import Any

from ._abi import ENGINE_VERSION, LIBRARY, PCRE2_VERSION, UnsupportedPattern, error
from ._match import Match
from ._pattern import Pattern, flag_bits
from ._set import PatternSet, compile_set

__all__ = [
    "ENGINE_VERSION",
    "LIBRARY",
    "PCRE2_VERSION",
    "Match",
    "Pattern",
    "PatternSet",
    "UnsupportedPattern",
    "__version__",
    "compile",
    "compile_set",
    "error",
    "escape",
    "findall",
    "finditer",
    "is_match",
    "purge",
    "search",
    "split",
    "sub",
    "subn",
]

#: The version of this Python package, read from the installed distribution's
#: own metadata rather than restated here — ``pyproject.toml`` is the only
#: place it is written, and a release moves that one line. A source checkout
#: that was never installed has no metadata to read, so it falls back to the
#: version the linked engine reports, which is what such a tree is actually
#: running. The engine has its own version, which one wheel can carry a newer
#: copy of without any API change here: :data:`ENGINE_VERSION`.
try:
    __version__ = _metadata.version("irregex")
except _metadata.PackageNotFoundError:  # source checkout, never pip-installed
    __version__ = ENGINE_VERSION

_Flags = dict[str, bool]


@functools.lru_cache(maxsize=512)
def _cached(pattern: str | bytes, flags: int) -> Pattern:
    return Pattern(pattern, flags)


def compile(  # noqa: A001 - shadows the builtin exactly as `re.compile` does
    pattern: str | bytes,
    *,
    fixed: bool = False,
    ignore_case: bool = False,
    word: bool = False,
    smart_case: bool = False,
    unicode: bool = True,
    multiline: bool = False,
    dotall: bool = False,
    pcre: bool = False,
) -> Pattern:
    """Compile ``pattern`` into a :class:`Pattern`.

    A pattern compiled from ``str`` searches ``str`` and reports codepoint
    indices; one compiled from ``bytes`` searches ``bytes`` and reports byte
    offsets. Mixing the two raises :exc:`TypeError`.

    A pattern may ask for these flags itself, in :mod:`re`'s own leading
    ``(?ims)`` form (plus ``(?-u)`` for ASCII semantics). Where both speak, the
    pattern wins, being the more specific statement: ``compile("(?-i)cat",
    ignore_case=True)`` is case-sensitive. As in :mod:`re` since 3.11, only a
    *leading* run is a whole-pattern flag; ``(?x)`` and the other letters this
    grammar does not have need ``pcre=True``.

    :param fixed: treat the pattern as a literal string, not a regex.
    :param ignore_case: fold case when matching.
    :param word: only report matches that stand alone as words.
    :param smart_case: fold case only if the pattern contains no uppercase.
    :param unicode: Unicode classes, folding and boundaries. On by default;
        ``unicode=False`` selects ASCII/byte semantics.
    :param multiline: ``re.M`` - ``^`` and ``$`` also match at a line break.
        Off by default, so they mean the ends of the text you passed;
        ``\\A`` and ``\\z`` mean those regardless.
    :param dotall: ``re.S`` - ``.`` matches a newline too.
    :param pcre: use the PCRE2 grammar, which has lookaround and
        backreferences and is not linear time.
    :raises UnsupportedPattern: if the pattern is well-formed but outside the
        linear grammar, in which case ``pcre=True`` compiles it.
    :raises error: if the pattern is malformed. The exception's ``pos`` says
        where.
    """
    return Pattern(
        pattern,
        flag_bits(
            fixed=fixed,
            ignore_case=ignore_case,
            word=word,
            smart_case=smart_case,
            unicode=unicode,
            multiline=multiline,
            dotall=dotall,
            pcre=pcre,
        ),
    )


def _prepared(pattern: str | bytes | Pattern, flags: _Flags) -> Pattern:
    """The Pattern for a module-level call, compiled once and reused.

    Module-level calls in a loop are the common shape, so an already-compiled
    pattern is cached by source and flags. Passing a :class:`Pattern` skips the
    cache entirely, which is what a caller who compiled it themselves expects.
    """
    if isinstance(pattern, Pattern):
        if flags:
            raise ValueError(
                "cannot pass flags with an already-compiled Pattern; "
                "the flags it was compiled under are fixed"
            )
        return pattern
    # An unknown keyword raises TypeError out of `flag_bits`, so a typo like
    # `ignorecase=True` fails loudly instead of silently matching case.
    return _cached(pattern, flag_bits(**flags))


def purge() -> None:
    """Drop the module-level pattern cache."""
    _cached.cache_clear()


def is_match(
    pattern: str | bytes | Pattern,
    text: str | bytes,
    **flags: bool,
) -> bool:
    """Whether ``text`` holds a match. The cheapest question the engine answers."""
    return _prepared(pattern, flags).is_match(text)


def search(
    pattern: str | bytes | Pattern,
    text: str | bytes,
    **flags: bool,
) -> Match | None:
    """The first match of ``pattern`` in ``text``, or ``None``."""
    return _prepared(pattern, flags).search(text)


def finditer(
    pattern: str | bytes | Pattern,
    text: str | bytes,
    **flags: bool,
) -> Iterator[Match]:
    """Every match of ``pattern`` in ``text``, in order."""
    return _prepared(pattern, flags).finditer(text)


def findall(
    pattern: str | bytes | Pattern,
    text: str | bytes,
    **flags: bool,
) -> list[Any]:
    """Match texts, or group texts when ``pattern`` declares groups."""
    return _prepared(pattern, flags).findall(text)


def split(
    pattern: str | bytes | Pattern,
    text: str | bytes,
    maxsplit: int = 0,
    **flags: bool,
) -> list[Any]:
    """``text`` split around each match of ``pattern``."""
    return _prepared(pattern, flags).split(text, maxsplit)


def sub(
    pattern: str | bytes | Pattern,
    repl: str | bytes | Callable[[Match], Any],
    text: str | bytes,
    count: int = 0,
    **flags: bool,
) -> Any:
    """``text`` with each match of ``pattern`` replaced by ``repl``.

    ``repl`` is either a template string, where ``\\1`` and ``\\g<name>`` refer
    to groups, or a callable taking the :class:`Match` and returning its
    replacement.
    """
    return _prepared(pattern, flags).sub(repl, text, count)


def subn(
    pattern: str | bytes | Pattern,
    repl: str | bytes | Callable[[Match], Any],
    text: str | bytes,
    count: int = 0,
    **flags: bool,
) -> tuple[Any, int]:
    """Like :func:`sub`, but also returns how many replacements were made."""
    return _prepared(pattern, flags).subn(repl, text, count)


_SPECIAL = frozenset("()[]{}?*+-|^$\\.&~# \t\n\r\v\f")


def escape(text: str | bytes) -> Any:
    """Backslash every character that carries meaning in a pattern.

    ``fixed=True`` is usually the better answer, since it needs no rewriting of
    the string at all. This exists so that code moving over from ``re`` keeps
    working, and for the case where a literal is being spliced into a larger
    pattern.
    """
    if isinstance(text, str):
        return "".join("\\" + c if c in _SPECIAL else c for c in text)
    return b"".join(b"\\" + bytes((c,)) if chr(c) in _SPECIAL else bytes((c,)) for c in bytes(text))

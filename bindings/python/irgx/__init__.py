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
* There are two types :mod:`re` has none of. :func:`compile_set` asks *which* of
  N patterns are in a text, in one pass, keeping the attribution an alternation
  would have thrown away; :func:`compile_munch` asks which of N patterns wins
  *at* a cursor and how far it reaches, which is the primitive a lexer runs on.
"""

from __future__ import annotations

import functools
import importlib.metadata as _metadata
from collections.abc import Callable, Iterator
from typing import Any

from ._abi import ENGINE_VERSION, LIBRARY, PCRE2_VERSION, UnsupportedPattern, error
from ._flags import flag_bits
from ._match import Match
from ._munch import Munch, Refusal, Scan, Token, Why, compile_munch
from ._pattern import Pattern
from ._set import PatternSet, compile_set

#: The planes beyond the buffer, and the one module each lives in. They are
#: resolved on first attribute access rather than imported here, because each one
#: binds its own prototypes at import time and a program that only ever calls
#: :func:`search` should not pay for the tree, the walk, the sieve and an
#: FM-index to be declared. It also means a wheel linked against an older engine
#: still imports: the plane that is missing raises when it is *reached for*,
#: naming the symbol, instead of making ``import irgx`` fail outright.
_PLANES: dict[str, tuple[str, str]] = {
    # anchored - re's match/fullmatch/Scanner, over the lexer plane
    "Scanner": ("_anchored", "Scanner"),
    "scanner": ("_anchored", "scanner"),
    # lines - byte offsets to the rows a person reads
    "Band": ("_lines", "Band"),
    "Line": ("_lines", "Line"),
    "line_context": ("_lines", "line_context"),
    "line_count": ("_lines", "line_count"),
    "split_lines": ("_lines", "split_lines"),
    # literals - what a pattern promises before it runs, and the Unicode tables
    "Facts": ("_literals", "Facts"),
    "Literals": ("_literals", "Literals"),
    "Place": ("_literals", "Place"),
    "Verdict": ("_literals", "Verdict"),
    "fold_orbit": ("_literals", "fold_orbit"),
    "literals": ("_literals", "literals"),
    "property_has": ("_literals", "property_has"),
    "property_ranges": ("_literals", "property_ranges"),
    "unicode_version": ("_literals", "unicode_version"),
    # needles - N literal strings in one pass, with attribution
    "Hit": ("_needles", "Hit"),
    "Needles": ("_needles", "Needles"),
    "Shape": ("_needles", "Shape"),
    "Tier": ("_needles", "Tier"),
    "compile_needles": ("_needles", "compile_needles"),
    # walk - which files a search may read
    "Ceilings": ("_walk", "Ceilings"),
    "File": ("_walk", "File"),
    "Genus": ("_walk", "Genus"),
    "Policy": ("_walk", "Policy"),
    "Walk": ("_walk", "Walk"),
    "genus": ("_walk", "genus"),
    "is_binary": ("_walk", "binary"),
    "walk": ("_walk", "walk"),
    "walk_limits": ("_walk", "limits"),
    # sieve - narrowing, so most files are never opened
    "Anchor": ("_sieve", "Anchor"),
    "Contents": ("_sieve", "Contents"),
    "Freshness": ("_sieve", "Freshness"),
    "Plan": ("_sieve", "Plan"),
    "Sieve": ("_sieve", "Sieve"),
    "Winnow": ("_sieve", "Winnow"),
    "sieve": ("_sieve", "sieve"),
    "winnow": ("_sieve", "winnow"),
    # tree - search a corpus on disk, not a buffer in hand
    "Cancel": ("_tree", "Cancel"),
    "Corpus": ("_tree", "Corpus"),
    "Cursor": ("_tree", "Cursor"),
    "Record": ("_tree", "Record"),
    "RecordKind": ("_tree", "Kind"),
    "corpus": ("_tree", "corpus"),
    # codex - an FM-index that answers about a text it does not store
    "Codex": ("_codex", "Codex"),
    "Cost": ("_codex", "Cost"),
    "Encoding": ("_codex", "Encoding"),
    "NO_LOCATE": ("_codex", "NO_LOCATE"),
    "Rows": ("_codex", "Rows"),
    "build_codex": ("_codex", "build"),
    "load_codex": ("_codex", "load"),
    "max_text_len": ("_codex", "max_text_len"),
}

__all__ = [
    "ENGINE_VERSION",
    "LIBRARY",
    "PCRE2_VERSION",
    "Match",
    "Munch",
    "Pattern",
    "PatternSet",
    "Refusal",
    "Scan",
    "Token",
    "UnsupportedPattern",
    "Why",
    "__version__",
    "compile",
    "compile_munch",
    "compile_set",
    "error",
    "escape",
    "findall",
    "finditer",
    "fullmatch",
    "is_match",
    "match",
    "purge",
    "search",
    "split",
    "sub",
    "subn",
    *_PLANES,
]


def __getattr__(name: str) -> Any:
    """Resolve a plane's export on first use.

    :raises AttributeError: for a name this package does not have — and, with the
        missing symbol named, for a plane the linked engine is too old to export.
    """
    try:
        module, attr = _PLANES[name]
    except KeyError:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}") from None
    import importlib

    value = getattr(importlib.import_module(f".{module}", __name__), attr)
    globals()[name] = value  # one import per plane, not one per access
    return value


def __dir__() -> list[str]:
    return sorted(__all__)


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


def _compiled(pattern: str | bytes, flags: int) -> Pattern:
    """The :class:`Pattern` for this source and these flags, compiled once.

    A compile costs ~200us here against ~0.1us for a hit off this cache, which
    is not a micro-optimization but the difference between a loop that recompiles
    per iteration being free and being unusable. :mod:`re` caches for the same
    reason, so a port that lifts ``re.compile(p).search(s)`` verbatim into a loop
    - the single most common shape there is - must not fall off a cliff here.
    Sharing one :class:`Pattern` between callers is what the object was built
    for: it holds a :class:`irgx._pool.Pool` of per-thread handles precisely so
    that the handle's single-threaded contract survives being shared.

    ``TEXTUAL`` admits ``bytearray``, which has no hash and so cannot key a
    cache. That is a pattern to compile uncached, not a pattern to refuse - the
    class accepts one, and the module-level verbs used to raise ``TypeError``
    from this cache for a pattern :func:`compile` took happily.
    """
    try:
        hash(pattern)
    except TypeError:
        return Pattern(pattern, flags)
    return _cached(pattern, flags)


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
    return _compiled(
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
    return _compiled(pattern, flag_bits(**flags))


def purge() -> None:
    """Drop the pattern cache that :func:`compile` and the module-level verbs share."""
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


def match(
    pattern: str | bytes | Pattern,
    text: str | bytes,
    **flags: bool,
) -> Match | None:
    """The match of ``pattern`` beginning at the start of ``text``, or ``None``."""
    return _prepared(pattern, flags).match(text)


def fullmatch(
    pattern: str | bytes | Pattern,
    text: str | bytes,
    **flags: bool,
) -> Match | None:
    """The match of ``pattern`` spanning the whole of ``text``, or ``None``."""
    return _prepared(pattern, flags).fullmatch(text)


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

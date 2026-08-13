"""What a pattern promises about its matches, and the tables the engine decides with.

An indexer needs to know, before it opens a file, which bytes any match MUST
contain. This plane answers that — and it answers with a *grade*, which is the
half a host cannot afford to lose. A candidate set proves only that the absence
of every member means no match; an exact set means containment and matching are
the same question. Build a prefilter on the wrong one and it silently drops real
matches, so :meth:`Literals.set` hands the grade back beside the bytes rather
than leaving it to be looked up separately and forgotten.

The Unicode verbs are here for the same reason: a host that folds case with its
own tables has a prefilter that disagrees with the matcher about what ``k`` is.
``'k'``, ``'K'`` and U+212A KELVIN SIGN are one fold class, so
:func:`fold_orbit` reports the orbit rather than a pair.
"""

from __future__ import annotations

import ctypes
import enum
from typing import TYPE_CHECKING, Any, NamedTuple

from ._abi import _VOID, MATCH, STALE, Text, check, declare, error, lib
from ._shape import Handle, borrowed, sink, sized

if TYPE_CHECKING:
    # The one thing this module needs from the pattern module is its name, and
    # only for the signature. Imported under the type-checking guard because a
    # runtime import here would be a load-order edge for a docstring's benefit.
    from ._pattern import Pattern

_U8P = ctypes.c_char_p
_SIZE = ctypes.c_size_t
_U32 = ctypes.c_uint32

#: ``max_len`` when the pattern has no upper bound at all (``a+``, ``.*``). A real
#: ceiling is never this value, so the sentinel cannot collide with a measurement.
UNBOUNDED = 0xFFFFFFFF

_PLACE_COUNT = 4


class Place(enum.IntEnum):
    """Which set of literals to read."""

    REQUIRED = 0
    """Bytes every match must contain somewhere."""
    PREFIX = 1
    """What a match may begin with."""
    SUFFIX = 2
    """What a match may end with."""
    WHOLE = 3
    """The complete strings the pattern accepts, when it accepts finitely many."""


class Verdict(enum.IntEnum):
    """How much a set proves. Ordered, so ``>= CANDIDATE`` is the safe-to-prune test."""

    NONE = 0
    """No set. Proves nothing either way — scan the document."""
    CANDIDATE = 1
    """Absence of EVERY member proves no match. Presence proves nothing and must
    still be verified against the document's bytes."""
    EXACT = 2
    """Containment and matching are one question."""


class Promise(ctypes.Structure):
    """``irgx_promise``: the whole-pattern promise, as the C layout spells it."""

    _fields_ = (
        ("struct_size", _U32),
        ("verdict", _U32 * _PLACE_COUNT),
        ("count", _U32 * _PLACE_COUNT),
        ("anchored", _U32),
        ("nullable", _U32),
        ("min_len", _U32),
        ("max_len", _U32),
        ("first_bytes", ctypes.c_uint64 * 4),
        ("signature", ctypes.c_uint64 * 2),
    )


class Range(ctypes.Structure):
    """``irgx_range``: an inclusive codepoint range."""

    _fields_ = (("lo", _U32), ("hi", _U32))


declare(
    (
        ("irgx_literals_open", ctypes.c_int32, (_VOID, ctypes.POINTER(_VOID))),
        ("irgx_literals_free", None, (_VOID,)),
        ("irgx_literals_promise", ctypes.c_int32, (_VOID, ctypes.POINTER(Promise))),
        (
            "irgx_literals_set",
            ctypes.c_int32,
            (_VOID, _U32, ctypes.POINTER(_U32), ctypes.POINTER(Text), _SIZE, ctypes.POINTER(_SIZE)),
        ),
        (
            "irgx_fold_orbit",
            ctypes.c_int32,
            (_U32, ctypes.POINTER(_U32), _SIZE, ctypes.POINTER(_SIZE)),
        ),
        (
            "irgx_property_ranges",
            ctypes.c_int32,
            (_U8P, _SIZE, ctypes.POINTER(Range), _SIZE, ctypes.POINTER(_SIZE)),
        ),
        ("irgx_property_has", ctypes.c_int32, (_U8P, _SIZE, _U32)),
        ("irgx_unicode_version", ctypes.c_int32, (ctypes.POINTER(Text),)),
    ),
    "the literal plane",
)


class Facts(NamedTuple):
    """What a pattern promises about every text that could match it."""

    anchored: bool
    """Whether a match can only begin at the start of the text."""
    nullable: bool
    """Whether the pattern accepts the empty string."""
    min_len: int
    max_len: int | None
    """The longest a match can be, or ``None`` when the pattern has no ceiling."""
    first_bytes: frozenset[int]
    """The bytes a match may BEGIN with. Empty means *unknown*, not "no byte can
    start a match" — the distinction a prefilter must not collapse."""
    signature: tuple[int, int]
    """A fingerprint of the LANGUAGE the pattern denotes, not of its text: two
    patterns spelled differently that accept the same set share it. For keying a
    derived artifact across spellings."""
    verdicts: tuple[Verdict, ...]
    """One grade per :class:`Place`, in :class:`Place` order."""
    counts: tuple[int, ...]
    """How many literals each :class:`Place` holds, in :class:`Place` order."""

    def verdict(self, place: Place) -> Verdict:
        """The grade for one place — how much that set proves."""
        return self.verdicts[int(place)]


class Literals(Handle):
    """What one compiled pattern promises about its matches.

    Build one with :func:`literals`, which can decline. Independent of the pattern
    once open: the handle copies what it needs, so the two are freed in either
    order.

    Use it as a context manager, or let the garbage collector close it. The
    ``irgx_text`` rows :meth:`set` reads BORROW this handle's arena, so they are
    copied into Python ``bytes`` before that method returns and nothing this
    class hands back can outlive its owner into a use-after-free.
    """

    __slots__ = ()

    def __init__(self, ptr: Any) -> None:
        super().__init__(ptr, lib.irgx_literals_free)

    def __repr__(self) -> str:
        # The promise, because it is the one thing a caller reaches this handle
        # for and the thing a bare object address cannot tell them. Read live
        # rather than cached: a closed handle says so instead of lying.
        try:
            facts = self.facts()
        except Exception:  # noqa: BLE001 - a repr never raises
            return "<irgx.Literals closed>"
        return (
            f"<irgx.Literals min_len={facts.min_len} max_len={facts.max_len} "
            f"anchored={facts.anchored} sets={sum(facts.counts)}>"
        )

    def facts(self) -> Facts:
        """The whole-pattern promise, and the size of every set, in one read.

        Read this BEFORE a set: it is what says whether the set you are about to
        read is a guarantee or a guess.
        """
        out = sized(Promise)
        check(
            lib.irgx_literals_promise(self.ptr, ctypes.byref(out)),
            "could not read the pattern's promise",
        )
        first = frozenset(
            byte for byte in range(256) if out.first_bytes[byte >> 6] >> (byte & 63) & 1
        )
        return Facts(
            anchored=bool(out.anchored),
            nullable=bool(out.nullable),
            min_len=out.min_len,
            max_len=None if out.max_len == UNBOUNDED else out.max_len,
            first_bytes=first,
            signature=(out.signature[0], out.signature[1]),
            verdicts=tuple(_verdict(out.verdict[i]) for i in range(_PLACE_COUNT)),
            counts=tuple(out.count[i] for i in range(_PLACE_COUNT)),
        )

    def set(self, place: Place) -> tuple[Verdict, tuple[bytes, ...]]:
        """One set of literals by ``place``, with the grade that says what it proves.

        The grade travels with the bytes rather than beside them, because a
        prefilter that reads a CANDIDATE set as an EXACT one drops real matches
        and looks correct while doing it.
        """
        verdict = _U32()
        handle = self.ptr
        _, out, count = sink(
            Text,
            lambda buf, cap, written: lib.irgx_literals_set(
                handle, int(place), ctypes.byref(verdict), buf, cap, written
            ),
            f"could not read the {Place(place).name.lower()} literals",
        )
        # Copied here, inside the call that produced them: the rows point into
        # this handle's arena and die with it.
        rows = tuple(bytes(ctypes.string_at(out[i].ptr, out[i].len)) for i in range(count))
        return _verdict(verdict.value), rows


def literals(pattern: Pattern) -> Literals | None:
    """What a compiled ``pattern`` promises about its matches, or ``None`` when the
    engine declines to say.

    ``None`` for a PCRE2-compiled pattern (``pcre=True``), and it is a
    declinature rather than a failure: that arm keeps no AST to under-claim from.
    The remedy is real rather than nominal — recompile the same text without
    ``pcre=True`` and ask again — so this returns a sentinel a caller can branch
    on instead of an exception it has to catch to discover a fact about its own
    pattern.
    """
    pool = getattr(pattern, "_pool", None)
    if pool is None:
        # A pattern's TEXT is the obvious thing to pass and the wrong one: the
        # promise is read off the compiled AST. Said here, because the alternative
        # is an AttributeError naming a private field.
        raise TypeError(
            f"literals() reads a compiled pattern, not {type(pattern).__name__} — "
            f"compile it first with irgx.compile()"
        )
    out = _VOID()
    status = lib.irgx_literals_open(pool.handle(), ctypes.byref(out))
    if status == STALE:
        return None
    check(
        status,
        f"could not extract the literals of {pattern.pattern!r}",
        pattern.pattern,
    )
    return Literals(out)


def _verdict(value: int) -> Verdict:
    """``value`` as a :class:`Verdict`, or the raw int for a grade this build has
    no name for — an append-only ordinal is a thing to surface, not to crash on."""
    try:
        return Verdict(value)
    except ValueError:
        return value  # type: ignore[return-value]


def fold_orbit(cp: int) -> tuple[int, ...]:
    """Every codepoint that case-folds together with ``cp``, INCLUDING ``cp``.

    The orbit, not a pair: this is the table ``ignore_case=True`` folds with, so
    a host building its own index folds identically rather than approximately.
    """
    _, out, count = sink(
        _U32,
        lambda buf, cap, written: lib.irgx_fold_orbit(cp, buf, cap, written),
        f"could not read the fold orbit of U+{cp:04X}",
        hint=4,
    )
    return tuple(out[i] for i in range(count))


def property_ranges(name: str | bytes) -> tuple[tuple[int, int], ...]:
    """The inclusive codepoint ranges of a Unicode property, ascending.

    ``"Letter"``, ``"Greek"``, ``"Nd"``. An unknown name FAULTS rather than
    answering empty, so a misspelled property and an empty class cannot look
    alike.
    """
    key = _key(name)
    _, out, count = sink(
        Range,
        lambda buf, cap, written: lib.irgx_property_ranges(key, len(key), buf, cap, written),
        f"could not read the ranges of Unicode property {name!r}",
        hint=64,
    )
    return tuple((out[i].lo, out[i].hi) for i in range(count))


def property_has(name: str | bytes, cp: int) -> bool:
    """Whether ``cp`` is in a Unicode property, without materializing its ranges."""
    key = _key(name)
    status = check(
        lib.irgx_property_has(key, len(key), cp),
        f"could not test Unicode property {name!r}",
    )
    return status == MATCH


def unicode_version() -> str:
    """The Unicode version these tables were generated from.

    A host whose own tables disagree is a host whose prefilter and this engine
    disagree about what a letter is.
    """
    out = Text()
    check(lib.irgx_unicode_version(ctypes.byref(out)), "could not read the Unicode version")
    return borrowed(out)


def _key(name: str | bytes) -> bytes:
    if isinstance(name, str):
        return name.encode("utf-8")
    if isinstance(name, bytes | bytearray | memoryview):
        return bytes(name)
    raise error(f"a Unicode property name must be str or bytes, not {type(name).__name__}")

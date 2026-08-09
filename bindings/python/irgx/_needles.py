"""Many literals, one pass, with attribution.

The question a regex alternation answers slowly. ``a|b|c|…`` over two hundred
words compiles into an automaton that then has to tell you *which* alternative
fired by re-examining the match; a wordlist scanner answers both in one walk, and
which machine it uses is a consequence of how many needles you handed it rather
than a knob you pick. :meth:`Needles.shape` reports the tier so a host budgeting
a scan can see what it bought.

Three questions, in ascending cost, and picking the cheapest one that answers
matters more here than anywhere else in this ABI: :meth:`Needles.is_match` stops
at the first hit, :meth:`Needles.which` reports presence once per needle, and
:meth:`Needles.find_all` reports every occurrence. Asking ``find_all`` when you
wanted ``which`` over a wordlist that hits ten thousand times is the whole
difference.
"""

from __future__ import annotations

import ctypes
import enum
from collections.abc import Iterable, Sequence
from typing import Any, NamedTuple

from ._abi import _VOID, MATCH, check, declare, error, lib
from ._shape import Handle, sink, sized

_U8P = ctypes.c_char_p
_SIZE = ctypes.c_size_t
_U32 = ctypes.c_uint32


class Tier(enum.IntEnum):
    """Which machine seated the set. Reported, never chosen."""

    NONE = 0
    MEMMEM = 1
    """One needle: a plain substring find."""
    LITERAL_SET = 2
    """A few: SIMD multi-substring."""
    TRAWL = 3
    """Many: Aho-Corasick."""


class Needle(ctypes.Structure):
    """``irgx_needle``: one literal, borrowed for the compile call only."""

    _fields_ = (("needle", _U8P), ("len", _SIZE))


class Occurrence(ctypes.Structure):
    """``irgx_occurrence``: one hit, attributed to the needle that produced it."""

    _fields_ = (
        ("needle", _U32),
        ("reserved", _U32),
        ("start", _SIZE),
        ("end", _SIZE),
    )


class NeedleShape(ctypes.Structure):
    """``irgx_needle_shape``: what the set is, and which machines answer about it."""

    _fields_ = (
        ("struct_size", _U32),
        ("presence_tier", _U32),
        ("attributed_tier", _U32),
        ("reserved", _U32),
        ("count", _SIZE),
        ("longest", _SIZE),
        ("bytes", _SIZE),
    )


declare(
    (
        (
            "irgx_needles_compile",
            ctypes.c_int32,
            (ctypes.POINTER(Needle), _SIZE, _U32, ctypes.POINTER(_SIZE), ctypes.POINTER(_VOID)),
        ),
        ("irgx_needles_free", None, (_VOID,)),
        ("irgx_needles_len", _SIZE, (_VOID,)),
        ("irgx_needles_describe", ctypes.c_int32, (_VOID, ctypes.POINTER(NeedleShape))),
        ("irgx_needles_is_match", ctypes.c_int32, (_VOID, _U8P, _SIZE)),
        (
            "irgx_needles_which",
            ctypes.c_int32,
            (_VOID, _U8P, _SIZE, ctypes.POINTER(_U32), _SIZE, ctypes.POINTER(_SIZE)),
        ),
        (
            "irgx_needles_find_all",
            ctypes.c_int32,
            (_VOID, _U8P, _SIZE, ctypes.POINTER(Occurrence), _SIZE, ctypes.POINTER(_SIZE)),
        ),
    ),
    "the needle plane",
)


class Shape(NamedTuple):
    """What a compiled set holds, and what asking about it will cost."""

    count: int
    """Needles SEATED. Less than what was handed in when some were refused."""
    longest: int
    bytes: int
    presence_tier: Tier
    attributed_tier: Tier
    """Which machine answers :meth:`Needles.find_all`. It can be a *different*,
    dearer machine than the one that answers presence, which is exactly the fact
    a host budgeting a scan needs and cannot derive."""


class Hit(NamedTuple):
    """One occurrence: which needle, and where."""

    needle: int
    start: int
    end: int


class Needles(Handle):
    """A compiled literal set, scanned in one pass.

    Single-threaded like every handle on this ABI: the scan runs in scratch the
    handle owns, so two threads sharing one corrupt an answer rather than race a
    counter. Compile one per thread.

    A compile is all or nothing: there is no partially-seated set, so a refusal
    raises rather than handing back something quietly smaller than what was
    passed in. The engine reports WHICH needle it refused, and that index rides
    the exception as :attr:`irgx.error.index` - with four hundred terms, "one of
    them is empty" is not an answer a caller can act on.
    """

    __slots__ = ("_seated",)

    def __init__(self, needles: Iterable[str | bytes]) -> None:
        # `keep` holds the encoded bytes for exactly as long as the compile call
        # reads them; the engine copies what it seats before returning.
        keep = [_encode(one) for one in needles]
        if not keep:
            raise error("a needle set needs at least one needle")
        row = (Needle * len(keep))()
        for i, text in enumerate(keep):
            row[i].needle = text
            row[i].len = len(text)
        # Seeded past the end so that "the engine wrote an index" and "it did not"
        # stay tellable apart: it only writes on a refusal, and 0 is a real index.
        refused = _SIZE(len(keep))
        out = _VOID()
        status = lib.irgx_needles_compile(
            row, len(keep), 0, ctypes.byref(refused), ctypes.byref(out)
        )
        at = refused.value
        check(
            status,
            f"could not compile {len(keep)} needle(s)",
            index=at if at < len(keep) else None,
        )
        super().__init__(out, lib.irgx_needles_free)
        self._seated = lib.irgx_needles_len(out)

    def __len__(self) -> int:
        """How many needles the set holds — the exact ``cap`` :meth:`which` needs."""
        return self._seated

    def shape(self) -> Shape:
        """What the set is and which machines answer about it.

        A pure reader: it starts no work, so it cannot disturb the fault a
        previous call left behind.
        """
        out = sized(NeedleShape)
        check(
            lib.irgx_needles_describe(self.ptr, ctypes.byref(out)),
            "could not describe the needle set",
        )
        return Shape(
            count=out.count,
            longest=out.longest,
            bytes=out.bytes,
            presence_tier=_tier(out.presence_tier),
            attributed_tier=_tier(out.attributed_tier),
        )

    def is_match(self, text: str | bytes) -> bool:
        """Whether ANY needle occurs. The cheapest question: it stops at the
        first hit and attributes nothing."""
        data = _encode(text)
        status = check(
            lib.irgx_needles_is_match(self.ptr, data, len(data)),
            "could not scan for the needle set",
        )
        return status == MATCH

    def which(self, text: str | bytes) -> tuple[int, ...]:
        """Which needles occur, as ascending indices — presence per needle, NOT
        one row per occurrence.

        The buffer is sized at ``len(self)`` up front, which is the exact ceiling
        the ABI promises, so this crosses once even for a wordlist that hits on
        every entry.
        """
        data = _encode(text)
        handle = self.ptr
        _, out, count = sink(
            _U32,
            lambda buf, cap, written: lib.irgx_needles_which(
                handle, data, len(data), buf, cap, written
            ),
            "could not scan which needles occur",
            hint=self._seated,
        )
        return tuple(out[i] for i in range(count))

    def find_all(self, text: str | bytes) -> tuple[Hit, ...]:
        """Every occurrence, each carrying its needle index and span.

        Unbounded in the length of ``text``, unlike :meth:`which`: a wordlist over
        a large document can hit far more often than it has needles, so ask
        :meth:`which` instead when presence is the actual question.
        """
        data = _encode(text)
        handle = self.ptr
        _, out, count = sink(
            Occurrence,
            lambda buf, cap, written: lib.irgx_needles_find_all(
                handle, data, len(data), buf, cap, written
            ),
            "could not scan for needle occurrences",
        )
        return tuple(Hit(out[i].needle, out[i].start, out[i].end) for i in range(count))


def compile_needles(needles: Sequence[str | bytes]) -> Needles:
    """Compile a literal set into one scanner.

    Spelled as a function so the plane reads like the rest of this package
    (:func:`irgx.compile`), and so a host never has to know that the handle class
    is the thing it constructs.
    """
    return Needles(needles)


def _tier(value: int) -> Tier:
    """``value`` as a :class:`Tier`, or the raw int for a tier this build has no
    name for. The constants are append-only, so an unknown one is news rather
    than a crash."""
    try:
        return Tier(value)
    except ValueError:
        return value  # type: ignore[return-value]


def _encode(text: Any) -> bytes:
    """``text`` as the bytes the engine scans.

    A ``str`` becomes UTF-8, so every offset this plane reports is a BYTE offset
    into that encoding rather than an index into the ``str``. Spans from a
    ``str`` subject are therefore not slice bounds for it — which is why the
    plane reports needle indices and spans rather than the matched text, and why
    a caller who wants slices should pass ``bytes``.
    """
    if isinstance(text, str):
        return text.encode("utf-8")
    if isinstance(text, bytes | bytearray | memoryview):
        return bytes(text)
    raise error(f"a needle and its subject must be str or bytes, not {type(text).__name__}")

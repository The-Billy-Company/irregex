"""The line grid: the translation from a byte offset to the row a person reads.

Every engine here answers in byte offsets and every user reads rows, and the
conversion is where the off-by-one lives. Counting ``\\n`` is not it: a final
line with no terminator is still a line, and an offset sitting ON a terminator
belongs to the line that terminator ENDS rather than the one after it. Both of
those are one-line mistakes that survive review, which is why the grid crosses
the ABI instead of being rebuilt per host.

Offsets here are BYTE offsets, always — including for a ``str`` subject, whose
UTF-8 encoding is what the matching engines see too. That is deliberate: this
plane exists to be handed offsets that came out of :func:`irgx.finditer` on the
same bytes, and silently reinterpreting one domain as the other is exactly the
class of bug it is here to prevent.
"""

from __future__ import annotations

import ctypes
from typing import Any, NamedTuple

from ._abi import check, declare, lib
from ._shape import sink

_U8P = ctypes.c_char_p
_SIZE = ctypes.c_size_t


class RawLine(ctypes.Structure):
    """``irgx_line``: one row of the grid, as the C layout spells it."""

    _fields_ = (
        ("number", ctypes.c_uint64),
        ("start", ctypes.c_uint64),
        ("content_end", ctypes.c_uint64),
        ("term_end", ctypes.c_uint64),
    )


declare(
    (
        ("irgx_lines_count", ctypes.c_int32, (_U8P, _SIZE, ctypes.POINTER(ctypes.c_uint64))),
        (
            "irgx_lines_context",
            ctypes.c_int32,
            (
                _U8P,
                _SIZE,
                _SIZE,
                _SIZE,
                _SIZE,
                ctypes.POINTER(RawLine),
                _SIZE,
                ctypes.POINTER(_SIZE),
                ctypes.POINTER(_SIZE),
            ),
        ),
        (
            "irgx_lines_split",
            ctypes.c_int32,
            (_U8P, _SIZE, ctypes.POINTER(RawLine), _SIZE, ctypes.POINTER(_SIZE)),
        ),
    ),
    "the line plane",
)


class Line(NamedTuple):
    """One line of the grid, in byte offsets into the text that was asked about.

    ``content_end`` and ``term_end`` are separate on purpose: render with the
    first, slice with the second, and a host never has to guess whether the file
    ended ``"\\n"``, ``"\\r\\n"``, or with no terminator at all. A CRLF's
    ``\\r`` is KEPT in the content, which is ripgrep's default and what the
    matching engines in this library see, so a host that strips it for display
    stays consistent with what it matched on.
    """

    number: int
    """1-based, matching what ``-n`` prints and what an editor jumps to. Clipping
    a band at the top of the text shortens it; it never renumbers."""
    start: int
    """First byte of the line."""
    content_end: int
    """One past the last content byte: terminator excluded."""
    term_end: int
    """One past the terminator, so the next line's ``start``. Equals the text
    length for a final unterminated line, which is still a line."""

    def content(self, text: bytes) -> bytes:
        """The row's own bytes, terminator excluded."""
        return text[self.start : self.content_end]


class Band(NamedTuple):
    """A window of rows around one offset, and which of them holds it."""

    rows: tuple[Line, ...]
    center: int
    """The BAND-RELATIVE index of the row holding the offset asked about — the
    number a caret needs, and one a caller cannot derive from the row count,
    because a band clipped at the start of the text has fewer preceding rows
    than it asked for."""


def encode(text: str | bytes) -> bytes:
    """``text`` as the bytes the engine reasons about.

    UTF-8 for a ``str``, unchanged for anything buffer-shaped. Offsets in and out
    of this plane index THESE bytes.
    """
    if isinstance(text, str):
        return text.encode("utf-8", "surrogateescape")
    if isinstance(text, bytes | bytearray | memoryview):
        return bytes(text)
    raise TypeError(f"expected str or bytes, not {type(text).__name__}")


def _rows(out: Any, count: int) -> tuple[Line, ...]:
    """``count`` C rows copied into Python tuples, before the buffer goes away."""
    return tuple(
        Line(out[i].number, out[i].start, out[i].content_end, out[i].term_end) for i in range(count)
    )


def line_count(text: str | bytes) -> int:
    """How many lines ``text`` holds.

    An unterminated tail counts, because a host printing *n* rows must print
    that one too. Empty text holds no lines.
    """
    data = encode(text)
    total = ctypes.c_uint64()
    check(
        lib.irgx_lines_count(data, len(data), ctypes.byref(total)),
        "could not count the lines of the text",
    )
    return total.value


def split_lines(text: str | bytes) -> tuple[Line, ...]:
    """The whole grid, one :class:`Line` per line."""
    data = encode(text)
    size = len(data)
    _, out, count = sink(
        RawLine,
        lambda buf, cap, written: lib.irgx_lines_split(data, size, buf, cap, written),
        "could not split the text into lines",
    )
    return _rows(out, count) if count else ()


def line_context(text: str | bytes, at: int, before: int = 0, after: int = 0) -> Band:
    """The band of rows around byte ``at``: ``before`` preceding, it, ``after`` following.

    ``at == len(text)`` is legal and lands on the tail. Clipping at either end
    shortens the band rather than renumbering it, so :attr:`Band.center` is the
    only honest way to say which row the offset was in.
    """
    data = encode(text)
    size = len(data)
    center = ctypes.c_size_t()
    _, out, count = sink(
        RawLine,
        lambda buf, cap, written: lib.irgx_lines_context(
            data, size, at, before, after, buf, cap, written, ctypes.byref(center)
        ),
        f"could not read the lines around byte {at}",
        hint=before + after + 1,
    )
    return Band(_rows(out, count) if count else (), center.value)

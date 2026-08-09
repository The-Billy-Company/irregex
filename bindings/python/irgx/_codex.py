"""Count, locate and restore — without the text.

A self-index. It answers about a text it does not store, and it can hand the text
back: :meth:`Codex.count` is proportional to the **pattern**, not the corpus,
because the occurrences are never enumerated to count them, and
:meth:`Codex.extract` decodes bytes the index never kept.

Three things a Python host should know before using it.

**Locate is optional and its absence is a declinature.** An index built without
locate structures counts exactly and positions nothing, so :meth:`Codex.locate`
and :meth:`Codex.position` return ``None`` rather than raising or answering empty.
The remedy is real: rebuild with a ``sample_rate``.

**``extract`` IS ``restore``.** Reconstructing the whole text is this verb at
``at=0``; there is no second name for it, because starting the decode beside the
answer instead of at the end is an argument rather than an operation.

**The row interval is publishable, not a curiosity.** :meth:`Codex.whole` plus
:meth:`Codex.extend` is the FM backward search, exposed so a host can drive its
own — two rank queries per byte, independent of corpus size — and
:meth:`Codex.position` is what turns the interval it lands on into text offsets.
Read right to left: to search for ``abc``, extend by ``c``, then ``b``, then ``a``.
"""

from __future__ import annotations

import ctypes
import enum
from typing import Any, NamedTuple

from ._abi import _VOID, STALE, check, declare, error, lib
from ._shape import Handle, sink, sized

_U8P = ctypes.c_char_p
_SIZE = ctypes.c_size_t
_U32 = ctypes.c_uint32
_U8 = ctypes.c_uint8

#: ``IRGX_NO_LOCATE`` — the ``sample_rate`` that builds **no locate structures at
#: all**. Pass it to :func:`build` for an index that counts and extracts but
#: positions nothing; ``0`` means this build's default stride, so it is not a way
#: to ask for the same thing.
#:
#: The frozen header declares this constant with a different meaning ("returned by
#: irgx_codex_locate for a row that has no sampled position"), which nothing in
#: ``src/surface/ffi/codex.zig`` does — there it is the options sentinel, and it is
#: the only reachable way to make :meth:`Codex.locate` decline. The engine's own
#: doc comment is what this follows.
NO_LOCATE = 0xFFFFFFFF


class Encoding(enum.IntEnum):
    """How the wavelet layer is encoded."""

    ADOPT_MIN = 0
    """Take the smaller of the two forms per block."""
    PLAIN_ONLY = 1
    """Forbid the compressed form, for a host that wants a predictable size over
    a smaller one."""


class Options(ctypes.Structure):
    """``irgx_codex_options``: build options. Zero is the default everywhere."""

    _fields_ = (
        ("struct_size", _U32),
        ("sample_rate", _U32),
        ("encoding", _U32),
        ("reserved", _U32),
    )


class CodexStats(ctypes.Structure):
    """``irgx_codex_stats``: what the index cost and what it can still do."""

    _fields_ = (
        ("struct_size", _U32),
        ("sample_rate", _U32),
        ("locates", _U32),
        ("reserved", _U32),
        ("text_len", _SIZE),
        ("index_bytes", _SIZE),
        ("tree_bytes", _SIZE),
        ("locate_bytes", _SIZE),
    )


class RowSpan(ctypes.Structure):
    """``irgx_codex_rows``: a half-open row interval ``[lo, hi)``."""

    _fields_ = (("lo", _SIZE), ("hi", _SIZE))


declare(
    (
        ("irgx_codex_max_text_len", _SIZE, ()),
        (
            "irgx_codex_build",
            ctypes.c_int32,
            (_U8P, _SIZE, ctypes.POINTER(Options), ctypes.POINTER(_VOID)),
        ),
        ("irgx_codex_load", ctypes.c_int32, (_U8P, _SIZE, ctypes.POINTER(_VOID))),
        ("irgx_codex_free", None, (_VOID,)),
        ("irgx_codex_len", _SIZE, (_VOID,)),
        ("irgx_codex_measure", ctypes.c_int32, (_VOID, ctypes.POINTER(CodexStats))),
        ("irgx_codex_count", ctypes.c_int32, (_VOID, _U8P, _SIZE, ctypes.POINTER(_SIZE))),
        (
            "irgx_codex_locate",
            ctypes.c_int32,
            (_VOID, _U8P, _SIZE, ctypes.POINTER(_SIZE), _SIZE, ctypes.POINTER(_SIZE)),
        ),
        ("irgx_codex_position", ctypes.c_int32, (_VOID, _SIZE, ctypes.POINTER(_SIZE))),
        ("irgx_codex_rows_whole", ctypes.c_int32, (_VOID, ctypes.POINTER(RowSpan))),
        ("irgx_codex_rows_extend", ctypes.c_int32, (_VOID, ctypes.POINTER(RowSpan), _U8)),
        (
            "irgx_codex_extract",
            ctypes.c_int32,
            (_VOID, _SIZE, ctypes.POINTER(_U8), _SIZE, ctypes.POINTER(_SIZE)),
        ),
        (
            "irgx_codex_save",
            ctypes.c_int32,
            (_VOID, ctypes.POINTER(_U8), _SIZE, ctypes.POINTER(_SIZE)),
        ),
    ),
    "the codex plane",
)


class Cost(NamedTuple):
    """What the index cost, and what it can still do."""

    text_len: int
    index_bytes: int
    tree_bytes: int
    locate_bytes: int
    sample_rate: int
    locates: bool
    """Whether the locate layer is present. When ``False``, :meth:`Codex.locate`
    and :meth:`Codex.position` decline — counting is exact either way."""


class Rows(NamedTuple):
    """A half-open row interval ``[lo, hi)`` — the suffixes a pattern still admits."""

    lo: int
    hi: int

    @property
    def width(self) -> int:
        """How many rows the interval holds. This is the OCCURRENCE COUNT of the
        pattern that produced it, which is why counting needs no enumeration."""
        return self.hi - self.lo

    @property
    def empty(self) -> bool:
        """Whether the interval is empty. Once empty it stays empty under every
        further :meth:`Codex.extend`, so a host may stop at the first one."""
        return self.hi <= self.lo


def max_text_len() -> int:
    """The longest text this build can index, so a host refuses before allocating.

    Returned as ``size_t``. This binding declares that ``restype`` explicitly —
    ctypes would otherwise default to ``c_int`` and this value in particular sits
    at ``INT32_MAX``, one bit from where truncation starts showing up as a
    *negative* ceiling.
    """
    return lib.irgx_codex_max_text_len()


class Codex(Handle):
    """A self-index over one text.

    Build one with :func:`build` or :func:`load`. Everything it hands back is an
    owned Python object — there is no arena to borrow from here, since the plane
    answers in offsets and bytes rather than in views.
    """

    __slots__ = ()

    def __init__(self, ptr: Any) -> None:
        super().__init__(ptr, lib.irgx_codex_free)

    def __len__(self) -> int:
        """The length of the text it stands for — which need not exist any more."""
        return lib.irgx_codex_len(self.ptr)

    def measure(self) -> Cost:
        """What it cost and what it can still do."""
        out = sized(CodexStats)
        check(lib.irgx_codex_measure(self.ptr, ctypes.byref(out)), "could not measure the codex")
        return Cost(
            text_len=out.text_len,
            index_bytes=out.index_bytes,
            tree_bytes=out.tree_bytes,
            locate_bytes=out.locate_bytes,
            sample_rate=out.sample_rate,
            locates=bool(out.locates),
        )

    def count(self, pattern: str | bytes) -> int:
        """How many times ``pattern`` occurs, in time proportional to the PATTERN.

        The empty pattern counts ``0``. That is a search answer rather than the
        vacuous ``n+1`` the mathematics gives, and it is the answer a host looping
        over user input needs.
        """
        needle = _utf8(pattern)
        out = _SIZE()
        check(
            lib.irgx_codex_count(self.ptr, needle, len(needle), ctypes.byref(out)),
            f"could not count {pattern!r}",
        )
        return out.value

    def locate(self, pattern: str | bytes) -> tuple[int, ...] | None:
        """Every match position of ``pattern`` as text offsets, or ``None`` when
        this index was built without locate structures.

        ``None`` rather than ``()``: an index that cannot position anything and a
        pattern that occurs nowhere are different facts, and only one of them is
        fixed by rebuilding with a ``sample_rate``.
        """
        needle = _utf8(pattern)
        handle = self.ptr
        status, out, count = sink(
            _SIZE,
            lambda buf, cap, written: lib.irgx_codex_locate(
                handle, needle, len(needle), buf, cap, written
            ),
            f"could not locate {pattern!r}",
            declines=True,
        )
        return None if status == STALE else tuple(out[i] for i in range(count))

    def position(self, row: int) -> int | None:
        """The text offset one row stands for, or ``None`` without locate structures.

        One sampled-mark walk — the cheapest locate there is, and what turns an
        interval built by :meth:`extend` into a text position. There are
        ``len(self) + 1`` rows; the sentinel suffix owns the last one.
        """
        out = _SIZE()
        status = lib.irgx_codex_position(self.ptr, row, ctypes.byref(out))
        if status == STALE:
            return None
        check(status, f"could not position row {row}")
        return out.value

    def whole(self) -> Rows:
        """The interval of the empty pattern: every row. Where a backward search
        starts."""
        out = RowSpan()
        check(lib.irgx_codex_rows_whole(self.ptr, ctypes.byref(out)), "could not read the rows")
        return Rows(out.lo, out.hi)

    def extend(self, rows: Rows, byte: int) -> Rows:
        """One FM backward-search step: the interval of ``byte + P`` from ``P``'s.

        Two rank queries, independent of corpus size. Read right to left. Returns
        a new interval rather than mutating — the C verb narrows in place, and a
        value here is what lets a host keep the interval it came from and branch.
        """
        if not 0 <= byte <= 0xFF:
            raise error(f"a byte must be in 0..255, not {byte}")
        span = RowSpan(rows.lo, rows.hi)
        check(
            lib.irgx_codex_rows_extend(self.ptr, ctypes.byref(span), byte),
            f"could not extend {rows} by byte {byte}",
        )
        return Rows(span.lo, span.hi)

    def extract(self, at: int = 0, limit: int | None = None) -> bytes:
        """Reconstruct ``text[at:]`` — the index decoding bytes it never stored.

        This is also *restore*: the whole text is ``at=0``. ``limit`` caps how many
        bytes come back, which is the one thing the sizing dance cannot express,
        since ``*written`` here reports the bytes that EXIST past ``at`` rather
        than the bytes written.

        ``at`` past the end refuses rather than answering empty — it is caller
        arithmetic, and the empty answer at ``at == len(self)`` is a real one.
        """
        handle = self.ptr
        if limit is not None:
            if limit < 0:
                raise error(f"a limit cannot be negative, got {limit}")
            out = (_U8 * limit)() if limit else None
            written = _SIZE()
            check(
                lib.irgx_codex_extract(handle, at, out, limit, ctypes.byref(written)),
                f"could not extract from byte {at}",
            )
            return bytes(bytearray(out[: min(limit, written.value)])) if limit else b""
        _, out, count = sink(
            _U8,
            lambda buf, cap, written: lib.irgx_codex_extract(handle, at, buf, cap, written),
            f"could not extract from byte {at}",
        )
        return bytes(bytearray(out[:count])) if count else b""

    def save(self) -> bytes:
        """Serialize the index — magic, version, payload, seal. Feed it to :func:`load`.

        The image can only be produced whole, so the sizing probe this uses costs
        exactly one serialization: the engine holds the image between the two calls
        and releases it when the second writes it out.
        """
        handle = self.ptr
        _, out, count = sink(
            _U8,
            lambda buf, cap, written: lib.irgx_codex_save(handle, buf, cap, written),
            "could not serialize the codex",
        )
        return bytes(bytearray(out[:count])) if count else b""


def build(
    text: str | bytes,
    *,
    sample_rate: int = 0,
    encoding: Encoding = Encoding.ADOPT_MIN,
) -> Codex:
    """Build a self-index over ``text``.

    ``sample_rate=0`` takes this build's own default. A larger rate is a smaller
    index and a slower locate; :data:`NO_LOCATE` builds the layer not at all, which
    is what makes :meth:`Codex.locate` and :meth:`Codex.position` decline.
    """
    data = _utf8(text)
    if len(data) > max_text_len():
        raise error(
            f"this build indexes at most {max_text_len()} bytes, and the text is "
            f"{len(data)} — refused before allocating rather than part way through"
        )
    opts = sized(Options)
    opts.sample_rate = sample_rate
    opts.encoding = int(encoding)
    out = _VOID()
    check(
        lib.irgx_codex_build(data, len(data), ctypes.byref(opts), ctypes.byref(out)),
        f"could not index {len(data)} bytes",
    )
    return Codex(out)


def load(blob: bytes) -> Codex:
    """Load a saved index. A blob this build cannot read fails closed."""
    data = bytes(blob)
    out = _VOID()
    check(
        lib.irgx_codex_load(data, len(data), ctypes.byref(out)),
        f"could not load a {len(data)}-byte codex image",
    )
    return Codex(out)


def _utf8(text: str | bytes) -> bytes:
    if isinstance(text, str):
        return text.encode("utf-8")
    if isinstance(text, bytes | bytearray | memoryview):
        return bytes(text)
    raise error(f"a codex text or pattern must be str or bytes, not {type(text).__name__}")

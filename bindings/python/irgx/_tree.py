"""Searching a corpus, not a buffer you already hold.

Every other search verb in this package takes bytes the caller has in hand. This
one takes a *corpus* — roots on disk — and the engine owns the walk, the
narrowing, the reads and the line accounting. So the answer is not spans into
your string; it is records with a path, a line, and the spans inside that line.

``corpus() → search() → iterate → close``, and the middle step can **decline**.
:meth:`Corpus.search` returns ``None`` when a tier stepped aside, which is not a
failure and not an empty result: no cursor exists, nothing to close, and the host
should answer through whatever it does when the warm path is unavailable.

Records are copied. Every ``path``, ``line`` and span array a record carries
borrows the *cursor's* arena and dies at close, and a Python ``str`` built from
borrowed memory is indistinguishable from any other — so a lazily-decoded record
would be a use-after-free that surfaces a week later in code that never saw the
FFI. :class:`Record` is therefore fully owned by the time you can touch it, at
the cost of one copy per record, which is what the batch pull is for.
"""

from __future__ import annotations

import ctypes
import enum
import os
from collections.abc import Iterable, Iterator
from typing import Any, NamedTuple

from ._abi import _VOID, MATCH, OK, STALE, Span, Text, check, declare, error, lib
from ._flags import search_bits
from ._shape import Handle, borrowed, sized

_U8P = ctypes.c_char_p
_SIZE = ctypes.c_size_t
_U32 = ctypes.c_uint32
_U64 = ctypes.c_uint64
_CHARPP = ctypes.POINTER(ctypes.c_char_p)

#: Records per crossing when iterating.
BATCH = 256


class Kind(enum.IntEnum):
    """Why a record is in the stream."""

    LINE = 0
    """A line the pattern selected."""
    CONTEXT = 1
    """A neighbor carried along by ``before``/``after``."""


class Request(ctypes.Structure):
    """``irgx_tree_request``: one complete tree-search shape.

    Zero is today's default for every field, so a stamped-but-otherwise-empty
    struct is an unbudgeted, uncancelled, contextless leftmost search for the
    empty pattern.
    """

    _fields_ = (
        ("struct_size", _U32),
        ("flags", _U32),
        ("max_count", _U64),
        ("before_context", _U64),
        ("after_context", _U64),
        ("pattern", _U8P),
        ("pattern_len", _SIZE),
        ("timeout_ns", _U64),
        ("max_results", _SIZE),
        ("cancel", _VOID),
    )


class TreeMatch(ctypes.Structure):
    """``irgx_match``: one record, every byte of it borrowed from the cursor."""

    _fields_ = (
        ("path", Text),
        ("line", Text),
        ("spans", ctypes.POINTER(Span)),
        ("nspans", _SIZE),
        ("line_number", _U64),
        ("kind", _U32),
    )


declare(
    (
        ("irgx_engine_open", ctypes.c_int32, (_CHARPP, _SIZE, ctypes.POINTER(_VOID))),
        ("irgx_engine_close", None, (_VOID,)),
        ("irgx_cancel_new", ctypes.c_int32, (ctypes.POINTER(_VOID),)),
        ("irgx_cancel_request", None, (_VOID,)),
        ("irgx_cancel_free", None, (_VOID,)),
        (
            "irgx_tree_search",
            ctypes.c_int32,
            (_VOID, ctypes.POINTER(Request), ctypes.POINTER(_VOID)),
        ),
        ("irgx_matches_next", ctypes.c_int32, (_VOID, ctypes.POINTER(TreeMatch))),
        (
            "irgx_matches_next_batch",
            ctypes.c_int32,
            (_VOID, ctypes.POINTER(TreeMatch), _SIZE, ctypes.POINTER(_SIZE)),
        ),
        ("irgx_matches_count", _SIZE, (_VOID,)),
        ("irgx_matches_close", None, (_VOID,)),
    ),
    "the tree plane",
)


class Record(NamedTuple):
    """One search record. Fully owned — nothing here points into the cursor."""

    path: str
    """Decoded with ``surrogateescape``; ``os.fsencode`` returns the original bytes."""
    line: str
    spans: tuple[tuple[int, int], ...]
    """Byte ranges INSIDE :attr:`line`, not into the file. Empty for a context
    record, and for an inverted search, where the record is the line that did not
    match and there is nothing in it to point at."""
    line_number: int
    """One-based, as every tool that prints a line number counts."""
    kind: Kind

    @property
    def matched(self) -> bool:
        """Whether the pattern selected this line, as opposed to it being carried
        along as context."""
        return self.kind is Kind.LINE

    def texts(self) -> tuple[str, ...]:
        """The matched substrings of :attr:`line`.

        The spans are byte offsets into the line's UTF-8, so they are sliced there
        and decoded back — slicing the ``str`` by them would be wrong the moment a
        line held a non-ASCII character before a match.
        """
        raw = self.line.encode("utf-8", "surrogateescape")
        return tuple(raw[at:end].decode("utf-8", "surrogateescape") for at, end in self.spans)


class Cancel(Handle):
    """A cancellation token. Trip it from any thread and every query using it stops.

    The one object on this plane that IS thread-safe, and deliberately: it is the
    only way to reach into a search that is already running. Free it only after
    every query using it has returned, which :meth:`Handle.close` cannot check for
    you — hold it in the scope that outlives the searches.
    """

    __slots__ = ()

    def __init__(self) -> None:
        out = _VOID()
        check(lib.irgx_cancel_new(ctypes.byref(out)), "could not allocate a cancellation token")
        super().__init__(out, lib.irgx_cancel_free)

    def request(self) -> None:
        """Trip the token. Every in-flight query using it stops."""
        lib.irgx_cancel_request(self.ptr)


class Cursor(Handle):
    """One search's records, pulled.

    Iterate it once: unlike a :class:`irgx._walk.Walk` this is a stream with no
    rewind, so :meth:`__iter__` picks up wherever the cursor is. :func:`len` is
    how many records the stream holds and does not advance it, which is how you
    ask "did anything match" without paying for the records.
    """

    __slots__ = ()

    def __init__(self, ptr: Any) -> None:
        super().__init__(ptr, lib.irgx_matches_close)

    def __len__(self) -> int:
        """How many records the stream holds, without advancing it."""
        return lib.irgx_matches_count(self.ptr)

    def __iter__(self) -> Iterator[Record]:
        return self.pull()

    def pull(self, batch: int = BATCH) -> Iterator[Record]:
        """Records, ``batch`` per crossing.

        ``*written`` here is what the call CONSUMED rather than what exists — a
        cursor, not a sink — so this is driven to exhaustion instead of being
        sized from a count.
        """
        if batch < 1:
            raise error(f"a batch must be at least one record, not {batch}")
        out = (TreeMatch * batch)()
        written = _SIZE()
        while True:
            status = check(
                lib.irgx_matches_next_batch(self.ptr, out, batch, ctypes.byref(written)),
                "could not read the next search records",
            )
            taken = written.value
            for i in range(taken):
                yield _record(out[i])
            if status == OK or taken == 0:
                return

    def one(self) -> Record | None:
        """The next single record, or ``None`` once drained."""
        out = TreeMatch()
        status = check(
            lib.irgx_matches_next(self.ptr, ctypes.byref(out)),
            "could not read the next search record",
        )
        return _record(out) if status == MATCH else None


class Corpus(Handle):
    """The engine's view of a set of roots on disk.

    Opened once and searched many times — the walk, the artifacts and whatever the
    engine caches live behind this handle, which is the entire reason it is a
    handle rather than an argument to a search function.

    Close its cursors before closing it.
    """

    __slots__ = ()

    def __init__(self, roots: Iterable[str | bytes | os.PathLike[str]] = ()) -> None:
        keep = [ctypes.c_char_p(_fsbytes(r)) for r in roots]
        array = (ctypes.c_char_p * len(keep))(*keep) if keep else None
        out = _VOID()
        check(
            lib.irgx_engine_open(array, len(keep), ctypes.byref(out)),
            f"could not open a corpus over {len(keep)} root(s)",
        )
        super().__init__(out, lib.irgx_engine_close)

    def search(
        self,
        pattern: str | bytes,
        *,
        fixed: bool = False,
        ignore_case: bool = False,
        smart_case: bool = False,
        word: bool = False,
        unicode: bool = True,
        invert: bool = False,
        max_count: int | None = None,
        before: int = 0,
        after: int = 0,
        timeout_ns: int = 0,
        max_results: int = 0,
        cancel: Cancel | None = None,
    ) -> Cursor | None:
        """Run one search over the corpus, or ``None`` when a tier declined.

        ``None`` is not "no matches" — an empty :class:`Cursor` is that. It means
        no tier answered, so there is no cursor and nothing to close, and the host
        should fall back to however it searches without the warm engine.

        ``max_count`` is a per-file ceiling, and ``None`` rather than ``0`` means
        unset, because ``0`` is itself a legal ceiling here. ``max_results=1`` is
        how existence-only early halt is spelled — there is deliberately no second
        way to say it.

        The flag set is narrower than :func:`irgx.compile`'s on purpose: this
        request has no field for ``pcre``, ``multiline`` or ``dotall``, and passing
        one would be accepted-and-ignored, so they are simply not parameters.
        """
        text = _utf8(pattern)
        req = sized(Request)
        req.flags = search_bits(
            fixed=fixed,
            ignore_case=ignore_case,
            smart_case=smart_case,
            word=word,
            unicode=unicode,
            invert=invert,
            capped=max_count is not None,
        )
        req.max_count = 0 if max_count is None else max_count
        req.before_context = before
        req.after_context = after
        req.pattern = text
        req.pattern_len = len(text)
        req.timeout_ns = timeout_ns
        req.max_results = max_results
        req.cancel = None if cancel is None else cancel.ptr

        out = _VOID()
        status = lib.irgx_tree_search(self.ptr, ctypes.byref(req), ctypes.byref(out))
        if status == STALE:
            return None
        # A cursor comes back on OK too — including OK with no records — so the
        # status reports the ANSWER and never whether there is a handle to release.
        check(status, f"could not search the corpus for {pattern!r}", pattern)
        return Cursor(out)


def corpus(*roots: str | bytes | os.PathLike[str]) -> Corpus:
    """Open a corpus over ``roots``. No roots walks the current directory, which
    is not an error."""
    return Corpus(roots)


def _record(raw: TreeMatch) -> Record:
    """One C record copied into an owned :class:`Record`, arena and all."""
    spans = (
        tuple((raw.spans[i].start, raw.spans[i].end) for i in range(raw.nspans))
        if raw.spans
        else ()
    )
    return Record(
        path=borrowed(raw.path),
        line=borrowed(raw.line),
        spans=spans,
        line_number=raw.line_number,
        kind=_kind(raw.kind),
    )


def _kind(value: int) -> Kind:
    try:
        return Kind(value)
    except ValueError:
        return value  # type: ignore[return-value]


def _fsbytes(path: str | bytes | os.PathLike[str]) -> bytes:
    if isinstance(path, bytes | bytearray | memoryview):
        return bytes(path)
    return os.fsencode(path)


def _utf8(pattern: str | bytes) -> bytes:
    if isinstance(pattern, str):
        return pattern.encode("utf-8")
    if isinstance(pattern, bytes | bytearray | memoryview):
        return bytes(pattern)
    raise error(f"a pattern must be str or bytes, not {type(pattern).__name__}")

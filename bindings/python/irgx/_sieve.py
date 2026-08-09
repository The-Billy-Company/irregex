"""Narrowing, so most files are never opened.

Two persisted tiers — a trigram index and the crest sieve — and one rule that
governs every answer on this plane: **a sieve rules documents OUT, it never rules
one in.** Every set here is a SUPERSET, so a candidate still has to be read and a
host that treats one as a result set reports matches that are not there. Nothing
in the Python surface lets you forget that: the sets are named
:meth:`Sieve.candidates` and :meth:`Sieve.reading_list`, never ``matches``.

Two handles, because the two halves have different lifetimes. A
:class:`Sieve` is the artifacts on disk, opened once per corpus. A
:class:`Winnow` is one *pattern's* narrowing plan, derived once and spent across
many queries — which is the whole reason it is a handle instead of an argument.

Absence is not failure here. A corpus with no index built yet is a perfectly
ordinary corpus, so :func:`sieve` returns ``None`` rather than raising: the
engine says so with ``IRGX_STALE``, a declinature that installs no fault, and the
host's answer is to read every file exactly as it did before.
"""

from __future__ import annotations

import ctypes
import enum
import os
from collections.abc import Iterable
from typing import NamedTuple

from ._abi import _VOID, STALE, Text, check, declare, error, lib
from ._shape import Handle, borrowed, sink, sized

_U8P = ctypes.c_char_p
_SIZE = ctypes.c_size_t
_U32 = ctypes.c_uint32


class Freshness(enum.IntEnum):
    """Whether the artifacts still describe the tree."""

    ANCHORED = 1
    """A build instant was recorded and the tree is measured against it."""
    UNANCHORED = 2
    """No recorded instant, so staleness cannot be bounded."""
    FOREIGN = 3
    """The anchor dates somebody else's tree. The artifacts are inert rather than
    wrong — which is why the instant is still reported: seeing it is how a host
    recognizes the situation."""


class SieveFacts(ctypes.Structure):
    """``irgx_sieve_facts``: what the artifacts contain, and which tiers exist."""

    _fields_ = (
        ("struct_size", _U32),
        ("doc_count", _U32),
        ("path_count", _U32),
        ("posting_count", _U32),
        ("root_count", _U32),
        ("has_crest", _U32),
        ("has_codicil", _U32),
        ("reserved", _U32),
    )


class FreshnessOut(ctypes.Structure):
    """``irgx_freshness``: the posture, and the wall clock it is measured against."""

    _fields_ = (
        ("struct_size", _U32),
        ("state", ctypes.c_int32),
        ("anchor_ns", ctypes.c_int64),
        ("reserved", ctypes.c_int32),
    )


class WinnowFacts(ctypes.Structure):
    """``irgx_winnow_facts``: what a plan is made of, and whether it narrows."""

    _fields_ = (
        ("struct_size", _U32),
        ("flags", _U32),
        ("clauses", _U32),
        ("atoms", _U32),
        ("literals", _U32),
        ("alternatives", _U32),
        ("sieve_active", _U32),
        ("idle", _U32),
    )


declare(
    (
        ("irgx_sieve_open", ctypes.c_int32, (_U8P, _SIZE, ctypes.POINTER(_VOID))),
        ("irgx_sieve_close", None, (_VOID,)),
        ("irgx_sieve_describe", ctypes.c_int32, (_VOID, ctypes.POINTER(SieveFacts))),
        ("irgx_sieve_doc_path", ctypes.c_int32, (_VOID, _U32, ctypes.POINTER(Text))),
        ("irgx_sieve_root", ctypes.c_int32, (_VOID, _U32, ctypes.POINTER(Text))),
        (
            "irgx_sieve_literal",
            ctypes.c_int32,
            (_VOID, _U8P, _SIZE, ctypes.POINTER(_U32), _SIZE, ctypes.POINTER(_SIZE)),
        ),
        (
            "irgx_sieve_alternation",
            ctypes.c_int32,
            (
                _VOID,
                ctypes.POINTER(Text),
                _SIZE,
                ctypes.POINTER(_U32),
                _SIZE,
                ctypes.POINTER(_SIZE),
            ),
        ),
        (
            "irgx_sieve_candidates",
            ctypes.c_int32,
            (_VOID, _VOID, ctypes.POINTER(_U32), _SIZE, ctypes.POINTER(_SIZE)),
        ),
        (
            "irgx_sieve_reading_list",
            ctypes.c_int32,
            (_VOID, _VOID, ctypes.POINTER(_U32), _SIZE, ctypes.POINTER(_SIZE)),
        ),
        ("irgx_sieve_freshness", ctypes.c_int32, (_VOID, ctypes.POINTER(FreshnessOut))),
        ("irgx_sieve_stale_count", ctypes.c_int32, (_VOID, ctypes.POINTER(_SIZE))),
        ("irgx_winnow_of", ctypes.c_int32, (_VOID, ctypes.POINTER(_VOID))),
        ("irgx_winnow_free", None, (_VOID,)),
        ("irgx_winnow_describe", ctypes.c_int32, (_VOID, ctypes.POINTER(WinnowFacts))),
    ),
    "the sieve plane",
)


class Contents(NamedTuple):
    """What one artifact set holds, and which tiers are present at all."""

    docs: int
    paths: int
    postings: int
    roots: int
    has_crest: bool
    """Whether the crest tier loaded. Without it the sieve stands down and only
    the trigram plan narrows — so a plan that looks weak may just be missing a
    tier rather than being a weak plan."""
    has_codicil: bool
    """Whether an amend sidecar is layered over the base postings. A fact about
    how the answer was assembled; it changes no contract above."""


class Anchor(NamedTuple):
    """The freshness verdict, and the instant it was measured against."""

    state: Freshness
    anchor_ns: int
    """The recorded build instant in epoch nanoseconds, or ``0`` when there is
    none. Non-zero under :attr:`Freshness.FOREIGN`: the anchor exists, it just
    dates another tree."""

    @property
    def trustworthy(self) -> bool:
        """Whether read elision may be trusted — i.e. the artifacts describe THIS
        tree from a known instant. A conjunction spelled once, so a host does not
        have to get it right per call site."""
        return self.state is Freshness.ANCHORED


class Plan(NamedTuple):
    """What a pattern's narrowing plan is made of."""

    clauses: int
    atoms: int
    literals: int
    alternatives: int
    sieve_active: bool
    idle: bool
    """The honest answer that this pattern rules **nothing** out. An empty
    candidate list would have been a lie, so the plan says ``idle`` and the host
    reads everything."""
    flags: int


class Winnow(Handle):
    """One pattern's narrowing plan, derived once and spent across many queries.

    Independent of the pattern it came from once built, and of any sieve: pass it
    to :meth:`Sieve.candidates` or :meth:`Sieve.reading_list` as many times as you
    like.
    """

    __slots__ = ()

    def __init__(self, pattern: object) -> None:
        out = _VOID()
        handle = pattern._pool.handle()  # type: ignore[attr-defined]
        check(
            lib.irgx_winnow_of(handle, ctypes.byref(out)),
            f"could not derive a narrowing plan for {pattern.pattern!r}",  # type: ignore[attr-defined]
        )
        super().__init__(out, lib.irgx_winnow_free)

    def describe(self) -> Plan:
        """What the plan is made of, and whether it can narrow at all."""
        out = sized(WinnowFacts)
        check(
            lib.irgx_winnow_describe(self.ptr, ctypes.byref(out)),
            "could not describe the narrowing plan",
        )
        return Plan(
            clauses=out.clauses,
            atoms=out.atoms,
            literals=out.literals,
            alternatives=out.alternatives,
            sieve_active=bool(out.sieve_active),
            idle=bool(out.idle),
            flags=out.flags,
        )


class Sieve(Handle):
    """The persisted narrowing artifacts for one corpus.

    Every document set this returns is a **superset**: it says which documents
    *could* contain something, never which do. Read the candidates.

    Document ids are indices into this handle's own path table, so they mean
    nothing after :meth:`close` and nothing to a different sieve. :meth:`path`
    turns one back into a path, copied out of the arena.
    """

    __slots__ = ()

    def __init__(self, ptr: object) -> None:
        super().__init__(ptr, lib.irgx_sieve_close)

    def describe(self) -> Contents:
        """What this artifact set contains."""
        out = sized(SieveFacts)
        check(lib.irgx_sieve_describe(self.ptr, ctypes.byref(out)), "could not describe the sieve")
        return Contents(
            docs=out.doc_count,
            paths=out.path_count,
            postings=out.posting_count,
            roots=out.root_count,
            has_crest=bool(out.has_crest),
            has_codicil=bool(out.has_codicil),
        )

    def path(self, doc: int) -> str:
        """The path a document id names. Copied, so it outlives this handle."""
        out = Text()
        check(
            lib.irgx_sieve_doc_path(self.ptr, doc, ctypes.byref(out)),
            f"could not resolve document {doc}",
        )
        return borrowed(out)

    def root(self, i: int) -> str:
        """The ``i``-th root the artifacts were built over. Copied."""
        out = Text()
        check(lib.irgx_sieve_root(self.ptr, i, ctypes.byref(out)), f"could not read root {i}")
        return borrowed(out)

    def roots(self) -> tuple[str, ...]:
        """Every root, in order — the scope any answer from this sieve covers."""
        return tuple(self.root(i) for i in range(self.describe().roots))

    def literal(self, needle: str | bytes) -> tuple[int, ...]:
        """Documents that could contain this literal, ascending. A superset."""
        key = _utf8(needle)
        handle = self.ptr
        _, out, count = sink(
            _U32,
            lambda buf, cap, written: lib.irgx_sieve_literal(
                handle, key, len(key), buf, cap, written
            ),
            f"could not narrow on the literal {needle!r}",
        )
        return tuple(out[i] for i in range(count))

    def alternation(self, needles: Iterable[str | bytes]) -> tuple[int, ...]:
        """The same for a union of literals, merged INSIDE the index.

        Not N calls the host unions afterwards: the merge happens where the
        postings are, so the cost is one crossing and one walk of the lists rather
        than N of each.
        """
        # `held` owns the bytes for the duration of the call; the Text rows only
        # borrow them, exactly as the C struct says.
        held = [ctypes.create_string_buffer(_utf8(one)) for one in needles]
        if not held:
            raise error("an alternation needs at least one literal")
        row = (Text * len(held))()
        for i, buf in enumerate(held):
            row[i].ptr = ctypes.cast(buf, ctypes.POINTER(ctypes.c_uint8))
            # `create_string_buffer` appends a NUL that is not part of the needle.
            row[i].len = len(buf) - 1
        handle = self.ptr
        _, out, count = sink(
            _U32,
            lambda buf, cap, written: lib.irgx_sieve_alternation(
                handle, row, len(held), buf, cap, written
            ),
            f"could not narrow on {len(held)} literals",
        )
        return tuple(out[i] for i in range(count))

    def candidates(self, plan: Winnow) -> tuple[int, ...] | None:
        """What a whole plan admits, in document-id order — or ``None`` when
        nothing could narrow at all.

        ``None`` and ``()`` are **different answers** and this is the one place on
        the plane where confusing them is catastrophic: an empty tuple says the
        index ruled every document out, ``None`` says the index has no opinion and
        the host must read everything. The engine keeps them apart with
        ``IRGX_STALE``, so this does too.

        As built, not as now: both prunings read artifacts written at build time,
        so a file changed since then may be missing. :meth:`reading_list` is the
        one that is sound against live bytes.
        """
        return self._admit(plan, "candidates")

    def reading_list(self, plan: Winnow) -> tuple[int, ...] | None:
        """The same set, sequenced by what is cheapest to read — and sound against
        the CURRENT tree.

        :meth:`candidates` folded together with freshness: the index answer, minus
        what the crest rules out, plus every file whose clocks cannot prove it
        predates the build anchor. This is the set to read when correctness against
        live bytes matters; ``candidates`` is the raw index answer to intersect
        with something else. ``None`` means the same thing it means there.
        """
        return self._admit(plan, "reading_list")

    def _admit(self, plan: Winnow, which: str) -> tuple[int, ...] | None:
        """One of the two whole-plan sets. Same shape, same buffer dance, same
        declinature, so the only thing that differs is which verb answers."""
        verb = getattr(lib, f"irgx_sieve_{which}")
        handle, spent = self.ptr, plan.ptr
        status, out, count = sink(
            _U32,
            lambda buf, cap, written: verb(handle, spent, buf, cap, written),
            f"could not read the {which.replace('_', ' ')}",
            declines=True,
        )
        return None if status == STALE else tuple(out[i] for i in range(count))

    def freshness(self) -> Anchor:
        """Whether the artifacts still describe the tree, and against what instant."""
        out = sized(FreshnessOut)
        check(
            lib.irgx_sieve_freshness(self.ptr, ctypes.byref(out)),
            "could not read the sieve's freshness",
        )
        return Anchor(_state(out.state), out.anchor_ns)

    def stale_count(self) -> int | None:
        """How many documents changed since the anchor, or ``None`` when there is
        no anchor to measure against.

        The magnitude :meth:`freshness` reduces to a state, for a host deciding
        whether a rebuild is worth it. ``None`` is the honest answer for an
        unanchored artifact set — a declinature, not zero, because zero would read
        as "nothing changed".
        """
        out = _SIZE()
        status = lib.irgx_sieve_stale_count(self.ptr, ctypes.byref(out))
        if status == STALE:
            return None
        check(status, "could not count the stale documents")
        return out.value


def sieve(at: str | bytes | os.PathLike[str] | None = None) -> Sieve | None:
    """Open the persisted artifacts, or ``None`` when this corpus has none.

    ``None`` for ``at`` means the artifact home the engine picks; naming a
    directory is a deliberate override and costs freshness.

    A corpus with no index is not a failure and does not raise: the engine
    declines with ``IRGX_STALE``, installing no fault, and the host's answer is to
    read every file as it did before. Artifacts built over a **different** tree
    open INERT rather than wrong — that case returns a handle whose
    :meth:`Sieve.freshness` reports :attr:`Freshness.FOREIGN`.
    """
    key = b"" if at is None else _fsbytes(at)
    out = _VOID()
    status = lib.irgx_sieve_open(key, len(key), ctypes.byref(out))
    if status == STALE:
        return None
    check(status, f"could not open the sieve at {at!r}" if at else "could not open the sieve")
    return Sieve(out)


def winnow(pattern: object) -> Winnow:
    """Derive one pattern's narrowing plan. Spend it across as many queries as
    you like; deriving it again per query is the cost this handle exists to
    remove."""
    return Winnow(pattern)


def _state(value: int) -> Freshness:
    """``value`` as a :class:`Freshness`, or the raw int for a posture this wheel
    has no name for. Negative means the question could not be answered at all."""
    try:
        return Freshness(value)
    except ValueError:
        return value  # type: ignore[return-value]


def _utf8(text: str | bytes) -> bytes:
    if isinstance(text, str):
        return text.encode("utf-8")
    if isinstance(text, bytes | bytearray | memoryview):
        return bytes(text)
    raise error(f"a literal must be str or bytes, not {type(text).__name__}")


def _fsbytes(path: str | bytes | os.PathLike[str]) -> bytes:
    if isinstance(path, bytes | bytearray | memoryview):
        return bytes(path)
    return os.fsencode(path)

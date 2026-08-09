"""Which files a search is even allowed to read.

gitignore precedence, the type registry, hidden and binary policy — answered as a
**materialized set you iterate** rather than as a side effect of searching. That
is the whole point of the plane: "would this file have been searched?" becomes a
question a host can ask on its own, before it has a pattern, and answer the same
way the search would.

Two facts shape the Python surface.

**The set is materialized, so iterating it twice is free.** :meth:`Walk.__iter__`
rewinds first, which re-reads nothing from the filesystem, so a :class:`Walk`
behaves like the collection it is instead of like a stream that empties. The raw
cursor is still there (:meth:`Walk.pull`) for a host that wants one pass with no
list in memory.

**An unreadable directory is a COUNT, not a refusal** — but only if you ask for
it. Without :attr:`Policy.TOLERATE_GAPS` a directory the walk cannot read fails
the whole walk, because "nothing matched" and "we never looked there" are
different answers and the safe default is to say so. With it, the number lands on
:attr:`Walk.gapped`, and a host that ignores that attribute has quietly chosen
the first answer anyway.
"""

from __future__ import annotations

import ctypes
import enum
import os
from collections.abc import Iterable, Iterator
from typing import NamedTuple

from ._abi import _VOID, MATCH, OK, Text, check, declare, error, lib
from ._shape import Handle, borrowed, sized

_U8P = ctypes.c_char_p
_SIZE = ctypes.c_size_t
_U32 = ctypes.c_uint32
_U64 = ctypes.c_uint64

#: Entries per crossing when iterating. Big enough that the per-call cost
#: disappears against the per-entry copy, small enough to stay cache-resident.
BATCH = 256


class Genus(enum.IntEnum):
    """What a path is FOR. A total, disjoint partition."""

    CODE = 0
    """The leftover, deliberately: an unfamiliar extension lands here rather than
    falling through a gap, so a policy mistake shows one file too many instead of
    silently hiding one."""
    DOCS = 1
    DATA = 2


class Kind(enum.IntEnum):
    """What a spec term MEANS. A root is a place to walk from; the rest narrow."""

    ROOT = 0
    GLOB = 1
    GLOB_NOT = 2
    IGLOB = 3
    TYPE = 4
    TYPE_NOT = 5
    IGNORE_FILE = 6


class Policy(enum.IntFlag):
    """Walk policy bits.

    Every one is a **declinature of a default the walk would otherwise apply**,
    which is why they read as ``NO_*``: the safe spelling is no flags at all.
    """

    HIDDEN = 1 << 0
    """Descend into dotfiles."""
    NO_IGNORE = 1 << 1
    """Honour no ignore file at all."""
    NO_IGNORE_VCS = 1 << 2
    NO_IGNORE_DOT = 1 << 3
    NO_IGNORE_PARENT = 1 << 4
    NO_IGNORE_EXCLUDE = 1 << 5
    NO_IGNORE_GLOBAL = 1 << 6
    NO_IGNORE_FILES = 1 << 7
    NO_REQUIRE_GIT = 1 << 8
    """Apply VCS rules outside a repository."""
    IGNORE_FILE_ICASE = 1 << 9
    FOLLOW = 1 << 10
    ONE_FILE_SYSTEM = 1 << 11
    GLOB_ICASE = 1 << 12
    MEMBERS = 1 << 13
    """Additionally apply the corpus CONTENT rules — binary sniff, per-file
    ceiling, empty — and report each admitted file's length in :attr:`File.size`.

    The only bit that makes the walk read file bytes, so it is also the only way
    ``size`` is anything but ``0``. (The frozen header describes this bit as
    "directories too, not files only", which is not what ``src/surface/ffi/walk.zig``
    implements; the engine's own doc comment is what this follows.)
    """
    TOLERATE_GAPS = 1 << 14
    """An unreadable directory becomes :attr:`Walk.gapped` instead of a refusal."""


#: No policy at all, which is the safe spelling: every bit is a declinature of a
#: default the walk would otherwise apply. A module-level singleton because it is
#: :func:`walk`'s default argument and a call in a signature is evaluated once
#: anyway — better to say so than to let it read as per-call.
DEFAULT_POLICY = Policy(0)


class Limit(ctypes.Structure):
    """``irgx_limits``: the ceilings this build enforces."""

    _fields_ = (
        ("struct_size", _U32),
        ("binary_window", _U32),
        ("file_cap", _U64),
        ("type_rows", _U32),
        ("type_names", _U32),
    )


class Term(ctypes.Structure):
    """``irgx_walk_term``: one clause, borrowed for the open call only."""

    _fields_ = (("kind", _U32), ("reserved", _U32), ("text", _U8P), ("text_len", _SIZE))


class Spec(ctypes.Structure):
    """``irgx_walk_spec``: one complete eligibility question."""

    _fields_ = (
        ("struct_size", _U32),
        ("flags", _U32),
        ("max_depth", _U64),
        ("terms", ctypes.POINTER(Term)),
        ("term_count", _SIZE),
    )


class WalkEntry(ctypes.Structure):
    """``irgx_walk_entry``: one eligible file. ``path`` borrows the walk."""

    _fields_ = (("path", Text), ("size", _U64), ("genus", _U32), ("reserved", _U32))


declare(
    (
        ("irgx_walk_limits", ctypes.c_int32, (ctypes.POINTER(Limit),)),
        ("irgx_walk_open", ctypes.c_int32, (ctypes.POINTER(Spec), ctypes.POINTER(_VOID))),
        ("irgx_walk_count", _SIZE, (_VOID,)),
        ("irgx_walk_gapped", _U32, (_VOID,)),
        ("irgx_walk_next", ctypes.c_int32, (_VOID, ctypes.POINTER(WalkEntry))),
        (
            "irgx_walk_next_batch",
            ctypes.c_int32,
            (_VOID, ctypes.POINTER(WalkEntry), _SIZE, ctypes.POINTER(_SIZE)),
        ),
        ("irgx_walk_rewind", None, (_VOID,)),
        ("irgx_walk_holds", ctypes.c_int32, (_VOID, _U8P, _SIZE)),
        ("irgx_walk_close", None, (_VOID,)),
        ("irgx_walk_binary", ctypes.c_int32, (_U8P, _SIZE)),
        ("irgx_walk_genus", ctypes.c_int32, (_U8P, _SIZE, ctypes.POINTER(_U32))),
    ),
    "the walk plane",
)


class Ceilings(NamedTuple):
    """What this build will actually enforce, so a host sizes a request against
    the truth rather than a constant it copied out of a header."""

    binary_window: int
    """Bytes sniffed for the binary verdict — the same window :func:`binary` applies."""
    file_cap: int
    """The most files one walk may materialize."""
    type_rows: int
    type_names: int


class File(NamedTuple):
    """One eligible file. Owned: the path is copied out of the walk's arena."""

    path: str
    """Decoded with ``surrogateescape``, so a path that is not valid UTF-8
    survives the trip and ``os.fsencode`` turns it back into the same bytes."""
    size: int
    genus: Genus

    @property
    def fspath(self) -> bytes:
        """The path as filesystem bytes — what to hand to ``open`` when the name
        was never valid UTF-8 in the first place."""
        return os.fsencode(self.path)


class Walk(Handle):
    """The eligible set for one spec, materialized.

    Build one with :func:`walk`. Iterate it as many times as you like; ask
    :meth:`holds` for membership without iterating. Single-threaded, like every
    handle on this ABI.

    Every :class:`File` this hands back **owns its path**: the C entry borrows the
    walk's arena and dies at close, and in Python a ``str`` built from borrowed
    memory is indistinguishable from any other, so the copy happens here rather
    than being left as a rule for the caller to remember.
    """

    __slots__ = ()

    def __init__(self, spec: Spec) -> None:
        # The spec's `terms` pointer borrows the caller's array for exactly this
        # call; ctypes holds that array in the struct's own `_objects` and the
        # walk copies what it retains, so nothing here outlives the open.
        out = _VOID()
        check(lib.irgx_walk_open(ctypes.byref(spec), ctypes.byref(out)), "could not open the walk")
        super().__init__(out, lib.irgx_walk_close)

    def __len__(self) -> int:
        """How many entries the set holds. Does not advance the cursor."""
        return lib.irgx_walk_count(self.ptr)

    @property
    def gapped(self) -> int:
        """How many directories were unreadable but tolerated.

        The number that separates "nothing matched" from "we never looked there".
        Always ``0`` unless the spec carried :attr:`Policy.TOLERATE_GAPS`, since
        without it an unreadable directory fails the walk outright.
        """
        return lib.irgx_walk_gapped(self.ptr)

    def __iter__(self) -> Iterator[File]:
        """Every entry, from the start.

        Rewinds first, so iterating twice yields the same set — the set is already
        materialized, so this re-reads nothing from the filesystem.
        """
        self.rewind()
        return self.pull()

    def pull(self, batch: int = BATCH) -> Iterator[File]:
        """Entries from wherever the cursor is, ``batch`` per crossing.

        The one-at-a-time verb (``irgx_walk_next``) is what :meth:`one` spells;
        this uses the batch pull, which reports what it CONSUMED rather than what
        exists — a cursor, not a sink — so it is driven until a pass consumes
        nothing.
        """
        if batch < 1:
            raise error(f"a batch must be at least one entry, not {batch}")
        out = (WalkEntry * batch)()
        written = _SIZE()
        while True:
            status = check(
                lib.irgx_walk_next_batch(self.ptr, out, batch, ctypes.byref(written)),
                "could not read the next walk entries",
            )
            taken = written.value
            # Whatever the pass consumed is yielded first, even on the pass that
            # reports the stream drained: `*written` is a consumption count, so a
            # final short batch carries entries AND the end of the stream.
            for i in range(taken):
                yield _file(out[i])
            if status == OK or taken == 0:
                return

    def one(self) -> File | None:
        """The next single entry, or ``None`` once drained.

        The one-record spelling. Prefer iteration; this exists for a host driving
        the cursor by hand.
        """
        out = WalkEntry()
        status = check(
            lib.irgx_walk_next(self.ptr, ctypes.byref(out)),
            "could not read the next walk entry",
        )
        return _file(out) if status == MATCH else None

    def rewind(self) -> None:
        """Restart iteration. Re-reads nothing: the set is already materialized."""
        lib.irgx_walk_rewind(self.ptr)

    def holds(self, path: str | bytes | os.PathLike[str]) -> bool:
        """Whether this exact path is in the set — membership, without iterating."""
        key = _fsbytes(path)
        status = check(
            lib.irgx_walk_holds(self.ptr, key, len(key)),
            f"could not test whether the walk holds {path!r}",
        )
        return status == MATCH


def walk(
    *roots: str | bytes | os.PathLike[str],
    globs: Iterable[str] = (),
    not_globs: Iterable[str] = (),
    iglobs: Iterable[str] = (),
    types: Iterable[str] = (),
    not_types: Iterable[str] = (),
    ignore_files: Iterable[str | bytes | os.PathLike[str]] = (),
    policy: Policy = DEFAULT_POLICY,
    max_depth: int = 0,
) -> Walk:
    """Materialize the eligible set for one spec.

    Each keyword is one term kind, in the spelling a caller already thinks in
    (``globs``, ``types``) rather than as a list of tagged structs. No roots means
    the walk's own default; ``max_depth=0`` is unbounded.
    """
    terms: list[tuple[Kind, bytes]] = [(Kind.ROOT, _fsbytes(r)) for r in roots]
    terms += [(Kind.GLOB, _utf8(g)) for g in globs]
    terms += [(Kind.GLOB_NOT, _utf8(g)) for g in not_globs]
    terms += [(Kind.IGLOB, _utf8(g)) for g in iglobs]
    terms += [(Kind.TYPE, _utf8(t)) for t in types]
    terms += [(Kind.TYPE_NOT, _utf8(t)) for t in not_types]
    terms += [(Kind.IGNORE_FILE, _fsbytes(f)) for f in ignore_files]

    row = (Term * len(terms))() if terms else None
    for i, (kind, text) in enumerate(terms):
        row[i].kind = int(kind)
        row[i].text = text
        row[i].text_len = len(text)

    spec = sized(Spec)
    spec.flags = int(policy)
    spec.max_depth = max_depth
    spec.terms = ctypes.cast(row, ctypes.POINTER(Term)) if terms else None
    spec.term_count = len(terms)
    return Walk(spec)


def limits() -> Ceilings:
    """The ceilings this build enforces."""
    out = sized(Limit)
    check(lib.irgx_walk_limits(ctypes.byref(out)), "could not read the walk limits")
    return Ceilings(out.binary_window, out.file_cap, out.type_rows, out.type_names)


def binary(data: bytes) -> bool:
    """Whether these bytes read as binary under the same window the walk applies.

    The same verdict, not a similar one: a host that sniffs with its own heuristic
    is a host whose file list disagrees with the search's.
    """
    blob = bytes(data)
    status = check(lib.irgx_walk_binary(blob, len(blob)), "could not judge the bytes")
    return status == MATCH


def genus(path: str | bytes | os.PathLike[str]) -> Genus:
    """What a path is FOR, without walking anything."""
    key = _fsbytes(path)
    out = _U32()
    check(
        lib.irgx_walk_genus(key, len(key), ctypes.byref(out)),
        f"could not classify {path!r}",
    )
    return Genus(out.value)


def _file(entry: WalkEntry) -> File:
    """One C entry copied into an owned :class:`File`, before the arena moves."""
    return File(borrowed(entry.path), entry.size, _genus(entry.genus))


def _genus(value: int) -> Genus:
    """``value`` as a :class:`Genus`, or the raw int for a partition this build
    has grown and this wheel has no name for."""
    try:
        return Genus(value)
    except ValueError:
        return value  # type: ignore[return-value]


def _fsbytes(path: str | bytes | os.PathLike[str]) -> bytes:
    """A path as the bytes the OS names it with. ``os.fsencode`` rather than
    ``.encode()``, so a surrogate-escaped name round-trips to the same bytes."""
    if isinstance(path, bytes | bytearray | memoryview):
        return bytes(path)
    return os.fsencode(path)


def _utf8(text: str) -> bytes:
    """A glob or type name as UTF-8. Not a path, so no ``fsencode`` here."""
    if isinstance(text, bytes | bytearray | memoryview):
        return bytes(text)
    if not isinstance(text, str):
        raise error(f"a glob or type name must be str, not {type(text).__name__}")
    return text.encode("utf-8")

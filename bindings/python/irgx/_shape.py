"""The three shapes every plane of this ABI repeats, written once each.

The C surface is a hundred symbols over nine planes, and almost all of the
per-verb work is the same three moves. Writing them per plane is how a binding
ends up with fourteen copies of a two-call dance, thirteen of which are right.

**The sink.** ``(out, cap, written)`` writes at most ``cap`` items and reports
how many EXIST, so a short buffer sizes its own retry. :func:`sink` is the only
place in this package that dance is written: call with ``cap = 0`` to learn the
count, allocate exactly that, call again. A verb whose ``*written`` reports what
it CONSUMED rather than what exists is *not* this shape — the batch pulls
(``irgx_matches_next_batch``, ``irgx_walk_next_batch``) are cursors, and routing
one through here would ask a stream how long it is.

**The sized struct.** Every ``*_options`` / ``*_spec`` / out-struct is
append-only with a fail-closed ``struct_size``: a size the build does not
recognize is ``IRGX_INVALID``, never a best-effort read. :func:`sized` stamps it
from ctypes' own ``sizeof``, never from a literal, so the number cannot drift
from the layout it describes.

**The handle.** Every allocating verb has exactly one paired free.
:class:`Handle` closes exactly once — by ``with``, by :meth:`Handle.close`, or by
the garbage collector — so a host that forgets ``with`` leaks nothing and a host
that closes twice double-frees nothing.

And one rule that is not a shape but a hazard: **borrowed bytes are copied at
this boundary**. A tree record's path, a walk entry's path, a sieve document's
path and a literal set's rows all point into an arena that dies with its handle,
and in Python a ``bytes`` built from borrowed memory is indistinguishable from an
owned one — so the segfault lands a week later in code that never saw the FFI.
Every plane here therefore decodes a borrowed ``irgx_text`` into a Python object
before the call that produced it returns. That costs one copy per record, which
the batch pulls amortize, and buys records that outlive their cursor.
"""

from __future__ import annotations

import ctypes
from collections.abc import Callable
from typing import Any

from ._abi import STALE, Text, check, error

#: A ``(out, cap, written)`` verb, with everything before those three already
#: bound by the caller. Returns the raw status.
Fill = Callable[[Any, int, Any], int]

#: What this package accepts as a subject text or a pattern source.
#:
#: A tuple and not the ``str | bytes | bytearray | memoryview`` it reads as,
#: because that expression is not a constant: written inline in an ``isinstance``
#: it builds three ``UnionType`` objects **per call**, which on a per-text guard
#: costs more than the type check it decorates. Bound once here, and shared so
#: that "what can be searched" has one answer rather than one per plane.
TEXTUAL = (str, bytes, bytearray, memoryview)

#: :data:`TEXTUAL` minus ``str``: the byte-domain half, for the guards that ask
#: which domain a value is in rather than whether it is text at all.
BINARY = (bytes, bytearray, memoryview)


def sized(kind: type[ctypes.Structure]) -> Any:
    """A zeroed ``kind`` with ``struct_size`` stamped from ctypes' own ``sizeof``.

    Zero is today's default for every other field by ABI contract, so this is
    the whole of "build me the struct that asks for current behavior".
    """
    out = kind()
    out.struct_size = ctypes.sizeof(kind)
    return out


def sink(
    element: Any,
    fill: Fill,
    doing: str,
    *,
    hint: int = 0,
    declines: bool = False,
) -> tuple[int, Any, int]:
    """Run one ``(out, cap, written)`` verb, sizing its own buffer.

    Returns ``(status, buffer, count)``. ``count`` is how many items EXIST and is
    never saturated at the capacity — that is the property that makes "did I get
    everything?" decidable — and ``buffer`` holds all ``count`` of them, or is
    ``None`` when there are none.

    ``hint`` is a first-pass capacity for a verb whose answer is usually small,
    which trades one crossing for one allocation. Left at 0, the first pass is a
    pure count query (``out`` NULL, ``cap`` 0), which every verb here documents
    as legal.

    Exactly one retry, never a growth schedule: the count came from the engine
    rather than from a guess, and these verbs answer about state that cannot
    change underneath them. A count that grew anyway is reported rather than
    chased, because a loop here would spin on the disagreement instead of naming
    it.

    ``declines=True`` admits ``IRGX_STALE`` as an answer and returns it with an
    empty buffer. A declinature installs no fault and is not an error — a codex
    built without the locate layer is answering honestly about a choice the
    caller made at build time — so it must not be raised.
    """
    cap = hint
    written = ctypes.c_size_t()
    for _ in range(2):
        out = (element * cap)() if cap else None
        status = fill(out, cap, ctypes.byref(written))
        if declines and status == STALE:
            return STALE, None, 0
        check(status, doing)
        if written.value <= cap:
            return status, out, written.value
        cap = written.value
    raise error(
        f"{doing}: the engine reported {written.value} items for a window sized "
        f"at the {cap} it asked for, so the count is not stable and a retry "
        f"would not converge"
    )


def borrowed(text: Text) -> str:
    """A borrowed ``irgx_text`` as a Python ``str``, copied out of the arena.

    ``surrogateescape`` so a path that is not valid UTF-8 survives the trip and
    round-trips back to the same bytes, which is the only honest way to hand a
    filesystem path to a ``str``-shaped host.
    """
    return text.decode()


class Handle:
    """One owned C handle, released exactly once.

    Three ways to close, all of them the same close: ``with``, an explicit
    :meth:`close`, and the garbage collector. :meth:`close` is idempotent, so
    the third never double-frees what the first already released — which is the
    failure a ``__del__`` plus a context manager invites if the pointer is not
    cleared under the same statement that reads it.

    A handle on this ABI is SINGLE-THREADED: it owns the per-call scratch its
    verbs run in, so two threads sharing one corrupt a result rather than race a
    counter. Nothing here makes one safe to share; the regex plane's answer is
    :class:`irgx._pool.Pool`, one handle per thread, and a plane whose handle is
    expensive to build (a walk, a sieve, a codex) is meant to be confined to the
    thread that opened it instead.
    """

    __slots__ = ("__weakref__", "_ptr", "_release")

    def __init__(self, ptr: Any, release: Callable[[Any], Any]) -> None:
        # `release` first, `ptr` second: a `__del__` reached because `__init__`
        # raised must never find a live pointer beside no way to free it.
        # Bound to the instance so teardown never reaches for a module global
        # that interpreter shutdown may already have cleared.
        self._release = release
        # Held as a plain address, not the `c_void_p` the compile wrote into.
        # ctypes converts an int to a pointer argument on its own, and the
        # native transport can only take one - so the integer is the spelling
        # both transports read, and NULL stays falsy either way.
        self._ptr = getattr(ptr, "value", ptr) or 0

    @property
    def ptr(self) -> Any:
        """The live pointer, or a refusal naming what was closed."""
        if not self._ptr:
            raise error(
                f"this {type(self).__name__} is closed; everything it lent out "
                f"died with it, so there is nothing left to ask"
            )
        return self._ptr

    @property
    def closed(self) -> bool:
        """Whether :meth:`close` has already run."""
        return not self._ptr

    def close(self) -> None:
        """Release the handle. Idempotent, so closing twice is a no-op."""
        ptr, self._ptr = getattr(self, "_ptr", None), None
        if ptr:
            self._release(ptr)

    def __enter__(self) -> Any:
        return self

    def __exit__(self, *exc: object) -> bool:
        self.close()
        return False

    def __del__(self) -> None:
        self.close()

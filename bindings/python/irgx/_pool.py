"""How a shareable :class:`irgx.Pattern` is built out of a handle that is not.

The header is blunt: an ``irgx_regex *`` owns the scratch its finds run in, so
two threads sharing one corrupt a match rather than race a counter, and the
advice is to compile one per thread. A Python caller, meanwhile, will write
``PATTERN = irgx.compile(...)`` at module scope and hand it to a
``ThreadPoolExecutor`` without a second thought, because that is what
``re.compile`` allows.

Both facts are satisfied by owning a **pool** of handles instead of one, which
is what every binding in this repository does - ``pool.rs`` leases one out of a
mutex, the Go binding parks them in a ``sync.Pool``, and here each thread keeps
its own in a :class:`threading.local`. A thread-local rather than a leased pool
because the compile is pure and Python threads are long-lived relative to a
search: one compile per thread and nothing after that, with no lock on the hot
path at all. The trade is the one a leased pool does not make - a handle parked
in a thread cannot be reclaimed by the pattern while that thread lives - and it
is the right way round here, because a ``threading.local`` entry dies with its
thread, so a pool of short-lived workers frees handles as it goes.
"""

from __future__ import annotations

import ctypes
import threading
from typing import Any

from ._abi import _VOID, STALE, UnsupportedPattern, _status_text, check, lib


class Compiled:
    """One ``irgx_regex *``, freed when this object dies.

    A handle is single-threaded by contract: it owns the scratch its finds run
    in, so two threads sharing one corrupt a match rather than race a counter.
    Ownership of that rule lives in :class:`Pool`, which keeps one of these per
    thread.
    """

    # `__weakref__` so a caller can observe a handle's lifetime without keeping
    # it alive; the per-thread handles are exactly the thing worth watching.
    __slots__ = ("__weakref__", "_free", "ptr")

    def __init__(self, pattern: bytes, flags: int, source: str | bytes | None = None) -> None:
        out = _VOID()
        status = lib.irgx_compile(pattern, len(pattern), flags, ctypes.byref(out))
        if status < 0:
            shown = pattern.decode("utf-8", "backslashreplace")
            doing = f"could not compile pattern {shown!r}"
            # The exception carries the pattern as the caller spelled it, since
            # that is what `re.error.pattern` holds and what a retry needs; the
            # encoded bytes stand in when nobody said what the source was.
            spelled = pattern if source is None else source
            if status == STALE:
                # A declinature, not a failure, and readable from the return
                # value alone: the linear tier stepped aside for a pattern PCRE2
                # takes as it stands. `out` is untouched, so there is no handle
                # to keep and none to free, and no fault to read either.
                # The ABI's own text for this status is deliberately
                # plane-neutral ("this tier declines - answer through the
                # fallback"), because the same code means a search tier stepping
                # aside elsewhere. Spliced into a compile error it reads as
                # vocabulary from a system the caller is not using, and it says
                # less than the sentence below, which names the grammar, the
                # remedy, and the cost of the remedy.
                raise UnsupportedPattern(
                    f"{doing}: the linear grammar does not accept it. Compiling "
                    f"with pcre=True does, at the cost of the linear-time "
                    f"guarantee",
                    spelled,
                )
            check(status, doing, spelled)
        self.ptr = out
        # Bound to the instance so teardown does not reach for a module global
        # that interpreter shutdown may already have torn down.
        self._free = lib.irgx_free

    def __del__(self) -> None:
        ptr, self.ptr = getattr(self, "ptr", None), None
        if ptr:
            self._free(ptr)


class Pool:
    """One :class:`Compiled` per thread, for one pattern and one flag word.

    Holds only what a compile needs, all of it immutable, so the pool itself is
    safe to share; the handles it hands out never are, and never leave the
    thread that asked for one.
    """

    __slots__ = ("_flags", "_local", "_pattern", "_source")

    def __init__(self, pattern: bytes, flags: int, source: str | bytes | None = None) -> None:
        self._pattern = pattern
        self._flags = flags
        self._source = source
        self._local = threading.local()

    def handle(self) -> Any:
        """This thread's handle, compiling one the first time it asks."""
        compiled = getattr(self._local, "compiled", None)
        if compiled is None:
            compiled = Compiled(self._pattern, self._flags, self._source)
            # The thread-local dies with the Pool, and each thread's entry dies
            # with the thread, so a pool of short-lived workers frees its
            # handles as it goes rather than accumulating them.
            self._local.compiled = compiled
        return compiled.ptr

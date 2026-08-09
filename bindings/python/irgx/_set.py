"""Many patterns over one text, keeping which of them matched.

:mod:`re` has no type for this, so nothing here is mirroring an API. The
question is the engine's: given N patterns and one text, *which* patterns are in
it, decided in a single pass. The two things a caller writes instead are a loop
over N compiled patterns, which reads the text N times, and one alternation
``a|b|c``, which reads it once and then cannot say which branch hit.

Two verbs and no iterator, because a slate is a **classifier** rather than a
scanner: once you know pattern 7 is in this text, :meth:`irgx.Pattern.finditer`
on pattern 7 is the walk you were going to run anyway, over a text now known to
be worth walking.

The unit is the whole text, exactly as it is for a :class:`irgx.Pattern`, so
:meth:`PatternSet.which` names pattern *i* if and only if
:meth:`irgx.Pattern.is_match` on pattern *i* alone would have said yes - for
every pattern and every text, the anchored and the nullable ones included. Two
verbs of one library must not answer differently about the same string.
"""

from __future__ import annotations

import ctypes
from typing import Any

from . import _abi
from ._abi import _VOID, SlatePattern, UnsupportedPattern, check, lib
from ._flags import flag_bits
from ._pool import Pool

#: The two flags a slate has nowhere to carry. Refused rather than dropped: a
#: caller who passed one believes something about the answer they are about to
#: get.
_LINE_FLAGS = ("multiline", "dotall")


class _CompiledSet:
    """One ``irgx_slate *``, freed when this object dies.

    Single-threaded by contract, like every other handle in this ABI - it owns
    the scratch its scans run in - so :class:`Pool` keeps one per thread.
    """

    __slots__ = ("__weakref__", "_free", "ptr")

    def __init__(self, patterns: tuple[bytes, ...], flags: int, source: tuple[Any, ...]) -> None:
        row = (SlatePattern * len(patterns))()
        for slot, body in zip(row, patterns, strict=True):
            # ctypes keeps each `bytes` alive in the array's `_objects` for as
            # long as the array lives, which covers the call below; the ABI
            # copies the pattern bytes during the compile, so they are not
            # needed after it returns.
            slot.pattern = body
            slot.len = len(body)
            slot.flags = flags
        out = _VOID()
        refused = ctypes.c_size_t(len(patterns))
        status = lib.irgx_slate_compile(
            row if patterns else None,
            len(patterns),
            ctypes.byref(refused),
            ctypes.byref(out),
        )
        if status < 0:
            _blame(status, refused.value, source)
        self.ptr = out
        # Bound to the instance so teardown does not reach for a module global
        # that interpreter shutdown may already have torn down.
        self._free = lib.irgx_slate_free

    def __del__(self) -> None:
        ptr, self.ptr = getattr(self, "ptr", None), None
        if ptr:
            self._free(ptr)


def _blame(status: int, at: int, source: tuple[Any, ...]) -> None:
    """Raise the refusal, named for the pattern that caused it.

    The ABI writes the offending index and leaves the reason in the thread's
    fault slot, so the exception a caller sees is the one a lone
    :func:`irgx.compile` of that pattern would have raised - the same class, the
    same ``pos`` - with :attr:`irgx.error.index` added.
    """
    if at >= len(source):
        # No index was written: the refusal is about the call rather than about
        # any one pattern, an argument guard for instance.
        check(status, f"could not compile a set of {len(source)} patterns")
    spelled = source[at]
    doing = f"could not compile pattern {at} of the set, {spelled!r}"
    if status == _abi.STALE:
        raise UnsupportedPattern(
            f"{doing}: the linear grammar does not accept it. Compiling the set "
            f"with pcre=True does, at the cost of the linear-time guarantee",
            spelled,
            index=at,
        )
    check(status, doing, spelled, at)


class PatternSet:
    """Many compiled patterns, matched against one text in a single pass.

    Build one with :func:`irgx.compile_set` rather than by calling this
    directly. Immutable, and safe to share across threads.
    """

    __slots__ = ("__weakref__", "_flags", "_is_bytes", "_pool", "_source")

    def __init__(self, patterns: tuple[str | bytes, ...], flags: int) -> None:
        kinds = {isinstance(p, str) for p in patterns}
        if len(kinds) > 1:
            raise TypeError(
                "a set is compiled from str patterns or from bytes patterns, not "
                "a mixture; they answer about different kinds of text"
            )
        for pattern in patterns:
            if not isinstance(pattern, str | bytes | bytearray | memoryview):
                # `bytes(42)` is 42 zero bytes rather than an error, so without
                # this guard an int would compile into something meaningless.
                raise TypeError(f"a pattern must be str or bytes, not {type(pattern).__name__}")
        self._is_bytes = not kinds.pop() if patterns else False
        self._source = patterns
        self._flags = flags
        encoded = tuple(p.encode("utf-8") if isinstance(p, str) else bytes(p) for p in patterns)
        self._pool = Pool(lambda: _CompiledSet(encoded, flags, patterns))
        # Compiling here rather than on first use means a refused pattern raises
        # from `compile_set()`, where the caller can see which one it was.
        self._pool.handle()

    # ── identity ──────────────────────────────────────────────────────────

    @property
    def patterns(self) -> tuple[Any, ...]:
        """The pattern sources, exactly as they were given and in the order
        :meth:`which` reports."""
        return self._source

    @property
    def is_bytes(self) -> bool:
        """Whether this set searches ``bytes`` (rather than ``str``)."""
        return self._is_bytes

    @property
    def flags(self) -> int:
        """The raw ``IRGX_*`` bit word every pattern in the set compiled under."""
        return self._flags

    def __len__(self) -> int:
        """How many patterns the set holds, which is also the ceiling on the
        length of a :meth:`which` answer."""
        return len(self._source)

    def __repr__(self) -> str:
        return f"irgx.compile_set({list(self._source)!r})"

    # ── the two questions ─────────────────────────────────────────────────

    def is_match(self, text: str | bytes) -> bool:
        """Whether *any* pattern in the set matches ``text``.

        The cheap question, and the one a batch workload spends its time in: a
        literal scan can throw out a hopeless text with no pattern running at
        all.
        """
        data = self._bytes(text)
        status = check(
            lib.irgx_slate_is_match(self._pool.handle(), data, len(data)),
            "could not match a set",
        )
        return status == _abi.MATCH

    def which(self, text: str | bytes) -> list[int]:
        """The index of every pattern matching ``text``, ascending.

        Indices are positions in :attr:`patterns`. The answer can never exceed
        ``len(self)``, so unlike a span walk this asks once and is never short.
        """
        count = len(self._source)
        if not count:
            return []
        data = self._bytes(text)
        out = (ctypes.c_uint32 * count)()
        written = ctypes.c_size_t()
        check(
            lib.irgx_slate_which(
                self._pool.handle(), data, len(data), out, count, ctypes.byref(written)
            ),
            "could not match a set",
        )
        return [out[i] for i in range(written.value)]

    def _bytes(self, text: str | bytes) -> bytes:
        """``text`` as the UTF-8 the engine searches.

        A set reports pattern indices rather than offsets, so there is no domain
        to translate back into - but the str/bytes discipline still holds, for
        the reason :mod:`re` holds it: a set compiled from ``str`` patterns is
        about text, and quietly encoding a caller's bytes into it would answer a
        question they did not ask.
        """
        if not isinstance(text, str | bytes | bytearray | memoryview):
            raise TypeError(f"expected str or bytes to search, not {type(text).__name__}")
        if isinstance(text, str) == self._is_bytes:
            wanted = "bytes" if self._is_bytes else "str"
            raise TypeError(
                f"cannot search {type(text).__name__} with a set compiled from "
                f"{wanted}; compile the set from {type(text).__name__} instead"
            )
        return text.encode("utf-8") if isinstance(text, str) else bytes(text)


def compile_set(patterns: Any, **flags: bool) -> PatternSet:
    """Compile every pattern in ``patterns`` as one :class:`PatternSet`.

    Takes the same keyword flags :func:`irgx.compile` does, minus ``multiline``
    and ``dotall``, and applies them to every pattern - which is the honest shape
    for a set that came out of a config file: one text, one question, one set of
    semantics. ``smart_case`` still resolves per pattern, against that pattern's
    own spelling, and so does a leading ``(?i)`` or ``(?-u)`` - one member can
    fold case without the rest of them folding. A pattern whose own head says
    ``(?m)`` or ``(?s)`` is refused, for the same reason the keyword is.

    Compilation is all or nothing: one refused pattern refuses the set, rather
    than silently leaving a hole in the numbering. The exception is the one a lone
    :func:`irgx.compile` of that pattern would have raised, with
    :attr:`irgx.error.index` saying which one it was.

    :raises ValueError: for ``multiline`` or ``dotall``, which this plane cannot
        carry.
    :raises UnsupportedPattern: if a pattern is well-formed but outside the
        linear grammar, in which case ``pcre=True`` compiles the set.
    :raises error: if a pattern is malformed.
    """
    for name in _LINE_FLAGS:
        if flags.get(name):
            raise ValueError(f"{name}=True is not available on a set")
    # An unknown keyword raises TypeError out of `flag_bits`, so a typo like
    # `ignorecase=True` fails loudly instead of silently matching case.
    return PatternSet(tuple(patterns), flag_bits(**flags))

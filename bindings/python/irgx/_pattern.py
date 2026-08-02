"""Compiled patterns: flag assembly, per-thread handles, and every search verb.

Two rules shape this file.

**Iteration comes from ``irgx_find_all``, never from a loop over
``irgx_captures``.** The engine owns what a match sequence is - whether an
empty match adjacent to the previous one counts, what happens at the end of the
text, how ``word=True`` filtering interacts with resuming - and those rules are
not re-derivable from a ``find(from)`` cursor. Every verb here therefore asks
``find_all`` once for the authoritative spans and only then, per match and only
when the pattern declares groups, asks ``captures`` to fill in the detail.

**A ``Pattern`` is safe to share across threads even though a C handle is not.**
The handle owns the scratch its finds run in, so the header says to compile one
per thread. A Python caller will put ``PAT = irgx.compile(...)`` at module
scope and hand it to a thread pool without a second thought, so the Pattern
keeps the pattern text and the flags - which are immutable - and gives each
thread its own handle out of a :class:`threading.local`. The compile is pure, so
this costs one compile per thread and nothing after that.
"""

from __future__ import annotations

import ctypes
import threading
from collections.abc import Callable, Iterator
from typing import Any

from . import _abi
from ._abi import Compiled, Span, check, error, lib
from ._match import Match, TextView, wrong_subject
from ._template import compile_template

# How many spans to ask for on the first `find_all`. The header's advice is to
# size the window at `len + 1`, which is the most matches a text can hold; doing
# that unconditionally would allocate 16 MB of span buffer for a 1 MB text that
# probably has four matches. So start here, and let the count the engine reports
# size the one retry a short window can ever need.
_FIRST_WINDOW = 4096


def flag_bits(
    *,
    fixed: bool = False,
    ignore_case: bool = False,
    word: bool = False,
    smart_case: bool = False,
    unicode: bool = True,
    pcre: bool = False,
) -> int:
    """The ``IRGX_*`` bit word for a set of keyword flags.

    ``unicode`` is inverted on purpose: Unicode semantics are the engine's
    default, so the bit that exists is ``IRGX_NO_UNICODE`` and passing
    ``unicode=True`` sets nothing.
    """
    return (
        (_abi.FIXED if fixed else 0)
        | (_abi.IGNORE_CASE if ignore_case else 0)
        | (_abi.WORD if word else 0)
        | (_abi.SMART_CASE if smart_case else 0)
        | (0 if unicode else _abi.NO_UNICODE)
        | (_abi.PCRE if pcre else 0)
    )


class Pattern:
    """A compiled pattern. Immutable, and safe to share across threads.

    Build one with :func:`irgx.compile` rather than by calling this
    directly.
    """

    __slots__ = (
        "__weakref__",
        "_bytes",
        "_flags",
        "_groupindex",
        "_groups",
        "_is_bytes",
        "_local",
        "_source",
    )

    def __init__(self, pattern: str | bytes, flags: int) -> None:
        if not isinstance(pattern, str | bytes | bytearray | memoryview):
            # `bytes(42)` is 42 zero bytes rather than an error, so without this
            # guard an int pattern would compile into something meaningless
            # instead of being refused.
            raise TypeError(f"a pattern must be str or bytes, not {type(pattern).__name__}")
        self._is_bytes = not isinstance(pattern, str)
        self._source = pattern
        self._bytes = pattern.encode("utf-8") if isinstance(pattern, str) else bytes(pattern)
        self._flags = flags
        self._local = threading.local()

        # Compiling here rather than on first use means a bad pattern raises
        # from `compile()`, where the caller can see which pattern it was.
        handle = self._handle()

        count = ctypes.c_uint32()
        status = lib.irgx_group_count(handle, ctypes.byref(count))
        # A negative status means the capture arm refused this pattern, which is
        # not the same as the pattern being unusable: `find_all` still answers.
        # Record the refusal and let anything that actually needs a group say so.
        self._groups: int | None = None if status < 0 else count.value
        self._groupindex = self._resolve_names(handle)

    def _resolve_names(self, handle: Any) -> dict[str, int]:
        """The named groups, keyed by name, asked of the parser that numbered them.

        Reading the names off the pattern text instead is where this goes
        wrong: an escaped ``\\(`` and a non-capturing ``(?:`` both fool the
        obvious scan, one inventing a group and the other shifting every number
        after it. The engine already holds the answer per index, so it is asked.
        """
        found: dict[str, int] = {}
        name = _abi.Text()
        for index in range(1, (self._groups or 0) + 1):
            status = check(
                lib.irgx_group_name(handle, index, ctypes.byref(name)),
                f"could not read the group names of {self._source!r}",
                self._source,
            )
            if status == _abi.MATCH:
                # The bytes borrow the handle, so the name is decoded into a
                # str here rather than kept as a pointer into the compiled
                # pattern, which dies with the thread that compiled it.
                found[name.decode()] = index
        return found

    # ── identity ──────────────────────────────────────────────────────────

    @property
    def pattern(self) -> Any:
        """The pattern source, exactly as it was given."""
        return self._source

    @property
    def is_bytes(self) -> bool:
        """Whether this pattern searches ``bytes`` (rather than ``str``)."""
        return self._is_bytes

    @property
    def flags(self) -> int:
        """The raw ``IRGX_*`` bit word this pattern compiled under."""
        return self._flags

    @property
    def groups(self) -> int:
        """How many capture groups the pattern declares, excluding the whole match."""
        if self._groups is None:
            raise error(
                f"the capture engine cannot compile {self._source!r}, so this pattern "
                f"has no group information; searching still works",
                self._source,
            )
        return self._groups

    @property
    def groupindex(self) -> dict[str, int]:
        """Named groups, mapped to their numbers. Empty when there are none."""
        return dict(self._groupindex)

    def __repr__(self) -> str:
        return f"irgx.compile({self._source!r})"

    # ── the C handle, one per thread ──────────────────────────────────────

    def _handle(self) -> Any:
        compiled = getattr(self._local, "compiled", None)
        if compiled is None:
            compiled = Compiled(self._bytes, self._flags, self._source)
            # The thread-local dies with the Pattern, and each thread's entry
            # dies with the thread, so a pool of short-lived workers frees its
            # handles as it goes rather than accumulating them.
            self._local.compiled = compiled
        return compiled.ptr

    def _view(self, text: str | bytes) -> TextView:
        if not isinstance(text, str | bytes | bytearray | memoryview):
            raise TypeError(f"expected str or bytes to search, not {type(text).__name__}")
        if isinstance(text, str) == self._is_bytes:
            raise wrong_subject(self, text)
        return TextView(text)

    # ── the engine calls ──────────────────────────────────────────────────

    def _find_all(self, data: bytes) -> list[tuple[int, int]]:
        """Every match span in ``data``, in the engine's own order.

        ``find_all`` reports how many matches the TEXT holds rather than how
        many fit, so a window that came up short says by how much and the retry
        is sized at the answer. There is no growth schedule: a second pass over
        unchanged text cannot find a different number.
        """
        handle = self._handle()
        size = len(data)

        def sweep(window: int) -> tuple[list[tuple[int, int]], int]:
            out = (Span * window)()
            written = ctypes.c_size_t()
            check(
                lib.irgx_find_all(handle, data, size, out, window, ctypes.byref(written)),
                f"could not search with {self._source!r}",
                self._source,
            )
            # At most `window` spans were written, however many the text holds,
            # so the read is bounded by the buffer and never by the count.
            total = written.value
            return [(out[i].start, out[i].end) for i in range(min(total, window))], total

        spans, total = sweep(min(size + 1, _FIRST_WINDOW))
        return spans if total <= len(spans) else sweep(total)[0]

    def _captures_at(self, view: TextView, start: int, end: int) -> list[tuple[int, int] | None]:
        """Group spans for the match ``find_all`` reported at ``start``.

        ``captures`` reports how many groups the PATTERN has, not how many it
        wrote, so a window that came up short sizes its own retry.
        """
        if self._groups is None:
            raise error(
                f"the capture engine cannot compile {self._source!r}, so group detail "
                f"is unavailable for its matches",
                self._source,
            )
        if self._groups == 0:
            return [(start, end)]

        data = view.data
        handle = self._handle()
        window = self._groups + 1
        while True:
            out = (Span * window)()
            written = ctypes.c_size_t()
            status = check(
                lib.irgx_captures(
                    handle, data, len(data), start, out, window, ctypes.byref(written)
                ),
                f"could not read capture groups for {self._source!r}",
                self._source,
            )
            if status != _abi.MATCH:
                # `find_all` reported a match here, so `captures` finding none
                # means the two arms disagree. Refusing beats inventing groups.
                raise error(
                    f"internal disagreement in the engine: find_all reported a match at "
                    f"byte {start} for {self._source!r}, but captures found none",
                    self._source,
                )
            if written.value <= window:
                break
            window = written.value

        whole = (out[0].start, out[0].end)
        if whole != (start, end):
            raise error(
                f"internal disagreement in the engine: find_all reported {(start, end)} "
                f"for {self._source!r}, but captures reported {whole} from the same offset",
                self._source,
            )
        return [
            None if out[i].start < 0 or out[i].end < 0 else (out[i].start, out[i].end)
            for i in range(min(window, written.value))
        ]

    # ── the search surface ────────────────────────────────────────────────

    def is_match(self, text: str | bytes) -> bool:
        """Whether ``text`` holds a match at all.

        The engine's cheapest question: it may stop at the first hit and never
        materializes a span. ``re`` has no equivalent, so this is spelled after
        the C verb rather than after a stdlib name.
        """
        view = self._view(text)
        status = check(
            lib.irgx_is_match(self._handle(), view.data, len(view.data)),
            f"could not search with {self._source!r}",
            self._source,
        )
        return status == _abi.MATCH

    def search(self, text: str | bytes) -> Match | None:
        """The first match in ``text``, or ``None``."""
        view = self._view(text)
        out = (Span * 1)()
        written = ctypes.c_size_t()
        # A one-span window, so a MATCH is out[0] and nothing else. The status
        # is what decides it: `written` counts the matches the TEXT holds, so
        # reading it as "how many spans came back" would be right only until a
        # text held two.
        status = check(
            lib.irgx_find_all(
                self._handle(), view.data, len(view.data), out, 1, ctypes.byref(written)
            ),
            f"could not search with {self._source!r}",
            self._source,
        )
        if status != _abi.MATCH:
            return None
        return Match(self, view, out[0].start, out[0].end)

    def finditer(self, text: str | bytes) -> Iterator[Match]:
        """Every match in ``text``, in order.

        The spans come from one ``find_all`` call, so the sequence is the
        engine's own. Group detail is filled per match on first request, so
        iterating purely to count costs no capture passes.
        """
        view = self._view(text)
        for start, end in self._find_all(view.data):
            yield Match(self, view, start, end)

    def findall(self, text: str | bytes) -> list[Any]:
        """Match texts, or group texts when the pattern declares groups.

        The shape follows ``re.findall``: no groups gives whole matches, one
        group gives that group's values, several give tuples. The value for a
        group the match did not enter is ``None`` rather than ``re``'s ``""``,
        because a group that did not participate and a group that matched empty
        are different facts and ``.groups()`` already tells them apart.
        """
        count = self._groups or 0
        if count == 0:
            return [m.group(0) for m in self.finditer(text)]
        if count == 1:
            return [m.group(1) for m in self.finditer(text)]
        return [m.groups() for m in self.finditer(text)]

    def split(self, text: str | bytes, maxsplit: int = 0) -> list[Any]:
        """``text`` split around each match; declared groups are kept in the result."""
        view = self._view(text)
        pieces: list[Any] = []
        cut = 0
        for taken, match in enumerate(self.finditer(text)):
            if maxsplit and taken >= maxsplit:
                break
            pieces.append(view.slice(cut, match.start()))
            if self._groups:
                pieces.extend(match.groups())
            cut = match.end()
        pieces.append(view.slice(cut, len(view.original)))
        return pieces

    def sub(
        self, repl: str | bytes | Callable[[Match], Any], text: str | bytes, count: int = 0
    ) -> Any:
        """``text`` with each match replaced by ``repl``."""
        return self.subn(repl, text, count)[0]

    def subn(
        self, repl: str | bytes | Callable[[Match], Any], text: str | bytes, count: int = 0
    ) -> tuple[Any, int]:
        """Like :meth:`sub`, but also returns how many replacements were made."""
        view = self._view(text)
        if callable(repl):
            render = repl
        else:
            template = compile_template(repl, self)
            render = template.render

        pieces: list[Any] = []
        cut = 0
        made = 0
        for match in self.finditer(text):
            if count and made >= count:
                break
            pieces.append(view.slice(cut, match.start()))
            pieces.append(render(match))
            cut = match.end()
            made += 1
        pieces.append(view.slice(cut, len(view.original)))
        joined = (b"" if self._is_bytes else "").join(pieces)
        return joined, made

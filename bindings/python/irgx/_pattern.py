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
keeps only what is immutable - the pattern source and the flags - and asks
:class:`irgx._pool.Pool` for a handle whenever it needs one. That module owns
the rule and explains why it is a thread-local rather than a lease.
"""

from __future__ import annotations

import ctypes
from collections.abc import Callable, Iterator
from typing import Any

from . import _abi
from ._abi import Span, check, error, lib
from ._match import Match, TextView, wrong_subject
from ._pool import Compiled, Pool
from ._replace import compile_template

# How many spans to ask for on the first `find_all`. The header's advice is to
# size the window at `len + 1`, which is the most matches a text can hold; doing
# that unconditionally would allocate 16 MB of span buffer for a 1 MB text that
# probably has four matches. So start here, and let the count the engine reports
# size the one retry a short window can ever need.
_FIRST_WINDOW = 4096


def _on_characters(spans: list[tuple[int, int]], data: bytes) -> list[tuple[int, int]]:
    """``spans`` restricted to the ones a ``str`` subject can actually report.

    A UTF-8 continuation byte (``0b10xxxxxx``) is a position inside a character,
    not a position between two, so a span starting there has no index in the
    caller's domain — it would surface as a duplicate of the character it splits.
    Only an empty match can start there for a well-formed pattern, but the test
    is on the offset rather than on the width, because that is the actual rule
    and a width test would be a guess about which patterns exist.

    A fast path for the ASCII case, which is most texts: no continuation byte can
    be present, so there is nothing to remove and no copy to pay for.
    """
    if data.isascii():
        return spans
    size = len(data)
    # `start >= size` is the end-of-text position, which is a boundary and has no
    # byte to inspect.
    return [at for at in spans if at[0] >= size or data[at[0]] & 0xC0 != 0x80]


class Pattern:
    """A compiled pattern. Immutable, and safe to share across threads.

    Build one with :func:`irgx.compile` rather than by calling this
    directly.
    """

    __slots__ = (
        "__weakref__",
        "_flags",
        "_groupindex",
        "_groups",
        "_is_bytes",
        "_pool",
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
        self._flags = flags
        encoded = pattern.encode("utf-8") if isinstance(pattern, str) else bytes(pattern)
        self._pool = Pool(lambda: Compiled(encoded, flags, pattern))

        # Compiling here rather than on first use means a bad pattern raises
        # from `compile()`, where the caller can see which pattern it was.
        handle = self._pool.handle()

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

    @property
    def windows(self) -> bool:
        """Whether this pattern can be searched from a mid-buffer offset.

        A property of the PATTERN, not of the call, so it is asked once. ``False``
        for the PCRE2 arm, which has no windowed entry — which is why
        :meth:`search`'s ``endpos`` truncates the haystack rather than passing a
        bound the other arm could not honor.
        """
        return bool(check(lib.irgx_pattern_windows(self._pool.handle()), "could not ask"))

    @property
    def earliest(self) -> bool:
        """Whether this pattern can report earliest-mode spans.

        ``False`` is a **refusal**, not a slower path: an earliest span request
        would fault rather than quietly hand back the leftmost-first match wearing
        an earliest label. PCRE2 declines because it exposes no inspectable
        program, and so does any assertion-bearing pattern, whose determinized
        states depend on the gap they were entered at. Informational here — this
        binding's search verbs are all leftmost — and reported because the answer
        belongs to the pattern a host is holding.
        """
        return bool(check(lib.irgx_pattern_earliest(self._pool.handle()), "could not ask"))

    def __repr__(self) -> str:
        return f"irgx.compile({self._source!r})"

    def _view(self, text: str | bytes) -> TextView:
        if not isinstance(text, str | bytes | bytearray | memoryview):
            raise TypeError(f"expected str or bytes to search, not {type(text).__name__}")
        if isinstance(text, str) == self._is_bytes:
            raise wrong_subject(self, text)
        return TextView(text)

    def _region(self, view: TextView, pos: int, endpos: int | None) -> tuple[bytes, int] | None:
        """``re``'s ``pos``/``endpos`` as the bytes to search and the byte to start at.

        ``None`` when no match is possible at all — ``pos`` past the end, or
        ``endpos`` below ``pos``, both of which ``re`` answers with no match
        rather than an error.

        The two bounds are **not symmetric in** ``re``, and this mirrors that
        rather than tidying it up. ``pos`` does not move the left edge, so ``^``
        still means offset 0 and ``\\b`` still reads the byte before the region::

            re.compile("^b").search("abc", 1)    # None
            re.compile(r"\\bbc").search("abc", 1)  # None

        ``endpos`` *does* move the right edge — the docs say it is "as if the
        string is endpos characters long", and it behaves that way::

            re.compile("b$").search("abc", 0, 2)   # matches (1, 2)

        So ``pos`` is a window bound and ``endpos`` is a truncation, which is why
        this returns a possibly-shortened ``bytes`` for the second and an offset
        for the first. That also means the search it feeds has an inert end bound
        (``to == len``), so ``endpos`` costs nothing on the PCRE arm — unlike the C
        ABI's true ``to``, which that arm cannot express. The engine underneath is
        strictly more expressive than ``endpos`` here; ``re``'s spelling is what
        this method promises.
        """
        # Resolved in the CALLER's domain first, because that is the domain `re`
        # clamps in. Converting first and comparing after would let `pos` past the
        # end survive as a clamped offset, and a nullable pattern would then
        # report an empty match where `re` reports none.
        size = len(view.original)
        # Both bounds clamp INTO the text. `pos` past the end is not "no match":
        # `re.compile("x*").search("abc", 99)` matches empty at 3, because the
        # bound was clamped before the search ever ran.
        first = min(max(pos, 0), size)
        last = size if endpos is None else min(max(endpos, 0), size)
        # `re` answers an inverted or past-the-end region with no match, never an
        # error, so this is a result rather than a raise.
        if first > last:
            return None
        data = view.data
        return (data if last == size else data[: view.offset(last)]), view.offset(first)

    # ── the engine calls ──────────────────────────────────────────────────

    def _find_all(
        self, data: bytes, start: int = 0, *, characters: bool = False
    ) -> list[tuple[int, int]]:
        """Every match span in ``data`` at or after ``start``, in the engine's own order.

        ``find_all`` reports how many matches the TEXT holds rather than how
        many fit, so a window that came up short says by how much and the retry
        is sized at the answer. There is no growth schedule: a second pass over
        unchanged text cannot find a different number.

        ``start`` is a window bound, not a slice: assertions still read ``data``
        from byte 0, which is what makes ``pos`` mean what ``re`` says it means.
        The end bound is always inert here (``endpos`` shortened ``data``
        instead), so this asks nothing the PCRE arm cannot answer.

        ``characters`` thins the sequence to the positions a ``str`` subject
        actually has. The engine reports the widest sequence — every empty match
        at every BYTE — and for a ``str`` that includes offsets inside a
        multi-byte character, which ``re`` has no position for and which collapse
        onto their character's index on the way out. ``x*`` over ``"é"`` reports
        empty at bytes 0, 1 and 2; byte 1 splits the character, so ``re`` shows
        two matches where the raw sequence would show three, the middle one a
        duplicate of the first. Subtractive, like every other binding's thinning
        rule, and off for ``bytes`` subjects, whose domain IS the engine's.
        """
        handle = self._pool.handle()
        size = len(data)

        def sweep(window: int) -> tuple[list[tuple[int, int]], int]:
            out = (Span * window)()
            written = ctypes.c_size_t()
            check(
                lib.irgx_find_all_in(
                    handle, data, size, start, size, out, window, ctypes.byref(written)
                ),
                f"could not search with {self._source!r}",
                self._source,
            )
            # At most `window` spans were written, however many the text holds,
            # so the read is bounded by the buffer and never by the count.
            total = written.value
            return [(out[i].start, out[i].end) for i in range(min(total, window))], total

        spans, total = sweep(min(size + 1, _FIRST_WINDOW))
        found = spans if total <= len(spans) else sweep(total)[0]
        return _on_characters(found, data) if characters else found

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
        handle = self._pool.handle()
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

    def is_match(self, text: str | bytes, pos: int = 0, endpos: int | None = None) -> bool:
        """Whether ``text`` holds a match at all.

        The engine's cheapest question: it may stop at the first hit and never
        materializes a span. ``re`` has no equivalent, so this is spelled after
        the C verb rather than after a stdlib name — but it takes the same
        ``pos``/``endpos`` the stdlib search verbs do, so switching between them
        never changes which region was asked about.
        """
        view = self._view(text)
        region = self._region(view, pos, endpos)
        if region is None:
            return False
        data, start = region
        status = check(
            lib.irgx_is_match_in(self._pool.handle(), data, len(data), start, len(data)),
            f"could not search with {self._source!r}",
            self._source,
        )
        return status == _abi.MATCH

    def search(self, text: str | bytes, pos: int = 0, endpos: int | None = None) -> Match | None:
        """The first match in ``text``, or ``None``.

        ``pos`` and ``endpos`` bound the search exactly as ``re`` bounds it: the
        region is ``text[pos:endpos]``, ``pos`` does not move ``^`` or ``\\b``,
        and ``endpos`` does (see :meth:`_region`). Both count in the units of
        ``text`` — characters for ``str``, bytes for ``bytes``.
        """
        view = self._view(text)
        region = self._region(view, pos, endpos)
        if region is None:
            return None
        data, start = region
        out = (Span * 1)()
        written = ctypes.c_size_t()
        # A one-span window, so a MATCH is out[0] and nothing else. The status
        # is what decides it: `written` counts the matches the REGION holds, so
        # reading it as "how many spans came back" would be right only until a
        # text held two.
        status = check(
            lib.irgx_find_all_in(
                self._pool.handle(),
                data,
                len(data),
                start,
                len(data),
                out,
                1,
                ctypes.byref(written),
            ),
            f"could not search with {self._source!r}",
            self._source,
        )
        if status != _abi.MATCH:
            return None
        return Match(self, view, out[0].start, out[0].end)

    def match(self, text: str | bytes, pos: int = 0, endpos: int | None = None) -> Match | None:
        """The match beginning at exactly ``pos``, or ``None`` — ``re``'s ``match``."""
        from ._anchored import match as anchored

        return anchored(self, text, pos, endpos)

    def fullmatch(self, text: str | bytes, pos: int = 0, endpos: int | None = None) -> Match | None:
        """The match spanning the whole region, or ``None`` — ``re``'s ``fullmatch``.

        Answered by the anchored-longest automaton rather than by a leftmost
        search, which is what makes it exact on a non-backtracking engine, and
        what makes it decline for ``pcre=True``, ``multiline=True`` and patterns
        already carrying ``\\A``/``\\z``. :mod:`irgx._anchored` has the reasoning.
        """
        from ._anchored import full

        return full(self, text, pos, endpos)

    def finditer(
        self, text: str | bytes, pos: int = 0, endpos: int | None = None
    ) -> Iterator[Match]:
        """Every match in ``text``, in order.

        The spans come from one ``find_all`` call, so the sequence is the
        engine's own. Group detail is filled per match on first request, so
        iterating purely to count costs no capture passes. ``pos``/``endpos`` bound
        the region as in :meth:`search`.
        """
        view = self._view(text)
        region = self._region(view, pos, endpos)
        if region is None:
            return
        data, start = region
        for at, end in self._find_all(data, start, characters=view.is_str):
            yield Match(self, view, at, end)

    def findall(self, text: str | bytes, pos: int = 0, endpos: int | None = None) -> list[Any]:
        """Match texts, or group texts when the pattern declares groups.

        The shape follows ``re.findall``: no groups gives whole matches, one
        group gives that group's values, several give tuples. The value for a
        group the match did not enter is ``None`` rather than ``re``'s ``""``,
        because a group that did not participate and a group that matched empty
        are different facts and ``.groups()`` already tells them apart.
        """
        count = self._groups or 0
        found = self.finditer(text, pos, endpos)
        if count == 0:
            return [m.group(0) for m in found]
        if count == 1:
            return [m.group(1) for m in found]
        return [m.groups() for m in found]

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

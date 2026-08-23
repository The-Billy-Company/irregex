"""Match objects, and the byte-offset to codepoint-index translation under them.

The engine speaks bytes. A Python caller who passed a ``str`` thinks in
codepoints, and handing them a byte offset into their own string is a silent
footgun: ``text[m.start():m.end()]`` would return the wrong characters, or raise,
the first time the text contained anything outside ASCII. So :class:`TextView`
owns exactly one job - keeping the caller's domain and the engine's domain
straight - and :class:`Match` reports positions only in the caller's.
"""

from __future__ import annotations

import bisect
import sys
from typing import TYPE_CHECKING, Any

from ._engine import READS_STR

if TYPE_CHECKING:
    from ._pattern import Pattern

# UTF-8 continuation bytes. Deleting them from a slice leaves exactly one byte
# per codepoint start, so `len(chunk.translate(None, _CONTINUATION))` is the
# codepoint count of that chunk - computed in C, not a Python loop.
_CONTINUATION = bytes(range(0x80, 0xC0))


class TextView:
    """One subject text, in both the caller's domain and the engine's.

    ``original`` is what the caller passed and what slices come from, so
    ``view.slice(m.start(), m.end()) == m.group()`` holds by construction rather
    than by an offset calculation that could drift. :attr:`data` is the UTF-8 the
    engine searched, and :attr:`subject` is whichever of the two the transport in
    this build reads most cheaply.
    """

    __slots__ = ("_bytes", "_marks", "original", "subject", "wide")

    original: Any
    subject: Any
    #: Whether the caller's domain and the engine's actually differ, and
    #: therefore whether any position needs translating or thinning at all.
    #: False for every ASCII text and every ``bytes``, which is most of them,
    #: and the flag every hot path branches on to skip the translation entirely.
    wide: bool
    _bytes: bytes | None
    _marks: list[tuple[int, int]] | None

    def __init__(self, text: str | bytes) -> None:
        if not isinstance(text, str):
            # Normalize bytearray / memoryview to bytes so that every slice this
            # view hands back is the same type, and joining them in `sub` works.
            self.original = self.subject = self._bytes = (
                text if isinstance(text, bytes) else bytes(text)
            )
            self._marks = None
            self.wide = False
            return
        self.original = text
        # ASCII is the common case and the one where the two domains are
        # identical, so it costs nothing. `_marks` None means identity.
        self.wide = wide = not text.isascii()
        self._marks = [(0, 0)] if wide else None
        # The native transport reads the str's OWN cached UTF-8, which for an
        # ASCII string is the object's storage - so a text searched twice is
        # copied zero times. ctypes cannot, and re-encoding per call would turn
        # a walk with groups quadratic, so on that transport the copy is made
        # once, here.
        self._bytes = None if READS_STR else text.encode("utf-8")
        self.subject = text if self._bytes is None else self._bytes

    @property
    def data(self) -> bytes:
        """The UTF-8 the engine sees.

        Materialized on demand rather than in ``__init__``, because on the
        native transport most searches never need it: the offset table is
        derived from the ``str``, and only a non-ASCII thinning pass or an
        ``endpos`` truncation actually has to hold the bytes.
        """
        if self._bytes is None:
            self._bytes = self.original.encode("utf-8")
        return self._bytes

    def index(self, offset: int) -> int:
        """The caller-domain index for an engine-domain byte offset.

        Built lazily and incrementally: each answer is remembered as a
        checkpoint, so a scan that walks forward pays one linear pass in total
        rather than one per match, and out-of-order access still starts from the
        nearest known point instead of from zero.
        """
        marks = self._marks
        if marks is None:
            return offset
        at = bisect.bisect_right(marks, (offset, sys.maxsize)) - 1
        base_byte, base_index = marks[at]
        if base_byte == offset:
            return base_index
        chunk = self.data[base_byte:offset]
        found = base_index + len(chunk.translate(None, _CONTINUATION))
        bisect.insort(marks, (offset, found))
        return found

    def offset(self, index: int) -> int:
        """The engine-domain byte offset for a caller-domain index.

        The inverse of :meth:`index`, and what ``pos``/``endpos`` need: ``re``
        states those in the caller's domain, so for ``str`` they count characters
        while the engine counts bytes.

        Deliberately not sharing :meth:`index`'s checkpoint cache. That cache
        earns its keep because a walk asks it once per match, whereas a bound is
        resolved once per search — so the straightforward encode is both cheaper
        in total and impossible to get subtly wrong, which matters more for the
        value that decides what gets searched at all.
        """
        if self._marks is None:
            return index
        return len(self.original[:index].encode("utf-8"))

    def slice(self, start: int, end: int) -> Any:
        return self.original[start:end]


class Match:
    """One match, reported in the domain of the text that produced it.

    Group detail is filled on first request rather than at construction: a
    caller iterating a pattern with groups purely to count hits should not pay a
    capture pass per match.
    """

    __slots__ = ("_end", "_re", "_spans", "_start", "_view")

    def __init__(self, pattern: Pattern, view: TextView, start: int, end: int) -> None:
        self._re = pattern
        self._view = view
        self._start = start
        self._end = end
        self._spans: list[tuple[int, int] | None] | None = None

    @property
    def re(self) -> Pattern:
        """The pattern that produced this match."""
        return self._re

    @property
    def string(self) -> Any:
        """The text that was searched, exactly as the caller passed it."""
        return self._view.original

    def _byte_spans(self) -> list[tuple[int, int] | None]:
        if self._spans is None:
            self._spans = self._re._captures_at(self._view, self._start, self._end)
        return self._spans

    def _resolve(self, group: int | str) -> int:
        if isinstance(group, str):
            # The private mapping, not the `groupindex` property: that one hands
            # out a copy so a caller cannot edit the pattern's own table, which
            # is right for a caller and absurd here - it would rebuild the whole
            # dict to read one key, once per named group per match.
            index = self._re._groupindex.get(group)
            if index is None:
                raise IndexError(f"no such group: {group!r}")
            return index
        if not isinstance(group, int):
            kind = type(group).__name__
            raise TypeError(f"group indices must be integers or strings, not {kind}")
        # Group 0 is the whole match, which `find_all` already reported. Asking
        # for it must not need the capture engine, so a pattern whose capture
        # arm refused still answers `m.group()` and `m.span()`.
        if group == 0:
            return 0
        count = self._re.groups
        if group < 0 or group > count:
            raise IndexError(f"no such group: {group} (the pattern declares {count})")
        return group

    def _span_of(self, group: int | str) -> tuple[int, int] | None:
        index = self._resolve(group)
        if index == 0:
            return (self._start, self._end)
        return self._byte_spans()[index]

    def _cut(self, span: tuple[int, int] | None, default: Any = None) -> Any:
        """The caller-domain text of one byte span, or ``default`` for a group not entered."""
        if span is None:
            return default
        view = self._view
        if view.wide:
            return view.slice(view.index(span[0]), view.index(span[1]))
        # The two domains coincide, so the engine's byte offsets already index
        # the caller's own object and the translation is the identity. Slicing
        # here rather than through `index` twice and `slice` once is the same
        # answer for three fewer calls, which on this method is most of the cost.
        return view.original[span[0] : span[1]]

    def group(self, *groups: int | str) -> Any:
        """One group's text, or a tuple when several are asked for.

        A group the match did not enter is ``None``, never ``""`` - the two are
        different answers and ``(a)|(b)`` produces one of each every time.
        """
        # `m.group()` and `m.group(n)` are what almost every caller writes, and
        # both want one value; building a one-tuple to immediately index it is
        # the tuple, the generator, and the `len` all spent on nothing.
        if len(groups) < 2:
            return self._text_of(groups[0] if groups else 0)
        return tuple(self._text_of(g) for g in groups)

    def _text_of(self, group: int | str) -> Any:
        # Group 0 on a subject whose domains coincide - the whole match of an
        # ASCII `str` or of `bytes` - is a slice of what the caller already
        # holds, and `find_all` reported those offsets directly. `type(...) is
        # int` rather than `== 0` so that `0.0` still reaches `_resolve` and is
        # still the TypeError it was, and `True` still means group 1.
        if type(group) is int and group == 0:
            view = self._view
            if not view.wide:
                return view.original[self._start : self._end]
        return self._cut(self._span_of(group))

    def __getitem__(self, group: int | str) -> Any:
        return self._text_of(group)

    def groups(self, default: Any = None) -> tuple[Any, ...]:
        """Every declared group's text, with ``default`` for the ones not entered."""
        return tuple(self._cut(span, default) for span in self._byte_spans()[1:])

    def groupdict(self, default: Any = None) -> dict[str, Any]:
        """The named groups only, keyed by name."""
        return {
            name: self._cut(self._span_of(index), default)
            for name, index in self._re._groupindex.items()
        }

    def start(self, group: int | str = 0) -> int:
        span = self._span_of(group)
        if span is None:
            return -1
        view = self._view
        return view.index(span[0]) if view.wide else span[0]

    def end(self, group: int | str = 0) -> int:
        span = self._span_of(group)
        if span is None:
            return -1
        view = self._view
        return view.index(span[1]) if view.wide else span[1]

    def span(self, group: int | str = 0) -> tuple[int, int]:
        # Whole match, coinciding domains: the pair the engine reported already
        # indexes the caller's own text, so this is the two numbers on hand
        # rather than a resolve, a tuple and two translations to rebuild them.
        if type(group) is int and group == 0:
            view = self._view
            if not view.wide:
                return (self._start, self._end)
        span = self._span_of(group)
        if span is None:
            return (-1, -1)
        view = self._view
        if not view.wide:
            return span
        return (view.index(span[0]), view.index(span[1]))

    def expand(self, template: str | bytes) -> Any:
        """``template`` with ``\\1`` / ``\\g<name>`` references filled from this match."""
        from ._replace import compile_template

        return compile_template(template, self._re).render(self)

    def __repr__(self) -> str:
        shown = self.group(0)
        return f"<irgx.Match object; span={self.span()}, match={shown!r}>"


def wrong_subject(pattern: Pattern, text: object) -> TypeError:
    """The error for feeding a str-compiled pattern bytes, or the reverse.

    `re` refuses this too, and for the same reason: the two answer in different
    domains, so quietly encoding one into the other would hand back offsets that
    do not index what the caller passed.
    """
    wanted = "bytes" if pattern.is_bytes else "str"
    return TypeError(
        f"cannot search {type(text).__name__} with a pattern compiled from "
        f"{wanted}; compile the pattern from {type(text).__name__} instead"
    )

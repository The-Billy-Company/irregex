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
    than by an offset calculation that could drift. ``data`` is the UTF-8 the
    engine searched.
    """

    __slots__ = ("_marks", "data", "is_str", "original")

    def __init__(self, text: str | bytes) -> None:
        if isinstance(text, str):
            self.original: Any = text
            self.data = text.encode("utf-8")
            self.is_str = True
            # ASCII is the common case and the one where the two domains are
            # identical, so it costs nothing. `_marks` None means identity.
            self._marks: list[tuple[int, int]] | None = None if text.isascii() else [(0, 0)]
        else:
            # Normalize bytearray / memoryview to bytes so that every slice this
            # view hands back is the same type, and joining them in `sub` works.
            self.original = text if isinstance(text, bytes) else bytes(text)
            self.data = self.original
            self.is_str = False
            self._marks = None

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
            index = self._re.groupindex.get(group)
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
        return self._view.slice(self._view.index(span[0]), self._view.index(span[1]))

    def group(self, *groups: int | str) -> Any:
        """One group's text, or a tuple when several are asked for.

        A group the match did not enter is ``None``, never ``""`` - the two are
        different answers and ``(a)|(b)`` produces one of each every time.
        """
        if not groups:
            groups = (0,)
        found = tuple(self._text_of(g) for g in groups)
        return found[0] if len(found) == 1 else found

    def _text_of(self, group: int | str) -> Any:
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
            for name, index in self._re.groupindex.items()
        }

    def start(self, group: int | str = 0) -> int:
        span = self._span_of(group)
        return -1 if span is None else self._view.index(span[0])

    def end(self, group: int | str = 0) -> int:
        span = self._span_of(group)
        return -1 if span is None else self._view.index(span[1])

    def span(self, group: int | str = 0) -> tuple[int, int]:
        span = self._span_of(group)
        if span is None:
            return (-1, -1)
        return (self._view.index(span[0]), self._view.index(span[1]))

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

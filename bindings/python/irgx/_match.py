"""Match objects, and the byte-offset to codepoint-index translation under them.

The engine speaks bytes. A Python caller who passed a ``str`` thinks in
codepoints, and handing them a byte offset into their own string is a silent
footgun: ``text[m.start():m.end()]`` would return the wrong characters, or raise,
the first time the text contained anything outside ASCII. So :class:`TextView`
owns exactly one job - keeping the caller's domain and the engine's domain
straight - and :class:`Match` reports positions only in the caller's.

A match is the one object this binding mints per *result* rather than per call,
so a walk over a page of prose builds hundreds of them and everything about them
is hot. When the accelerator is present, :data:`Match` is therefore its C type
rather than the class written below - see :func:`_graft`, which finishes that
type with these method bodies so the harder half of a match has one
implementation and not two.
"""

from __future__ import annotations

import bisect
import sys
from functools import partial
from itertools import starmap
from typing import TYPE_CHECKING, Any

from ._abi import ACCEL
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

    __slots__ = ("_bytes", "_marks", "original", "searched", "subject", "wide")

    original: Any
    subject: Any
    #: The subject the engine was actually handed, which is :attr:`subject`
    #: unless an ``endpos`` cut it short. Distinct from ``subject`` because a
    #: capture pass filled in lazily has to run against the same bytes the walk
    #: did: ``endpos`` is a truncation, so groups re-derived from the whole text
    #: can run past the bound the caller set.
    searched: Any
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
            self.original = self.subject = self.searched = self._bytes = (
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
        self.subject = self.searched = text if self._bytes is None else self._bytes

    def upto(self, last: int) -> Any:
        """The subject to search when the caller's ``endpos`` ends the text at ``last``.

        Recorded on the view as well as returned, because the walk is not the
        only pass that reads it: group spans are filled in on first request,
        from a second engine call that must see exactly the text the first one
        did. Handing that call the whole subject let a greedy group run past
        ``endpos`` and report a wider whole-match than the walk had found — a
        disagreement between the two arms rather than a wrong answer, but the
        caller met it as a refusal.

        A truncation is a suffix cut, so every offset before it is unchanged and
        the left bound needs no adjusting. The cut is made in whichever domain
        the transport already reads, since the index is a character boundary in
        both.
        """
        if last == len(self.original):
            return self.subject
        cut = self.original[:last] if self.subject is self.original else self.data[: self.offset(last)]
        self.searched = cut
        return cut

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
            self._spans = self._re._captures_at(self._view.searched, self._start, self._end)
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

    @property
    def lastindex(self) -> int | None:
        """The index of the last matched capturing group, or ``None``.

        Derived from the spans rather than from an execution-order mark the
        engine does not keep: the matched group whose span ends last, ties
        going to the outermost (lowest-numbered) group. That reproduces every
        case ``re`` documents - ``(a)b`` and ``((a)(b))`` and ``((ab))`` give 1
        on ``'ab'``, ``(a)(b)`` gives 2 - and in particular the shape this
        property exists for, an alternation of groups where exactly one
        participates. A capture inside a lookaround that outruns every later
        group is the one corner where ``re``'s mark ordering could answer
        differently.
        """
        spans = self._byte_spans()
        best = None
        for index, span in enumerate(spans[1:], 1):
            if span is not None and (best is None or span[1] > spans[best][1]):
                best = index
        return best

    @property
    def lastgroup(self) -> str | None:
        """The name of :attr:`lastindex`'s group, or ``None`` when it has no name."""
        index = self.lastindex
        if index is None:
            return None
        for name, at in self._re._groupindex.items():
            if at == index:
                return name
        return None

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


# ── the two ways a match gets built ───────────────────────────────────────


def viewing(text: Any) -> TextView:
    """A view over the whole of ``text``, which is exactly ``str`` or ``bytes``.

    What every unbounded verb has once its domain check has passed: the caller's
    own object, in the pattern's own domain, searched end to end. Every branch
    :meth:`TextView.__init__` exists to take is therefore already decided, so
    this fills the slots directly rather than through a constructor whose frame
    costs more than the work in it. Those assignments are that ``__init__``'s
    rules and not new ones - which is why this is one function two callers share
    rather than a shortcut copied into each.
    """
    view = TextView.__new__(TextView)
    view.original = text
    if type(text) is str:
        view.wide = wide = not text.isascii()
        view._marks = [(0, 0)] if wide else None
        view._bytes = None if READS_STR else text.encode("utf-8")
        view.subject = text if view._bytes is None else view._bytes
    else:
        view._bytes = text
        view._marks = None
        view.wide = False
        view.subject = text
    # Nothing bounded this search, so the text searched IS the whole subject.
    view.searched = view.subject
    return view


def _over(pattern: Pattern, text: Any, span: tuple[int, int]) -> Match:
    """One match over ``text``, whose view is built here because there was none.

    What :meth:`irgx.Pattern.search` has after a hit, on the transport with no
    fused verb to do both at once. The match itself is built by attribute for
    the reason :func:`viewing` is: an ``__init__`` frame costs more than the four
    assignments in it, and every input is settled by the caller.
    """
    m = Match.__new__(Match)
    m._re = pattern
    m._view = viewing(text)
    m._start, m._end = span
    m._spans = None
    return m


def _matches(pattern: Pattern, view: TextView, spans: list[tuple[int, int]]) -> list[Match]:
    """Every match of one walk, over one shared view.

    Shared deliberately: :meth:`TextView.index` remembers each answer, so a walk
    that translates offsets pays one linear pass in total rather than one per
    match. A view per match would make a non-ASCII ``finditer`` quadratic.

    Built eagerly, because the walk it reports on already was - one ``find_all``
    settles every span before there is anything to yield, which is what ``re``
    does too. The cost of that is one object per span held at once instead of
    one at a time; the saving is a frame and a constructor per match that a
    lazy spelling cannot avoid.
    """
    return list(starmap(partial(Match, pattern, view), spans))


#: A match over a fresh subject, and every match of one walk. Both come from the
#: accelerator when it has them, which is what makes :data:`Match` a C type
#: worth having: a constructor reached through ``type.__call__`` would spend more
#: on argument parsing than the object costs to make.
over = _over
matches = _matches

#: The methods the C type does not implement, and does not want two of. Each one
#: reads this module's storage under the private names the C type exposes
#: (``_re`` / ``_view`` / ``_start`` / ``_end`` / ``_spans``), so these bodies
#: work verbatim against it.
_COLD = (
    "_byte_spans",
    "_resolve",
    "_span_of",
    "_cut",
    "_text_of",
    "groupdict",
    "expand",
    "lastindex",
    "lastgroup",
)

#: What the C type calls when a question is not its own - a group by name, an
#: out-of-range or non-integer group, a subject whose two domains differ. The
#: value is the Python method that already states that rule; the key is the name
#: the C fast path declines to, chosen so it cannot route back into C.
_SLOW = {
    "_slow_span": "span",
    "_slow_start": "start",
    "_slow_end": "end",
    "_slow_text": "_text_of",
    "_slow_group": "group",
    "_slow_groups": "groups",
}


def _graft(kind: type, written: type) -> type:
    """Finish the accelerator's Match type with the bodies ``written`` states.

    The C type owns the storage, the construction, and the four accessors for
    the case that is nearly every case. It owns none of the rules, which is why
    this is a graft rather than a port: there is one statement of what group 3
    means, what a name resolves to, and how a wide span translates, and it is
    the class above.
    """
    for name in _COLD:
        setattr(kind, name, getattr(written, name))
    for alias, name in _SLOW.items():
        setattr(kind, alias, getattr(written, name))
    return kind


#: The pure-Python match, kept reachable after the swap below so the suite can
#: hold the two implementations to each other rather than to one description of
#: both.
PythonMatch = Match

_native = getattr(ACCEL, "Match", None)
if _native is not None:
    # `TextView` handed over rather than imported: the C module builds one on the
    # translating arm, and reaching back into this package from C would fix an
    # import order this package is entitled to choose.
    ACCEL.set_view(TextView)
    Match = _graft(_native, PythonMatch)  # type: ignore[misc, assignment]
    over = ACCEL.over
    matches = ACCEL.matches


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

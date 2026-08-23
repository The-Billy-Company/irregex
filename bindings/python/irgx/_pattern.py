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
from functools import partial
from itertools import starmap
from typing import Any

from . import _abi
from ._abi import check, error, lib
from ._engine import READS_STR, transport
from ._match import Match, TextView, wrong_subject
from ._pool import Compiled, Pool
from ._replace import compile_template
from ._shape import TEXTUAL

# The three verbs this plane crosses the FFI with once per text, each resolved
# to the native transport where there is one and to the ctypes implementation
# beside it otherwise. Bound here rather than looked up per call, so choosing a
# transport costs nothing at all once the module is imported. Buffer sizing, the
# short-window retry and the span objects live behind them; see `irgx._engine`.
#
# The seam's boolean regex verb, `is_match`, is deliberately not among them: see
# :meth:`Pattern.is_match` for the measurement that routes it elsewhere. It stays
# bound in the seam, and under parity test, because it is the right verb again
# the day its kernel stops declining on a character class.
_find_first_in, _find_all_in, _captures, _texts, _group_texts = transport(
    "find_first", "find_all", "captures", "texts", "group_texts"
)


def _on_characters(spans: list[tuple[int, int]], data: bytes) -> list[tuple[int, int]]:
    """``spans`` restricted to the ones a ``str`` subject can actually report.

    A UTF-8 continuation byte (``0b10xxxxxx``) is a position inside a character,
    not a position between two, so a span starting there has no index in the
    caller's domain — it would surface as a duplicate of the character it splits.
    Only an empty match can start there for a well-formed pattern, but the test
    is on the offset rather than on the width, because that is the actual rule
    and a width test would be a guess about which patterns exist.
    """
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
        if not isinstance(pattern, TEXTUAL):
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
        if not isinstance(text, TEXTUAL):
            raise TypeError(f"expected str or bytes to search, not {type(text).__name__}")
        if isinstance(text, str) == self._is_bytes:
            raise wrong_subject(self, text)
        return TextView(text)

    def _region(self, view: TextView, pos: int, endpos: int | None) -> tuple[Any, int] | None:
        """``re``'s ``pos``/``endpos`` as the text to search and the byte to start at.

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
        this returns a possibly-shortened subject for the second and an offset
        for the first. That also means the search it feeds has an inert end bound
        (``to == len``), so ``endpos`` costs nothing on the PCRE arm — unlike the C
        ABI's true ``to``, which that arm cannot express. The engine underneath is
        strictly more expressive than ``endpos`` here; ``re``'s spelling is what
        this method promises.

        The subject comes back in whichever domain the transport reads cheapest
        (:attr:`irgx._match.TextView.subject`), which for the untruncated case —
        every call that does not pass ``endpos`` — means the caller's own object,
        copied zero times. Truncation slices in the caller's domain when it can,
        because the cut is at a character boundary either way.
        """
        # The whole text, which is what every call that passes no bounds means -
        # and that is nearly all of them. Worth saying separately: the clamping
        # below is a length, four comparisons and a domain translation spent
        # arriving at the two values already in hand.
        if pos == 0 and endpos is None:
            return view.subject, 0
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
        start = view.offset(first)
        if last == size:
            return view.subject, start
        # A truncation is a suffix cut, so every offset before it is unchanged
        # and `start` needs no adjusting. `original` is sliceable at `last`
        # directly — that index is already in its domain — and is the right
        # object to slice whenever it is also the one the transport reads.
        if view.subject is view.original:
            return view.original[:last], start
        return view.data[: view.offset(last)], start

    # ── the engine calls ──────────────────────────────────────────────────

    def _find_all(self, subject: Any, start: int = 0, limit: int = 0) -> list[tuple[int, int]]:
        """Every match span in ``subject`` at or after ``start``, in the engine's own order.

        ``start`` is a window bound, not a slice: assertions still read the
        subject from byte 0, which is what makes ``pos`` mean what ``re`` says it
        means. The end bound is always inert here (``endpos`` shortened the
        subject instead), so this asks nothing the PCRE arm cannot answer.
        ``limit`` caps how many spans are wanted — one, for :meth:`search`.

        Window sizing and the single retry a short one needs belong to the
        transport, which is the layer that knows whether a span buffer was
        involved at all; see :mod:`irgx._engine`. What belongs here is the
        sentence a refusal gets told in, which is why the seam hands back the
        engine's own status rather than raising something generic.
        """
        found = _find_all_in(self._pool.handle(), subject, start, limit)
        if type(found) is int:
            check(found, f"could not search with {self._source!r}", self._source)
            return []
        return found

    def _first(self, subject: Any, start: int = 0) -> tuple[int, int] | None:
        """The leftmost span at or after ``start``, or ``None`` when there is none.

        What :meth:`search` wants, and deliberately not ``find_all`` capped at
        one: a cap bounds how many spans get *written* and never how many get
        walked, because the count that comes back is the one the whole text
        holds. Asking that way made every ``search`` pay for every later match
        plus the tally over them — on a page of prose, an order of magnitude of
        work for a span nobody could read.
        """
        found = _find_first_in(self._pool.handle(), subject, start)
        if type(found) is int:
            check(found, f"could not search with {self._source!r}", self._source)
            return None
        return found

    def _captures_at(self, view: TextView, start: int, end: int) -> list[tuple[int, int] | None]:
        """Group spans for the match ``find_all`` reported at ``start``."""
        if self._groups is None:
            raise error(
                f"the capture engine cannot compile {self._source!r}, so group detail "
                f"is unavailable for its matches",
                self._source,
            )
        if self._groups == 0:
            return [(start, end)]

        out = _captures(self._pool.handle(), view.subject, start, self._groups)
        if type(out) is int:
            check(
                out,
                f"could not read capture groups for {self._source!r}",
                self._source,
            )
            # `find_all` reported a match here, so `captures` finding none means
            # the two arms disagree. Refusing beats inventing groups.
            raise error(
                f"internal disagreement in the engine: find_all reported a match at "
                f"byte {start} for {self._source!r}, but captures found none",
                self._source,
            )

        whole = out[0]
        if whole != (start, end):
            raise error(
                f"internal disagreement in the engine: find_all reported {(start, end)} "
                f"for {self._source!r}, but captures reported {whole} from the same offset",
                self._source,
            )
        return out

    # ── the search surface ────────────────────────────────────────────────

    def is_match(self, text: str | bytes, pos: int = 0, endpos: int | None = None) -> bool:
        """Whether ``text`` holds a match at all.

        The engine's cheapest question: it may stop at the first hit and never
        materializes a span. ``re`` has no equivalent, so this is spelled after
        the C verb rather than after a stdlib name — but it takes the same
        ``pos``/``endpos`` the stdlib search verbs do, so switching between them
        never changes which region was asked about.
        """
        # The common call passes no bounds and the caller's own object in the
        # pattern's own domain, and for that call a `TextView` has nothing to
        # say: no truncation, no offset, and no `Match` to translate spans for.
        # An exact type in the right domain IS the validation `_view` performs,
        # so anything else — a subclass, a memoryview, a mismatch — still takes
        # the slow path below for its diagnostics.
        if pos == 0 and endpos is None:
            kind = type(text)
            if kind is bytes if self._is_bytes else kind is str:
                # The seam call spelled inline rather than through `_first`,
                # whose frame costs more than the verb here; a refusal still
                # arrives as an int and still gets `_first`'s sentence. The
                # handle is read straight off the pool's thread-local for the
                # same reason — `handle()` is one attribute in a frame that
                # costs more than the attribute (see `Pool.handle`, which the
                # cold miss still goes through).
                pool = self._pool
                try:
                    handle = pool._local.address
                except AttributeError:
                    handle = pool.handle()
                found = _find_first_in(handle, text, 0)
                if type(found) is tuple:
                    return True
                if found < 0:
                    check(found, f"could not search with {self._source!r}", self._source)
                return False
        view = self._view(text)
        region = self._region(view, pos, endpos)
        if region is None:
            return False
        # `find_first` and not the boolean verb, which reads backwards and is
        # measured. Two things net out that way. The boolean kernel is ~25 ns
        # cheaper at the ABI on a pattern it has a fast path for, and then hands
        # back a status the caller has to run through `check` — a frame that
        # `_first` already absorbs — so from here it arrives slower anyway. And
        # where that fast path declines, which is every character class and
        # every bounded repeat, it falls back to a walk without the prefilter the
        # span verbs get: `\w+` over a line of prose costs 1012 ns to answer
        # yes/no and 89 ns to answer WHERE. That second one is an engine defect
        # rather than a fact about booleans, so this is a routing choice and not
        # a claim; the span is discarded, and the walk, region and iteration
        # rules are the same either way.
        return self._first(*region) is not None

    def search(self, text: str | bytes, pos: int = 0, endpos: int | None = None) -> Match | None:
        """The first match in ``text``, or ``None``.

        ``pos`` and ``endpos`` bound the search exactly as ``re`` bounds it: the
        region is ``text[pos:endpos]``, ``pos`` does not move ``^`` or ``\\b``,
        and ``endpos`` does (see :meth:`_region`). Both count in the units of
        ``text`` — characters for ``str``, bytes for ``bytes``.
        """
        # Same fast path as :meth:`is_match`, with the view built only on a hit:
        # a miss needs no object at all, and the hit builds it from the same
        # `text` the slow path would have viewed. The engine's leftmost-first
        # rule is what keeps the raw span safe to wrap unthinned — an empty
        # match inside a multi-byte character would imply an equally valid one
        # at that character's first byte, which sorts earlier.
        if pos == 0 and endpos is None:
            kind = type(text)
            is_str = kind is str
            if kind is bytes if self._is_bytes else is_str:
                pool = self._pool
                try:
                    handle = pool._local.address
                except AttributeError:
                    handle = pool.handle()
                found = _find_first_in(handle, text, 0)
                if type(found) is tuple:
                    # The view and the match built by attribute rather than by
                    # call: two `__init__` frames cost more than everything
                    # either one does, and on this path every input to both is
                    # already known exactly — the type was just checked, so the
                    # branches those constructors exist to take are settled.
                    # `TextView.__init__` and `Match.__init__` remain the one
                    # written form; these are those assignments, not new rules.
                    view = TextView.__new__(TextView)
                    view.original = view.subject = text
                    if is_str:
                        view.wide = wide = not text.isascii()
                        view._marks = [(0, 0)] if wide else None
                        view._bytes = None if READS_STR else text.encode("utf-8")
                        if view._bytes is not None:
                            view.subject = view._bytes
                    else:
                        view._bytes = text
                        view._marks = None
                        view.wide = False
                    m = Match.__new__(Match)
                    m._re = self
                    m._view = view
                    m._start, m._end = found
                    m._spans = None
                    return m
                if found < 0:
                    check(found, f"could not search with {self._source!r}", self._source)
                return None
        view = self._view(text)
        region = self._region(view, pos, endpos)
        if region is None:
            return None
        found = self._first(*region)
        return None if found is None else Match(self, view, *found)

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

    def _walk(
        self, text: str | bytes, pos: int, endpos: int | None
    ) -> tuple[TextView, list[tuple[int, int]]]:
        """The view over ``text`` and every match span the caller can index.

        One ``find_all`` call, so the sequence is the engine's own — and shared
        by the two verbs that walk it, which otherwise repeat the region and the
        thinning in two places that must agree.
        """
        view = self._view(text)
        region = self._region(view, pos, endpos)
        if region is None:
            return view, []
        found = self._find_all(*region)
        # The engine reports the widest sequence — every empty match at every
        # BYTE — and for a `str` that includes offsets inside a multi-byte
        # character, which `re` has no position for and which would collapse onto
        # their character's index on the way out. `x*` over `"é"` reports empty at
        # bytes 0, 1 and 2; byte 1 splits the character, so `re` shows two matches
        # where the raw sequence shows three, the middle one a duplicate. Only a
        # text whose two domains differ can hold such a position.
        return view, _on_characters(found, view.data) if view.wide else found

    def finditer(
        self, text: str | bytes, pos: int = 0, endpos: int | None = None
    ) -> Iterator[Match]:
        """Every match in ``text``, in order.

        Group detail is filled per match on first request, so iterating purely
        to count costs no capture passes. ``pos``/``endpos`` bound the region as
        in :meth:`search`.
        """
        # `starmap` rather than a `yield` loop: the walk is one `find_all` and
        # is already done by the time there is anything to yield, so a generator
        # would only add a Python frame resumed once per match to hand back an
        # object the constructor could have handed back directly. The one visible
        # difference is that a `finditer(...)` nobody iterates now does the scan,
        # which is what `re.finditer` does too.
        view, found = self._walk(text, pos, endpos)
        return starmap(partial(Match, self, view), found)

    def findall(self, text: str | bytes, pos: int = 0, endpos: int | None = None) -> list[Any]:
        """Match texts, or group texts when the pattern declares groups.

        The shape follows ``re.findall``: no groups gives whole matches, one
        group gives that group's values, several give tuples. The value for a
        group the match did not enter is ``None`` rather than ``re``'s ``""``,
        because a group that did not participate and a group that matched empty
        are different facts and ``.groups()`` already tells them apart.
        """
        # One crossing, whatever the group count. `findall` returns text, and a
        # text needs no index in either domain — a UTF-8 slice decodes to the
        # same `str` the caller would have cut — so the walk, the capture pass,
        # the empty-match thinning and every finished slice happen behind one
        # verb (`texts`, or `group_texts` when the pattern declares groups; see
        # :mod:`irgx._engine`). No `Match` is built, no span comes back, and on
        # a page of prose that is several hundred objects and as many FFI
        # crossings not made, for answers identical to `m.group(0)`,
        # `m.group(1)` and `m.groups()`.
        # The common no-bounds call skips the view and the region the same way
        # :meth:`search` does: the verbs below thin and slice in the engine's
        # own domain, so nothing here needs a translation object — the exact
        # type check IS the validation, and anything else takes `_view` for
        # its diagnostics.
        if (
            pos == 0
            and endpos is None
            and (type(text) is bytes if self._is_bytes else type(text) is str)
        ):
            subject, start = text, 0
        else:
            view = self._view(text)
            region = self._region(view, pos, endpos)
            if region is None:
                return []
            subject, start = region
        pool = self._pool
        try:
            handle = pool._local.address
        except AttributeError:
            handle = pool.handle()
        count = self._groups or 0
        decode = not self._is_bytes
        found = (
            _texts(handle, subject, start, decode)
            if count == 0
            else _group_texts(handle, subject, start, count, decode)
        )
        if type(found) is int:
            check(found, f"could not search with {self._source!r}", self._source)
            return []
        return found

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

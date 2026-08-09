""":mod:`re`'s anchored verbs, built on the one ABI verb that is actually anchored.

:func:`re.match` and :func:`re.fullmatch` look like the same question asked with
two different bounds, and they are not. Both are reachable here, but from
different primitives, and the reason is worth stating because getting it wrong
produces answers that are right for most patterns and quietly wrong for the rest.

**match is a leftmost search with a start test.** This engine is leftmost-first,
exactly as :mod:`re` is (``a|ab`` over ``"ab"`` matches ``"a"`` on both). So if
any match begins at ``pos``, the leftmost match at-or-after ``pos`` begins at
``pos``; and if the leftmost one begins later, none begins at ``pos`` at all.
Comparing the start is therefore not an approximation, it is the whole test.

**fullmatch is not**, and this is the trap. ``a|ab`` has no match beginning at 0
that is also two bytes long *under leftmost-first*, yet
``re.fullmatch("a|ab", "ab")`` matches: ``re`` backtracks to satisfy the anchor.
A linear-time engine does not backtrack, so the question has to be asked of a
machine that was determinized to answer it — which is ``irgx_munch_scan`` under
``IRGX_MUNCH_LONGEST``, the *longest* match beginning at exactly one offset. If
the longest match from ``pos`` reaches the end of the region then a full match
exists, and if it does not then none does, because longest is maximal. That is an
exact answer, not a near one.

The cost of borrowing the lexer plane is that its refusals come along: a munch
determinizes a pattern rather than walking it, so ``pcre=True``, ``multiline=True``
and a pattern carrying ``\\A`` or ``\\z`` are all outside it. Each of those is
raised, naming itself, instead of being answered wrongly — see
:func:`Pattern.fullmatch`. One more consequence is documented and unfixable from
here: **groups of a full match whose span differs from the leftmost-first span
cannot be reported**, because ``irgx_captures`` finds the leftmost match at an
offset and there is no anchored capture verb in this ABI. It is refused loudly at
match time rather than at group time, so the error names the cause.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from ._abi import MULTILINE, PCRE, error
from ._match import Match, TextView
from ._munch import Munch

if TYPE_CHECKING:
    from collections.abc import Callable, Iterable, Sequence

    from ._pattern import Pattern

#: Slates built for :func:`full`, keyed by the pattern object they were built
#: for. A weak-keyed map, so a slate never keeps a Pattern alive and a
#: module-level ``PAT = irgx.compile(...)`` builds its slate once for the life of
#: the process. Built lazily: a program that never calls ``fullmatch`` never pays
#: for the determinization, which is the expensive half of this file.
_SLATES: Any = None


def _slate(pattern: Pattern) -> Munch:
    """The single-terminal lexer slate for ``pattern``, determinized once.

    Compiled from the pattern's own *bytes* rather than its source domain, so the
    scan reports byte lengths that :class:`Match` can take directly — a ``str``
    pattern's character indices are then produced by the view exactly as they are
    for every other verb, instead of by a second conversion here.
    """
    global _SLATES
    if _SLATES is None:
        import weakref

        _SLATES = weakref.WeakKeyDictionary()
    if (found := _SLATES.get(pattern)) is not None:
        return found
    if pattern.flags & PCRE:
        raise error(
            "fullmatch needs an anchored automaton and the PCRE2 arm has none; "
            "compile without pcre=True, or match on a pattern that ends in \\z",
            pattern.pattern,
        )
    if pattern.flags & MULTILINE:
        raise error(
            "fullmatch needs an anchored automaton and multiline=True has no answer "
            "to where a line begins inside one; drop it, or anchor with \\A and \\z",
            pattern.pattern,
        )
    source = pattern.pattern
    encoded = source.encode("utf-8") if isinstance(source, str) else bytes(source)
    slate = Munch((encoded,), pattern.flags)
    if not len(slate):
        raise error(
            f"the anchored automaton fullmatch needs could not be built for "
            f"{source!r}: {slate.declined[0].why.name.lower()}. A pattern carrying "
            f"\\A or \\z is already anchored — use search() and check the span.",
            source,
        )
    _SLATES[pattern] = slate
    return slate


def match(
    pattern: Pattern, text: str | bytes, pos: int = 0, endpos: int | None = None
) -> Match | None:
    """The match beginning at exactly ``pos``, or ``None``.

    :mod:`re`'s ``match``. One leftmost search and one comparison — see this
    module's docstring for why that is exact rather than an approximation on a
    leftmost-first engine.
    """
    found = pattern.search(text, pos, endpos)
    if found is None:
        return None
    return found if found.start() == min(max(pos, 0), len(text)) else None


def full(
    pattern: Pattern, text: str | bytes, pos: int = 0, endpos: int | None = None
) -> Match | None:
    """The match spanning the whole of ``text[pos:endpos]``, or ``None``.

    :mod:`re`'s ``fullmatch``, answered by the longest anchored match rather than
    by a leftmost one. :func:`_slate` carries the refusals this borrows.
    """
    view = TextView(text)
    if isinstance(text, str) == pattern.is_bytes:
        from ._match import wrong_subject

        raise wrong_subject(pattern, text)
    size = len(view.original)
    first = min(max(pos, 0), size)
    last = size if endpos is None else min(max(endpos, 0), size)
    if first > last:
        return None

    start, end = view.offset(first), view.offset(last)
    region = view.data[:end]
    token = _slate(pattern).token(region, start)
    if token is None or start + token.length != end:
        return None

    # The private count, not the `groups` property: that one raises when the
    # capture arm refused the pattern, and a pattern with no capture support has
    # no group divergence to worry about in the first place.
    # The full match and the leftmost match at `pos` are the same span for almost
    # every pattern, and when they are not, `irgx_captures` would report the
    # leftmost one's groups under the full one's span. There is no anchored capture
    # verb to ask instead, so say so rather than answer with the wrong groups.
    leftmost = pattern.search(text, pos, endpos) if pattern._groups else None  # noqa: SLF001
    if leftmost is not None and (
        view.offset(leftmost.start()),
        view.offset(leftmost.end()),
    ) != (start, end):
        raise error(
            f"{pattern.pattern!r} full-matches {view.original[first:last]!r} only by a "
            f"path its leftmost match does not take, and this ABI has no anchored "
            f"capture verb, so the group spans would belong to the wrong match. Ask "
            f"search() for groups, or spell the anchor into the pattern with \\A/\\z.",
            pattern.pattern,
        )
    return Match(pattern, view, start, end)


class Scanner:
    """:class:`re.Scanner`, over the lexer plane instead of over an alternation.

    Built from ``(pattern, action)`` pairs and driven with :meth:`scan`, which
    returns the actions' results and whatever tail could not be tokenized —
    :mod:`re`'s own shape, and its own undocumented-but-relied-upon contract.

    What differs is what is underneath, and it is the difference between a lexer
    and a regex. ``re.Scanner`` joins the terminals into one big alternation, so
    the winner is whichever alternative matches **first in declaration order**;
    this asks a slate determinized together for the **longest** match at the
    cursor, and reports every terminal that reached that length. So ``["if",
    "[a-z]+"]`` scanning ``"iffy"`` yields one identifier here and, under
    ``re``, the keyword ``if`` followed by ``fy``. Maximal munch is what a lexer
    wants and is the reason this exists; if you need first-declared-wins, order
    is still yours — the tie-break among *equal-length* winners is
    first-declared, which is the half a slate cannot decide for you.

    An action is either a callable taking ``(scanner, token_text)`` or a constant
    to emit; ``None`` discards the token, which is how whitespace is skipped.
    """

    __slots__ = ("_actions", "_munch")

    def __init__(self, rules: Iterable[tuple[Any, Any]], **flags: bool) -> None:
        from ._munch import compile_munch

        pairs = list(rules)
        if not pairs:
            raise error("a scanner needs at least one (pattern, action) rule")
        self._munch = compile_munch([p for p, _ in pairs], **flags)
        self._actions: Sequence[Any] = [a for _, a in pairs]
        if declined := self._munch.declined:
            names = ", ".join(f"{pairs[r.index][0]!r} ({r.why.name.lower()})" for r in declined)
            raise error(f"a scanner cannot seat every terminal it was given: {names}")

    @property
    def munch(self) -> Munch:
        """The slate underneath, for :attr:`Munch.declined` and the raw verbs."""
        return self._munch

    def scan(self, text: str | bytes) -> tuple[list[Any], Any]:
        """``(results, remainder)`` — the actions' values, then the untokenized tail.

        Stops at the first cursor no terminal accepts, and at any terminal that
        accepts **empty** there: a zero-width win would otherwise spin forever,
        and a lexer that loops is worse than one that stops and shows you where.
        """
        scan = self._munch.over(text)
        results: list[Any] = []
        at, size = 0, len(text)
        while at < size:
            token = scan.token(at)
            if token is None or token.length == 0:
                break
            piece = text[at : at + token.length]
            action = self._actions[token.patterns[0]]
            if action is not None:
                results.append(action(self, piece) if callable(action) else action)
            at += token.length
        return results, text[at:]


def scanner(rules: Iterable[tuple[Any, Any]], **flags: bool) -> Scanner:
    """Build a :class:`Scanner`. Spelled as a function to match this package's verbs."""
    return Scanner(rules, **flags)


if TYPE_CHECKING:  # pragma: no cover - documents the action shape for a reader
    Action = Callable[[Scanner, Any], Any] | Any

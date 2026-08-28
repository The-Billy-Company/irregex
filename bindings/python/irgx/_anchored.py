"""``fullmatch`` and :class:`Scanner`, built on the one ABI verb that is actually anchored.

:func:`re.match` and :func:`re.fullmatch` look like the same question asked with
two different bounds, and they are not. They are reached from different
primitives, and the reason is worth stating because getting it wrong produces
answers that are right for most patterns and quietly wrong for the rest.

**match is a leftmost search with a start test**, so it needs nothing from this
module and lives on :meth:`irgx.Pattern.match` as the two lines it is. This
engine is leftmost-first, exactly as :mod:`re` is (``a|ab`` over ``"ab"`` matches
``"a"`` on both), so if any match begins at ``pos``, the leftmost match
at-or-after ``pos`` begins at ``pos``; and if the leftmost one begins later, none
begins at ``pos`` at all. Comparing the start is the whole test.

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
from ._match import Match, TextView, viewing
from ._munch import Munch

if TYPE_CHECKING:
    from collections.abc import Callable, Iterable, Sequence

    from ._pattern import Pattern


def _slate(pattern: Pattern) -> Munch:
    """The single-terminal lexer slate for ``pattern``, determinized once.

    Compiled from the pattern's own *bytes* rather than its source domain, so the
    scan reports byte lengths that :class:`Match` can take directly — a ``str``
    pattern's character indices are then produced by the view exactly as they are
    for every other verb, instead of by a second conversion here.

    Kept in the pattern's own ``_slate`` slot, so a module-level ``PAT =
    irgx.compile(...)`` determinizes once for the life of the process and every
    later call pays a slot read. The refusals below are outside the memo on
    purpose: a refusal never becomes a slate, so a pattern this plane cannot
    carry raises on its second call exactly as loudly as on its first.
    """
    if (found := pattern._slate) is not None:  # noqa: SLF001 - the pattern owns it
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
    pattern._slate = slate  # noqa: SLF001 - the pattern owns it
    return slate


def full(
    pattern: Pattern, text: str | bytes, pos: int = 0, endpos: int | None = None
) -> Match | None:
    """The match spanning the whole of ``text[pos:endpos]``, or ``None``.

    :mod:`re`'s ``fullmatch``, answered by the longest anchored match rather than
    by a leftmost one. :func:`_slate` carries the refusals this borrows.
    """
    # The same domain check every other verb opens with, and for the same reason:
    # an exact type in the pattern's own domain is what `viewing` is allowed to
    # assume, and it fills the view's slots for a whole-subject read rather than
    # deciding branches `__init__` must take for the general case. A subclass or
    # a buffer is still a legitimate subject, so it keeps the constructor.
    kind = type(text)
    if kind is bytes if pattern._is_bytes else kind is str:  # noqa: SLF001
        view = viewing(text)
    else:
        if isinstance(text, str) == pattern.is_bytes:
            from ._match import wrong_subject

            raise wrong_subject(pattern, text)
        view = TextView(text)
    size = len(view.original)
    first = min(max(pos, 0), size)
    last = size if endpos is None else min(max(endpos, 0), size)
    if first > last:
        return None

    start, end = view.offset(first), view.offset(last)
    # A truncation is needed only to stop the longest match from running past
    # `endpos` — and `endpos` is absent on nearly every call, so nearly every call
    # hands the engine the subject it already holds. `_reach` speaks bytes on both
    # sides, which is the domain `start` and `end` are in and the domain the slate
    # was compiled for; see :meth:`Munch._reach`.
    reach = _slate(pattern)._reach(view.upto(last), start)
    if reach is None or start + reach != end:
        return None

    # One leftmost search from the same bounds, wanted for two unrelated reasons.
    #
    # The first is correctness, and only ever from a non-zero `pos`. The munch
    # plane scans from a cursor and reads that cursor as the beginning of the
    # text, where `re` — and every other verb here — reads `pos` as a window into
    # a text that still begins at byte 0. So `^`, `\b` and their kin assert
    # differently under it: `re.fullmatch(r"^\w+", " lead", 1)` is None, because
    # `^` cannot hold at offset 1, while the scan is happy to begin a line there.
    # Rather than read the pattern looking for an anchor — a parse this module
    # does not have and a substring test would get wrong on `\\^` — ask the arm
    # whose assertions are already right. Leftmost-first means that if any match
    # begins at `start` then the leftmost one at-or-after `pos` begins there, so a
    # leftmost match beginning later (or none at all) proves nothing begins at
    # `start`, and a full match is above all a match that begins at `start`.
    #
    # The second is the groups one, and applies from anywhere. The private count,
    # not the `groups` property: that one raises when the capture arm refused the
    # pattern, and a pattern with no capture support has no group divergence to
    # worry about in the first place. The full match and the leftmost match at
    # `pos` are the same span for almost every pattern, and when they are not,
    # `irgx_captures` would report the leftmost one's groups under the full one's
    # span. There is no anchored capture verb to ask instead, so say so rather
    # than answer with the wrong groups.
    leftmost = pattern.search(text, pos, endpos) if start or pattern._groups else None  # noqa: SLF001
    if start and (leftmost is None or view.offset(leftmost.start()) != start):
        return None
    if (
        leftmost is not None
        and pattern._groups
        and (  # noqa: SLF001
            view.offset(leftmost.start()),
            view.offset(leftmost.end()),
        )
        != (start, end)
    ):
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

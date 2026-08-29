"""Maximal munch: the longest match *beginning* at an offset, among many patterns.

This is the lexer primitive, and it is a different question from every other verb
in the package. :meth:`irgx.Pattern.search` finds where a pattern is; a lexer
already knows where it is - at the cursor - and needs to know which of its
hundred and fifty terminals wins there, and how far it reaches. Written out of
the parts this library otherwise offers, that loop is N anchored searches at
every cursor position, which is quadratic in the number of terminals and reads
the same bytes N times.

Two things fall out of the shape of the problem rather than out of taste:

**Partial refusal is success.** A slate of a hundred and fifty terminals where
one is outside the linear grammar is a working lexer. So :func:`compile_munch`
returns a :class:`Munch` that seated what it could and reports the rest through
:attr:`Munch.declined`, where :func:`irgx.compile_set` refuses the whole set.
That is not an inconsistency between the two planes; it is why they are two
planes. A classifier that silently dropped a pattern would misreport *which*
patterns matched, while a lexer that refused to build over one bad terminal would
simply not lex.

**The text outlives the token.** A lexer asks the same text a thousand questions,
so the entry point that matters is :meth:`Munch.over`, which encodes once and
hands back a :class:`Scan` to ask at each cursor. :meth:`Munch.token` is the
one-shot convenience over it, and for a ``str`` it pays that encode every call -
fine for a probe, quadratic for a lexer.

There is no automaton surface here, and that is deliberate: a host stepping DFA
states would be a second opinion about what a pattern means, and one engine that
disagrees with itself is worse than one that is missing a verb.
"""

from __future__ import annotations

import ctypes
import enum
from typing import TYPE_CHECKING, Any, NamedTuple

from . import _abi
from ._abi import _VOID, MunchPattern, MunchRefusal, UnsupportedPattern, check, lib
from ._engine import transport
from ._flags import flag_bits
from ._match import TextView
from ._pool import Pool
from ._shape import TEXTUAL

# The one verb this plane crosses the FFI with per cursor - and the hottest in
# the package, since a lexer asks it once per token rather than once per text.
_scan = transport("munch_scan")[0]

if TYPE_CHECKING:
    from collections.abc import Iterable

#: Flags a munch has nowhere to carry, and why each is refused rather than
#: dropped. Answering as if one had meant something is worse than saying so.
_UNCARRIED = {
    "multiline": (
        "a scan is anchored at the cursor you pass, so the line-anchor reading "
        "it asks for cannot be observed either way: `^` is true at the cursor "
        "and `$` at the end of it, whichever way the flag is set"
    ),
    "verbose": (
        "a terminal is one token you named and the whitespace in it is yours; "
        "a slate-wide rewrite of every terminal's spaces is not what a lexer "
        "asked for. A single terminal that wants it wraps itself: `(?x: ... )`"
    ),
}


class Why(enum.IntEnum):
    """Why a terminal could not be seated.

    Carried rather than inferred because the four have different owners and
    different repairs. :attr:`STATES` and :attr:`BUFFER_ANCHOR` in particular are
    a budget and a wall: the first says a bigger build would take this pattern,
    the second that none ever will.
    """

    SYNTAX = _abi.MUNCH_SYNTAX
    """The parser would not accept the pattern at all. Yours to fix."""

    STATES = _abi.MUNCH_STATES
    """The subset construction hit this build's state bound. Not a statement
    about regular languages - a statement about this build's budget."""

    WORD_CONTEXT = _abi.MUNCH_WORD_CONTEXT
    """A ``\\b`` reached through the pattern body, with no left context to
    resolve it against. A scan starts where you point it, so there is no byte
    before the cursor for the assertion to read."""

    BUFFER_ANCHOR = _abi.MUNCH_BUFFER_ANCHOR
    """A ``\\A`` or ``\\z``, which no budget admits: the position it asserts is
    not something a machine determinized over the pattern alone can see. A scan
    is already anchored where you point it, which leaves ``\\A`` redundant and
    ``\\z`` unsatisfiable - drop it from the terminal."""


class Refusal(NamedTuple):
    """One terminal the slate could not take.

    ``why`` is a :class:`Why` when this build knows the reason and a plain
    :class:`int` when a newer engine reports one it does not - which is a thing
    to log rather than a thing to crash on.
    """

    pattern: int
    """Its index in the list :func:`compile_munch` was given."""
    why: Why | int
    """Why it was refused."""


class Token(NamedTuple):
    """What a scan found at one cursor.

    ``length`` is in the units of the text that was scanned - characters for
    ``str``, bytes for ``bytes`` - so ``text[at : at + tok.length]`` is the
    token's own spelling.
    """

    length: int
    """How far the winner reached from the cursor. ``0`` is a real answer: a
    terminal that accepts the empty string won, which is a live lexer hazard
    rather than a miss."""
    patterns: tuple[int, ...]
    """Every pattern that reached :attr:`length`, ascending. More than one is
    the ordinary case - ``if`` is both the keyword and an identifier - and
    resolving that tie is the lexer's business, not the engine's, so the whole
    tie is reported rather than a winner being invented."""


class _CompiledMunch:
    """One ``irgx_munch *``, freed when this object dies.

    Single-threaded by contract like every other handle in this ABI - it owns the
    permission set each scan rewrites - so :class:`Pool` keeps one per thread.
    """

    __slots__ = ("__weakref__", "_free", "ptr")

    def __init__(self, patterns: tuple[bytes, ...], flags: int, source: tuple[Any, ...]) -> None:
        row = (MunchPattern * len(patterns))()
        for slot, body in zip(row, patterns, strict=True):
            # ctypes keeps each `bytes` alive in the array's `_objects` for as
            # long as the array lives, which covers the call below; the ABI
            # copies the pattern bytes during the compile.
            slot.pattern = body
            slot.len = len(body)
        out = _VOID()
        status = lib.irgx_munch_compile(
            row if patterns else None, len(patterns), flags, ctypes.byref(out)
        )
        if status == _abi.STALE:
            # Nothing could be seated, so there is no handle to read reasons
            # from. Distinct from a partial refusal, which is success.
            raise UnsupportedPattern(
                f"not one of these {len(source)} terminals could be determinized, "
                f"so there is no lexer to build. Every reason is per pattern and "
                f"lives on a handle that was never made; compile them as a set, or "
                f"one at a time, to see which is which",
                source[0] if len(source) == 1 else None,
            )
        check(status, f"could not compile a munch of {len(source)} terminals")
        self.ptr = out
        # Bound to the instance so teardown does not reach for a module global
        # that interpreter shutdown may already have torn down.
        self._free = lib.irgx_munch_free

    def __del__(self) -> None:
        ptr, self.ptr = getattr(self, "ptr", None), None
        if ptr:
            self._free(ptr)


class Scan:
    """One text, encoded once, ready to be asked at any cursor.

    Get one from :meth:`Munch.over`. Holding it is what makes a lexer linear:
    the ``str`` -> UTF-8 encode and the offset bookkeeping happen here, once,
    instead of per token.

    Cursors and lengths are in the units of the text this was built from. It
    holds a reference to that text and nothing that outlives it.
    """

    __slots__ = ("_munch", "_view")

    def __init__(self, munch: Munch, text: str | bytes) -> None:
        self._munch = munch
        self._view = munch._view(text)

    @property
    def text(self) -> Any:
        """The text being scanned, exactly as it was given."""
        return self._view.original

    def __len__(self) -> int:
        """The length of the text, in the caller's own units."""
        return len(self._view.original)

    def __repr__(self) -> str:
        return f"<irgx.Scan over {self._view.original!r}>"

    def token(
        self,
        at: int = 0,
        *,
        allow: Iterable[int] | None = None,
        shortest: bool = False,
    ) -> Token | None:
        """The winning token beginning at exactly ``at``, or ``None``.

        ``allow`` restricts the scan to those pattern indices for this call
        only, which is how a context-sensitive lexer is written: the permission
        set is what changes between "expecting an operand" and "expecting an
        operator", and rebuilding a slate per context would cost a compile.
        ``None`` permits everything the slate seated. An empty ``allow`` permits
        nothing and answers ``None`` without a scan.

        ``shortest`` asks for the shortest *non-empty* reading instead of the
        longest. It is the other reading of the same offset, not a different
        search - useful for a delimiter that must not swallow its terminator.

        ``at == len(text)`` is legal and asks the only question left at the end
        of the input: does anything accept the empty string.

        :raises IndexError: if ``at`` is past the end of the text.
        """
        view = self._view
        if not 0 <= at <= len(view.original):
            raise IndexError(f"cursor {at} is outside a text of length {len(view.original)}")
        seated = len(self._munch)
        permitted = None if allow is None else tuple(allow)
        if not seated or permitted == ():
            return None

        cursor = view.offset(at)
        found = _scan(
            self._munch._pool.handle(),
            view.subject,
            cursor,
            permitted,
            _abi.MUNCH_SHORTEST if shortest else _abi.MUNCH_LONGEST,
            seated,
        )
        if type(found) is int:
            check(found, "could not scan a munch")
            return None
        # The engine answers in bytes from the start of the text; the caller
        # thinks in their own units from the cursor.
        reach, winners = found
        return Token(view.index(cursor + reach) - at, winners)


class Munch:
    """A lexer slate: many terminals, each asked only at the cursor.

    Build one with :func:`compile_munch` rather than by calling this directly.
    Immutable, and safe to share across threads.
    """

    __slots__ = ("__weakref__", "_declined", "_flags", "_is_bytes", "_pool", "_seated", "_source")

    def __init__(self, patterns: tuple[str | bytes, ...], flags: int) -> None:
        kinds = {isinstance(p, str) for p in patterns}
        if len(kinds) > 1:
            raise TypeError(
                "a munch is compiled from str patterns or from bytes patterns, "
                "not a mixture; they answer about different kinds of text"
            )
        for pattern in patterns:
            if not isinstance(pattern, TEXTUAL):
                # `bytes(42)` is 42 zero bytes rather than an error, so without
                # this guard an int would compile into something meaningless.
                raise TypeError(f"a terminal must be str or bytes, not {type(pattern).__name__}")
        self._is_bytes = not kinds.pop() if patterns else False
        self._source = patterns
        self._flags = flags
        encoded = tuple(p.encode("utf-8") if isinstance(p, str) else bytes(p) for p in patterns)
        self._pool = Pool(lambda: _CompiledMunch(encoded, flags, patterns))
        # Compiling here rather than on first use means a slate nothing could be
        # seated in raises from `compile_munch()`, and the two facts a caller
        # needs about the build - what got in, and what did not - are read once
        # here rather than per scan.
        handle = self._pool.handle()
        self._seated = lib.irgx_munch_len(handle)
        self._declined = self._survey(handle)

    def _survey(self, handle: Any) -> tuple[Refusal, ...]:
        """Every terminal the engine would not seat, asked once at build time.

        The compile list is the exact cap: a refusal is one per pattern, so this
        can never come up short and never needs the grow-and-retry loop the span
        verbs need.
        """
        cap = len(self._source)
        if not cap:
            return ()
        out = (MunchRefusal * cap)()
        written = ctypes.c_size_t()
        status = check(
            lib.irgx_munch_declined(handle, out, cap, ctypes.byref(written)),
            "could not read a munch's refusals",
        )
        if status != _abi.MATCH:
            return ()
        return tuple(Refusal(out[i].pattern, _why(out[i].why)) for i in range(written.value))

    # ── identity ──────────────────────────────────────────────────────────

    @property
    def patterns(self) -> tuple[Any, ...]:
        """The terminal sources, exactly as given and in the order a
        :class:`Token` names them."""
        return self._source

    @property
    def is_bytes(self) -> bool:
        """Whether this slate lexes ``bytes`` (rather than ``str``)."""
        return self._is_bytes

    @property
    def flags(self) -> int:
        """The raw ``IRGX_*`` bit word every terminal compiled under."""
        return self._flags

    @property
    def declined(self) -> tuple[Refusal, ...]:
        """Every terminal that could not be seated, ascending by index.

        Empty in the ordinary case. A non-empty answer is a working lexer that
        will never emit those tokens, so it is worth checking once at startup
        rather than discovering as a mis-lex.
        """
        return self._declined

    def __len__(self) -> int:
        """How many terminals were actually seated.

        The admitted count, not the compile-list count - which is the number
        that matters, because a declined terminal can never win and so can never
        be named by a :class:`Token`. Compare ``len(munch.patterns)`` to learn
        whether anything was turned away.
        """
        return self._seated

    def __repr__(self) -> str:
        return f"irgx.compile_munch({list(self._source)!r})"

    # ── the questions ─────────────────────────────────────────────────────

    def over(self, text: str | bytes) -> Scan:
        """A :class:`Scan` over ``text``, encoded once.

        The entry point for a lexer loop: every cursor after the first is then a
        single engine call with no re-encoding and no re-walking of the text's
        offset table.
        """
        return Scan(self, text)

    def token(
        self,
        text: str | bytes,
        at: int = 0,
        *,
        allow: Iterable[int] | None = None,
        shortest: bool = False,
    ) -> Token | None:
        """One token at ``at``, for when there is only one to ask about.

        Exactly ``self.over(text).token(at, ...)``. Reach for :meth:`over` in a
        loop instead: this re-encodes ``text`` on every call, which turns a
        ``str`` lexer quadratic.
        """
        return Scan(self, text).token(at, allow=allow, shortest=shortest)

    def _reach(self, subject: str | bytes, at: int) -> int | None:
        """The **byte** length of the longest token at **byte** offset ``at``, or ``None``.

        The view-free arm of :meth:`token`, for the one caller that already holds
        the engine's own domain and wants an answer in it: :func:`irgx._anchored.full`,
        which compares the reach against a byte bound it computed itself. Going
        through :class:`Scan` would build a second :class:`TextView` over the same
        text and then translate the reach into caller units so that the caller
        could translate it back — two objects and four calls spent arriving at the
        number the engine already returned.

        ``subject`` is passed to the transport as-is, so a ``str`` is read through
        its own cached UTF-8 and never re-encoded. That is why the offsets here are
        bytes on both sides regardless of the subject's type, and why this is
        private: the unit contract is the caller's to keep, where :meth:`token`
        keeps it for them.
        """
        seated = self._seated
        if not seated:
            return None
        found = _scan(self._pool.handle(), subject, at, None, _abi.MUNCH_LONGEST, seated)
        if type(found) is int:
            check(found, "could not scan a munch")
            return None
        return found[0]

    def _view(self, text: str | bytes) -> TextView:
        if not isinstance(text, TEXTUAL):
            raise TypeError(f"expected str or bytes to lex, not {type(text).__name__}")
        if isinstance(text, str) == self._is_bytes:
            wanted = "bytes" if self._is_bytes else "str"
            raise TypeError(
                f"cannot lex {type(text).__name__} with a munch compiled from "
                f"{wanted}; compile the munch from {type(text).__name__} instead"
            )
        return TextView(text)


def _why(value: int) -> Why | int:
    """``value`` as a :class:`Why`, or as itself when a newer engine names a
    reason this build has never heard of."""
    try:
        return Why(value)
    except ValueError:
        return value


def compile_munch(patterns: Iterable[Any], **flags: bool) -> Munch:
    """Compile ``patterns`` as one lexer slate.

    Takes the same keyword flags :func:`irgx.compile` does, minus ``multiline``
    and ``verbose``,
    and applies them to every terminal - a munch determinizes them together, so
    per-pattern options are not a thing the machine can be. A leading ``(?i)`` on
    one terminal is likewise not available and is refused as a syntax problem by
    the engine rather than silently applied to its neighbors.

    Compilation is **partial**: terminals that cannot be determinized are left
    out and reported in :attr:`Munch.declined`, and the rest lex. Only a slate
    where *nothing* could be seated raises.

    :raises ValueError: for ``multiline`` or ``verbose``, which this plane cannot
        carry.
    :raises UnsupportedPattern: if not one terminal could be determinized.
    :raises error: if the compile failed outright.
    """
    for name, why in _UNCARRIED.items():
        if flags.get(name):
            raise ValueError(f"{name}=True is not available on a munch: {why}")
    # An unknown keyword raises TypeError out of `flag_bits`, so a typo like
    # `ignorecase=True` fails loudly instead of silently matching case.
    return Munch(tuple(patterns), flag_bits(**flags))

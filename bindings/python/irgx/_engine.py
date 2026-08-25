"""One interface over two transports: the native accelerator, or ctypes.

Fourteen verbs in this ABI are asked once per *text* - a search, a scan, a
classification - and the rest are asked once per *program*: open a handle,
describe it, compile a slate, free it. The cost of crossing the FFI boundary is
the same either way, and it only matters for the first group:

    irgx_is_match_in   engine  12.7 ns   through ctypes  327 ns
    irgx_find_all_in   engine  66.1 ns   through ctypes  585 ns

That is a linear-time engine spending eight times longer being *called* than
running, and no amount of work on the Zig side can touch it. So the fourteen hot
verbs get a second transport - :mod:`irgx._accel`, a stable-ABI C extension that
takes the caller's own ``str`` and hands back finished Python objects - and this
module is where the package picks one and stops caring which.

Both transports answer identically, and "identically" is the load-bearing word:
same arguments, same objects, same statuses, same order. The suite proves it by
running the whole thing twice, once with ``IRGX_NO_ACCEL=1``, so the fallback
is a path under test rather than a path in principle.

**The seam speaks statuses, not exceptions.** Every verb here returns the
engine's own ``int32`` when it has no result, and a finished Python object when
it does. Which sentence to build out of a status depends on the plane - "could
not search with 'x['", "could not scan a munch" - so the translation stays with
:func:`irgx._abi.check` at the call site, and neither transport has to carry
error prose. That is also what keeps the C module small enough to be worth
having.

**Nothing here is required.** No accelerator - an interpreter it was not built
for, a source checkout, ``IRGX_NO_ACCEL=1`` in the environment - and every verb
falls back to the ctypes implementation beside it, which is the one this package
shipped with. :data:`NATIVE` says which one answered.
"""

from __future__ import annotations

import ctypes
from collections.abc import Callable
from typing import Any

from ._abi import ACCEL, MunchToken, Occurrence, Span, lib

#: How many spans to ask for on a first ``find_all``. The header's advice is to
#: size the window at ``len + 1``, the most matches a text can hold; doing that
#: unconditionally would allocate 16 MB of span buffer for a 1 MB text that
#: probably has four matches. So start here and let the count the engine reports
#: size the one retry a short window can ever need.
_FIRST_WINDOW = 4096

_SIZE = ctypes.c_size_t
_U32 = ctypes.c_uint32


def _raw(subject: Any) -> bytes:
    """``subject`` as the bytes ctypes can hand to a ``const uint8_t *``.

    The native transport reads a ``str``'s own cached UTF-8 and copies nothing,
    so when it is present the planes above hand their subjects over unencoded
    (see :data:`READS_STR`). ctypes cannot, so this is where a ``str`` becomes
    bytes on the fallback path - and it accepts one either way, so the two
    transports are interchangeable in the suite rather than merely parallel.
    """
    if type(subject) is bytes:
        return subject
    if isinstance(subject, str):
        return subject.encode("utf-8")
    return bytes(subject)


# ── the regex plane ────────────────────────────────────────────────────────


def _is_match(regex: int, subject: Any, start: int) -> int:
    data = _raw(subject)
    return int(lib.irgx_is_match_in(regex, data, len(data), start, len(data)))


def _find_all(regex: int, subject: Any, start: int, limit: int) -> list[tuple[int, int]] | int:
    """Spans as ``[(start, end)]``, or the engine's status when it refused.

    ``limit`` is how many spans the caller wants at most, ``0`` for all of them
    - the difference between ``search`` and ``finditer``, and the reason those
    are one entry point rather than two. The end bound is always the end of the
    buffer: ``endpos`` is expressed by shortening the subject, because that is
    what ``re`` means by it, so there is no ceiling left to pass.
    """
    data = _raw(subject)
    size = len(data)
    cap = min(size + 1, _FIRST_WINDOW)
    if limit:
        cap = min(cap, limit)
    written = _SIZE()
    out = (Span * cap)()
    status = lib.irgx_find_all_in(regex, data, size, start, size, out, cap, ctypes.byref(written))
    if status < 0:
        return int(status)
    # A short window says by how much, and a second pass over unchanged text
    # cannot find a different number, so there is no growth schedule - one
    # retry, sized at the count, and never a third. A caller who asked for a
    # limit has everything they asked for already.
    if written.value > cap and not limit:
        cap = written.value
        out = (Span * cap)()
        status = lib.irgx_find_all_in(
            regex, data, size, start, size, out, cap, ctypes.byref(written)
        )
        if status < 0:
            return int(status)
    return [(out[i].start, out[i].end) for i in range(min(written.value, cap))]


def _find_first(regex: int, subject: Any, start: int) -> tuple[int, int] | int:
    """The leftmost span at or after ``start``, or the engine's status.

    Not ``find_all`` with a cap of one, which is a different question: a cap
    bounds what gets *written* and never what gets walked, because ``written``
    owes the caller how many matches the whole text holds. So a ``search`` spelled
    that way pays for every match in the text and the tally over them, all of it
    for spans the caller has no way to read. This asks only for the first, and the
    walk stops there - which is why it beats even ``is_match`` on the same text.
    """
    data = _raw(subject)
    size = len(data)
    span = Span()
    status = lib.irgx_find_first_in(regex, data, size, start, size, ctypes.byref(span))
    return (span.start, span.end) if status == 1 else int(status)


def _texts(regex: int, subject: Any, start: int, decode: bool) -> list[Any] | int:
    """findall with no groups: every whole-match text, in one verb.

    ``decode`` says the caller's domain is ``str``: each slice comes back
    decoded, and an empty match on a UTF-8 continuation byte is dropped — it
    splits a character the caller has no position for, the same rule the span
    walk applies before building ``Match`` objects. The native transport builds
    the finished list in C; this is the same answer assembled from the verbs
    beside it.
    """
    data = _raw(subject)
    found = _find_all(regex, data, start, 0)
    if type(found) is int:
        return found
    if not decode:
        return [data[at:end] for at, end in found]
    size = len(data)
    return [
        data[at:end].decode("utf-8") for at, end in found if at >= size or data[at] & 0xC0 != 0x80
    ]


def _group_texts(regex: int, subject: Any, start: int, count: int, decode: bool) -> list[Any] | int:
    """findall with groups: the walk, the capture pass and the texts, in one verb.

    One group answers bare, several answer as a tuple, and a group the match
    did not enter answers ``None``. A capture refusal the walk did not hit
    propagates as its status; a capture answer that contradicts the walk raises,
    because inventing groups would be worse than refusing.
    """
    data = _raw(subject)
    found = _find_all(regex, data, start, 0)
    if type(found) is int:
        return found
    size = len(data)
    out: list[Any] = []
    for at, end in found:
        if decode and at < size and data[at] & 0xC0 == 0x80:
            continue
        spans = _captures(regex, data, at, count)
        if type(spans) is int:
            if spans < 0:
                return spans
            raise RuntimeError(
                f"internal disagreement in the engine: find_all reported a match at "
                f"bytes ({at}, {end}), but captures found none there"
            )
        if spans[0] != (at, end):
            raise RuntimeError(
                f"internal disagreement in the engine: find_all reported a match at "
                f"bytes ({at}, {end}), but captures answered differently from the same offset"
            )
        row = spans[1:]
        texts = [
            None
            if span is None
            else (data[span[0] : span[1]].decode("utf-8") if decode else data[span[0] : span[1]])
            for span in row
        ]
        out.append(texts[0] if count == 1 else tuple(texts))
    return out


def _thinned(found: list[tuple[int, int]], data: bytes, decode: bool) -> list[tuple[int, int]]:
    """``found`` with the spans no caller has a position for dropped.

    An empty match landing on a UTF-8 continuation byte splits a character, and
    a ``str`` caller counts characters - so the span walk drops it before any
    answer is assembled from it. On a subject whose UTF-8 is all ASCII no byte
    can be a continuation byte, which is why this needs no ``wide`` test to be
    exactly free there.
    """
    if not decode:
        return found
    size = len(data)
    return [(at, end) for at, end in found if at >= size or data[at] & 0xC0 != 0x80]


def _spliced(regex: int, subject: Any, sep: Any, count: int, decode: bool) -> tuple[Any, int] | int:
    """``sub`` with a constant replacement: ``(text, made)``, or the status.

    The whole substitution in one verb, for the template that renders the same
    text for every match - which is most of them. There is no ``Match`` in this
    answer and no character index either: the pieces are cut out of the
    subject's own UTF-8 and decoded once at the end, which is the same string as
    decoding each piece because every cut sits on a character boundary.
    """
    data = _raw(subject)
    found = _find_all(regex, data, 0, 0)
    if type(found) is int:
        return found
    blade = sep.encode("utf-8") if decode else sep
    out: list[bytes] = []
    cut = made = 0
    for at, end in _thinned(found, data, decode):
        if count and made >= count:
            break
        out.append(data[cut:at])
        out.append(blade)
        cut = end
        made += 1
    out.append(data[cut:])
    whole = b"".join(out)
    return (whole.decode("utf-8") if decode else whole), made


def _pieces(regex: int, subject: Any, maxsplit: int, decode: bool) -> list[Any] | int:
    """``split`` with no groups: every piece between the matches, in one verb."""
    data = _raw(subject)
    found = _find_all(regex, data, 0, 0)
    if type(found) is int:
        return found
    out: list[bytes] = []
    cut = 0
    for taken, (at, end) in enumerate(_thinned(found, data, decode)):
        if maxsplit and taken >= maxsplit:
            break
        out.append(data[cut:at])
        cut = end
    out.append(data[cut:])
    return [piece.decode("utf-8") for piece in out] if decode else out


def _captures(regex: int, subject: Any, at: int, groups: int) -> list[tuple[int, int] | None] | int:
    """Group spans for the match at ``at``, with ``None`` for a group not entered.

    ``groups`` is what the pattern declares, which is the exact window the ABI
    documents - it reports how many groups the PATTERN has, not how many it
    wrote - so the retry below is a belt for a claim rather than a path anyone
    takes.
    """
    data = _raw(subject)
    cap = groups + 1
    written = _SIZE()
    while True:
        out = (Span * cap)()
        status = lib.irgx_captures(regex, data, len(data), at, out, cap, ctypes.byref(written))
        if status != 1 or written.value <= cap:
            break
        cap = written.value
    if status != 1:
        return int(status)
    return [
        None if out[i].start < 0 or out[i].end < 0 else (out[i].start, out[i].end)
        for i in range(written.value)
    ]


# ── presence and attribution ───────────────────────────────────────────────

# Every attribution verb in this ABI has the same shape - ascending uint32
# indices into a compiled list, under a cap the caller already knows exactly -
# so the slate and the needle set are one implementation asked twice.


def _present(verb: Any, handle: int, subject: Any) -> int:
    data = _raw(subject)
    return int(verb(handle, data, len(data)))


def _indices(verb: Any, handle: int, subject: Any, cap: int) -> list[int] | int:
    data = _raw(subject)
    out = (_U32 * cap)() if cap else None
    written = _SIZE()
    status = verb(handle, data, len(data), out, cap, ctypes.byref(written))
    if status < 0:
        return int(status)
    return [out[i] for i in range(min(written.value, cap))]


def _slate_is_match(slate: int, subject: Any) -> int:
    return _present(lib.irgx_slate_is_match, slate, subject)


def _slate_which(slate: int, subject: Any, cap: int) -> list[int] | int:
    return _indices(lib.irgx_slate_which, slate, subject, cap)


def _needles_is_match(needles: int, subject: Any) -> int:
    return _present(lib.irgx_needles_is_match, needles, subject)


def _needles_which(needles: int, subject: Any, cap: int) -> list[int] | int:
    return _indices(lib.irgx_needles_which, needles, subject, cap)


def _needles_find_all(needles: int, subject: Any) -> list[tuple[int, int, int]] | int:
    """Occurrences as ``[(needle, start, end)]``.

    Unbounded in the length of the text, unlike the two ``which`` verbs, so this
    is the one attribution verb that has to size its own retry.
    """
    data = _raw(subject)
    cap = _FIRST_WINDOW
    written = _SIZE()
    for _ in range(2):
        out = (Occurrence * cap)()
        status = lib.irgx_needles_find_all(
            needles, data, len(data), out, cap, ctypes.byref(written)
        )
        if status < 0:
            return int(status)
        if written.value <= cap:
            break
        cap = written.value
    return [(out[i].needle, out[i].start, out[i].end) for i in range(min(written.value, cap))]


# ── the lexer plane ────────────────────────────────────────────────────────


def _munch_scan(
    munch: int, subject: Any, at: int, allow: tuple[int, ...] | None, pick: int, seated: int
) -> tuple[int, tuple[int, ...]] | int:
    """``(reach, winners)`` for the cursor at ``at``, or the status.

    ``seated`` is the exact cap at which ``count`` can never exceed what was
    written - a pattern cannot win twice - so this never retries.
    """
    data = _raw(subject)
    out = (_U32 * seated)()
    row = None if allow is None else (_U32 * len(allow))(*allow)
    token = MunchToken()
    status = lib.irgx_munch_scan(
        munch,
        data,
        len(data),
        at,
        row,
        0 if allow is None else len(allow),
        pick,
        ctypes.byref(token),
        out,
        seated,
    )
    if status != 1:
        return int(status)
    return token.len, tuple(out[i] for i in range(min(token.count, seated)))


_FALLBACK: dict[str, Callable[..., Any]] = {
    "is_match": _is_match,
    "find_first": _find_first,
    "find_all": _find_all,
    "captures": _captures,
    "texts": _texts,
    "group_texts": _group_texts,
    "spliced": _spliced,
    "pieces": _pieces,
    "slate_is_match": _slate_is_match,
    "slate_which": _slate_which,
    "munch_scan": _munch_scan,
    "needles_is_match": _needles_is_match,
    "needles_which": _needles_which,
    "needles_find_all": _needles_find_all,
}

#: Whether the transport takes a ``str`` subject without encoding it first.
#:
#: The native one reads a ``str``'s own cached UTF-8, which for the ASCII case
#: *is* the object's storage - so a text searched twice is copied zero times,
#: where ``.encode()`` mints a fresh ``bytes`` on every call. The planes above
#: consult this to decide whether their subject needs encoding at all; see
#: :class:`irgx._match.TextView`, which keeps the encoded copy lazy when it does
#: not.
READS_STR = ACCEL is not None


def native() -> tuple[str, ...]:
    """Which verbs the native transport can currently answer for.

    Asked rather than snapshotted, because a plane declares its own symbols when
    it is first imported and the planes are imported lazily - the needle verbs
    simply do not exist yet for a program that has only ever searched. Empty
    when there is no accelerator at all.
    """
    return () if ACCEL is None else tuple(ACCEL.bound())


def transport(*names: str) -> tuple[Callable[..., Any], ...]:
    """The best implementation of each named verb, in the order asked.

    Resolved once at plane-import time and bound to a module global, so the
    choice costs nothing per call - no dispatch, no attribute walk, no branch.
    A plane calls this immediately after its :func:`irgx._abi.declare`, which is
    what makes the routing per verb rather than per build: an engine too old to
    export one symbol keeps the ctypes path for that verb alone.
    """
    live = frozenset(native())
    return tuple(getattr(ACCEL, name) if name in live else _FALLBACK[name] for name in names)

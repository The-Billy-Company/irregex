"""The ``IRGX_*`` bit words, one builder per plane that takes one.

Two planes accept a flag word and they accept **different sets**, which is the
whole reason this is a module rather than a function. The pattern plane takes the
grammar and semantics bits; the tree request takes the search-shape bits, and has
no field for ``IRGX_PCRE``, ``IRGX_MULTILINE`` or ``IRGX_DOTALL`` to travel in —
any bit outside its set is ``IRGX_INVALID`` rather than ignored, because a host
that set one has a wrong belief about what it is about to be told.

So there is no single ``flags=`` integer in this package's surface. Each plane
takes keywords it can actually honor, and a bit that plane cannot express is not
a parameter at all — which is how "accepted and silently ignored" is made
unspellable rather than merely discouraged.

The numbering is shared across the ecosystem: bits 3 and (for the pattern plane)
4 and 7 are claimed by the sibling search library for its own behavioral flags,
so nothing here reuses them.
"""

from __future__ import annotations

# Bound as names here rather than reached for as `_abi.FIXED` per bit. Both
# builders are on the compile path — `irgx.compile` calls one on every call,
# cache hit or not — and eight module-attribute walks per call was the largest
# single cost in a cached compile, above the cache lookup it feeds.
from ._abi import (
    DOTALL,
    FIXED,
    IGNORE_CASE,
    MULTILINE,
    NO_UNICODE,
    PCRE,
    SMART_CASE,
    WORD,
)

#: ``IRGX_MAX_COUNT`` — the tree request's per-file ceiling is PRESENT.
#:
#: It needs a bit of its own because ``0`` is a legal ceiling here, so "unset"
#: cannot be spelled as zero the way every other budget in that request spells it.
MAX_COUNT = 1 << 4
#: ``IRGX_INVERT`` — select the NON-matching lines. Tree request only.
INVERT = 1 << 7


def flag_bits(
    *,
    fixed: bool = False,
    ignore_case: bool = False,
    word: bool = False,
    smart_case: bool = False,
    unicode: bool = True,
    multiline: bool = False,
    dotall: bool = False,
    pcre: bool = False,
) -> int:
    """The bit word for a compiled pattern's semantics.

    ``unicode`` is inverted on purpose: Unicode semantics are the engine's
    default, so the bit that exists is ``IRGX_NO_UNICODE`` and passing
    ``unicode=True`` sets nothing.

    ``multiline`` and ``dotall`` are ``re.M`` and ``re.S``, spelled as keywords
    and defaulting off exactly as they do there.
    """
    return (
        (FIXED if fixed else 0)
        | (IGNORE_CASE if ignore_case else 0)
        | (WORD if word else 0)
        | (SMART_CASE if smart_case else 0)
        | (0 if unicode else NO_UNICODE)
        | (MULTILINE if multiline else 0)
        | (DOTALL if dotall else 0)
        | (PCRE if pcre else 0)
    )


def search_bits(
    *,
    fixed: bool = False,
    ignore_case: bool = False,
    smart_case: bool = False,
    word: bool = False,
    unicode: bool = True,
    invert: bool = False,
    capped: bool = False,
) -> int:
    """The bit word for one ``irgx_tree_request``.

    The same four semantics bits the pattern plane takes, plus the two this plane
    has fields for — and deliberately none of the three it does not. ``capped``
    says ``max_count`` is set; the caller spells that by passing a ceiling, so it
    is derived there rather than being a keyword a host has to remember to pair.
    """
    return (
        (FIXED if fixed else 0)
        | (IGNORE_CASE if ignore_case else 0)
        | (SMART_CASE if smart_case else 0)
        | (WORD if word else 0)
        | (0 if unicode else NO_UNICODE)
        | (INVERT if invert else 0)
        | (MAX_COUNT if capped else 0)
    )

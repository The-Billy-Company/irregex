"""Every ctypes prototype must be spelled as the frozen header spells it.

This is the gate for the one hazard that is invisible from the Python side:
:mod:`ctypes` defaults an unset ``restype`` to ``c_int``, so a verb returning
``size_t`` comes back **silently truncated to 32 bits** on a 64-bit host. It is a
wrong answer rather than a crash, and no test whose numbers stay under
2\\ :sup:`31` can ever see it. Seven verbs in ``include/irgx.h`` return
``size_t``; the count of files a walk yielded, the length of a text a codex
indexes and the number of records a tree search found are all among them, and all
three are quantities a real corpus can push past 2\\ :sup:`31`.

Rather than eyeball a table, this reads the header and compares it — return type
and every parameter type, for all 100 symbols — against
:data:`irgx._abi.PROTOTYPES`, the table :func:`irgx._abi.declare` records as it
binds. Both halves of every prototype are therefore checked mechanically, so a
new plane added without a ``restype`` fails here instead of in someone's data.

The comparison is by SHAPE, not by spelling: a C type is reduced to a base kind
and a pointer depth, because ctypes has one type for several C spellings that are
the same machine word. ``const char *``, ``const uint8_t *`` and ``uint8_t *``
are all one byte pointer; a pointer to an opaque handle and a ``void *`` are both
one address. What survives the reduction is exactly what can be got wrong in a
way the CPU notices: **width**, **signedness** and **indirection**.

The three things this deliberately does NOT check, so they are said out loud
rather than implied: the identity of a struct behind a struct pointer (the ABI's
own ``struct_size`` handshake catches a wrong layout at the call — see
:func:`test_a_wrong_struct_size_is_refused`), the parameter NAMES (documentation,
not contract), and whether a pointer is ``const`` (a C-side promise ctypes has no
spelling for).
"""

from __future__ import annotations

import ctypes
import functools
import re
from typing import Any

import irgx
import pytest
from irgx import _abi
from test_cdef_header_parity import _COMMENT, _DECL, _TOKEN, _header_path, _preprocessor_free

#: The reduction target. ``base`` is a canonical kind, ``depth`` the number of
#: ``*``s: ``("size_t", 0)`` is a returned count, ``("size_t", 1)`` the
#: ``written`` out-parameter every sink verb takes.
Shape = tuple[str, int]

#: Scalars, keyed by the header's spelling. Fixed-width names on purpose — this
#: header never says bare ``int`` or ``long``, so there is no place for a type
#: whose width is the compiler's business.
_SCALARS: dict[str, Any] = {
    "int32_t": ctypes.c_int32,
    "uint32_t": ctypes.c_uint32,
    "uint64_t": ctypes.c_uint64,
    "uint8_t": ctypes.c_uint8,
    "size_t": ctypes.c_size_t,
}

#: ctypes scalars back to a canonical base. ``c_size_t`` is its own kind rather
#: than an alias of ``c_uint64``: they are the same width on this host and the
#: distinction is the whole point of the audit.
_BASES: dict[Any, str] = {cls: name for name, cls in _SCALARS.items()}

#: Single-byte pointees. ctypes collapses them all into ``c_char_p``, and the
#: header's choice between them is about whether the bytes are text — a
#: documentation distinction, not a machine one.
_BYTES = frozenset({"char", "uint8_t"})

#: The names for one 64-bit unsigned word, collapsed **only where ctypes has
#: already collapsed them**. On every LP64 host — which is every host this wheel
#: is built for — ``ctypes.c_uint64 is ctypes.c_size_t``, both being ``c_ulong``,
#: so no audit written in Python can tell a ``size_t`` prototype from a
#: ``uint64_t`` one. Pretending otherwise would make this gate fail on a
#: distinction the language cannot express. On an ILP32 host the two classes ARE
#: distinct, the set collapses to nothing, and the audit gets stricter by itself.
#: The hazard this file exists for is unaffected: ``c_int`` is 32 bits on both.
_WORD = frozenset({"size_t", "uint64_t"}) if ctypes.c_uint64 is ctypes.c_size_t else frozenset()


def _header_source() -> str:
    return _preprocessor_free(_COMMENT.sub(" ", _header_path().read_text(encoding="utf-8")))


@functools.cache
def _opaque() -> frozenset[str]:
    """Handle types with no published layout: ``typedef struct irgx_x irgx_x;``.

    A pointer to one of these is an address and nothing else, which is why this
    binding spells them ``c_void_p``. Every other ``irgx_*`` is a real struct
    whose fields a host reads, so a pointer to one must be a ``POINTER`` to a
    :class:`ctypes.Structure` — telling the two apart is the difference between
    a handle a host may not peer into and an out-parameter it must.
    """
    source = _header_source()
    return frozenset(re.findall(r"typedef\s+struct\s+(\w+)\s+\1\b", source))


def _normal(base: str, depth: int) -> Shape:
    """The one canonical form both sides reduce into.

    Byte-ness and opacity only mean anything BEHIND a pointer, so the collapsing
    happens here rather than in either reducer: ``uint8_t`` returned by value is a
    byte-wide integer and must not compare equal to a pointer to bytes.
    """
    if base in _WORD:
        base = "u64"
    if depth == 0:
        return (base, 0)
    if base in _BYTES:
        return ("byte", depth)
    if base == "void" or base in _opaque():
        return ("opaque", depth)
    if base == "u64" or base in _SCALARS:
        return (base, depth)
    return ("aggregate", depth)


def _reduce_c(tokens: tuple[str, ...]) -> Shape:
    """A C parameter or return type reduced to :data:`Shape`."""
    depth = sum(token.count("*") for token in tokens)
    words = [t for t in tokens if "*" not in t and t != "const"]
    return _normal(words[-1] if words else "void", depth)


def _reduce_py(kind: Any) -> Shape:
    """A ctypes type reduced to the same :data:`Shape`."""
    base, depth = _raw_py(kind)
    return _normal(base, depth)


def _raw_py(kind: Any) -> tuple[str, int]:
    """``(base, pointer depth)`` for a ctypes type, before canonicalization."""
    if kind is None:
        return ("void", 0)
    if kind is ctypes.c_char_p:
        return ("char", 1)
    if kind is ctypes.c_void_p:
        return ("void", 1)
    if kind is ctypes.c_char:
        return ("char", 0)
    if (base := _BASES.get(kind)) is not None:
        return (base, 0)
    if (pointee := getattr(kind, "_type_", None)) is not None:
        inner, depth = _raw_py(pointee)
        return (inner, depth + 1)
    if isinstance(kind, type) and issubclass(kind, ctypes.Structure):
        return ("aggregate", 0)
    raise AssertionError(f"the audit has no reduction for the ctypes type {kind!r}")


def _params(text: str) -> tuple[Shape, ...]:
    """One :data:`Shape` per declared parameter. ``(void)`` reduces to no parameters."""
    if text.strip() == "void":
        return ()
    out: list[Shape] = []
    for param in text.split(","):
        tokens = tuple(_TOKEN.findall(param))
        if len(tokens) > 1 and re.fullmatch(r"[A-Za-z_]\w*", tokens[-1]):
            tokens = tokens[:-1]  # trailing identifier is the name
        out.append(_reduce_c(tokens))
    return tuple(out)


@functools.cache
def _declarations() -> dict[str, tuple[str, str]]:
    """``{name: (raw return type, raw parameter list)}``, straight off the header."""
    found: dict[str, tuple[str, str]] = {}
    for statement in _header_source().split(";"):
        text = " ".join(statement.split())
        if not text or text.startswith("typedef") or "(" not in text:
            continue
        if (match := _DECL.match(text)) is None:
            continue
        found[match["name"]] = (" ".join(match["ret"].split()), match["params"])
    return found


@functools.cache
def _header() -> dict[str, tuple[Shape, tuple[Shape, ...]]]:
    """``{name: (return shape, parameter shapes)}`` for all 100 declared functions."""
    return {
        name: (_reduce_c(tuple(_TOKEN.findall(ret))), _params(params))
        for name, (ret, params) in _declarations().items()
    }


@functools.cache
def _bound() -> dict[str, tuple[Any, tuple[Any, ...]]]:
    """Every prototype this binding declares, with every plane resolved first.

    The planes load lazily, so an audit that only imported the package would see
    the regex plane and call it parity. Touching each export forces every module
    to import and therefore to declare.
    """
    for name in irgx.__all__:
        getattr(irgx, name)
    return dict(_abi.PROTOTYPES)


def test_the_header_parses_to_the_frozen_count() -> None:
    """Guard the extractor: a regex that matched nothing would pass every test below."""
    assert len(_header()) == 100, (
        f"the header parsed to {len(_header())} functions, not the frozen 100 — "
        f"either the ABI grew (this number moves with it) or the extractor broke"
    )


@functools.cache
def _mirrored() -> frozenset[str]:
    """Names the cffi tier declares instead of ctypes.

    The row cursor and the schema probe are the substrate a PRODUCER links against
    — a host that already has a face-shaped result set and wants its rows — and
    they are declared in :data:`irgx.contract.abi.CDEF`, checked against this same
    header by ``test_cdef_header_parity``. They are bound, just not here, and this
    audit says so explicitly rather than letting them read as a gap.

    The two tiers overlap on the engine, the cancellation token and
    ``irgx_status_message``, because both drive the same engine and read the same
    status codes. That is expected: this set exists to EXCUSE a ctypes absence, not
    to claim exclusivity.
    """
    from irgx.contract import abi as contract

    return frozenset(re.findall(r"\b(irgx_\w+)\s*\(", contract.CDEF + contract.ANALYTIC_CDEF))


def test_every_declared_symbol_is_bound() -> None:
    """Binding parity, asked of the prototype table rather than of the source text.

    ``quality/parity/check.py`` greps for the name, which a comment would satisfy.
    This asks the loaded library, so a symbol counts here only if ``declare``
    actually resolved it and set both halves of its signature — or if the cffi
    tier declares it, which is a real binding under a different mechanism.
    """
    missing = sorted(set(_header()) - set(_bound()) - _mirrored())
    assert not missing, f"{len(missing)} header symbols are bound by neither tier: {missing}"


def test_nothing_is_bound_that_the_header_does_not_declare() -> None:
    """The inverse: a prototype for a name the header dropped is a stale binding."""
    extra = sorted(set(_bound()) - set(_header()))
    assert not extra, f"bound but not declared by the header: {extra}"


@pytest.mark.parametrize("name", sorted(_bound()))
def test_prototype_matches_the_header(name: str) -> None:
    """Every ctypes prototype matches the header.

    The cffi-only row/schema substrate is checked by
    ``test_cdef_header_parity`` instead. Parameterizing this ctypes audit over
    header names used to manufacture seven skipped tests for those deliberately
    separate bindings, despite both tiers already having complete coverage.
    """
    want_ret, want_params = _header()[name]
    restype, argtypes = _bound()[name]
    got_ret = _reduce_py(restype)
    got_params = tuple(_reduce_py(a) for a in argtypes)
    assert got_ret == want_ret, (
        f"{name}: restype is {restype!r} ({got_ret}), the header returns {want_ret}"
    )
    assert len(got_params) == len(want_params), (
        f"{name}: {len(got_params)} argtypes, the header declares {len(want_params)}"
    )
    for i, (got, want) in enumerate(zip(got_params, want_params, strict=True)):
        assert got == want, (
            f"{name}: parameter {i} is {argtypes[i]!r} ({got}), the header declares {want}"
        )


def test_every_size_t_return_is_a_size_t() -> None:
    """The truncation hazard, stated as a list so it reads as one.

    Derived from the header rather than written out, so a new ``size_t`` verb is
    covered the day it lands. The assertion is deliberately stricter than
    ``sizeof`` equality: on this host ``c_size_t`` IS ``c_uint64``, and a
    prototype that said ``c_int`` would pass a width check that compared widths
    after the truncation had already happened.
    """
    counters = sorted(n for n, (ret, _) in _declarations().items() if ret == "size_t")
    assert len(counters) == 7, f"expected 7 size_t verbs in the frozen ABI, found {counters}"
    for name in counters:
        restype, _ = _bound()[name]
        assert restype is ctypes.c_size_t, (
            f"{name} returns size_t and its restype is {restype!r}. Left unset, ctypes "
            f"would use c_int and truncate the answer to 32 bits without failing."
        )


def test_an_unset_restype_really_does_truncate() -> None:
    """Prove the hazard is real on THIS host, not merely asserted about.

    The audit above is a rule; this is the reason for the rule. ``strtoull`` is
    borrowed from libc because it is the one function reachable from a bare
    interpreter that returns a value above 2\\ :sup:`32` on demand — no verb in
    this library can be made to, which is precisely why no ordinary test of it
    would ever catch the bug.
    """
    try:
        # Two handles on the same library, because a `_FuncPtr` is cached per CDLL
        # and `restype = None` means "returns void", not "unset". The only way to
        # exhibit the DEFAULT is a pointer nobody has assigned a restype to.
        careful = ctypes.CDLL(None).strtoull
        naive = ctypes.CDLL(None).strtoull
    except (OSError, AttributeError):  # pragma: no cover - platform without a global libc
        pytest.skip("no process-global libc to borrow strtoull from")

    both = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_int]
    careful.argtypes, careful.restype = both, ctypes.c_size_t
    naive.argtypes = both  # restype left at its default, which is c_int

    assert careful(b"4294967296", None, 10) == 2**32, "the borrowed strtoull does not work"
    truncated = naive(b"4294967296", None, 10)
    assert truncated != 2**32, (
        "an unset restype did NOT truncate here, so this test cannot vouch for the "
        "audit; treat the audit as the only guard and say so"
    )
    assert truncated == 0, f"expected the low 32 bits of 2**32, which are 0, got {truncated}"


def test_a_wrong_struct_size_is_refused(tmp_path: Any) -> None:
    """The other half of the layout story: the ABI checks what this audit cannot.

    A struct pointer's shape is all the audit can compare, so a Python struct with
    the right field count and the wrong field widths would pass it. The ABI's
    ``struct_size`` handshake closes that on every struct a host fills IN: the
    engine compares the stamped size against the layout it was built with and
    refuses a mismatch rather than reading through it. Asserted with a deliberately
    wrong size, because a guard nobody has watched fail is a guard nobody knows is
    wired — and this binding stamps that field from :func:`ctypes.sizeof` in one
    helper, so if the handshake were absent a layout drift would be silent.
    """
    from irgx._abi import OK
    from irgx._shape import sized
    from irgx._walk import Kind, Spec, Term

    def spec_over(root: bytes) -> Any:
        term = (Term * 1)()
        term[0].kind = int(Kind.ROOT)
        term[0].text = root
        term[0].text_len = len(root)
        built = sized(Spec)
        built.terms = ctypes.cast(term, ctypes.POINTER(Term))
        built.term_count = 1
        return built

    root = bytes(tmp_path)
    honest, out = spec_over(root), ctypes.c_void_p()
    assert _abi.lib.irgx_walk_open(ctypes.byref(honest), ctypes.byref(out)) == OK, (
        "the control case did not even open, so the refusal below proves nothing"
    )
    _abi.lib.irgx_walk_close(out)

    lying = spec_over(root)
    lying.struct_size = ctypes.sizeof(Spec) - 8
    refused = ctypes.c_void_p()
    assert _abi.lib.irgx_walk_open(ctypes.byref(lying), ctypes.byref(refused)) != OK, (
        "the engine accepted a struct_size that matches no layout it knows; the "
        "handshake this binding relies on for every in-struct is not enforced"
    )
    assert not refused, "a refused open still handed back a handle"

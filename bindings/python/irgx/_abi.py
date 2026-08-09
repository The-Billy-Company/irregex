"""The ctypes seam onto ``libirgx``.

This module owns three things and nothing else: finding the shared library,
declaring every C signature, and turning a negative status into a Python
exception. Everything above it (:mod:`irgx._pool`, :mod:`irgx._pattern`,
:mod:`irgx._match`) speaks Python types and never sees a status code.

The Rust binding splits this in two - ``sys.rs`` for the seam, ``error.rs`` for
the refusal vocabulary - because it *links* the engine, so its seam has no
failure path to report. Here the library is *loaded*, and a wrong ``IRGX_LIB``
is a refusal raised by the seam itself, so the two are one module rather than a
cycle between two.

ctypes rather than cffi or a C extension is a distribution decision. ctypes is
in the standard library, so the wheel needs no compiler, no Python headers, and
no build step on the installing machine; the same wheel works on any CPython
that can ``dlopen`` the bundled library.
"""

from __future__ import annotations

import ctypes
import os
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any, NamedTuple

#: One ctypes prototype: the symbol, its return type, and its parameter types.
#: ``restype`` is ``None`` for a ``void`` verb, which is why the tuple carries it
#: explicitly rather than letting a missing entry mean anything.
Signatures = Sequence[tuple[str, Any, tuple[Any, ...]]]

# The only C-ABI version this binding knows how to speak. The header promises
# this bumps on any breaking change, so refusing anything else is the whole
# point of it existing.
ABI_VERSION = 2

OK = 0
MATCH = 1
STALE = -1
OOM = -2
OPEN_FAILED = -3
INVALID = -4

# Why a munch could not seat a terminal. STATES and BUFFER_ANCHOR are a budget
# and a wall, which is the distinction worth carrying: the first says a bigger
# build would take the pattern, the second that none ever will.
MUNCH_SYNTAX = 0
MUNCH_STATES = 1
MUNCH_WORD_CONTEXT = 2
MUNCH_BUFFER_ANCHOR = 3

# Which reading of the cursor a scan asks for.
MUNCH_LONGEST = 0
MUNCH_SHORTEST = 1

# Which ruler `irgx_fault.at` is measured in. AT_NONE is 0 because byte 0 is
# a real offset, so absence cannot be spelled by `at` itself.
AT_NONE = 0
AT_FILE = 1
AT_PATTERN = 2

# Pattern semantics, from the IRGX_* block in irgx.h. Bits 3, 4 and 7 are
# deliberately absent: the sibling search library claims them for its own
# behavioral flags, and one numbering across the ecosystem is the point.
FIXED = 1 << 0
IGNORE_CASE = 1 << 1
WORD = 1 << 2
SMART_CASE = 1 << 5
NO_UNICODE = 1 << 6
PCRE = 1 << 8
MULTILINE = 1 << 9
DOTALL = 1 << 10


class error(Exception):  # noqa: N801 - named to match `re.error` so `except` clauses port
    """A pattern the engine will not compile, or a call it could not complete.

    Named ``error`` rather than ``IrregexError`` so that code written against
    ``re.error`` ports by changing the import alone, and carrying the same three
    attributes for the same reason:

    :ivar msg: the reason on its own, without the surrounding sentence.
    :ivar pattern: the pattern as the caller spelled it, or ``None`` when the
        failure was not about a pattern.
    :ivar pos: where in ``pattern`` the engine located the refusal, or ``None``
        when it did not locate one. A pattern that is refused for its *grammar*
        rather than its spelling is not wrong anywhere, so there is nothing to
        point at; see :class:`UnsupportedPattern`.
    :ivar index: which pattern of a :class:`irgx.PatternSet` this is about, or
        ``None`` for a lone pattern. With two hundred patterns, "one of them is
        unsupported" is not something a caller can act on, so the position in
        the list travels with the reason.
    """

    def __init__(
        self,
        msg: str,
        pattern: str | bytes | None = None,
        pos: int | None = None,
        index: int | None = None,
    ) -> None:
        super().__init__(msg)
        self.msg = msg
        self.pattern = pattern
        self.pos = pos
        self.index = index


class UnsupportedPattern(error):
    """A pattern the linear grammar cannot express, but PCRE2 can.

    Lookaround, a backreference, an atomic group: nothing is wrong with the
    pattern, it just needs the other engine. Recompiling it with ``pcre=True``
    succeeds, which is why this is a class of its own - a caller who wants to
    retry can catch it, and ``except irgx.error`` still catches it too.

    The engine says so by *declining* rather than by failing: the compile
    returns ``IRGX_STALE``, the one negative status that is not an error.
    So :attr:`~error.pos` is always ``None`` here, and not because the position
    was withheld - a tier that stepped aside files no report at all.
    """


class Span(ctypes.Structure):
    """``irgx_span``: one byte range ``[start, end)``, or ``(-1, -1)`` for a
    capture group the match did not enter."""

    _fields_ = (("start", ctypes.c_int64), ("end", ctypes.c_int64))


class Fault(ctypes.Structure):
    """``irgx_fault``: per-incident detail for this thread's last failure."""

    _fields_ = (
        ("struct_size", ctypes.c_uint32),
        ("status", ctypes.c_int32),
        ("at_space", ctypes.c_int32),
        ("name", ctypes.c_char_p),
        ("path", ctypes.POINTER(ctypes.c_uint8)),
        ("path_len", ctypes.c_size_t),
        ("at", ctypes.c_uint64),
    )


class SlatePattern(ctypes.Structure):
    """``irgx_slate_pattern``: one pattern of a slate, and its own flag word.

    ``pattern`` is declared ``c_char_p`` so a ``bytes`` can be assigned to it
    directly; ctypes then keeps that object alive in the array's ``_objects``
    for as long as the array lives, which covers the compile call that reads it.
    """

    _fields_ = (
        ("pattern", ctypes.c_char_p),
        ("len", ctypes.c_size_t),
        ("flags", ctypes.c_uint32),
    )


class MunchPattern(ctypes.Structure):
    """``irgx_munch_pattern``: one terminal of a lexer slate, and nothing else.

    No per-pattern flag word, unlike :class:`SlatePattern`, and the difference is
    forced rather than chosen: a munch determinizes every pattern *together*
    under one set of options, so "terminal 3 is case-insensitive" is not a thing
    the resulting machine can be.
    """

    _fields_ = (("pattern", ctypes.c_char_p), ("len", ctypes.c_size_t))


class MunchRefusal(ctypes.Structure):
    """``irgx_munch_refusal``: one terminal the slate could not take, and why."""

    _fields_ = (("pattern", ctypes.c_uint32), ("why", ctypes.c_uint32))


class MunchToken(ctypes.Structure):
    """``irgx_munch_token``: how far a scan reached, and how many patterns got there.

    ``count`` is how many reached ``len`` whether or not the winner buffer held
    them - :func:`irgx_find_all`'s contract - but here the short-buffer retry is
    always avoidable, because the count can never exceed ``irgx_munch_len``.
    """

    _fields_ = (("len", ctypes.c_size_t), ("count", ctypes.c_size_t))


class Text(ctypes.Structure):
    """``irgx_text``: a borrowed UTF-8 span, not NUL-terminated.

    ``len`` is authoritative; the bytes belong to whatever produced them and
    have that thing's lifetime, so anything read out of one is copied before
    the owner is freed.
    """

    _fields_ = (("ptr", ctypes.POINTER(ctypes.c_uint8)), ("len", ctypes.c_size_t))

    def decode(self) -> str:
        return bytes(ctypes.string_at(self.ptr, self.len)).decode("utf-8", "surrogateescape")


def _soname() -> str:
    if sys.platform == "darwin":
        return "libirgx.dylib"
    if sys.platform == "win32":
        return "irgx.dll"
    return "libirgx.so"


def library_path() -> Path:
    """Where the shared library lives: the ``IRGX_LIB`` override, else the
    copy the wheel bundled inside this package.

    The override exists for people running against their own build of the
    engine. It names a file, not a directory, so a typo fails loudly here
    instead of silently falling back to the bundled copy and reporting results
    from a library the caller did not choose.
    """
    override = os.environ.get("IRGX_LIB")
    if override:
        path = Path(override)
        if not path.is_file():
            raise error(f"IRGX_LIB points at {override!r}, which is not a file")
        return path
    bundled = Path(__file__).resolve().parent / "lib" / _soname()
    if bundled.is_file():
        return bundled
    # Editable / in-tree checkout: the hatch hook has not bundled a copy, but
    # `zig build` left one under the package root. Substrate importers
    # (`irgx.contract`, `irgx.runtime`) share this package, so a missing
    # wheel payload must not make them unimportable next to a built tree.
    name = _soname()
    for parent in Path(__file__).resolve().parents:
        candidate = parent / "zig-out" / "lib" / name
        if candidate.is_file():
            return candidate
        if (parent / "build.zig").is_file():
            break
    raise error(
        f"the irregex shared library is missing from the installed package "
        f"(expected {bundled}). This wheel was built without its native "
        f"library, or the install is damaged. Set IRGX_LIB to point at a "
        f"build of libirgx to work around it."
    )


_VOID = ctypes.c_void_p
_U8P = ctypes.c_char_p  # `const uint8_t *`; ctypes hands a bytes buffer straight through
_SIZE = ctypes.c_size_t

# (name, restype, argtypes). Every entry is declared. A missing `argtypes` lets
# ctypes pass a 64-bit pointer through the default int conversion and truncate
# it to 32 bits on some platforms, which is the classic way an FFI binding
# segfaults far from the mistake.
_SIGNATURES = (
    ("irgx_abi_version", ctypes.c_uint32, ()),
    ("irgx_version", ctypes.c_char_p, ()),
    ("irgx_pcre2_version", ctypes.c_char_p, ()),
    ("irgx_status_message", ctypes.c_char_p, (ctypes.c_int32,)),
    ("irgx_last_fault", ctypes.c_int32, (ctypes.POINTER(Fault),)),
    ("irgx_compile", ctypes.c_int32, (_U8P, _SIZE, ctypes.c_uint32, ctypes.POINTER(_VOID))),
    ("irgx_free", None, (_VOID,)),
    ("irgx_is_match", ctypes.c_int32, (_VOID, _U8P, _SIZE)),
    (
        "irgx_find_all",
        ctypes.c_int32,
        (_VOID, _U8P, _SIZE, ctypes.POINTER(Span), _SIZE, ctypes.POINTER(_SIZE)),
    ),
    ("irgx_pattern_windows", ctypes.c_int32, (_VOID,)),
    ("irgx_is_match_in", ctypes.c_int32, (_VOID, _U8P, _SIZE, _SIZE, _SIZE)),
    (
        "irgx_find_all_in",
        ctypes.c_int32,
        (_VOID, _U8P, _SIZE, _SIZE, _SIZE, ctypes.POINTER(Span), _SIZE, ctypes.POINTER(_SIZE)),
    ),
    (
        "irgx_captures",
        ctypes.c_int32,
        (_VOID, _U8P, _SIZE, _SIZE, ctypes.POINTER(Span), _SIZE, ctypes.POINTER(_SIZE)),
    ),
    ("irgx_group_count", ctypes.c_int32, (_VOID, ctypes.POINTER(ctypes.c_uint32))),
    (
        "irgx_group_index",
        ctypes.c_int32,
        (_VOID, _U8P, _SIZE, ctypes.POINTER(ctypes.c_uint32)),
    ),
    ("irgx_group_name", ctypes.c_int32, (_VOID, ctypes.c_uint32, ctypes.POINTER(Text))),
    (
        "irgx_slate_compile",
        ctypes.c_int32,
        (ctypes.POINTER(SlatePattern), _SIZE, ctypes.POINTER(_SIZE), ctypes.POINTER(_VOID)),
    ),
    ("irgx_slate_free", None, (_VOID,)),
    ("irgx_slate_len", _SIZE, (_VOID,)),
    ("irgx_slate_is_match", ctypes.c_int32, (_VOID, _U8P, _SIZE)),
    (
        "irgx_slate_which",
        ctypes.c_int32,
        (_VOID, _U8P, _SIZE, ctypes.POINTER(ctypes.c_uint32), _SIZE, ctypes.POINTER(_SIZE)),
    ),
    (
        "irgx_munch_compile",
        ctypes.c_int32,
        (ctypes.POINTER(MunchPattern), _SIZE, ctypes.c_uint32, ctypes.POINTER(_VOID)),
    ),
    ("irgx_munch_free", None, (_VOID,)),
    ("irgx_munch_len", _SIZE, (_VOID,)),
    (
        "irgx_munch_declined",
        ctypes.c_int32,
        (_VOID, ctypes.POINTER(MunchRefusal), _SIZE, ctypes.POINTER(_SIZE)),
    ),
    (
        "irgx_munch_scan",
        ctypes.c_int32,
        (
            _VOID,
            _U8P,
            _SIZE,
            _SIZE,
            ctypes.POINTER(ctypes.c_uint32),
            _SIZE,
            ctypes.c_uint32,
            ctypes.POINTER(MunchToken),
            ctypes.POINTER(ctypes.c_uint32),
            _SIZE,
        ),
    ),
    ("irgx_pattern_earliest", ctypes.c_int32, (_VOID,)),
)

#: Every prototype this binding has declared, keyed by symbol. Written by
#: :func:`declare` and read back by ``tests/test_abi_types.py``, which holds each
#: entry to the return type ``include/irgx.h`` states for it — so the table is
#: checked against the frozen header rather than against a reviewer's attention.
PROTOTYPES: dict[str, tuple[Any, tuple[Any, ...]]] = {}


def declare(signatures: Signatures, plane: str = "this plane") -> None:
    """Bind ``(name, restype, argtypes)`` prototypes onto the loaded library.

    Both halves are always set, and the ``restype`` half is the one that bites.
    ctypes defaults an unset ``restype`` to ``c_int``, so a verb returning
    ``size_t`` — ``irgx_matches_count``, ``irgx_walk_count``, ``irgx_codex_len``,
    ``irgx_codex_max_text_len``, ``irgx_slate_len``, ``irgx_munch_len``,
    ``irgx_needles_len`` — would come back **silently truncated** to 32 bits on a
    64-bit host. That is a wrong answer rather than a crash, and no test whose
    numbers stay under 2\\ :sup:`31` can see it, which is why every entry is
    declared and the whole table is audited against the header.

    A plane declares its own prototypes beside the wrapper that calls them,
    rather than growing one table that knows about every plane. A symbol this
    library does not export is a stale library and says so, naming the plane it
    is behind — additive symbols do not bump :data:`ABI_VERSION`, so the version
    probe cannot catch it.
    """
    for name, restype, argtypes in signatures:
        try:
            fn = getattr(lib, name)
        except AttributeError as exc:
            raise error(
                f"the library at {LIBRARY} does not export {name}; it is not "
                f"libirgx, or it predates {plane}"
            ) from exc
        fn.restype = restype
        fn.argtypes = list(argtypes)
        PROTOTYPES[name] = (restype, tuple(argtypes))


def _load() -> ctypes.CDLL:
    path = library_path()
    try:
        return ctypes.CDLL(str(path))
    except OSError as exc:
        raise error(f"could not load the irregex library at {path}: {exc}") from exc


lib = _load()

#: The resolved path of the loaded library. Public so a caller can prove which
#: copy answered, which matters the moment IRGX_LIB enters the picture.
LIBRARY = str(library_path())

declare(_SIGNATURES, "the regex plane")

_FOUND_ABI = lib.irgx_abi_version()
if _FOUND_ABI != ABI_VERSION:
    raise error(
        f"irregex ABI mismatch: this wheel speaks ABI {ABI_VERSION}, but the "
        f"library at {LIBRARY} reports ABI {_FOUND_ABI}. The wheel and the "
        f"library disagree; install a matching pair, or unset IRGX_LIB."
    )

#: The engine's semantic version, e.g. ``"1.0.0"``. Distinct from the Python
#: package version: one wheel can bundle a newer engine without an API change.
ENGINE_VERSION = lib.irgx_version().decode()

#: The vendored PCRE2 version the ``pcre=True`` arm runs on.
PCRE2_VERSION = lib.irgx_pcre2_version().decode()


def _status_text(status: int) -> str:
    message = lib.irgx_status_message(status)
    return message.decode() if message else f"status {status}"


class _Detail(NamedTuple):
    """This thread's last fault, as far as Python cares about it."""

    name: str
    #: Where in the *pattern* the engine located the refusal, or ``None`` when
    #: the fault has no pattern offset to report.
    pos: int | None
    path: str | None

    def __str__(self) -> str:
        return f"{self.name} at {self.path}" if self.path is not None else self.name


def _fault() -> _Detail | None:
    """This thread's last fault, or None when it has nothing to add.

    A non-OK status does not imply a detail exists - an argument guard has
    nothing to say beyond its status message - so absence here is normal.
    """
    detail = Fault()
    detail.struct_size = ctypes.sizeof(Fault)
    if lib.irgx_last_fault(ctypes.byref(detail)) != MATCH:
        return None
    name = detail.name.decode() if detail.name else None
    if not name:
        return None
    path = (
        bytes(ctypes.string_at(detail.path, detail.path_len)).decode("utf-8", "surrogateescape")
        if detail.path
        else None
    )
    # The fault states which ruler `at` is measured in, so nothing here has to
    # infer it from whether `path` came back NULL. Only a pattern offset can be
    # surfaced as `pos`, which is an index into the pattern by definition;
    # IRGX_AT_FILE cannot arrive on this plane at all, since the regex verbs
    # take a buffer the caller already holds and never open a file.
    at = detail.at if detail.at_space == AT_PATTERN else None
    return _Detail(name, at, path)


def check(
    status: int,
    doing: str,
    pattern: str | bytes | None = None,
    index: int | None = None,
) -> int:
    """Return ``status`` when the call produced a result; raise otherwise.

    ``IRGX_OOM`` becomes ``MemoryError`` because that is what a Python caller
    already catches for it. Every other negative status becomes :class:`error`
    carrying both the status sentence and, when the engine left one, the
    per-incident fault name and the position it located.

    ``IRGX_STALE`` is a declinature rather than a failure, and what a caller
    should do about one depends entirely on which verb declined and what its
    fallback is. So it is not translated here. Compile is the only verb in this
    plane that declines, and :class:`irgx._pool.Compiled` takes its fallback -
    the PCRE2 grammar - before ever reaching this function. A stale arriving
    here is a verb that grew a fallback this binding does not know how to take,
    which is worth saying out loud rather than reporting as either a failure or
    a result.
    """
    if status >= 0:
        return status
    if status == STALE:
        raise error(
            f"{doing}: {_status_text(status)} - but this call has no fallback to "
            f"answer through, so the declinature cannot be honored here",
            pattern,
            index=index,
        )
    detail = _fault()
    reason = f"{detail}; {_status_text(status)}" if detail else _status_text(status)
    if status == OOM:
        raise MemoryError(f"{doing}: {reason}")
    raise error(f"{doing}: {reason}", pattern, detail.pos if detail else None, index)

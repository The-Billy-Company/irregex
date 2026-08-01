"""The ctypes seam onto ``libirregex``.

This module owns three things and nothing else: finding the shared library,
declaring every C signature, and turning a negative status into a Python
exception. Everything above it (:mod:`irregex._pattern`, :mod:`irregex._match`)
speaks Python types and never sees a status code.

ctypes rather than cffi or a C extension is a distribution decision. ctypes is
in the standard library, so the wheel needs no compiler, no Python headers, and
no build step on the installing machine; the same wheel works on any CPython
that can ``dlopen`` the bundled library.
"""

from __future__ import annotations

import ctypes
import os
import sys
from pathlib import Path
from typing import NamedTuple

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

# Which ruler `irregex_fault.at` is measured in. AT_NONE is 0 because byte 0 is
# a real offset, so absence cannot be spelled by `at` itself.
AT_NONE = 0
AT_FILE = 1
AT_PATTERN = 2

# Pattern semantics, from the IRREGEX_* block in irregex.h. Bits 3, 4 and 7 are
# deliberately absent: the sibling search library claims them for its own
# behavioral flags, and one numbering across the ecosystem is the point.
FIXED = 1 << 0
IGNORE_CASE = 1 << 1
WORD = 1 << 2
SMART_CASE = 1 << 5
NO_UNICODE = 1 << 6
PCRE = 1 << 8


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
    """

    def __init__(
        self,
        msg: str,
        pattern: str | bytes | None = None,
        pos: int | None = None,
    ) -> None:
        super().__init__(msg)
        self.msg = msg
        self.pattern = pattern
        self.pos = pos


class UnsupportedPattern(error):
    """A pattern the linear grammar cannot express, but PCRE2 can.

    Lookaround, a backreference, an atomic group: nothing is wrong with the
    pattern, it just needs the other engine. Recompiling it with ``pcre=True``
    succeeds, which is why this is a class of its own - a caller who wants to
    retry can catch it, and ``except irregex.error`` still catches it too.

    The engine says so by *declining* rather than by failing: the compile
    returns ``IRREGEX_STALE``, the one negative status that is not an error.
    So :attr:`~error.pos` is always ``None`` here, and not because the position
    was withheld - a tier that stepped aside files no report at all.
    """


class Span(ctypes.Structure):
    """``irregex_span``: one byte range ``[start, end)``, or ``(-1, -1)`` for a
    capture group the match did not enter."""

    _fields_ = (("start", ctypes.c_int64), ("end", ctypes.c_int64))


class Fault(ctypes.Structure):
    """``irregex_fault``: per-incident detail for this thread's last failure."""

    _fields_ = (
        ("struct_size", ctypes.c_uint32),
        ("status", ctypes.c_int32),
        ("at_space", ctypes.c_int32),
        ("name", ctypes.c_char_p),
        ("path", ctypes.POINTER(ctypes.c_uint8)),
        ("path_len", ctypes.c_size_t),
        ("at", ctypes.c_uint64),
    )


class Text(ctypes.Structure):
    """``irregex_text``: a borrowed UTF-8 span, not NUL-terminated.

    ``len`` is authoritative; the bytes belong to whatever produced them and
    have that thing's lifetime, so anything read out of one is copied before
    the owner is freed.
    """

    _fields_ = (("ptr", ctypes.POINTER(ctypes.c_uint8)), ("len", ctypes.c_size_t))

    def decode(self) -> str:
        return bytes(ctypes.string_at(self.ptr, self.len)).decode("utf-8", "surrogateescape")


def _soname() -> str:
    if sys.platform == "darwin":
        return "libirregex.dylib"
    if sys.platform == "win32":
        return "irregex.dll"
    return "libirregex.so"


def library_path() -> Path:
    """Where the shared library lives: the ``IRREGEX_LIB`` override, else the
    copy the wheel bundled inside this package.

    The override exists for people running against their own build of the
    engine. It names a file, not a directory, so a typo fails loudly here
    instead of silently falling back to the bundled copy and reporting results
    from a library the caller did not choose.
    """
    override = os.environ.get("IRREGEX_LIB")
    if override:
        path = Path(override)
        if not path.is_file():
            raise error(f"IRREGEX_LIB points at {override!r}, which is not a file")
        return path
    bundled = Path(__file__).resolve().parent / "lib" / _soname()
    if bundled.is_file():
        return bundled
    # Editable / in-tree checkout: the hatch hook has not bundled a copy, but
    # `zig build` left one under the package root. Substrate importers
    # (`irregex.contract`, `irregex.runtime`) share this package, so a missing
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
        f"library, or the install is damaged. Set IRREGEX_LIB to point at a "
        f"build of libirregex to work around it."
    )


_VOID = ctypes.c_void_p
_U8P = ctypes.c_char_p  # `const uint8_t *`; ctypes hands a bytes buffer straight through
_SIZE = ctypes.c_size_t

# (name, restype, argtypes). Every entry is declared. A missing `argtypes` lets
# ctypes pass a 64-bit pointer through the default int conversion and truncate
# it to 32 bits on some platforms, which is the classic way an FFI binding
# segfaults far from the mistake.
_SIGNATURES = (
    ("irregex_abi_version", ctypes.c_uint32, ()),
    ("irregex_version", ctypes.c_char_p, ()),
    ("irregex_pcre2_version", ctypes.c_char_p, ()),
    ("irregex_status_message", ctypes.c_char_p, (ctypes.c_int32,)),
    ("irregex_last_fault", ctypes.c_int32, (ctypes.POINTER(Fault),)),
    ("irregex_compile", ctypes.c_int32, (_U8P, _SIZE, ctypes.c_uint32, ctypes.POINTER(_VOID))),
    ("irregex_free", None, (_VOID,)),
    ("irregex_is_match", ctypes.c_int32, (_VOID, _U8P, _SIZE)),
    (
        "irregex_find_all",
        ctypes.c_int32,
        (_VOID, _U8P, _SIZE, ctypes.POINTER(Span), _SIZE, ctypes.POINTER(_SIZE)),
    ),
    (
        "irregex_captures",
        ctypes.c_int32,
        (_VOID, _U8P, _SIZE, _SIZE, ctypes.POINTER(Span), _SIZE, ctypes.POINTER(_SIZE)),
    ),
    ("irregex_group_count", ctypes.c_int32, (_VOID, ctypes.POINTER(ctypes.c_uint32))),
    (
        "irregex_group_index",
        ctypes.c_int32,
        (_VOID, _U8P, _SIZE, ctypes.POINTER(ctypes.c_uint32)),
    ),
    ("irregex_group_name", ctypes.c_int32, (_VOID, ctypes.c_uint32, ctypes.POINTER(Text))),
)


def _load() -> ctypes.CDLL:
    path = library_path()
    try:
        lib = ctypes.CDLL(str(path))
    except OSError as exc:
        raise error(f"could not load the irregex library at {path}: {exc}") from exc

    for name, restype, argtypes in _SIGNATURES:
        try:
            fn = getattr(lib, name)
        except AttributeError as exc:
            raise error(
                f"the library at {path} does not export {name}; it is not libirregex, "
                f"or it predates the regex plane"
            ) from exc
        fn.restype = restype
        fn.argtypes = list(argtypes)

    found = lib.irregex_abi_version()
    if found != ABI_VERSION:
        raise error(
            f"irregex ABI mismatch: this wheel speaks ABI {ABI_VERSION}, but the "
            f"library at {path} reports ABI {found}. The wheel and the library "
            f"disagree; install a matching pair, or unset IRREGEX_LIB."
        )
    return lib


lib = _load()

#: The engine's semantic version, e.g. ``"0.3.0"``. Distinct from the Python
#: package version: one wheel can bundle a newer engine without an API change.
ENGINE_VERSION = lib.irregex_version().decode()

#: The vendored PCRE2 version the ``pcre=True`` arm runs on.
PCRE2_VERSION = lib.irregex_pcre2_version().decode()

#: The resolved path of the loaded library. Public so a caller can prove which
#: copy answered, which matters the moment IRREGEX_LIB enters the picture.
LIBRARY = str(library_path())


def _status_text(status: int) -> str:
    message = lib.irregex_status_message(status)
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
    if lib.irregex_last_fault(ctypes.byref(detail)) != MATCH:
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
    # IRREGEX_AT_FILE cannot arrive on this plane at all, since the regex verbs
    # take a buffer the caller already holds and never open a file.
    at = detail.at if detail.at_space == AT_PATTERN else None
    return _Detail(name, at, path)


def check(status: int, doing: str, pattern: str | bytes | None = None) -> int:
    """Return ``status`` when the call produced a result; raise otherwise.

    ``IRREGEX_OOM`` becomes ``MemoryError`` because that is what a Python caller
    already catches for it. Every other negative status becomes :class:`error`
    carrying both the status sentence and, when the engine left one, the
    per-incident fault name and the position it located.

    ``IRREGEX_STALE`` is a declinature rather than a failure, and what a caller
    should do about one depends entirely on which verb declined and what its
    fallback is. So it is not translated here. Compile is the only verb in this
    plane that declines, and :class:`Compiled` takes its fallback - the PCRE2
    grammar - before ever reaching this function. A stale arriving here is a
    verb that grew a fallback this binding does not know how to take, which is
    worth saying out loud rather than reporting as either a failure or a result.
    """
    if status >= 0:
        return status
    if status == STALE:
        raise error(
            f"{doing}: {_status_text(status)} - but this call has no fallback to "
            f"answer through, so the declinature cannot be honored here",
            pattern,
        )
    detail = _fault()
    reason = f"{detail}; {_status_text(status)}" if detail else _status_text(status)
    if status == OOM:
        raise MemoryError(f"{doing}: {reason}")
    raise error(f"{doing}: {reason}", pattern, detail.pos if detail else None)


class Compiled:
    """One ``irregex_regex *``, freed when this object dies.

    A handle is single-threaded by contract: it owns the scratch its finds run
    in, so two threads sharing one corrupt a match rather than race a counter.
    Ownership of that rule lives one layer up, in
    :class:`irregex._pattern.Pattern`, which keeps one of these per thread.
    """

    # `__weakref__` so a caller can observe a handle's lifetime without keeping
    # it alive; the per-thread handles are exactly the thing worth watching.
    __slots__ = ("__weakref__", "_free", "ptr")

    def __init__(self, pattern: bytes, flags: int, source: str | bytes | None = None) -> None:
        out = _VOID()
        status = lib.irregex_compile(pattern, len(pattern), flags, ctypes.byref(out))
        if status < 0:
            shown = pattern.decode("utf-8", "backslashreplace")
            doing = f"could not compile pattern {shown!r}"
            # The exception carries the pattern as the caller spelled it, since
            # that is what `re.error.pattern` holds and what a retry needs; the
            # encoded bytes stand in when nobody said what the source was.
            spelled = pattern if source is None else source
            if status == STALE:
                # A declinature, not a failure, and readable from the return
                # value alone: the linear tier stepped aside for a pattern PCRE2
                # takes as it stands. `out` is untouched, so there is no handle
                # to keep and none to free, and no fault to read either.
                raise UnsupportedPattern(
                    f"{doing}: {_status_text(status)} - compiling it with "
                    f"pcre=True accepts this pattern",
                    spelled,
                )
            check(status, doing, spelled)
        self.ptr = out
        # Bound to the instance so teardown does not reach for a module global
        # that interpreter shutdown may already have torn down.
        self._free = lib.irregex_free

    def __del__(self) -> None:
        ptr, self.ptr = getattr(self, "ptr", None), None
        if ptr:
            self._free(ptr)

"""Where a product library gets opened, and the only place cffi's type universe is composed.

The substrate can *describe* every producer — `irgx.h` declares `gist_run`,
`relate_run` and `blast_run`, because analytic op numbers stayed ecosystem-wide
when the libraries split — but describing is not opening. Which shared library a
process maps is a decision belonging to the package that owns that face, so this
module opens only what has been **registered**, and registers nothing itself.
`gist._native` registers the search face; a process that never imports it never
maps `libgist`, and the analytic plane answers that face's verbs one tier down.

A face contributes its own C declarations along with its library. cffi fixes a
library's type universe at `cdef` time, so those declarations are appended to the
substrate's `CDEF` before the `dlopen` — one universe, assembled from two halves,
each half checked against the header that actually declares it (`irgx.h` here,
`gist.h` in gist's own header-parity gate).

**Fail-open by construction.** Every entry returns `None` rather than raising
when a library is absent, `cffi` is missing, the ABI version disagrees, or the
face declined via its own opt-out knob — so a caller answers through the tier
below and an in-process path is a pure accelerator that never adds a failure
mode.
"""

from __future__ import annotations

import os
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

from ..contract import abi

if TYPE_CHECKING:
    from cffi import FFI


@dataclass(frozen=True, slots=True)
class Face:
    """One product library the analytic plane may dispatch into.

    :param name: the face's name, and the prefix of its `<name>_run` producer —
        which is how a verb's entry symbol identifies the library to open,
        without a table maintained beside the dispatch.
    :param library: the shared library's stem, or None to be *declared but never
        opened* — a face that contributes types the universe needs while leaving
        the decision to map it to some other package.
    :param checkout: the directory owning the library, when it differs from the
        library's own name. It does for exactly one package: the engine builds
        `libirgx` inside a checkout still called `irregex`.
    :param cdef: the face's own C declarations, appended to the substrate's.
    :param abi: `(symbol, version)` the library must agree on, or None to skip
        the gate. A disagreement is a decline, never an error.
    :param off_env: an environment variable that, when set, declines this face's
        in-process tier outright.
    """

    name: str
    library: str | None = None
    checkout: str | None = None
    cdef: str = ""
    abi: tuple[str, int] | None = None
    off_env: str = ""


_faces: dict[str, Face] = {}
_registry_lock = threading.Lock()
_loaded: dict[str, tuple[FFI, object] | None] = {}
_load_lock = threading.Lock()
# Substrate handles are kept alive for the process: `libirgx` is opened
# RTLD_GLOBAL so a product library's undefined `irgx_*` references resolve
# against it, and letting the handle drop would unmap the symbols the face's
# own already-bound code still calls.
_substrate: list[object] = []


def register(face: Face) -> None:
    """Make `face` openable. Idempotent for an identical re-registration.

    Re-registering the same name with *different* terms is a programming error
    rather than a decline: two packages disagreeing about which library answers a
    producer would silently give one of them the other's engine.
    """
    with _registry_lock:
        if (seen := _faces.get(face.name)) is not None and seen != face:
            msg = f"face {face.name!r} is already registered as {seen!r}, not {face!r}"
            raise ValueError(msg)
        _faces[face.name] = face


def face(name: str) -> Face | None:
    """The registered face called `name`, or None if no package registered it."""
    return _faces.get(name)


def registered() -> tuple[Face, ...]:
    """Every registered face, in registration order."""
    return tuple(_faces.values())


def _dylib_name(stem: str) -> str:
    if sys.platform == "darwin":
        return f"lib{stem}.dylib"
    if sys.platform == "win32":
        return f"{stem}.dll"
    return f"lib{stem}.so"


def library(stem: str, checkout: str | None = None) -> str | None:
    """Shared library owned by `stem`: `${STEM}_LIB` override, else its own tree.

    The same structural rule `shell._locate_root` uses for binaries, for the same
    reason: this loader is substrate, so a package's library is in *that
    package's* `zig-out/lib`, not in whichever tree happens to be above this
    file. `libgist` resolves out of `../gist`, `librelate` out of `../relate`,
    and the walk is over ancestors rather than a counted depth.

    Returns None (→ the tier below) when nothing is built or installed; an
    in-process library is an accelerator here, never a dependency.
    """
    if override := os.environ.get(f"{stem.upper()}_LIB"):
        return override if Path(override).is_file() else None
    here, name, owner_dir = Path(__file__).resolve(), _dylib_name(stem), checkout or stem
    for parent in here.parents:  # installed into a prefix, or this package's own build
        if (candidate := parent / "zig-out" / "lib" / name).is_file():
            return str(candidate)
    for parent in here.parents:  # a dev tree: the checkouts sit side by side
        if not (parent / "build.zig").is_file():
            continue
        owner = parent if parent.name == owner_dir else parent.parent / owner_dir
        if (candidate := owner / "zig-out" / "lib" / name).is_file():
            return str(candidate)
        return None  # in a checkout but unbuilt — one tier down until `zig build`
    return None


def load(name: str) -> tuple[FFI, object] | None:
    """The `(ffi, lib)` pair for face `name`, opened once per process. None on any miss.

    None when the face was never registered, declares no library to open, opted
    out by its own knob, is absent from disk, or disagrees about its ABI version.
    """
    if name in _loaded:
        return _loaded[name]
    with _load_lock:
        if name in _loaded:
            return _loaded[name]
        _loaded[name] = _open(_faces.get(name))
        return _loaded[name]


def _open(spec: Face | None) -> tuple[FFI, object] | None:
    if spec is None or spec.library is None:
        return None
    if spec.off_env and os.environ.get(spec.off_env) is not None:
        return None
    product = library(spec.library)
    engine = library("irgx", checkout="irregex")
    if product is None or engine is None:
        return None
    try:
        import ctypes

        from cffi import FFI
    except ImportError:
        return None
    ffi = FFI()
    ffi.cdef(abi.CDEF + abi.ANALYTIC_CDEF + spec.cdef)
    try:
        # The substrate first and globally, so the product's undefined `irgx_*`
        # references — the engine handle, the row cursor, the schema table —
        # resolve against the very implementation its own cursors read.
        _substrate.append(ctypes.CDLL(engine, mode=ctypes.RTLD_GLOBAL))
        lib = ffi.dlopen(product)
        if spec.abi is not None:
            symbol, want = spec.abi
            if getattr(lib, symbol)() != want:
                return None  # header/library ABI drift — decline, answer below
    except (AttributeError, OSError):
        return None
    return (ffi, lib)


def available(name: str) -> bool:
    """Whether face `name` can be driven in-process (registered, present, ABI agrees)."""
    return load(name) is not None


def exports(name: str, *symbols: str) -> bool:
    """Whether face `name`'s loaded library exports every named symbol.

    The analytic plane is additive, so a library built before it landed answers
    its exact ABI perfectly and simply has no `<face>_run`. cffi resolves an
    ABI-mode symbol on first attribute access, which makes this the honest probe
    — and its absence a declinature, never an error.
    """
    loaded = load(name)
    if loaded is None:
        return False
    try:
        for symbol in symbols:
            getattr(loaded[1], symbol)
    except AttributeError:
        return False
    return True

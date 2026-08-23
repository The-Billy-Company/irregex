"""How to compile ``irgx_accel.c``, written once and asked twice.

The wheel hook needs this to put an accelerator in a release, and
``scripts/build_accel.py`` needs the same answer to put one in a checkout. Two
copies of "which compiler, which flags, which filename" is how a developer ends
up measuring against a binary built differently from the one that ships, so the
knowledge lives beside the C source it is about.

Stdlib only, and deliberately: the hook that imports this runs inside a build
backend, and the script that imports it runs in a bare checkout with nothing
installed. Neither can be asked for a dependency to learn how to invoke ``cc``.
"""

from __future__ import annotations

import platform
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path

#: The oldest interpreter the accelerator's stable ABI admits, as the hex
#: ``Py_LIMITED_API`` wants and as the ``cp3XX`` half of the wheel tag. One
#: number in two spellings: a wheel tagged for an interpreter the binary refuses
#: to load on is the failure mode abi3 exists to prevent.
ABI3_FLOOR = (3, 12)

#: The C source, resolved from this file rather than from a caller's cwd.
SOURCE = Path(__file__).resolve().parent / "irgx_accel.c"


def host_os() -> str:
    """This machine's OS, spelled the way a Zig triple spells it."""
    return {"darwin": "macos", "win32": "windows"}.get(sys.platform, "linux")


def host_arch() -> str:
    """This machine's architecture, spelled the way a Zig triple spells it."""
    machine = platform.machine().lower()
    return {"arm64": "aarch64", "amd64": "x86_64", "x64": "x86_64"}.get(machine, machine)


def is_native(zig_target: str | None, which_os: str) -> bool:
    """Whether a wheel for ``zig_target`` is being built by its own target.

    The accelerator compiles against the *target's* Python headers, and a
    cross-build has only the host's - so this is the question that decides
    whether it is attempted at all. A build that names no target is native by
    definition; one that names this machine's own triple is native too, which is
    what ``build_wheels.py`` does for the one target it is the host for.
    """
    if zig_target is None:
        return True
    return which_os == host_os() and zig_target.split("-", 1)[0] == host_arch()


def compilers() -> list[list[str]]:
    """C compilers to try, best first.

    The interpreter's own ``CC`` first, because an extension compiled by the
    compiler that built CPython is the one combination nobody has to reason
    about. ``zig cc`` last and always considered, because Zig is already
    required to build the engine - so a machine that can build this project at
    all can build the accelerator, with no second toolchain to install.
    """
    found: list[list[str]] = []
    if sys.platform != "win32":
        configured = sysconfig.get_config_var("CC")
        if configured:
            found.append(configured.split())
        if shutil.which("cc"):
            found.append(["cc"])
    if shutil.which("zig"):
        found.append(["zig", "cc"])
    return found


def link_flags() -> list[str]:
    """What to link the extension against on this platform.

    An extension resolves the CPython symbols it calls out of the interpreter
    that loads it, so on Unix it links nothing and simply leaves them undefined
    - which macOS needs told explicitly. Windows has no such thing as an
    undefined symbol in a DLL, so there it links the stable ``python3.lib``,
    which is the import library the limited API exists to make usable.
    """
    if sys.platform == "win32":
        libs = Path(sysconfig.get_config_var("installed_base") or sys.base_prefix) / "libs"
        return ["-shared", f"-L{libs}", "-lpython3"]
    if sys.platform == "darwin":
        return ["-shared", "-fPIC", "-undefined", "dynamic_lookup"]
    return ["-shared", "-fPIC"]


def filename() -> str:
    """What the built extension must be called for ``import`` to find it.

    ``.abi3.so`` and ``.pyd`` are entries in CPython's own
    ``importlib.machinery.EXTENSION_SUFFIXES``, and the abi3 one is what says
    "any 3.x from the floor up" rather than pinning a single minor version -
    which is the entire point of building against the limited API.
    """
    return "_accel.pyd" if sys.platform == "win32" else "_accel.abi3.so"


def compile(out: Path, *, loud: bool = False) -> list[str]:
    """Build the extension at ``out``. Returns what failed, empty on success.

    Every compiler is tried in turn rather than the first being decisive,
    because "no compiler on this machine" and "this compiler cannot do it" are
    the same outcome to a caller who only wants the file - and the list of
    attempts is what makes a required build's failure message actionable.
    """
    floor = f"0x{ABI3_FLOOR[0]:02X}{ABI3_FLOOR[1]:02X}0000"
    common = [
        "-O2",
        "-std=c11",
        "-Wall",
        "-Wextra",
        f"-DPy_LIMITED_API={floor}",
        f"-I{sysconfig.get_paths()['include']}",
        str(SOURCE),
        "-o",
        str(out),
    ]
    flags = link_flags()
    attempts: list[str] = []
    for compiler in compilers():
        command = [*compiler, *flags, *common]
        if loud:
            print(f"$ {' '.join(command)}", flush=True)
        done = subprocess.run(command, capture_output=not loud, text=True)
        if done.returncode == 0 and out.is_file():
            return []
        said = "" if loud else ((done.stderr or done.stdout).strip().splitlines() or [""])[-1]
        attempts.append(f"{' '.join(compiler)}: {said or f'exit {done.returncode}'}")
    return attempts or ["no C compiler found, and zig is not on PATH"]

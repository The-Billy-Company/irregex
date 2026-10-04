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
    required to build the engine, so it is also available if the interpreter's
    configured compiler cannot build the accelerator. macOS wheel packaging
    additionally uses Apple's tools to inspect the binaries before shipping.
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


def macos_target(platform_tag: str) -> str | None:
    """The macOS deployment target a wheel tag promises, or ``None`` elsewhere."""
    if not platform_tag.startswith("macosx_"):
        return None
    try:
        _, major, minor, arch = platform_tag.split("_", 3)
        version = f"{int(major)}.{int(minor)}"
        cpu = {"arm64": "aarch64", "x86_64": "x86_64"}[arch]
    except (ValueError, KeyError) as exc:
        raise RuntimeError(f"unsupported macOS wheel platform {platform_tag!r}") from exc
    return f"{cpu}-macos.{version}"


def check_macos_floor(artifact: Path, platform_tag: str) -> None:
    """Ask Apple's tools whether this binary fits its wheel's architecture and floor.

    Both the engine and the extension must pass. An import on the build host
    cannot catch an extension that inherited that host's newer deployment target.
    This checks the real Mach-O load commands, without rewriting their promise.
    """
    target = macos_target(platform_tag)
    if target is None:
        return
    if shutil.which("xcrun") is None:
        raise RuntimeError(
            "macOS wheel validation needs Apple's Command Line Tools: xcode-select --install"
        )
    arch = platform_tag.split("_", 3)[3]
    arches = subprocess.check_output(["xcrun", "lipo", "-archs", str(artifact)], text=True)
    if arches.split() != [arch]:
        raise RuntimeError(
            f"{artifact}: architectures {arches.strip()!r} do not fit {platform_tag}"
        )
    output = subprocess.check_output(["xcrun", "vtool", "-show-build", str(artifact)], text=True)
    commands: list[dict[str, str]] = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        name, value = fields
        if name == "cmd":
            commands.append({name: value})
        elif commands:
            commands[-1][name] = value
    builds = [
        cmd for cmd in commands if cmd["cmd"] in ("LC_BUILD_VERSION", "LC_VERSION_MIN_MACOSX")
    ]
    if len(builds) != 1:
        raise RuntimeError(f"{artifact}: expected one macOS deployment load command, got {builds}")
    build = builds[0]
    if build["cmd"] == "LC_BUILD_VERSION" and build.get("platform") != "MACOS":
        raise RuntimeError(f"{artifact}: deployment platform is not macOS: {build}")
    minimum = build.get("minos") if build["cmd"] == "LC_BUILD_VERSION" else build.get("version")
    if not minimum:
        raise RuntimeError(f"{artifact}: missing macOS deployment version: {build}")

    def version(text: str) -> tuple[int, ...]:
        parts = tuple(map(int, text.split(".")))
        return parts + (0,) * (3 - len(parts))

    promised = target.split("-macos.", 1)[1]
    if version(minimum) > version(promised):
        raise RuntimeError(
            f"{artifact}: requires macOS {minimum}, but {platform_tag} promises {promised}"
        )


def compile(
    out: Path,
    *,
    loud: bool = False,
    zig_target: str | None = None,
    zig_cpu: str | None = None,
) -> list[str]:
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
    if zig_target and "-macos." in zig_target:
        # Explicit flags override CPython's CC and the host SDK/environment.
        flags.append(f"-mmacosx-version-min={zig_target.split('-macos.', 1)[1]}")
    attempts: list[str] = []
    for compiler in compilers():
        target = []
        if compiler == ["zig", "cc"] and zig_target:
            # An implicit Zig target detects the build host's CPU. Reuse the
            # engine's explicit target and CPU policy instead of narrowing a
            # portable wheel to the newer machine that happened to build it.
            target = ["-target", zig_target]
            if zig_cpu:
                target.append(f"-mcpu={zig_cpu}")
        command = [*compiler, *target, *flags, *common]
        if loud:
            print(f"$ {' '.join(command)}", flush=True)
        done = subprocess.run(command, capture_output=not loud, text=True)
        if done.returncode == 0 and out.is_file():
            return []
        said = "" if loud else ((done.stderr or done.stdout).strip().splitlines() or [""])[-1]
        attempts.append(f"{' '.join(compiler)}: {said or f'exit {done.returncode}'}")
    return attempts or ["no C compiler found, and zig is not on PATH"]

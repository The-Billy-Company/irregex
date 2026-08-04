#!/usr/bin/env python3
"""Rebuild the prebuilt static archives this crate links.

A `build.rs` runs on the installing machine, so this crate *could* just shell
`zig build`. It carries archives anyway, because requiring a Zig toolchain to
`cargo add` a regex crate is a tax most users will not pay. Zig cross-compiles,
so the whole set comes off one machine:

    python3 scripts/vendor_libraries.py                        # every target
    python3 scripts/vendor_libraries.py --only aarch64-apple-darwin
    python3 scripts/vendor_libraries.py --list

Archives land in ``vendor/<rust-target-triple>/libirgx.a``, which is exactly
where ``build.rs`` looks. Rerun this whenever the engine changes: the archives
are committed build output, so a source change not followed by a run of this
script ships an engine older than the repository it came from.

Three things happen per target beyond ``zig build``.

**The C floor is verified present, not folded in.** ``build.zig`` packs
``libirgx.a`` from a partially-linked object on every target now, so PCRE2 and
libsais ride inside the archive it installs. This script used to merge them
itself on ELF, where the build once shipped the Zig objects alone and a link
died on ``pcre2_compile_8``; what is left of that is the probe, kept as a
precondition. An archive that reaches here without the floor is a regression in
the build, and vendoring it would push the failure out to somebody's
``cargo build``.

**Debug info is stripped.** DWARF is the large majority of an unstripped ELF
archive and nothing links against it. Stripping is the difference between a
reasonable crate and a rude one.

**Every archive is proved to link before it is committed.** A probe program
that exercises the compile / search / release cycle is linked against the fresh
archive with ``zig cc -target <triple>``. A missing symbol is then a failure of
this script rather than a failure in somebody's ``cargo build`` a week later.
"""

from __future__ import annotations

import argparse
import functools
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
CRATE = HERE.parent
ENGINE = CRATE.parents[1]
VENDOR = CRATE / "vendor"

# Exercises the whole cycle rather than one symbol, so the check fails on a
# partially linkable archive instead of passing on a lucky one.
PROBE = """
#include <stdio.h>
#include "irgx.h"

int main(void) {
  irgx_regex *re = NULL;
  irgx_span spans[4];
  size_t written = 0;
  if (irgx_compile((const uint8_t *)"a+", 2, IRGX_PCRE, &re) != IRGX_OK) return 1;
  if (irgx_find_all(re, (const uint8_t *)"aa b", 4, spans, 4, &written) != IRGX_MATCH) return 2;
  if (irgx_captures(re, (const uint8_t *)"aa b", 4, 0, spans, 4, &written) != IRGX_MATCH) return 3;
  if (irgx_is_match(re, (const uint8_t *)"aa b", 4) != IRGX_MATCH) return 4;
  irgx_free(re);
  printf("%s %s %u %lld\\n", irgx_version(), irgx_pcre2_version(),
         irgx_abi_version(), (long long)spans[0].end);
  return 0;
}
"""


@dataclass(frozen=True)
class Target:
    #: The Rust target triple, which is what `build.rs` selects on.
    rust: str
    #: The Zig triple, carrying an explicit minimum platform version. Inheriting
    #: the host SDK would produce an archive that refuses to link or load on an
    #: older machine than the one that built it.
    zig: str
    #: The ``-Dcpu`` subtarget: the instruction floor this archive may use, and
    #: therefore the oldest CPU it can be linked into. It has to be named for
    #: the same reason the platform version does, and it must agree with the
    #: floor `build.rs` passes on the source rung, or the two ways to obtain
    #: this crate's engine would not be the same engine.
    cpu: str
    #: System libraries the archive needs beyond what `std` already links, as
    #: `build.rs` names them. Empty everywhere the archive closes against libc
    #: alone; see the Windows entries below for the one place it does not.
    libs: tuple[str, ...] = ()

    @property
    def archive(self) -> Path:
        return VENDOR / self.rust / "libirgx.a"


# macOS 11 is where arm64 begins. glibc 2.17 is the manylinux2014 floor and
# still the widest useful baseline; Zig links against exactly that version
# rather than the host's, which is what makes a portable Linux archive off a
# macOS laptop a real thing rather than a claim.
#
# aarch64's baseline already carries NEON. x86_64's baseline is SSE2, and the
# scan kernels' `pshufb` is SSSE3 - so an unfloored x86_64 archive is one that
# executes an instruction its own triple never promised. Zig's x86_64-macos
# default happens to include SSSE3 and its linux one does not, which is why
# only one of these was visibly wrong and both were equally undeclared.
#
# Windows 10 RS4 is the floor `build.zig`'s own `check-windows` drift gate
# compiles against, so the shipped archive and that gate describe one platform.
# The two Windows rows are the GNU ABI under the two names Rust gives it: x86_64
# leads with `-gnu` (mingw-w64's gcc), and aarch64 has no `-gnu` at all, because
# that toolchain was never ported to it - `-gnullvm` (llvm-mingw) is the only
# GNU-ABI arm64 Windows target Rust has. One archive serves both spellings on a
# given architecture; `build.rs` maps the aliases onto these directories rather
# than this script committing a second copy of the same bytes.
#
# Only the GNU arms are here. Zig cannot cross-compile to `-pc-windows-msvc`:
# the MSVC C runtime headers are not redistributable, so it has nothing to
# compile the PCRE2 floor against unless Visual Studio is on the machine, and
# an archive that can only be produced on one operating system is not one this
# script can promise. `build.rs` knows the MSVC triples anyway and builds them
# from source there, which is where a machine that *can* produce them already
# is.
MATRIX = (
    Target("aarch64-apple-darwin", "aarch64-macos.11.0", "baseline"),
    Target("x86_64-apple-darwin", "x86_64-macos.11.0", "x86_64_v2"),
    Target("x86_64-unknown-linux-gnu", "x86_64-linux-gnu.2.17", "x86_64_v2"),
    Target("aarch64-unknown-linux-gnu", "aarch64-linux-gnu.2.17", "baseline"),
    Target("x86_64-pc-windows-gnu", "x86_64-windows.win10_rs4-gnu", "x86_64_v2", ("ntdll",)),
    Target("aarch64-pc-windows-gnullvm", "aarch64-windows.win10_rs4-gnu", "baseline", ("ntdll",)),
)

# One symbol from the vendored PCRE2, standing witness for the whole C floor.
# Checking behavior beats checking the platform: this asks the archive what it
# contains rather than assuming what the build does per target.
FLOOR_WITNESS = "pcre2_compile_8"

LLVM_SEARCH = (
    "/opt/homebrew/opt/llvm/bin",
    "/usr/local/opt/llvm/bin",
    "/opt/homebrew/opt/llvm@22/bin",
    "/opt/homebrew/opt/llvm@21/bin",
    "/opt/homebrew/opt/llvm@20/bin",
    "/usr/lib/llvm-22/bin",
    "/usr/lib/llvm-21/bin",
    "/usr/lib/llvm-20/bin",
)


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, check=True, text=True, **kwargs)


@functools.cache
def rustup_llvm_bin() -> Path | None:
    """Where rustup keeps LLVM's binutils, or None if this machine has no Rust.

    The rung with a version on it. `.mise.toml` pins rust with
    `components = ["llvm-tools"]`, and rustup builds those binutils from the
    same LLVM the pinned rustc links - so they move when the pin moves and not
    otherwise. Homebrew's LLVM under LLVM_SEARCH floats with whatever the
    machine last upgraded to, which is fine as a fallback and wrong as the
    default for a script whose output is committed.
    """
    try:
        sysroot = run(["rustc", "--print", "sysroot"], capture_output=True).stdout.strip()
        version = run(["rustc", "-vV"], capture_output=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    host = next(
        (ln.removeprefix("host: ") for ln in version.splitlines() if ln.startswith("host: ")),
        "",
    )
    pinned = Path(sysroot, "lib", "rustlib", host, "bin") if sysroot and host else None
    return pinned if pinned and pinned.is_dir() else None


def find_tool(name: str, env_var: str) -> str | None:
    """An LLVM binutil: the environment, then rustup, then PATH, Xcode, a prefix."""
    override = os.environ.get(env_var)
    if override:
        return override
    pinned = rustup_llvm_bin()
    if pinned and (candidate := pinned / name).is_file():
        return str(candidate)
    found = shutil.which(name)
    if found:
        return found
    try:
        located = subprocess.run(
            ["xcrun", "--find", name], capture_output=True, text=True, check=True
        ).stdout.strip()
        if located:
            return located
    except (OSError, subprocess.CalledProcessError):
        pass
    for prefix in LLVM_SEARCH:
        candidate = Path(prefix) / name
        if candidate.is_file():
            return str(candidate)
    return None


def defines(nm: str, archive: Path, symbol: str) -> bool:
    """Whether ``archive`` carries a definition of ``symbol``.

    Only a definition counts: an undefined reference to the very symbol we are
    looking for is exactly the state this is meant to catch.
    """
    listing = subprocess.run([nm, "--defined-only", str(archive)], capture_output=True, text=True)
    return any(
        line.split()[-1].lstrip("_") == symbol
        for line in listing.stdout.splitlines()
        if line.split()
    )


def verify_build_rs(targets: list[Target]) -> None:
    """Hold ``build.rs`` to the libraries this matrix probes against.

    The probe below proves an archive closes under one particular set of
    libraries. Nobody ever performs that link: a consumer's is emitted by
    ``build.rs``, so if the two sets disagree the proof is about a build that
    does not happen. Checked before anything is compiled, because the answer
    costs a file read and the alternative costs minutes per target.
    """
    source = (CRATE / "build.rs").read_text()
    for target in targets:
        for lib in target.libs:
            if f'"{lib}"' not in source:
                raise SystemExit(
                    f"{target.rust} is vendored against -l{lib}, but build.rs never emits "
                    f"it, so a consumer's link would go without. Add it to system_libs()."
                )


#: The ``sys.platform`` a Rust triple's operating system is native to, keyed by
#: the component of the triple that names it.
HOST_PLATFORM = {"apple": "darwin", "linux": "linux", "windows": "win32"}

#: ``platform.machine()`` spellings, in the architecture vocabulary a Rust
#: triple leads with.
HOST_ARCH = {
    "arm64": "aarch64",
    "ARM64": "aarch64",
    "aarch64": "aarch64",
    "x86_64": "x86_64",
    "AMD64": "x86_64",
}


def probe_link(zig: str, target: Target, archive: Path, header: Path, workdir: Path) -> str:
    """Compile and link a program against ``archive``; run it when it is native."""
    source = workdir / "probe.c"
    source.write_text(PROBE)
    windows = "windows" in target.rust
    binary = workdir / ("probe.exe" if windows else "probe")
    run(
        [
            zig, "cc", "-target", target.zig,
            f"-I{header.parent}", str(source), str(archive),
            *(f"-l{lib}" for lib in target.libs),
            "-o", str(binary),
        ]
    )  # fmt: skip
    host = next((p for name, p in HOST_PLATFORM.items() if name in target.rust), None)
    native = host is not None and sys.platform.startswith(host)
    if native and HOST_ARCH.get(platform.machine()) == target.rust.split("-", 1)[0]:
        return run([str(binary)], capture_output=True).stdout.strip()
    return "cross-compiled; linked but not run"


def build(
    target: Target, cache_root: Path, zig: str, strip: str | None, nm: str
) -> tuple[int, str]:
    cache = cache_root / target.zig
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="irregex-rust-") as scratch:
        work = Path(scratch)
        staging = work / "stage"
        run(
            [
                zig, "build", "-Doptimize=ReleaseFast", f"-Dtarget={target.zig}",
                f"-Dcpu={target.cpu}",
                "--prefix", str(staging), "--cache-dir", str(cache),
            ],
            cwd=ENGINE,
        )  # fmt: skip
        archive = staging / "lib" / "libirgx.a"
        if not archive.is_file():
            raise RuntimeError(f"zig build produced no {archive}")

        if not defines(nm, archive, FLOOR_WITNESS):
            raise RuntimeError(
                f"{target.rust}: {archive} does not define {FLOOR_WITNESS}, so the C floor "
                f"is not inside it and a consumer's link will fail. build.zig packs the "
                f"archive from a partially-linked object to prevent exactly this; check "
                f"what changed there rather than merging the floor in here."
            )

        if strip:
            run([strip, "--strip-debug", str(archive)])

        header = ENGINE / "include" / "irgx.h"
        note = probe_link(zig, target, archive, header, work)

        target.archive.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(archive, target.archive)
        return target.archive.stat().st_size, note


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--only", action="append", metavar="TRIPLE", help="build just these targets"
    )
    parser.add_argument("--list", action="store_true", help="print the matrix and exit")
    parser.add_argument(
        "--keep-debug",
        action="store_true",
        help="skip the strip step (roughly quadruples the vendored bytes)",
    )
    parser.add_argument(
        "--cache-root",
        default=str(Path(tempfile.gettempdir()) / "irregex-rust-vendor-cache"),
        help="where the per-target Zig build caches live",
    )
    args = parser.parse_args()

    if args.list:
        for target in MATRIX:
            print(
                f"{target.rust:28} zig={target.zig:30} cpu={target.cpu:11}"
                f" -> {target.archive.relative_to(CRATE)}"
                f"{'  libs=' + ' '.join('-l' + lib for lib in target.libs) if target.libs else ''}"
            )
        return 0

    chosen = list(MATRIX)
    if args.only:
        by_name = {t.rust: t for t in MATRIX}
        unknown = [n for n in args.only if n not in by_name]
        if unknown:
            raise SystemExit(f"no target named {', '.join(unknown)}")
        chosen = [by_name[n] for n in args.only]

    verify_build_rs(chosen)

    zig = shutil.which("zig")
    if not zig:
        raise SystemExit("zig is not on PATH; it is what cross-compiles the archives")
    nm = find_tool("llvm-nm", "LLVM_NM") or shutil.which("nm")
    if not nm:
        raise SystemExit("no nm found; needed to tell whether an archive carries the C floor")
    strip = None if args.keep_debug else find_tool("llvm-strip", "LLVM_STRIP")
    if strip is None and not args.keep_debug:
        raise SystemExit(
            "llvm-strip not found. It removes the DWARF that nothing links against and\n"
            "that dominates the archive size. Run `mise install` for the pinned Rust\n"
            "toolchain's llvm-tools, set $LLVM_STRIP, or pass --keep-debug to vendor\n"
            "the unstripped archives anyway."
        )

    total = 0
    for target in chosen:
        print(f"\n=== {target.rust} ({target.zig}) ===", flush=True)
        size, note = build(target, Path(args.cache_root), zig, strip, nm)
        total += size
        print(f"    {size / 1e6:.2f} MB  probe: {note}")

    print(f"\nvendored {len(chosen)} archive(s), {total / 1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

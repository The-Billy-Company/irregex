#!/usr/bin/env python3
"""Rebuild the prebuilt static archives this Go module links.

Go has no build.rs, so a consumer cannot compile Zig at install time. What
makes `go get` + `go build` work on a machine with no toolchain is that the
module *carries* one static archive per platform and lets a cgo build
constraint pick the matching one. Zig cross-compiles, so the whole set comes
off one machine:

    python3 scripts/vendor_libraries.py              # every target
    python3 scripts/vendor_libraries.py --only linux/amd64
    python3 scripts/vendor_libraries.py --list

Rerun this whenever the engine changes. The archives are committed build
output, so a source change that is not followed by a run of this script ships
an engine older than the repository it came from.

Four things happen per target beyond `zig build`.

**The link file is held to this matrix.** A consumer's cgo link is driven by
the `#cgo LDFLAGS` line in `link_<goos>_<goarch>.go`, not by anything here, so
that line is checked against the libraries this matrix declares before a byte
is compiled. Otherwise the probe below would be evidence about a link nobody
performs - which is a live risk on exactly one platform, Windows, where the
archive needs `-lntdll` and Zig's driver supplies it silently while mingw's
gcc does not.

**The C floor is verified present, not folded in.** `build.zig` packs
`libirgx.a` from a partially-linked object on every target now, so PCRE2 and
libsais ride inside the archive it installs. This script used to merge them
itself on ELF, where the build once shipped the Zig objects alone and a cgo
link died on `pcre2_compile_8`; what is left of that is the probe, kept as a
precondition. An archive that reaches here without the floor is a regression in
the build, and vendoring it would push the failure out to somebody's
`go build`.

**Debug info is stripped.** DWARF is ~85% of an unstripped ELF archive here,
and nothing links against it. Stripping takes the vendored set from ~26 MB to
under 8 MB, which is the difference between a reasonable module and a rude one.

**Every archive is proved to link before it is committed.** A probe program
that calls the ABI is compiled and linked against the fresh archive with
`zig cc -target <triple>`, under the target's declared libraries and nothing
else. A missing symbol is then a failure of this script rather than a failure
in somebody's `go build` a week later. When the host is the target, the probe
is also run.
"""

from __future__ import annotations

import argparse
import functools
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODULE = HERE.parent
ENGINE = MODULE.parents[1]
VENDOR = MODULE

# The C source of the probe link. It touches the compile / search / release
# cycle rather than one symbol, so the check fails on a partially linkable
# archive instead of passing on a lucky one.
PROBE = """
#include <stdio.h>
#include "irgx.h"

int main(void) {
  irgx_regex *re = NULL;
  irgx_span spans[4];
  irgx_text name;
  size_t written = 0;
  const uint8_t *pattern = (const uint8_t *)"(?P<g>a+)";
  if (irgx_compile(pattern, 9, IRGX_PCRE, &re) != IRGX_OK) return 1;
  if (irgx_find_all(re, (const uint8_t *)"aa b", 4, spans, 4, &written) != IRGX_MATCH) return 2;
  if (irgx_captures(re, (const uint8_t *)"aa b", 4, 0, spans, 4, &written) != IRGX_MATCH) return 3;
  if (irgx_is_match(re, (const uint8_t *)"aa b", 4) != IRGX_MATCH) return 4;
  // The Go binding builds its whole name table out of this one, so an archive
  // that cannot resolve it is a broken `go build` rather than a broken search.
  if (irgx_group_name(re, 1, &name) != IRGX_MATCH) return 5;
  irgx_free(re);
  printf("%s %s %u %lld\\n", irgx_version(), irgx_pcre2_version(),
         irgx_abi_version(), (long long)spans[0].end);
  return 0;
}
"""


@dataclass(frozen=True)
class Target:
    goos: str
    goarch: str
    #: The Zig triple, carrying an explicit minimum platform version. Inheriting
    #: the host SDK would produce an archive that refuses to link or load on an
    #: older machine than the one that built it.
    zig: str
    #: The ``-Dcpu`` subtarget: the instruction floor this archive may use, and
    #: therefore the oldest CPU a Go consumer can link it into. Named rather
    #: than defaulted, for the same reason the platform version is.
    cpu: str
    #: System libraries the archive needs beyond what the platform's cgo
    #: compiler links by default, as they appear in the `#cgo LDFLAGS` line.
    #: Empty everywhere the default set already closes the archive; see the
    #: Windows entries below for the one place it does not.
    libs: tuple[str, ...] = ()
    #: ``platform.machine()`` spellings this target is the native host for, so
    #: the probe below can be *run* rather than only linked.
    machines: tuple[str, ...] = field(default=(), repr=False)

    @property
    def name(self) -> str:
        return f"{self.goos}/{self.goarch}"

    @property
    def archive(self) -> Path:
        # Beside the Go source, not under it: `go mod vendor` copies a package's
        # own files and skips subdirectories that hold no Go package, so an
        # archive one level down would vanish from a vendored consumer.
        return VENDOR / f"libirgx_{self.goos}_{self.goarch}.a"

    @property
    def link_file(self) -> Path:
        """The cgo file whose build constraint selects this archive."""
        return VENDOR / f"link_{self.goos}_{self.goarch}.go"

    @property
    def ldflags(self) -> str:
        """The `#cgo LDFLAGS` value this target's link file has to declare."""
        return " ".join((f"${{SRCDIR}}/{self.archive.name}", *self.libs))


# macOS 11 is where arm64 begins. glibc 2.17 is the manylinux2014 floor and
# still the widest useful baseline; Zig links against exactly that version
# rather than the host's, which is what makes a portable Linux archive off a
# macOS laptop a real thing rather than a claim. Windows 10 RS4 is the floor
# `build.zig`'s own `check-windows` drift gate compiles against, so naming it
# here keeps the shipped archive and the gate describing one platform.
#
# The CPU floors match `bindings/python/scripts/build_wheels.py`, and for the
# same reason: a `GOARCH` says as little about instructions as a wheel tag does,
# so the promise is kept here or nowhere. aarch64's baseline already has NEON.
# x86_64's baseline is SSE2, which the scan kernels' `pshufb` is not in - Zig's
# x86_64-macos default happens to carry SSSE3 already, its linux one does not,
# and depending on that difference is how one of these archives ended up with
# 52 instructions its own triple never promised.
#
# Only Windows names a library. Everywhere else the archive's externals are
# libc and the platform's crt, which every cgo compiler links by default. On
# Windows the engine reaches the kernel through ntdll - 60 `Nt*`/`Ldr*`/`Rtl*`
# symbols, which is Zig's std, not ours - and mingw-w64's default library set
# stops at kernel32. Zig's own driver adds ntdll silently, so a probe linked by
# `zig cc` proves nothing about the gcc that cgo will actually use; the flag is
# declared here, checked into the link file, and cross-checked below.
MATRIX = (
    Target("darwin", "arm64", "aarch64-macos.11.0", "baseline", machines=("arm64", "aarch64")),
    Target("darwin", "amd64", "x86_64-macos.11.0", "x86_64_v2", machines=("x86_64",)),
    Target("linux", "amd64", "x86_64-linux-gnu.2.17", "x86_64_v2", machines=("x86_64",)),
    Target("linux", "arm64", "aarch64-linux-gnu.2.17", "baseline", machines=("aarch64",)),
    Target(
        "windows",
        "amd64",
        "x86_64-windows.win10_rs4-gnu",
        "x86_64_v2",
        libs=("-lntdll",),
        machines=("AMD64", "x86_64"),
    ),
    Target(
        "windows",
        "arm64",
        "aarch64-windows.win10_rs4-gnu",
        "baseline",
        libs=("-lntdll",),
        machines=("ARM64", "aarch64"),
    ),
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
    """Whether `archive` carries a definition of `symbol`.

    Only a definition counts: an undefined reference to the very symbol we are
    looking for is exactly the state this is meant to catch.
    """
    listing = subprocess.run([nm, "--defined-only", str(archive)], capture_output=True, text=True)
    return any(
        line.split()[-1].lstrip("_") == symbol
        for line in listing.stdout.splitlines()
        if line.split()
    )


#: The ``sys.platform`` a target's GOOS is the native host for.
HOST_PLATFORM = {"darwin": "darwin", "linux": "linux", "windows": "win32"}

#: The one directive in a link file that the Go toolchain acts on.
LDFLAGS = re.compile(r"^// #cgo LDFLAGS: *(?P<flags>.+?) *$", re.MULTILINE)


def verify_link_files(targets: list[Target]) -> None:
    """Hold each target's cgo directive to the libraries this matrix declares.

    The probe below proves an archive closes under one particular set of
    libraries. Nobody ever performs that link: a consumer's cgo link is driven
    by the `#cgo LDFLAGS` line in the target's own file, so if the two sets
    disagree the proof is about a build that does not happen. Checked before
    anything is compiled, because the answer costs a file read and the
    alternative costs several minutes per target.
    """
    for target in targets:
        if not target.link_file.is_file():
            raise SystemExit(
                f"{target.name} is in the matrix but {target.link_file.name} does not exist, "
                f"so a build for it would select no archive. Add the file, declaring "
                f"`// #cgo LDFLAGS: {target.ldflags}`."
            )
        found = LDFLAGS.search(target.link_file.read_text())
        if found is None:
            raise SystemExit(f"{target.link_file.name} declares no `#cgo LDFLAGS` line")
        if found["flags"] != target.ldflags:
            raise SystemExit(
                f"{target.link_file.name} links `{found['flags']}`, but this matrix vendors "
                f"an archive proved to close under `{target.ldflags}`. Reconcile the two: "
                f"the probe is only evidence about the link a consumer actually performs."
            )

    # A target whose link file exists but which `link_unsupported.go` still
    # rejects compiles both files at once and fails on the undefined constant
    # there - in the consumer's build, naming neither this matrix nor the
    # platform they asked for.
    unsupported = (VENDOR / "link_unsupported.go").read_text()
    for goos in dict.fromkeys(t.goos for t in targets):
        arches = " || ".join(t.goarch for t in MATRIX if t.goos == goos)
        clause = f"!({goos} && ({arches}))"
        if clause not in unsupported:
            raise SystemExit(
                f"link_unsupported.go does not exclude {goos}: its build constraint needs "
                f"`{clause}`, or a {goos} build compiles it alongside the archive's own "
                f"link file and dies on the undefined constant."
            )


def probe_link(zig: str, target: Target, archive: Path, header: Path, workdir: Path) -> str:
    """Compile and link a program against `archive`; run it when it is native."""
    source = workdir / "probe.c"
    source.write_text(PROBE)
    binary = workdir / ("probe.exe" if target.goos == "windows" else "probe")
    run(
        [
            zig,
            "cc",
            "-target",
            target.zig,
            f"-I{header.parent}",
            str(source),
            str(archive),
            *target.libs,
            "-o",
            str(binary),
        ]
    )
    native = (
        sys.platform.startswith(HOST_PLATFORM[target.goos])
        and platform.machine() in target.machines
    )
    if native:
        return run([str(binary)], capture_output=True).stdout.strip()
    return "cross-compiled; linked but not run"


def build(
    target: Target, cache_root: Path, zig: str, strip: str | None, nm: str
) -> tuple[int, str]:
    cache = cache_root / target.zig
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="irregex-go-") as scratch:
        work = Path(scratch)
        staging = work / "stage"
        run(
            [
                zig,
                "build",
                "-Doptimize=ReleaseFast",
                f"-Dtarget={target.zig}",
                f"-Dcpu={target.cpu}",
                "--prefix",
                str(staging),
                "--cache-dir",
                str(cache),
            ],
            cwd=ENGINE,
        )
        archive = staging / "lib" / "libirgx.a"
        if not archive.is_file():
            raise RuntimeError(f"zig build produced no {archive}")

        if not defines(nm, archive, FLOOR_WITNESS):
            raise RuntimeError(
                f"{target.name}: {archive} does not define {FLOOR_WITNESS}, so the C floor "
                f"is not inside it and a cgo link will fail. build.zig packs the archive "
                f"from a partially-linked object to prevent exactly this; check what "
                f"changed there rather than merging the floor in here."
            )

        if strip:
            run([strip, "--strip-debug", str(archive)])

        header = ENGINE / "include" / "irgx.h"
        note = probe_link(zig, target, archive, header, work)

        shutil.copy2(archive, target.archive)
        shutil.copy2(header, VENDOR / "irgx.h")
        return target.archive.stat().st_size, note


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--only", action="append", metavar="GOOS/GOARCH", help="build just these targets"
    )
    parser.add_argument("--list", action="store_true", help="print the matrix and exit")
    parser.add_argument(
        "--keep-debug",
        action="store_true",
        help="skip the strip step (roughly quadruples the vendored bytes)",
    )
    parser.add_argument(
        "--cache-root",
        default=str(Path(tempfile.gettempdir()) / "irregex-go-vendor-cache"),
        help="where the per-target Zig build caches live",
    )
    args = parser.parse_args()

    if args.list:
        for target in MATRIX:
            print(
                f"{target.name:14} zig={target.zig:30} cpu={target.cpu:11}"
                f" -> {target.archive.relative_to(MODULE)}"
                f"{'  libs=' + ' '.join(target.libs) if target.libs else ''}"
            )
        return 0

    chosen = list(MATRIX)
    if args.only:
        by_name = {t.name: t for t in MATRIX}
        unknown = [n for n in args.only if n not in by_name]
        if unknown:
            raise SystemExit(f"no target named {', '.join(unknown)}")
        chosen = [by_name[n] for n in args.only]

    verify_link_files(chosen)

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
        print(f"\n=== {target.name} ({target.zig}) ===", flush=True)
        size, note = build(target, Path(args.cache_root), zig, strip, nm)
        total += size
        print(f"    {size / 1e6:.2f} MB  probe: {note}")

    print(f"\nvendored {len(chosen)} archive(s), {total / 1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

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

Three things happen per target beyond `zig build`.

**The C floor is folded in where the build leaves it out.** On macOS the
installed archive is a relocatable-object merge and already carries PCRE2; on
ELF it is a plain archive of the Zig objects only, so a cgo link fails on
`pcre2_compile_8` and friends. The fix is not platform-conditional here: the
archive is probed for a PCRE2 symbol, and the floor is merged in only when it
is genuinely absent. The floor archive comes out of a per-target build cache
that this script owns, so the one it finds is the one this build produced -
never a stale sibling from another target or optimize mode.

**Debug info is stripped.** DWARF is ~85% of an unstripped ELF archive here,
and nothing links against it. Stripping takes the vendored set from ~26 MB to
under 8 MB, which is the difference between a reasonable module and a rude one.

**Every archive is proved to link before it is committed.** A probe program
that calls the ABI is compiled and linked against the fresh archive with
`zig cc -target <triple>`. A missing symbol is then a failure of this script
rather than a failure in somebody's `go build` a week later.
"""

from __future__ import annotations

import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
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

    @property
    def name(self) -> str:
        return f"{self.goos}/{self.goarch}"

    @property
    def archive(self) -> Path:
        # Beside the Go source, not under it: `go mod vendor` copies a package's
        # own files and skips subdirectories that hold no Go package, so an
        # archive one level down would vanish from a vendored consumer.
        return VENDOR / f"libirgx_{self.goos}_{self.goarch}.a"


# macOS 11 is where arm64 begins. glibc 2.17 is the manylinux2014 floor and
# still the widest useful baseline; Zig links against exactly that version
# rather than the host's, which is what makes a portable Linux archive off a
# macOS laptop a real thing rather than a claim.
MATRIX = (
    Target("darwin", "arm64", "aarch64-macos.11.0"),
    Target("darwin", "amd64", "x86_64-macos.11.0"),
    Target("linux", "amd64", "x86_64-linux-gnu.2.17"),
    Target("linux", "arm64", "aarch64-linux-gnu.2.17"),
)

# One symbol from the vendored PCRE2, used to decide whether the C floor is
# already inside the archive. Checking behaviour beats checking the platform:
# the day the Zig build folds the floor in everywhere, this script keeps working
# and stops merging, with nothing to edit.
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


def find_tool(name: str, env_var: str) -> str | None:
    """An LLVM binutil, from the environment, PATH, Xcode, or a known prefix."""
    override = os.environ.get(env_var)
    if override:
        return override
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
    looking for is exactly the state that needs the merge.
    """
    listing = subprocess.run(
        [nm, "--defined-only", str(archive)], capture_output=True, text=True
    )
    return any(line.split()[-1].lstrip("_") == symbol for line in listing.stdout.splitlines() if line.split())


def floor_archive(cache: Path) -> Path:
    """The PCRE2 archive this build produced.

    The Zig build does not install its C floors, so they have to be read out of
    the build cache. That is only safe because the cache is per-target and owned
    by this script: more than one candidate means the assumption broke, and
    guessing between them would silently vendor the wrong architecture.
    """
    found = sorted(glob.glob(str(cache / "o" / "*" / "libpcre2irregex.a")))
    if len(found) != 1:
        raise RuntimeError(
            f"expected exactly one libpcre2irregex.a under {cache}, found {len(found)}; "
            f"delete that cache directory and rerun"
        )
    return Path(found[0])


def merge(zig: str, base: Path, floor: Path, out: Path) -> None:
    """Fold `floor`'s members into `base`, writing `out`."""
    script = f"create {out}\naddlib {base}\naddlib {floor}\nsave\nend\n"
    run([zig, "ar", "-M"], input=script)
    members = run(
        [zig, "ar", "t", str(out)], capture_output=True
    ).stdout.split()
    names = [Path(m).name for m in members]
    if len(names) != len(set(names)):
        raise RuntimeError(f"{out} has duplicate member names; the two archives collide")


def probe_link(zig: str, target: Target, archive: Path, header: Path, workdir: Path) -> str:
    """Compile and link a program against `archive`; run it when it is native."""
    source = workdir / "probe.c"
    source.write_text(PROBE)
    binary = workdir / "probe"
    run(
        [
            zig, "cc", "-target", target.zig,
            f"-I{header.parent}", str(source), str(archive),
            "-o", str(binary),
        ]
    )
    native = (sys.platform == "darwin" and target.goos == "darwin") or (
        sys.platform.startswith("linux") and target.goos == "linux"
    )
    host_arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "amd64", "AMD64": "amd64"}
    if native and host_arch.get(os.uname().machine) == target.goarch:
        return run([str(binary)], capture_output=True).stdout.strip()
    return "cross-compiled; linked but not run"


def build(target: Target, cache_root: Path, zig: str, strip: str | None, nm: str) -> tuple[int, str]:
    cache = cache_root / target.zig
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="irregex-go-") as scratch:
        work = Path(scratch)
        staging = work / "stage"
        run(
            [
                zig, "build", "-Doptimize=ReleaseFast", f"-Dtarget={target.zig}",
                "--prefix", str(staging), "--cache-dir", str(cache),
            ],
            cwd=ENGINE,
        )
        archive = staging / "lib" / "libirgx.a"
        if not archive.is_file():
            raise RuntimeError(f"zig build produced no {archive}")

        if not defines(nm, archive, FLOOR_WITNESS):
            merged = work / "libirgx.a"
            merge(zig, archive, floor_archive(cache), merged)
            archive = merged
            if not defines(nm, archive, FLOOR_WITNESS):
                raise RuntimeError(f"{target.name}: merged archive still lacks {FLOOR_WITNESS}")

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
            print(f"{target.name:14} zig={target.zig:24} -> {target.archive.relative_to(MODULE)}")
        return 0

    chosen = list(MATRIX)
    if args.only:
        by_name = {t.name: t for t in MATRIX}
        unknown = [n for n in args.only if n not in by_name]
        if unknown:
            raise SystemExit(f"no target named {', '.join(unknown)}")
        chosen = [by_name[n] for n in args.only]

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
            "that dominates the archive size. Install LLVM, set $LLVM_STRIP, or pass\n"
            "--keep-debug to vendor the unstripped archives anyway."
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

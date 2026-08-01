#!/usr/bin/env python3
"""Rebuild the prebuilt static archives this crate links.

A `build.rs` runs on the installing machine, so this crate *could* just shell
`zig build`. It carries archives anyway, because requiring a Zig toolchain to
`cargo add` a regex crate is a tax most users will not pay. Zig cross-compiles,
so the whole set comes off one machine:

    python3 scripts/vendor_libraries.py                        # every target
    python3 scripts/vendor_libraries.py --only aarch64-apple-darwin
    python3 scripts/vendor_libraries.py --list

Archives land in ``vendor/<rust-target-triple>/libirregex.a``, which is exactly
where ``build.rs`` looks. Rerun this whenever the engine changes: the archives
are committed build output, so a source change not followed by a run of this
script ships an engine older than the repository it came from.

Three things happen per target beyond ``zig build``.

**The C floor is folded in where the build leaves it out.** On macOS the
installed archive is a relocatable-object merge and already carries PCRE2; on
ELF it is a plain archive of the Zig objects only, so a link fails on
``pcre2_compile_8`` and friends. The archive is probed for a PCRE2 symbol and
the floor is merged in only when it is genuinely absent, so this keeps working
unchanged the day the Zig build folds the floor in everywhere.

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
import glob
import os
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
#include "irregex.h"

int main(void) {
  irregex_regex *re = NULL;
  irregex_span spans[4];
  size_t written = 0;
  if (irregex_compile((const uint8_t *)"a+", 2, IRREGEX_PCRE, &re) != IRREGEX_OK) return 1;
  if (irregex_find_all(re, (const uint8_t *)"aa b", 4, spans, 4, &written) != IRREGEX_MATCH) return 2;
  if (irregex_captures(re, (const uint8_t *)"aa b", 4, 0, spans, 4, &written) != IRREGEX_MATCH) return 3;
  if (irregex_is_match(re, (const uint8_t *)"aa b", 4) != IRREGEX_MATCH) return 4;
  irregex_free(re);
  printf("%s %s %u %lld\\n", irregex_version(), irregex_pcre2_version(),
         irregex_abi_version(), (long long)spans[0].end);
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

    @property
    def archive(self) -> Path:
        return VENDOR / self.rust / "libirregex.a"


# macOS 11 is where arm64 begins. glibc 2.17 is the manylinux2014 floor and
# still the widest useful baseline; Zig links against exactly that version
# rather than the host's, which is what makes a portable Linux archive off a
# macOS laptop a real thing rather than a claim.
MATRIX = (
    Target("aarch64-apple-darwin", "aarch64-macos.11.0"),
    Target("x86_64-apple-darwin", "x86_64-macos.11.0"),
    Target("x86_64-unknown-linux-gnu", "x86_64-linux-gnu.2.17"),
    Target("aarch64-unknown-linux-gnu", "aarch64-linux-gnu.2.17"),
)

# One symbol from the vendored PCRE2, used to decide whether the C floor is
# already inside the archive. Checking behaviour beats checking the platform.
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
    """Whether ``archive`` carries a definition of ``symbol``.

    Only a definition counts: an undefined reference to the very symbol we are
    looking for is exactly the state that needs the merge.
    """
    listing = subprocess.run([nm, "--defined-only", str(archive)], capture_output=True, text=True)
    return any(
        line.split()[-1].lstrip("_") == symbol
        for line in listing.stdout.splitlines()
        if line.split()
    )


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
    """Fold ``floor``'s members into ``base``, writing ``out``."""
    run([zig, "ar", "-M"], input=f"create {out}\naddlib {base}\naddlib {floor}\nsave\nend\n")
    members = run([zig, "ar", "t", str(out)], capture_output=True).stdout.split()
    names = [Path(m).name for m in members]
    if len(names) != len(set(names)):
        raise RuntimeError(f"{out} has duplicate member names; the two archives collide")


def probe_link(zig: str, target: Target, archive: Path, header: Path, workdir: Path) -> str:
    """Compile and link a program against ``archive``; run it when it is native."""
    source = workdir / "probe.c"
    source.write_text(PROBE)
    binary = workdir / "probe"
    run(
        [
            zig, "cc", "-target", target.zig,
            f"-I{header.parent}", str(source), str(archive),
            "-o", str(binary),
        ]
    )  # fmt: skip
    goos = "macos" if "apple" in target.rust else "linux"
    native = (sys.platform == "darwin" and goos == "macos") or (
        sys.platform.startswith("linux") and goos == "linux"
    )
    arch = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64", "AMD64": "x86_64"}
    if native and arch.get(os.uname().machine) == target.rust.split("-", 1)[0]:
        return run([str(binary)], capture_output=True).stdout.strip()
    return "cross-compiled; linked but not run"


def build(target: Target, cache_root: Path, zig: str, strip: str | None, nm: str) -> tuple[int, str]:
    cache = cache_root / target.zig
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="irregex-rust-") as scratch:
        work = Path(scratch)
        staging = work / "stage"
        run(
            [
                zig, "build", "-Doptimize=ReleaseFast", f"-Dtarget={target.zig}",
                "--prefix", str(staging), "--cache-dir", str(cache),
            ],
            cwd=ENGINE,
        )  # fmt: skip
        archive = staging / "lib" / "libirregex.a"
        if not archive.is_file():
            raise RuntimeError(f"zig build produced no {archive}")

        if not defines(nm, archive, FLOOR_WITNESS):
            merged = work / "libirregex.a"
            merge(zig, archive, floor_archive(cache), merged)
            archive = merged
            if not defines(nm, archive, FLOOR_WITNESS):
                raise RuntimeError(f"{target.rust}: merged archive still lacks {FLOOR_WITNESS}")

        if strip:
            run([strip, "--strip-debug", str(archive)])

        header = ENGINE / "include" / "irregex.h"
        note = probe_link(zig, target, archive, header, work)

        target.archive.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(archive, target.archive)
        return target.archive.stat().st_size, note


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", action="append", metavar="TRIPLE", help="build just these targets")
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
            print(f"{target.rust:28} zig={target.zig:24} -> {target.archive.relative_to(CRATE)}")
        return 0

    chosen = list(MATRIX)
    if args.only:
        by_name = {t.rust: t for t in MATRIX}
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
        print(f"\n=== {target.rust} ({target.zig}) ===", flush=True)
        size, note = build(target, Path(args.cache_root), zig, strip, nm)
        total += size
        print(f"    {size / 1e6:.2f} MB  probe: {note}")

    print(f"\nvendored {len(chosen)} archive(s), {total / 1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

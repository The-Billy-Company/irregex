"""Compare the shipped Windows ARM64 archive with both compiler strip postures."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import runpy
import shutil
import subprocess
import sys
from pathlib import Path

ENGINE = Path(__file__).resolve().parent.parent
DLL_PROBE = """
import ctypes, sys
library = ctypes.CDLL(sys.argv[1])
compile = library.irgx_compile
compile.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint32,
                   ctypes.POINTER(ctypes.c_void_p)]
compile.restype = ctypes.c_int32
out = ctypes.c_void_p()
assert compile(b'(unclosed', 9, 0, ctypes.byref(out)) == -4
assert out.value is None
print('invalid pattern refused by the actual DLL')
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "win32" or platform.machine().lower() not in ("arm64", "aarch64"):
        raise SystemExit("this diagnostic must execute on a native Windows ARM64 kernel")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    vendor = runpy.run_path(str(ENGINE / "bindings/go/scripts/vendor_libraries.py"))
    target = next(t for t in vendor["MATRIX"] if t.name == "windows/arm64")
    strip = vendor["find_tool"]("llvm-strip", "LLVM_STRIP")
    dump = vendor["find_tool"]("llvm-objdump", "LLVM_OBJDUMP")
    if not strip or not dump:
        raise SystemExit("pinned Rust llvm-tools must provide strip and objdump")
    records: dict[str, dict] = {}

    def run(name: str, command: list[str], *, cwd: Path = ENGINE, required: bool = True) -> int:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)
        stdout, stderr = out / f"{name}.stdout.txt", out / f"{name}.stderr.txt"
        stdout.write_text(result.stdout)
        stderr.write_text(result.stderr)
        records[name] = {"command": command, "returncode": result.returncode}
        (out / "results.json").write_text(json.dumps(records, indent=2) + "\n")
        print(f"{name}: exit {result.returncode}", flush=True)
        if required and result.returncode != 0:
            raise RuntimeError(f"{name} failed; see {stdout} and {stderr}")
        return result.returncode

    def probe(label: str, archive: Path, *, required: bool) -> None:
        records[label] = {"archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
        source, binary = out / f"{label}.c", out / f"{label}.exe"
        source.write_text(vendor["PROBE"])
        run(
            f"{label}-link",
            [
                "zig",
                "cc",
                "-target",
                target.zig,
                f"-I{ENGINE / 'include'}",
                str(source),
                str(archive),
                *target.libs,
                "-o",
                str(binary),
            ],
        )
        run(f"{label}-native", [str(binary)], required=required)
        run(f"{label}-symbols", [dump, "--syms", str(binary)])
        run(
            f"{label}-error",
            [dump, "-dr", "--disassemble-symbols=pcre2_get_error_message_8", str(binary)],
        )
        run(
            f"{label}-archive-tls",
            [
                dump,
                "-dr",
                "--disassemble-symbols=.Lkernel.regex.pcre2.engine.Pcre.compileOpts,kernel.regex.pcre2.engine.Pcre.compileOpts",
                str(archive),
            ],
        )
        shutil.copy2(archive, out / f"{label}.a")

    probe("committed", target.archive, required=False)
    env = os.environ | {
        "CC": f"zig cc -target {target.zig}",
        "CGO_ENABLED": "1",
        "GOMAXPROCS": "2",
        # Go does not track changed external static-library bytes in its build
        # cache. Separate empty caches prove each archive really reaches cgo.
        "GOCACHE": str(out.parent / "irregex-go-cache-committed"),
    }
    os.environ.update(env)
    module = ENGINE / "bindings/go"
    run("committed-go-build", ["go", "test", "-c", "-o", str(out / "committed-go.exe")], cwd=module)
    run(
        "committed-go-native",
        [
            str(out / "committed-go.exe"),
            "-test.run=^TestDecodingOverAUsedPatternDoesNotKeepTheOldOne$",
            "-test.v",
        ],
        required=False,
    )
    run("committed-go-symbols", [dump, "--syms", str(out / "committed-go.exe")])
    for compiler_strip in (True, False):
        label = "compiler-stripped" if compiler_strip else "post-link-stripped"
        prefix = out / label
        run(
            f"{label}-build",
            [
                "zig",
                "build",
                "-j1",
                "-Doptimize=ReleaseFast",
                f"-Dstrip={str(compiler_strip).lower()}",
                f"-Dtarget={target.zig}",
                f"-Dcpu={target.cpu}",
                "--prefix",
                str(prefix),
            ],
        )
        archive = prefix / "lib/libirgx.a"
        library = prefix / "bin/irgx.dll"
        run(f"{label}-strip", [strip, "--strip-debug", str(archive), str(library)])
        probe(label, archive, required=not compiler_strip)
        run(
            f"{label}-dll",
            [sys.executable, "-c", DLL_PROBE, str(library)],
            required=not compiler_strip,
        )
        if not compiler_strip:
            shutil.copy2(archive, target.archive)
            os.environ["GOCACHE"] = str(out.parent / "irregex-go-cache-corrected")
            run("corrected-go-vet", ["go", "vet", "-p", "1", "./..."], cwd=module)
            run("corrected-go-suite", ["go", "test", "-p", "1", "-count=1", "./..."], cwd=module)
    print(f"comparison complete: {out / 'results.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

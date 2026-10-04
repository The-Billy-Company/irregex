"""Compare the shipped Windows ARM64 archive with both compiler strip postures."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import platform
import runpy
import shutil
import subprocess
import sys
import time
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
    parser.add_argument("--alternate-zig", type=Path)
    parser.add_argument("--archive-ref", default="HEAD")
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
    # Children inherit the process error mode. Keep actual crash exit codes,
    # without waiting for Windows Error Reporting's modal UI:
    # https://learn.microsoft.com/windows/win32/api/errhandlingapi/nf-errhandlingapi-seterrormode
    kernel = ctypes.WinDLL("kernel32")
    kernel.GetErrorMode.argtypes = []
    kernel.GetErrorMode.restype = ctypes.c_uint32
    kernel.SetErrorMode.argtypes = [ctypes.c_uint32]
    kernel.SetErrorMode.restype = ctypes.c_uint32
    previous_mode = kernel.GetErrorMode()
    kernel.SetErrorMode(previous_mode | 0x0002)  # SEM_NOGPFAULTERRORBOX
    current_mode = kernel.GetErrorMode()
    if not current_mode & 0x0002:
        raise RuntimeError("Windows did not set SEM_NOGPFAULTERRORBOX")
    records["windows-error-mode"] = {"before": previous_mode, "current": current_mode}

    def run(
        name: str,
        command: list[str],
        *,
        cwd: Path = ENGINE,
        required: bool = True,
        env: dict[str, str] | None = None,
        timeout: int | None = None,
        stdout_path: Path | None = None,
    ) -> int:
        stdout = stdout_path or out / f"{name}.stdout.txt"
        stderr = out / f"{name}.stderr.txt"
        effective_env = os.environ if env is None else env
        records[name] = {
            "command": command,
            "cwd": str(cwd),
            "status": "RUNNING",
            "returncode": None,
            "timeout_seconds": timeout,
            "cc": effective_env.get("CC"),
            "go_cache": effective_env.get("GOCACHE"),
            "stdout_file": stdout.name,
            "stderr_file": stderr.name,
        }
        (out / "results.json").write_text(json.dumps(records, indent=2) + "\n")
        budget = f"{timeout}s" if timeout is not None else "workflow budget"
        print(f"{name}: start ({budget})", flush=True)
        started = time.monotonic()
        try:
            result = subprocess.run(
                command, cwd=cwd, env=env, capture_output=True, timeout=timeout, check=False
            )
        except subprocess.TimeoutExpired as expired:
            stdout.write_bytes(expired.stdout or b"")
            stderr.write_bytes(expired.stderr or b"")
            records[name]["status"] = "INCONCLUSIVE_TIMEOUT"
            records[name]["elapsed_seconds"] = time.monotonic() - started
            (out / "results.json").write_text(json.dumps(records, indent=2) + "\n")
            print(f"{name}: INCONCLUSIVE timeout after {timeout}s", flush=True)
            # Even an expected crashing control must finish. A killed child
            # cannot establish its native behavior or count as a passing probe.
            raise RuntimeError(f"{name} timed out; see {stdout} and {stderr}") from expired
        stdout.write_bytes(result.stdout)
        stderr.write_bytes(result.stderr)
        records[name].update(
            status="FINISHED",
            returncode=result.returncode,
            elapsed_seconds=time.monotonic() - started,
        )
        (out / "results.json").write_text(json.dumps(records, indent=2) + "\n")
        print(f"{name}: exit {result.returncode}", flush=True)
        if required and result.returncode != 0:
            raise RuntimeError(f"{name} failed; see {stdout} and {stderr}")
        return result.returncode

    def probe(label: str, archive: Path, *, required: bool, compiler: str = "zig") -> None:
        records[label] = {"archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
        shutil.copy2(archive, out / f"{label}.a")
        source, binary = out / f"{label}.c", out / f"{label}.exe"
        source.write_text(vendor["PROBE"])
        run(
            f"{label}-link",
            [
                compiler,
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
        run(f"{label}-native", [str(binary)], required=required, timeout=30)
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
        run(
            f"{label}-linked-tls",
            [
                dump,
                "-dr",
                "--disassemble-symbols=.Lkernel.regex.pcre2.engine.Pcre.compileOpts,kernel.regex.pcre2.engine.Pcre.compileOpts",
                str(binary),
            ],
        )

    run(
        "inherited-error-mode",
        [
            sys.executable,
            "-c",
            "import ctypes; mode = ctypes.windll.kernel32.GetErrorMode(); print(mode); assert mode & 2",
        ],
        timeout=30,
    )
    run("current-source", ["git", "rev-parse", "--verify", "HEAD"])
    run(
        "baseline-commit",
        ["git", "rev-parse", "--verify", "--end-of-options", f"{args.archive_ref}^{{commit}}"],
    )
    baseline_commit = (out / "baseline-commit.stdout.txt").read_text(encoding="utf-8").strip()
    baseline = out / "baseline.a"
    run(
        "baseline-blob",
        ["git", "show", f"{baseline_commit}:{target.archive.relative_to(ENGINE).as_posix()}"],
        stdout_path=baseline,
    )
    records["baseline-source"] = {
        "commit": baseline_commit,
        "archive_sha256": hashlib.sha256(baseline.read_bytes()).hexdigest(),
    }
    shutil.copy2(baseline, target.archive)
    probe("committed", baseline, required=False)
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
            "-test.timeout=60s",
        ],
        required=False,
        timeout=120,
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
            timeout=30,
        )
        if not compiler_strip:
            shutil.copy2(archive, target.archive)
            os.environ["GOCACHE"] = str(out.parent / "irregex-go-cache-corrected")
            run("corrected-go-vet", ["go", "vet", "-p", "1", "./..."], cwd=module)
            run(
                "corrected-go-packages",
                [
                    "go",
                    "list",
                    "-f",
                    "{{if or .TestGoFiles .XTestGoFiles}}{{.Dir}}{{end}}",
                    "./...",
                ],
                cwd=module,
            )
            packages = (
                (out / "corrected-go-packages.stdout.txt").read_text(encoding="utf-8").splitlines()
            )
            packages = [Path(directory) for directory in packages if directory]
            if not packages:
                raise RuntimeError("Go discovered no test packages")
            # Bound the actual test process, rather than its Go driver: a
            # surviving descendant can otherwise keep captured pipes open.
            for index, package in enumerate(packages):
                binary = out / f"corrected-go-suite-{index}.exe"
                run(
                    f"corrected-go-suite-{index}-build",
                    ["go", "test", "-c", "-p", "1", "-o", str(binary), "."],
                    cwd=package,
                )
                run(
                    f"corrected-go-suite-{index}-native",
                    [
                        str(binary),
                        "-test.count=1",
                        "-test.timeout=60s",
                        "-test.paniconexit0",
                        "-test.v",
                    ],
                    cwd=package,
                    timeout=120,
                )
    if args.alternate_zig:
        compiler = str(args.alternate_zig.resolve())
        run("alternate-zig-version", [compiler, "version"])
        run("alternate-clang-version", [compiler, "cc", "--version"])
        committed = out / "committed.a"
        probe("alternate-linker", committed, required=True, compiler=compiler)
        # Only the consumer linker changes. These are the exact failing archive
        # bytes, with a third empty Go build cache outside the evidence upload.
        shutil.copy2(committed, target.archive)
        alternate_env = os.environ | {
            "CC": f'"{compiler}" cc -target {target.zig}',
            "GOCACHE": str(out.parent / "irregex-go-cache-alternate"),
        }
        run(
            "alternate-go-build",
            ["go", "test", "-c", "-o", str(out / "alternate-go.exe")],
            cwd=module,
            env=alternate_env,
        )
        run(
            "alternate-go-native",
            [
                str(out / "alternate-go.exe"),
                "-test.run=^TestDecodingOverAUsedPatternDoesNotKeepTheOldOne$",
                "-test.v",
                "-test.timeout=60s",
            ],
            env=alternate_env,
            timeout=120,
        )
    print(f"comparison complete: {out / 'results.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

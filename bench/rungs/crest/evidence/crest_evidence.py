#!/usr/bin/env python3
"""Create, verify, and render revision-bound CREST evidence packages."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from datetime import date, datetime, timezone
from datetime import time as datetime_time
from pathlib import Path

import monograph
import tomllib
import verify

HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[3]  # evidence → crest → rungs → bench → repo root
CONTRACT = KERNEL / "contract/crest_evidence.toml"
UTC = timezone.utc

type _JsonValue = (
    None | bool | int | float | str | list[_JsonValue] | dict[str, _JsonValue]
)
type _JsonObject = dict[str, _JsonValue]
type _TomlValue = (
    bool
    | int
    | float
    | str
    | date
    | datetime
    | datetime_time
    | list[_TomlValue]
    | dict[str, _TomlValue]
)
type _TomlTable = dict[str, _TomlValue]
type _PlistValue = (
    bool
    | int
    | float
    | str
    | bytes
    | datetime
    | plistlib.UID
    | list[_PlistValue]
    | dict[str, _PlistValue]
)
type _PlistObject = dict[str, _PlistValue]


def _utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _json_write(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _git(*args: str, text: bool = True) -> str | bytes:
    return subprocess.check_output(
        ["git", "-C", str(KERNEL), *args],
        text=text,
        stderr=subprocess.PIPE,
    ).strip()


def _clean_commit() -> str:
    dirty = _git("status", "--porcelain", "--untracked-files=all")
    if dirty:
        count = len(str(dirty).splitlines())
        raise ValueError(
            f"publish requires a clean worktree; found {count} dirty path(s)"
        )
    commit = str(_git("rev-parse", "HEAD"))
    if len(commit) not in range(40, 65):
        raise ValueError("cannot resolve a full source commit")
    return commit


def _contract_at(commit: str) -> _TomlTable:
    path = "contract/crest_evidence.toml"
    raw = subprocess.check_output(
        ["git", "-C", str(KERNEL), "show", f"{commit}:{path}"],
        text=True,
        stderr=subprocess.PIPE,
    )
    return tomllib.loads(raw)


def _expand(argv: list[str], contract: _TomlTable) -> list[str]:
    benchmark = contract["benchmark"]
    values = {key: benchmark[key] for key in ("rank", "budget", "runs", "warmup")}
    return [part.format_map(values) for part in argv]


def _run(
    label: str,
    argv: list[str],
    cwd: Path,
    transcript: Path,
) -> _JsonObject:
    started, wall = _utc_now(), time.monotonic()
    try:
        completed = subprocess.run(
            argv,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
    except OSError as error:
        transcript.write_text(f"unable to execute {argv[0]}: {error}\n")
        raise ValueError(f"{label} command could not start: {error}") from error
    transcript.write_bytes(completed.stdout)
    receipt = {
        "label": label,
        "argv": argv,
        "cwd": str(cwd.relative_to(KERNEL)),
        "started_at_utc": started,
        "finished_at_utc": _utc_now(),
        "duration_seconds": round(time.monotonic() - wall, 6),
        "exit_code": completed.returncode,
        "transcript": transcript.name,
        "transcript_sha256": _sha256(transcript),
    }
    if completed.returncode:
        raise ValueError(
            f"{label} failed with exit {completed.returncode}; see {transcript}"
        )
    return receipt


def _archive(
    commit: str,
    paths: list[str],
    destination: Path,
) -> _JsonObject:
    argv = [
        "git",
        "-C",
        str(KERNEL),
        "archive",
        "--format=tar",
        "--prefix=crest-source/",
        f"--output={destination}",
        commit,
        "--",
        *paths,
    ]
    started, wall = _utc_now(), time.monotonic()
    completed = subprocess.run(argv, capture_output=True, check=False)
    receipt = {
        "label": "source_archive",
        "argv": argv,
        "cwd": ".",
        "started_at_utc": started,
        "finished_at_utc": _utc_now(),
        "duration_seconds": round(time.monotonic() - wall, 6),
        "exit_code": completed.returncode,
        "stderr": completed.stderr.decode(errors="replace").strip(),
    }
    if completed.returncode:
        raise ValueError(f"git archive failed: {receipt['stderr']}")
    return receipt


def _probe(*argv: str) -> str | None:
    try:
        value = subprocess.check_output(
            argv, text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return value or None


def _darwin_volume_info() -> _PlistObject:
    if platform.system() != "Darwin":
        return {}
    mount = _probe("stat", "-f", "%T", str(KERNEL))
    if not mount:
        return {}
    try:
        raw = subprocess.check_output(
            ["diskutil", "info", "-plist", mount], stderr=subprocess.DEVNULL
        )
        return plistlib.loads(raw)
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException):
        return {}


def _cpu_model() -> tuple[str | None, str | None]:
    value = _probe("sysctl", "-n", "machdep.cpu.brand_string")
    if value:
        return value, None
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                return line.partition(":")[2].strip(), None
    except OSError:
        pass
    value = platform.processor() or None
    return (
        value,
        None
        if value
        else "host exposed no CPU model through sysctl, procfs, or platform",
    )


def _memory_bytes() -> tuple[int | None, str | None]:
    value = _probe("sysctl", "-n", "hw.memsize")
    if value and value.isdigit():
        return int(value), None
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES"), None
    except (OSError, ValueError):
        return None, "host exposed no physical-memory total"


def _filesystem() -> tuple[str | None, str | None]:
    if platform.system() == "Darwin":
        info = _darwin_volume_info()
        value = info.get("FilesystemType") or info.get("FilesystemName")
    else:
        value = _probe("stat", "-f", "-c", "%T", str(KERNEL))
    return value, None if value else "filesystem type probe unavailable"


def _storage() -> tuple[_JsonObject | None, str | None]:
    try:
        usage = shutil.disk_usage(KERNEL)
    except OSError:
        return None, "disk-usage probe failed"
    result: _JsonObject = {
        "path": str(KERNEL),
        "total_bytes": usage.total,
        "used_bytes": usage.used,
        "free_bytes": usage.free,
    }
    df = _probe("df", "-P", str(KERNEL))
    if df and len(df.splitlines()) >= 2:
        result["device"] = df.splitlines()[-1].split()[0]
    info = _darwin_volume_info()
    for source, target in (
        ("MediaName", "media_name"),
        ("MediaType", "media_type"),
        ("SolidState", "solid_state"),
        ("BusProtocol", "bus_protocol"),
    ):
        if source in info:
            result[target] = info[source]
    return result, None


def _power() -> tuple[_JsonObject | None, str | None]:
    if platform.system() == "Darwin":
        battery = _probe("pmset", "-g", "batt")
        policy = _probe("pmset", "-g", "custom")
        if battery or policy:
            return {"battery": battery, "policy": policy}, None
    paths = sorted(Path("/sys/class/power_supply").glob("*/status"))
    if paths:
        return {
            "supplies": {
                str(path.parent.name): path.read_text(errors="replace").strip()
                for path in paths
            }
        }, None
    return None, "host exposed no supported power-state probe"


def _machine(contract: _TomlTable) -> _JsonObject:
    cpu, cpu_note = _cpu_model()
    memory, memory_note = _memory_bytes()
    filesystem, filesystem_note = _filesystem()
    storage, storage_note = _storage()
    power, power_note = _power()
    result = {
        "captured_at_utc": _utc_now(),
        "hostname": socket.gethostname(),
        "os": platform.platform(),
        "kernel": platform.release(),
        "architecture": platform.machine(),
        "cpu_model": cpu,
        "logical_cpu_count": os.cpu_count(),
        "memory_bytes": memory,
        "filesystem": filesystem,
        "storage": storage,
        "power": power,
        "cache_condition": {
            "warmup_runs": contract["benchmark"]["warmup"],
            "storage_cache_drop_attempted": False,
            "condition": "warmup-conditioned page cache; storage caches not forcibly dropped",
        },
        "toolchain": {
            "python": sys.version.replace("\n", " "),
            "git": _probe("git", "--version"),
            "zig": _probe("zig", "version")
            or _probe("mise", "exec", "--", "zig", "version"),
        },
    }
    for key, note in (
        ("cpu_model", cpu_note),
        ("memory_bytes", memory_note),
        ("filesystem", filesystem_note),
        ("storage", storage_note),
        ("power", power_note),
    ):
        if note:
            result[f"{key}_note"] = note
    return result


def _copy_benchmark_artifacts(stage: Path, contract: _TomlTable) -> None:
    paths = contract["paths"]
    for source_key, destination in (
        ("run_json", "crest-run.json"),
        ("aggregate_csv", "crest.csv"),
        ("corpus_manifest", "corpus-manifest.tsv"),
    ):
        source = KERNEL / paths[source_key]
        if not source.is_file():
            raise ValueError(f"benchmark did not produce required artifact: {source}")
        shutil.copyfile(source, stage / destination)


def _reseal(stage: Path, contract: _TomlTable, manifest: _JsonObject) -> None:
    manifest["files"] = {
        name: _sha256(stage / name)
        for name in contract["artifacts"]["payload_required"]
    }
    _json_write(stage / verify.MANIFEST, manifest)
    digest = _sha256(stage / verify.MANIFEST)
    (stage / verify.DETACHED).write_text(f"{digest}  {verify.MANIFEST}\n")


def package(output: Path | None = None) -> Path:
    commit = _clean_commit()
    contract = _contract_at(commit)
    raw_dir = KERNEL / contract["paths"]["raw_dir"]
    raw_dir.mkdir(parents=True, exist_ok=True)
    destination = output or raw_dir / f"package-{commit}"
    destination = destination.resolve()
    if not destination.is_relative_to(raw_dir.resolve()):
        raise ValueError(f"evidence packages must stay under {raw_dir}")
    if destination.exists():
        raise ValueError(
            f"refusing to overwrite existing evidence package: {destination}"
        )

    stage = Path(tempfile.mkdtemp(prefix=".package-", dir=raw_dir))
    try:
        commands: list[_JsonObject] = []
        benchmark_argv = _expand(contract["commands"]["benchmark"], contract)
        commands.append(
            _run(
                "benchmark", benchmark_argv, KERNEL, stage / "benchmark-transcript.txt"
            )
        )
        _copy_benchmark_artifacts(stage, contract)

        test_argv = list(contract["commands"]["test"])
        test_receipt = _run("test", test_argv, KERNEL, stage / "test-transcript.txt")
        commands.append(test_receipt)
        _json_write(
            stage / "test-artifact.json",
            {
                "schema_version": contract["meta"]["schema_version"],
                "source_commit": commit,
                **test_receipt,
            },
        )

        (stage / "source-commit.txt").write_text(f"{commit}\n")
        commands.append(
            _archive(
                commit, contract["paths"]["source_archive_paths"], stage / "source.tar"
            )
        )
        machine = _machine(contract)
        _json_write(stage / "machine.json", machine)
        _json_write(
            stage / "command-log.json",
            {
                "schema_version": contract["meta"]["schema_version"],
                "source_commit": commit,
                "commands": commands,
            },
        )

        run = json.loads((stage / "crest-run.json").read_text())
        archive_sha = _sha256(stage / "source.tar")
        benchmark_sha = _sha256(stage / "crest-run.json")
        test_sha = _sha256(stage / "test-artifact.json")
        monograph.write(
            stage,
            repo=KERNEL,
            commit=commit,
            archive_sha256=archive_sha,
            benchmark_sha256=benchmark_sha,
            test_sha256=test_sha,
            run=run,
            source_paths=contract["paths"]["monograph_sources"],
        )

        environment = {
            "toolchain": machine["toolchain"],
            "platform": {
                key: machine[key]
                for key in (
                    "hostname",
                    "os",
                    "kernel",
                    "architecture",
                    "cpu_model",
                    "logical_cpu_count",
                    "memory_bytes",
                    "filesystem",
                    "storage",
                    "power",
                    "cache_condition",
                )
            },
        }
        manifest = {
            "schema_version": contract["meta"]["schema_version"],
            "artifact_kind": contract["meta"]["artifact_kind"],
            "created_at_utc": _utc_now(),
            "source_commit": commit,
            "source_archive_sha256": archive_sha,
            "benchmark_artifact_sha256": benchmark_sha,
            "test_artifact_sha256": test_sha,
            "corpus_manifest_sha256": _sha256(stage / "corpus-manifest.tsv"),
            "machine_artifact_sha256": _sha256(stage / "machine.json"),
            "command_log_sha256": _sha256(stage / "command-log.json"),
            "environment": environment,
            "environment_sha256": hashlib.sha256(
                json.dumps(
                    environment,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=True,
                ).encode()
            ).hexdigest(),
            "matcher_results": {
                "fixed_regression": run["fixed_regression"],
                "randomized_soundness": run["randomized_soundness"],
                "violations": run["violations"],
                "passed": run["passed"],
            },
        }
        _reseal(stage, contract, manifest)
        if _clean_commit() != commit:
            raise ValueError("source revision changed while packaging")
        problems = verify.verify_package(stage, CONTRACT, KERNEL)
        if problems:
            raise ValueError("package verification failed:\n- " + "\n- ".join(problems))
        stage.replace(destination)
        return destination
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def regenerate_monograph(package_dir: Path) -> None:
    contract = verify.load_contract(CONTRACT)
    manifest = json.loads((package_dir / verify.MANIFEST).read_text())
    commit = manifest["source_commit"]
    pinned_contract = _contract_at(commit)
    run = json.loads((package_dir / "crest-run.json").read_text())
    monograph.write(
        package_dir,
        repo=KERNEL,
        commit=commit,
        archive_sha256=manifest["source_archive_sha256"],
        benchmark_sha256=manifest["benchmark_artifact_sha256"],
        test_sha256=manifest["test_artifact_sha256"],
        run=run,
        source_paths=pinned_contract["paths"]["monograph_sources"],
    )
    _reseal(package_dir, contract, manifest)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser(
        "package", help="run proofs and create a clean-tree package"
    )
    create.add_argument("--output", type=Path)
    check = sub.add_parser("verify", help="verify every hash, receipt, and revision")
    check.add_argument("package", type=Path)
    render = sub.add_parser("monograph", help="regenerate the revision-bound monograph")
    render.add_argument("package", type=Path)
    args = parser.parse_args()

    try:
        if args.command == "package":
            path = package(args.output)
            print(path)
        elif args.command == "monograph":
            regenerate_monograph(args.package.resolve())
            problems = verify.verify_package(args.package.resolve(), CONTRACT, KERNEL)
            if problems:
                raise ValueError(
                    "monograph package verification failed:\n- " + "\n- ".join(problems)
                )
            print(args.package.resolve() / monograph.MONOGRAPH)
        else:
            problems = verify.verify_package(args.package.resolve(), CONTRACT, KERNEL)
            if problems:
                print("CREST evidence verification FAILED")
                for problem in problems:
                    print(f"- {problem}")
                return 1
            print("CREST evidence verification passed")
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"CREST evidence error: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

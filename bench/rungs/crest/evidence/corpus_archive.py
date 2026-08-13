#!/usr/bin/env python3
"""Run the CREST corpus proof against a safely staged ZIP archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import struct
import subprocess
import tempfile
import zipfile
from contextlib import ExitStack, contextmanager
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import BinaryIO

import verify

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
CONTRACT = REPO / "contract/crest_evidence.toml"
MAX_MEMBER_BYTES = 32 << 20
MAX_ARCHIVE_BYTES = 64 << 20
MAX_ARCHIVE_MEMBERS = 10_000
MAX_ARCHIVE_DIRECTORIES = 1_000
MAX_ZERO_BYTE_MEMBERS = 1_000
MAX_COMPRESSION_RATIO = 200
SUPPORTED_RANKS = (1, 2, 4)
SUPPORTED_BUDGETS = (1, 2, 4, 8)
EVIDENCE_DIR = REPO / ".local/crest-evidence"
_EOCD = struct.Struct("<4s4H2LH")
_CENTRAL_DIRECTORY = struct.Struct("<4s6H3L5H2L")


class CorpusArchiveError(ValueError):
    pass


def profile_name(rank: int, budget: int) -> str:
    if rank not in SUPPORTED_RANKS:
        raise CorpusArchiveError(f"rank must be one of {SUPPORTED_RANKS}")
    if budget not in SUPPORTED_BUDGETS:
        raise CorpusArchiveError(f"budget must be one of {SUPPORTED_BUDGETS}")
    return f"q{rank}-b{budget}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _sha256_source(source: BinaryIO) -> str:
    position = source.tell()
    source.seek(0)
    digest = hashlib.sha256()
    for chunk in iter(lambda: source.read(1 << 20), b""):
        digest.update(chunk)
    source.seek(position)
    return digest.hexdigest()


@contextmanager
def _opened_archive(archive_path: Path):
    flags = os.O_RDONLY
    for flag in ("O_BINARY", "O_CLOEXEC", "O_NOFOLLOW", "O_NONBLOCK"):
        flags |= getattr(os, flag, 0)
    try:
        descriptor = os.open(archive_path, flags)
    except OSError as error:
        raise CorpusArchiveError(
            "corpus input must be an explicit no-follow regular ZIP file"
        ) from error
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise CorpusArchiveError("corpus input must be an explicit regular ZIP file")
        if not hasattr(os, "O_NOFOLLOW"):
            linked = os.lstat(archive_path)
            if stat.S_ISLNK(linked.st_mode) or (linked.st_dev, linked.st_ino) != (
                opened.st_dev,
                opened.st_ino,
            ):
                raise CorpusArchiveError("corpus archive changed while it was being opened")
        source = os.fdopen(descriptor, "rb")
        descriptor = -1
        with source:
            yield source
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _safe_path(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if (
        not name
        or "\0" in name
        or "\\" in name
        or name.startswith("/")
        or "//" in name
        or path.is_absolute()
        or any(part in {"", ".", ".."} for part in path.parts)
        or (path.parts and ":" in path.parts[0])
    ):
        raise CorpusArchiveError("ZIP member path is non-canonical or unsafe")
    return path


def _zip_end_record(source: BinaryIO) -> tuple[int, int, int]:
    source.seek(0, os.SEEK_END)
    archive_size = source.tell()
    source.seek(max(0, archive_size - (0xFFFF + _EOCD.size)))
    tail = source.read()
    offset = tail.rfind(b"PK\x05\x06")
    while offset >= 0:
        if len(tail) - offset >= _EOCD.size:
            record = _EOCD.unpack_from(tail, offset)
            if offset + _EOCD.size + record[-1] == len(tail):
                (
                    _,
                    disk,
                    central_disk,
                    disk_entries,
                    total_entries,
                    central_size,
                    central_offset,
                    _,
                ) = record
                if disk or central_disk or disk_entries != total_entries:
                    raise CorpusArchiveError("multi-disk ZIP archives are forbidden")
                if (
                    total_entries == 0xFFFF
                    or central_size == 0xFFFFFFFF
                    or central_offset == 0xFFFFFFFF
                    or (offset >= 20 and tail[offset - 20 : offset - 16] == b"PK\x06\x07")
                ):
                    raise CorpusArchiveError("ZIP64 archives are forbidden")
                if total_entries > MAX_ARCHIVE_MEMBERS:
                    raise CorpusArchiveError("ZIP exceeds CREST member-count limit")
                eocd_offset = archive_size - len(tail) + offset
                if central_offset + central_size != eocd_offset:
                    raise CorpusArchiveError("ZIP central directory exceeds archive bounds")
                return total_entries, central_offset, central_size
        offset = tail.rfind(b"PK\x05\x06", 0, offset)
    raise CorpusArchiveError("corpus input is not a canonical ZIP archive")


def _preflight_zip(source: BinaryIO) -> None:
    """Bound central-directory work before ZipFile allocates per-entry state."""
    entries, offset, size = _zip_end_record(source)
    source.seek(offset)
    consumed = directories = zero_bytes = 0
    for _ in range(entries):
        header = source.read(_CENTRAL_DIRECTORY.size)
        if len(header) != _CENTRAL_DIRECTORY.size:
            raise CorpusArchiveError("ZIP central directory is truncated")
        fields = _CENTRAL_DIRECTORY.unpack(header)
        if fields[0] != b"PK\x01\x02":
            raise CorpusArchiveError("ZIP central directory entry is malformed")
        uncompressed_size = fields[9]
        name_length, extra_length, comment_length = fields[10:13]
        name = source.read(name_length)
        if len(name) != name_length:
            raise CorpusArchiveError("ZIP central directory name is truncated")
        source.seek(extra_length + comment_length, os.SEEK_CUR)
        consumed += _CENTRAL_DIRECTORY.size + name_length + extra_length + comment_length
        is_directory = name.endswith(b"/")
        directories += is_directory
        zero_bytes += not is_directory and uncompressed_size == 0
        if directories > MAX_ARCHIVE_DIRECTORIES:
            raise CorpusArchiveError("ZIP exceeds directory-entry limit")
        if zero_bytes > MAX_ZERO_BYTE_MEMBERS:
            raise CorpusArchiveError("ZIP exceeds zero-byte member limit")
    if consumed != size:
        raise CorpusArchiveError("ZIP central directory size is inconsistent")


def _inspect_zip(archive: zipfile.ZipFile, archive_sha256: str) -> dict[str, object]:
    infos = archive.filelist
    if len(infos) > MAX_ARCHIVE_MEMBERS:
        raise CorpusArchiveError("ZIP exceeds CREST member-count limit")
    names: set[str] = set()
    folded: set[str] = set()
    members: list[dict[str, object]] = []
    total = 0
    for info in infos:
        name = info.filename.rstrip("/")
        if not name:
            continue
        relative = _safe_path(name)
        canonical = relative.as_posix()
        if canonical != name:
            raise CorpusArchiveError("ZIP member path is not canonical")
        casefolded = canonical.casefold()
        if canonical in names or casefolded in folded:
            raise CorpusArchiveError("ZIP has duplicate or case-colliding members")
        names.add(canonical)
        folded.add(casefolded)
        mode = (info.external_attr >> 16) & 0o170000
        if mode == stat.S_IFLNK:
            raise CorpusArchiveError("ZIP symlinks are forbidden")
        if info.flag_bits & 0x1:
            raise CorpusArchiveError("encrypted ZIP members are forbidden")
        if info.is_dir():
            continue
        total += info.file_size
        if info.file_size > MAX_MEMBER_BYTES or total > MAX_ARCHIVE_BYTES:
            raise CorpusArchiveError("ZIP exceeds CREST corpus size limits")
        if (
            info.file_size > 1 << 20
            and info.file_size / max(info.compress_size, 1) > MAX_COMPRESSION_RATIO
        ):
            raise CorpusArchiveError("ZIP member exceeds compression-ratio limit")
        members.append(
            {
                "path": canonical,
                "size_bytes": info.file_size,
                "crc32": f"{info.CRC:08x}",
            }
        )
    if not members:
        raise CorpusArchiveError("ZIP contains no regular files")
    members.sort(key=lambda member: os.fsencode(str(member["path"])))
    canonical = json.dumps(members, sort_keys=True, separators=(",", ":")).encode()
    return {
        "schema": "irregex-crest-corpus-archive-v1",
        "archive_sha256": archive_sha256,
        "member_manifest_sha256": hashlib.sha256(canonical).hexdigest(),
        "file_count": len(members),
        "total_bytes": total,
        "members": members,
        "benchmark_policy": {
            "capable_profiles": ["q1-b8", "q4-b8"],
            "promotion_eligible": False,
            "authorization": "capability-only; promotion requires separately verified evidence",
            "q4_promotion_blocked": True,
            "adaptive_dictionary_pending": True,
        },
    }


def inspect_archive(archive_path: Path) -> dict[str, object]:
    with _opened_archive(archive_path) as source:
        _preflight_zip(source)
        archive_sha256 = _sha256_source(source)
        source.seek(0)
        try:
            with zipfile.ZipFile(source) as archive:
                receipt = _inspect_zip(archive, archive_sha256)
        except zipfile.BadZipFile as error:
            raise CorpusArchiveError("corpus input is not a readable ZIP file") from error
        if _sha256_source(source) != archive_sha256:
            raise CorpusArchiveError("corpus archive changed during inspection")
        return receipt


def _extract_members(
    archive: zipfile.ZipFile,
    root: Path,
    members: list[dict[str, object]],
) -> None:
    for member in members:
        relative = PurePosixPath(str(member["path"]))
        destination = root.joinpath(*relative.parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() or destination.is_symlink():
            raise CorpusArchiveError("staged corpus destination collision")
        with (
            archive.open(archive.getinfo(str(member["path"]))) as source,
            destination.open("xb") as target,
        ):
            shutil.copyfileobj(source, target)
        if destination.stat().st_size != member["size_bytes"]:
            raise CorpusArchiveError("staged corpus member size drift")
        destination.chmod(0o444)


@contextmanager
def staged_archive(archive_path: Path):
    with _opened_archive(archive_path) as source:
        _preflight_zip(source)
        archive_sha256 = _sha256_source(source)
        source.seek(0)
        try:
            with zipfile.ZipFile(source) as archive:
                receipt = _inspect_zip(archive, archive_sha256)
                with tempfile.TemporaryDirectory(prefix="irregex-crest-corpus-") as temporary:
                    root = Path(temporary)
                    _extract_members(archive, root, receipt["members"])
                    if _sha256_source(source) != archive_sha256:
                        raise CorpusArchiveError("corpus archive changed during staging")
                    yield root, receipt
        except zipfile.BadZipFile as error:
            raise CorpusArchiveError("corpus input is not a readable ZIP file") from error


def _artifact_paths(profile: str) -> dict[str, Path]:
    return {
        "aggregate_csv": EVIDENCE_DIR / f"crest-{profile}.csv",
        "run_json": EVIDENCE_DIR / f"crest-run-{profile}.json",
        "corpus_manifest": EVIDENCE_DIR / "corpus-manifest.tsv",
    }


def _artifact_snapshot(paths: dict[str, Path]) -> dict[str, str | None]:
    return {
        name: sha256_file(path) if path.is_file() and not path.is_symlink() else None
        for name, path in paths.items()
    }


def _file_stamp(metadata: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


@contextmanager
def _opened_artifact(path: Path, name: str):
    flags = os.O_RDONLY
    for flag in ("O_BINARY", "O_CLOEXEC", "O_NOFOLLOW", "O_NONBLOCK"):
        flags |= getattr(os, flag, 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise CorpusArchiveError(f"CREST benchmark did not produce {name}: {path.name}") from error
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise CorpusArchiveError(f"CREST benchmark did not produce regular {name}: {path.name}")
        if not hasattr(os, "O_NOFOLLOW"):
            linked = os.lstat(path)
            if stat.S_ISLNK(linked.st_mode) or (linked.st_dev, linked.st_ino) != (
                opened.st_dev,
                opened.st_ino,
            ):
                raise CorpusArchiveError(f"CREST benchmark replaced {name} while it was opened")
        source = os.fdopen(descriptor, "rb")
        descriptor = -1
        with source:
            yield source, opened
    finally:
        if descriptor >= 0:
            os.close(descriptor)


@contextmanager
def _immutable_artifacts(paths: dict[str, Path]):
    with (
        tempfile.TemporaryDirectory(prefix="irregex-crest-artifacts-") as temporary,
        ExitStack() as stack,
    ):
        root = Path(temporary)
        snapshots: dict[str, Path] = {}
        hashes: dict[str, str] = {}
        opened: dict[str, tuple[BinaryIO, os.stat_result]] = {}
        for name, path in paths.items():
            source, metadata = stack.enter_context(_opened_artifact(path, name))
            snapshot = root / path.name
            digest = hashlib.sha256()
            with snapshot.open("xb") as target:
                while chunk := source.read(1 << 20):
                    digest.update(chunk)
                    target.write(chunk)
            if _file_stamp(os.fstat(source.fileno())) != _file_stamp(metadata):
                raise CorpusArchiveError(f"CREST benchmark changed {name} while it was snapshotted")
            snapshots[name], hashes[name], opened[name] = (
                snapshot,
                digest.hexdigest(),
                (source, metadata),
            )
        try:
            yield snapshots, hashes
        finally:
            for name, (source, metadata) in opened.items():
                path = paths[name]
                try:
                    linked = os.lstat(path)
                except OSError as error:
                    raise CorpusArchiveError(
                        f"CREST benchmark changed {name} during verification"
                    ) from error
                if (
                    stat.S_ISLNK(linked.st_mode)
                    or (linked.st_dev, linked.st_ino) != (metadata.st_dev, metadata.st_ino)
                    or _file_stamp(os.fstat(source.fileno())) != _file_stamp(metadata)
                ):
                    raise CorpusArchiveError(f"CREST benchmark changed {name} during verification")


def _verify_artifacts(
    paths: dict[str, Path],
    before: dict[str, str | None],
    rank: int,
    budget: int,
    profile: str,
    runs: int,
    warmup: int,
) -> dict[str, object]:
    with _immutable_artifacts(paths) as (snapshots, hashes):
        for name in ("aggregate_csv", "run_json"):
            if before[name] == hashes[name]:
                raise CorpusArchiveError(f"CREST benchmark left stale {name}: {paths[name].name}")
        contract = verify.load_contract(CONTRACT)
        benchmark = contract["benchmark"]
        expected_names = {name: path.name for name, path in paths.items()}
        _, problems = verify.verify_benchmark_artifacts(
            snapshots["run_json"],
            snapshots["aggregate_csv"],
            snapshots["corpus_manifest"],
            schema_version=contract["meta"]["schema_version"],
            artifact_kind=contract["meta"]["artifact_kind"],
            expected_config={
                "rank": rank,
                "budget": budget,
                "profile": profile,
                "runs": runs,
                "warmup": warmup,
                "timing_clock": benchmark["timing_clock"],
                "aggregation": benchmark["aggregation"],
            },
            expected_artifacts=expected_names,
            expected_production=benchmark["production"],
        )
        if problems:
            raise CorpusArchiveError(
                "CREST benchmark artifacts are inconsistent:\n- " + "\n- ".join(problems)
            )
        return {
            name: {"filename": path.name, "sha256": hashes[name]} for name, path in paths.items()
        }


def run(
    archive_path: Path,
    runs: int,
    warmup: int,
    receipt_path: Path,
    *,
    rank: int = 1,
    budget: int = 8,
) -> dict[str, object]:
    if runs <= 0 or warmup < 0:
        raise CorpusArchiveError("runs must be positive and warmup non-negative")
    profile = profile_name(rank, budget)
    if not receipt_path.parent.is_dir() or receipt_path.exists() or receipt_path.is_symlink():
        raise CorpusArchiveError("receipt parent must exist and destination must be new")
    artifact_paths = _artifact_paths(profile)
    before = _artifact_snapshot(artifact_paths)
    with staged_archive(archive_path) as (root, archive_receipt):
        command = [
            "mise",
            "exec",
            "--",
            "zig",
            "build",
            "crest",
            "--",
            "--rank",
            str(rank),
            "--budget",
            str(budget),
            "--runs",
            str(runs),
            "--warmup",
            str(warmup),
        ]
        environment = {
            "GIST_ROOTS": str(root),
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": os.environ.get("PATH", os.defpath),
            "TZ": "UTC",
        }
        started_at = datetime.now(UTC).isoformat().replace("+00:00", "Z")
        completed = subprocess.run(
            command,
            cwd=REPO,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        transcript = completed.stdout
        if completed.returncode:
            raise CorpusArchiveError(
                f"CREST corpus benchmark failed with exit {completed.returncode}"
            )
        artifacts = _verify_artifacts(
            artifact_paths,
            before,
            rank,
            budget,
            profile,
            runs,
            warmup,
        )
        receipt = {
            **archive_receipt,
            "run": {
                "started_at_utc": started_at,
                "argv": command,
                "cwd": ".",
                "profile": profile,
                "rank": rank,
                "budget": budget,
                "runs": runs,
                "warmup": warmup,
                "exit_code": completed.returncode,
                "transcript_sha256": hashlib.sha256(transcript).hexdigest(),
                "artifacts": artifacts,
                "promotion": {
                    "eligible": False,
                    "authorization": "none",
                    "q4_blocked": rank == 4,
                },
            },
        }
    with receipt_path.open("x") as destination:
        json.dump(receipt, destination, indent=2, sort_keys=True)
        destination.write("\n")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inspect = commands.add_parser("inspect", help="validate and fingerprint without benchmarking")
    inspect.add_argument("--archive", required=True, type=Path)
    execute = commands.add_parser("run", help="stage the ZIP and run one ranked proof")
    execute.add_argument("--archive", required=True, type=Path)
    execute.add_argument("--rank", type=int, choices=SUPPORTED_RANKS, default=1)
    execute.add_argument("--budget", type=int, choices=SUPPORTED_BUDGETS, default=8)
    execute.add_argument("--runs", type=int, default=20)
    execute.add_argument("--warmup", type=int, default=3)
    execute.add_argument("--receipt", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "inspect":
            print(json.dumps(inspect_archive(args.archive), indent=2, sort_keys=True))
        else:
            print(
                json.dumps(
                    run(
                        args.archive,
                        args.runs,
                        args.warmup,
                        args.receipt,
                        rank=args.rank,
                        budget=args.budget,
                    ),
                    indent=2,
                    sort_keys=True,
                )
            )
        return 0
    except (CorpusArchiveError, OSError, zipfile.BadZipFile) as error:
        print(f"CREST corpus archive error: {error}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

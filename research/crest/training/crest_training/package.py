"""Read CREST training packages in place and fail closed on unsafe inputs."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import struct
import zipfile
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import BinaryIO

from .source import SourceOpenError, open_beneath, open_regular

TRACE_ROOT = PurePosixPath("data/entireio_trace_v1")
PARTITION_MEMBERS = {
    "train": TRACE_ROOT / "train.jsonl",
    "validation": TRACE_ROOT / "validation.jsonl",
    "test": TRACE_ROOT / "test.jsonl",
    "excluded": TRACE_ROOT / "excluded_cross_boundary.jsonl",
}
SEALED_MEMBERS = frozenset({PARTITION_MEMBERS["test"], PARTITION_MEMBERS["excluded"]})
MANIFEST_MEMBER = TRACE_ROOT / "manifest.json"
CHECKSUMS_MEMBER = PurePosixPath("CHECKSUMS.sha256")
ANALYSIS_MEMBERS = frozenset(
    {
        CHECKSUMS_MEMBER,
        MANIFEST_MEMBER,
        PARTITION_MEMBERS["train"],
        PARTITION_MEMBERS["validation"],
    }
)
MAX_ARCHIVE_BYTES = 64 << 20
MAX_MEMBER_BYTES = 32 << 20
MAX_COMPRESSION_RATIO = 200
MAX_PACKAGE_MEMBERS = 4096
MAX_PACKAGE_DIRECTORIES = 256
MAX_ZERO_BYTE_MEMBERS = 256
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
_EOCD = struct.Struct("<4s4H2LH")
_CENTRAL_DIRECTORY = struct.Struct("<4s6H3L5H2L")


class TrainingError(Exception):
    """A fail-closed training-tool error with a stable CLI category."""

    category = "training_error"


class InputSafetyError(TrainingError):
    category = "unsafe_input"


class IntegrityError(TrainingError):
    category = "integrity_error"


class SchemaError(TrainingError):
    category = "schema_error"


class CorpusEvidenceRequiredError(TrainingError):
    category = "corpus_evidence_required"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_stream(source: BinaryIO) -> str:
    digest = hashlib.sha256()
    for chunk in iter(lambda: source.read(1 << 20), b""):
        digest.update(chunk)
    return digest.hexdigest()


def is_strict_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def canonical_json_sha256(value: object) -> str:
    raw = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode()
    return sha256_bytes(raw)


def _safe_relative(name: str | PurePosixPath) -> PurePosixPath:
    raw = str(name)
    path = PurePosixPath(raw)
    if (
        not raw
        or "\x00" in raw
        or "\\" in raw
        or raw.startswith("/")
        or "//" in raw
        or path.is_absolute()
        or any(part in {"", ".", ".."} for part in path.parts)
        or (path.parts and ":" in path.parts[0])
    ):
        raise InputSafetyError("package member path is non-canonical or unsafe")
    return path


def _zip_end_record(source: BinaryIO) -> tuple[int, int, int]:
    source.seek(0, os.SEEK_END)
    size = source.tell()
    source.seek(max(0, size - (0xFFFF + _EOCD.size)))
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
                    raise InputSafetyError("multi-disk ZIP packages are forbidden")
                if total_entries == 0xFFFF:
                    raise InputSafetyError("ZIP64 package directories are forbidden")
                if total_entries > MAX_PACKAGE_MEMBERS:
                    raise InputSafetyError("archive exceeds member-count limit")
                if central_offset + central_size > size:
                    raise InputSafetyError(
                        "ZIP central directory exceeds archive bounds"
                    )
                return total_entries, central_offset, central_size
        offset = tail.rfind(b"PK\x05\x06", 0, offset)
    raise InputSafetyError("package is not a canonical ZIP archive")


def _preflight_zip(source: BinaryIO) -> None:
    """Bound central-directory work before ZipFile allocates per-entry state."""
    entries, offset, size = _zip_end_record(source)
    source.seek(offset)
    consumed = directories = zero_bytes = 0
    for _ in range(entries):
        header = source.read(_CENTRAL_DIRECTORY.size)
        if len(header) != _CENTRAL_DIRECTORY.size:
            raise InputSafetyError("ZIP central directory is truncated")
        fields = _CENTRAL_DIRECTORY.unpack(header)
        if fields[0] != b"PK\x01\x02":
            raise InputSafetyError("ZIP central directory entry is malformed")
        uncompressed_size = fields[9]
        name_length, extra_length, comment_length = fields[10:13]
        name = source.read(name_length)
        if len(name) != name_length:
            raise InputSafetyError("ZIP central directory name is truncated")
        source.seek(extra_length + comment_length, os.SEEK_CUR)
        consumed += (
            _CENTRAL_DIRECTORY.size + name_length + extra_length + comment_length
        )
        is_directory = name.endswith(b"/")
        directories += is_directory
        zero_bytes += not is_directory and uncompressed_size == 0
        if directories > MAX_PACKAGE_DIRECTORIES:
            raise InputSafetyError("archive exceeds directory-entry limit")
        if zero_bytes > MAX_ZERO_BYTE_MEMBERS:
            raise InputSafetyError("archive exceeds zero-byte member limit")
    if consumed != size:
        raise InputSafetyError("ZIP central directory size is inconsistent")


def _validate_archive_members(
    infos: Sequence[zipfile.ZipInfo],
) -> tuple[str, frozenset[str], frozenset[str]]:
    if len(infos) > MAX_PACKAGE_MEMBERS:
        raise InputSafetyError("archive exceeds member-count limit")
    names: set[str] = set()
    files: set[str] = set()
    folded: set[str] = set()
    total = directories = zero_bytes = 0
    for info in infos:
        trimmed = info.filename.rstrip("/")
        if not trimmed:
            continue
        canonical = str(_safe_relative(trimmed))
        if canonical != trimmed:
            raise InputSafetyError("archive member path is not canonical")
        lowered = canonical.casefold()
        if canonical in names or lowered in folded:
            raise InputSafetyError(
                "archive contains duplicate or case-colliding members"
            )
        names.add(canonical)
        folded.add(lowered)
        mode = (info.external_attr >> 16) & 0o170000
        if mode == stat.S_IFLNK:
            raise InputSafetyError("archive symlinks are forbidden")
        if info.flag_bits & 0x1:
            raise InputSafetyError("encrypted archive members are forbidden")
        if info.is_dir():
            directories += 1
            if directories > MAX_PACKAGE_DIRECTORIES:
                raise InputSafetyError("archive exceeds directory-entry limit")
            continue
        files.add(canonical)
        total += info.file_size
        zero_bytes += info.file_size == 0
        if zero_bytes > MAX_ZERO_BYTE_MEMBERS:
            raise InputSafetyError("archive exceeds zero-byte member limit")
        if info.file_size > MAX_MEMBER_BYTES or total > MAX_ARCHIVE_BYTES:
            raise InputSafetyError("archive exceeds CREST evidence size limits")
        if (
            info.file_size > 1 << 20
            and info.file_size / max(info.compress_size, 1) > MAX_COMPRESSION_RATIO
        ):
            raise InputSafetyError("archive member exceeds compression-ratio limit")
    suffix = str(MANIFEST_MEMBER)
    roots = {
        name[: -len(suffix)].rstrip("/")
        for name in names
        if name == suffix or name.endswith(f"/{suffix}")
    }
    if len(roots) != 1:
        raise SchemaError("archive must contain exactly one CREST trace manifest")
    root = roots.pop()
    prefix = f"{root}/" if root else ""
    if any(prefix and name != root and not name.startswith(prefix) for name in names):
        raise SchemaError("archive members must share the CREST package root")
    relative_files = frozenset(name.removeprefix(prefix) for name in files)
    return root, frozenset(names), relative_files


def _validate_directory(root: Path) -> frozenset[str]:
    files: set[str] = set()
    folded: set[str] = set()
    stack = [root]
    total = directories = zero_bytes = 0
    while stack:
        directory = stack.pop()
        try:
            entries = os.scandir(directory)
        except OSError as error:
            raise InputSafetyError(
                "package directory cannot be inspected safely"
            ) from error
        with entries:
            for entry in entries:
                path = Path(entry.path)
                if entry.is_symlink():
                    raise InputSafetyError("package symlinks are forbidden")
                relative = path.relative_to(root).as_posix()
                canonical = str(_safe_relative(relative))
                lowered = canonical.casefold()
                if lowered in folded:
                    raise InputSafetyError("package contains case-colliding members")
                folded.add(lowered)
                if entry.is_dir(follow_symlinks=False):
                    directories += 1
                    if directories > MAX_PACKAGE_DIRECTORIES:
                        raise InputSafetyError("package exceeds directory-entry limit")
                    stack.append(path)
                    continue
                if not entry.is_file(follow_symlinks=False):
                    raise InputSafetyError("package contains a non-regular member")
                info = entry.stat(follow_symlinks=False)
                files.add(canonical)
                total += info.st_size
                zero_bytes += info.st_size == 0
                if len(files) > MAX_PACKAGE_MEMBERS:
                    raise InputSafetyError("package exceeds member-count limit")
                if zero_bytes > MAX_ZERO_BYTE_MEMBERS:
                    raise InputSafetyError("package exceeds zero-byte member limit")
                if info.st_size > MAX_MEMBER_BYTES or total > MAX_ARCHIVE_BYTES:
                    raise InputSafetyError("package exceeds CREST evidence size limits")
    return frozenset(files)


def _parse_checksums(raw: bytes) -> dict[PurePosixPath, str]:
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise SchemaError("package checksum manifest is not UTF-8") from error
    checksums: dict[PurePosixPath, str] = {}
    for line_number, line in enumerate(lines, 1):
        if not line:
            continue
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            raise SchemaError(f"checksum manifest line {line_number} is malformed")
        member = _safe_relative(match.group(2))
        if member in checksums:
            raise SchemaError("checksum manifest contains duplicate members")
        checksums[member] = match.group(1)
    return checksums


@dataclass(frozen=True)
class PackageReceipt:
    source_kind: str
    package_sha256: str
    checksums_sha256: str

    def as_dict(self) -> dict[str, str]:
        return {
            "source_kind": self.source_kind,
            "package_sha256": self.package_sha256,
            "checksums_sha256": self.checksums_sha256,
        }


class DataPackage:
    """A fixed-root package reader that never exposes test or excluded data."""

    def __init__(self, source: str | Path) -> None:
        self._source = Path(source)
        self._archive_root = ""
        self._archive_names: frozenset[str] = frozenset()
        self._archive: zipfile.ZipFile | None = None
        self._archive_source: BinaryIO | None = None
        self._verified = False
        if self._source.is_dir():
            self._kind = "directory"
            if self._source.is_symlink():
                raise InputSafetyError("package root must not be a symlink")
            self._member_files = _validate_directory(self._source)
            self._package_digest = ""
        else:
            self._open_archive()
        self._checksums_raw = self._read_member(CHECKSUMS_MEMBER, allow_sealed=True)
        self._checksums = _parse_checksums(self._checksums_raw)
        self.verify_integrity()

    def _open_archive(self) -> None:
        try:
            source = open_regular(self._source)
        except SourceOpenError as error:
            raise InputSafetyError(
                "package source must be a directory or ZIP archive"
            ) from error
        try:
            _preflight_zip(source)
            source.seek(0)
            package_digest = _sha256_stream(source)
            source.seek(0)
            archive = zipfile.ZipFile(source)
            root, names, files = _validate_archive_members(archive.filelist)
        except (zipfile.BadZipFile, zipfile.LargeZipFile, OSError) as error:
            source.close()
            raise InputSafetyError(
                "package source is not a safe ZIP archive"
            ) from error
        except (InputSafetyError, SchemaError):
            source.close()
            raise
        self._kind = "zip"
        self._archive_root = root
        self._archive_names = names
        self._member_files = files
        self._package_digest = package_digest
        self._archive_source = source
        self._archive = archive

    def _archive_name(self, member: PurePosixPath) -> str:
        return f"{self._archive_root}/{member}" if self._archive_root else str(member)

    @contextmanager
    def _directory_stream(self, member: PurePosixPath) -> Iterator[BinaryIO]:
        try:
            with open_beneath(self._source, member.parts) as source:
                yield source
        except SourceOpenError as error:
            raise InputSafetyError(
                f"package member is missing or not regular: {member}"
            ) from error

    @contextmanager
    def _member_stream(
        self,
        member: str | PurePosixPath,
        *,
        allow_sealed: bool,
    ) -> Iterator[BinaryIO]:
        relative = _safe_relative(member)
        if relative in SEALED_MEMBERS and not allow_sealed:
            raise InputSafetyError("test and excluded partitions are sealed")
        if str(relative) not in self._member_files:
            raise SchemaError(f"package member is missing: {relative}")
        if self._kind == "zip":
            if self._archive is None:
                raise IntegrityError("ZIP package reader is closed")
            name = self._archive_name(relative)
            if name not in self._archive_names:
                raise SchemaError(f"package member is missing: {relative}")
            with self._archive.open(name) as source:
                yield source
            return
        with self._directory_stream(relative) as source:
            yield source

    def _read_member(self, member: str | PurePosixPath, *, allow_sealed: bool) -> bytes:
        with self._member_stream(member, allow_sealed=allow_sealed) as source:
            raw = source.read(MAX_MEMBER_BYTES + 1)
        if len(raw) > MAX_MEMBER_BYTES:
            raise InputSafetyError("package member exceeds CREST evidence size limits")
        return raw

    def read(self, member: str | PurePosixPath) -> bytes:
        if _safe_relative(member) not in ANALYSIS_MEMBERS:
            raise InputSafetyError("package member is sealed from analysis")
        return self._read_member(member, allow_sealed=False)

    def read_partition(self, role: str) -> bytes:
        if role not in {"train", "validation"}:
            raise InputSafetyError("analysis role must be train or validation")
        return self.read(PARTITION_MEMBERS[role])

    def verify_integrity(self) -> None:
        """Stream every declared member, including sealed partitions."""
        current_files = (
            self._member_files
            if self._kind == "zip"
            else _validate_directory(self._source)
        )
        if current_files != self._member_files:
            raise IntegrityError("package member set changed after inspection")
        checksums_raw = self._read_member(CHECKSUMS_MEMBER, allow_sealed=True)
        if checksums_raw != self._checksums_raw:
            raise IntegrityError("package checksum manifest changed after inspection")
        payloads = current_files - {str(CHECKSUMS_MEMBER)}
        declared = {str(member) for member in self._checksums}
        if payloads != declared:
            raise IntegrityError("checksum manifest and package member sets differ")
        required = {MANIFEST_MEMBER, *PARTITION_MEMBERS.values()}
        missing = sorted(str(member) for member in required - set(self._checksums))
        if missing:
            raise SchemaError(
                f"checksum manifest does not bind required member: {missing[0]}"
            )
        for member, expected in self._checksums.items():
            with self._member_stream(member, allow_sealed=True) as source:
                observed = _sha256_stream(source)
            if observed != expected:
                raise IntegrityError(f"package checksum drift for {member}")
        self._verified = True

    def verify_required_checksums(self) -> None:
        self.verify_integrity()

    def verified_checksum(self, member: str | PurePosixPath) -> str:
        if not self._verified:
            raise IntegrityError("package checksum verification has not completed")
        relative = _safe_relative(member)
        try:
            return self._checksums[relative]
        except KeyError as error:
            raise SchemaError(f"checksum manifest does not bind {relative}") from error

    def receipt(self) -> PackageReceipt:
        if not self._verified:
            raise IntegrityError("package receipt requires verified integrity")
        package_digest = self._package_digest or canonical_json_sha256(
            {str(member): digest for member, digest in self._checksums.items()}
        )
        return PackageReceipt(
            self._kind,
            package_digest,
            sha256_bytes(self._checksums_raw),
        )

    def close(self) -> None:
        if self._archive is not None:
            self._archive.close()
            self._archive = None
        if self._archive_source is not None:
            self._archive_source.close()
            self._archive_source = None

    def __del__(self) -> None:
        self.close()

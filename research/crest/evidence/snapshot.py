"""Capture publication artifacts once through confined file descriptors."""

from __future__ import annotations

import os
import stat
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType

MAX_SNAPSHOT_FILES = 4096
MAX_SNAPSHOT_BYTES = 256 << 20


class SnapshotError(OSError):
    pass


@dataclass(frozen=True)
class ArtifactSnapshot:
    files: Mapping[str, bytes]


@dataclass(frozen=True)
class _OpenEntry:
    descriptor: int
    parent: int | None
    name: str | Path
    metadata: os.stat_result
    directory: bool


def _metadata(path: str | Path, parent: int | None) -> os.stat_result:
    return os.stat(path, dir_fd=parent, follow_symlinks=False)


def _identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _open(path: str | Path, *, parent: int | None, directory: bool) -> _OpenEntry:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NONBLOCK", 0)
        | nofollow
        | (getattr(os, "O_DIRECTORY", 0) if directory else 0)
    )
    try:
        before = _metadata(path, parent) if not nofollow else None
        descriptor = os.open(path, flags, dir_fd=parent)
    except OSError as error:
        raise SnapshotError("artifact entry could not be opened safely") from error
    try:
        opened = os.fstat(descriptor)
        expected = stat.S_ISDIR if directory else stat.S_ISREG
        if not expected(opened.st_mode):
            raise SnapshotError("artifact entry has an unsafe type")
        if before is not None:
            after = _metadata(path, parent)
            identity = (opened.st_dev, opened.st_ino)
            if (
                stat.S_ISLNK(before.st_mode)
                or stat.S_ISLNK(after.st_mode)
                or (before.st_dev, before.st_ino) != identity
                or (after.st_dev, after.st_ino) != identity
            ):
                raise SnapshotError("artifact entry changed while opening")
        return _OpenEntry(descriptor, parent, path, opened, directory)
    except Exception:
        os.close(descriptor)
        raise


def _assert_stable(entry: _OpenEntry) -> None:
    try:
        opened = os.fstat(entry.descriptor)
        current = _metadata(entry.name, entry.parent)
    except OSError as error:
        raise SnapshotError("artifact entry changed during capture") from error
    expected = stat.S_ISDIR if entry.directory else stat.S_ISREG
    if (
        not expected(current.st_mode)
        or _identity(opened) != _identity(entry.metadata)
        or (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
    ):
        raise SnapshotError("artifact entry changed during capture")


@contextmanager
def capture(root: Path) -> Iterator[ArtifactSnapshot]:
    entries: list[_OpenEntry] = []
    files: dict[str, bytes] = {}
    total = 0

    def walk(directory: _OpenEntry, prefix: str) -> None:
        nonlocal total
        try:
            names = sorted(os.listdir(directory.descriptor))
        except OSError as error:
            raise SnapshotError("artifact directory cannot be listed safely") from error
        for name in names:
            if "/" in name or "\\" in name or "\0" in name:
                raise SnapshotError("artifact entry name is unsafe")
            try:
                metadata = _metadata(name, directory.descriptor)
            except OSError as error:
                raise SnapshotError("artifact entry changed during capture") from error
            relative = f"{prefix}/{name}" if prefix else name
            if stat.S_ISLNK(metadata.st_mode):
                raise SnapshotError(f"artifact symlinks are forbidden: {relative}")
            if stat.S_ISDIR(metadata.st_mode):
                child = _open(name, parent=directory.descriptor, directory=True)
                entries.append(child)
                walk(child, relative)
                continue
            entry = _open(name, parent=directory.descriptor, directory=False)
            entries.append(entry)
            if len(files) >= MAX_SNAPSHOT_FILES:
                raise SnapshotError("artifact snapshot exceeds file-count limit")
            chunks: list[bytes] = []
            size = 0
            while chunk := os.read(entry.descriptor, 1 << 20):
                size += len(chunk)
                total += len(chunk)
                if size > MAX_SNAPSHOT_BYTES or total > MAX_SNAPSHOT_BYTES:
                    raise SnapshotError("artifact snapshot exceeds byte limit")
                chunks.append(chunk)
            files[relative] = b"".join(chunks)

    try:
        root_entry = _open(root, parent=None, directory=True)
        entries.append(root_entry)
        walk(root_entry, "")
        yield ArtifactSnapshot(MappingProxyType(files))
        for entry in reversed(entries):
            _assert_stable(entry)
    finally:
        for entry in reversed(entries):
            os.close(entry.descriptor)

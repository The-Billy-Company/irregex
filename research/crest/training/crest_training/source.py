"""Race-safe descriptor opening for untrusted CREST package sources."""

from __future__ import annotations

import os
import stat
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from pathlib import Path
from typing import BinaryIO


class SourceOpenError(OSError):
    pass


def _metadata(path: str | Path, dir_fd: int | None) -> os.stat_result:
    return os.stat(path, dir_fd=dir_fd, follow_symlinks=False)


def _open_checked(
    path: str | Path,
    *,
    directory: bool,
    dir_fd: int | None = None,
) -> int:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NONBLOCK", 0)
        | nofollow
        | (getattr(os, "O_DIRECTORY", 0) if directory else 0)
    )
    try:
        before = _metadata(path, dir_fd) if not nofollow else None
        descriptor = os.open(path, flags, dir_fd=dir_fd)
    except OSError as error:
        raise SourceOpenError("package source could not be opened safely") from error
    try:
        opened = os.fstat(descriptor)
        expected = stat.S_ISDIR if directory else stat.S_ISREG
        if not expected(opened.st_mode):
            raise SourceOpenError("package source has an unsafe entry type")
        if before is not None:
            after = _metadata(path, dir_fd)
            identity = (opened.st_dev, opened.st_ino)
            if (
                stat.S_ISLNK(before.st_mode)
                or stat.S_ISLNK(after.st_mode)
                or (before.st_dev, before.st_ino) != identity
                or (after.st_dev, after.st_ino) != identity
            ):
                raise SourceOpenError("package source changed while opening")
        return descriptor
    except SourceOpenError:
        os.close(descriptor)
        raise
    except OSError as error:
        os.close(descriptor)
        raise SourceOpenError("package source changed while opening") from error


def open_regular(path: Path) -> BinaryIO:
    """Open without blocking or following a path replacement."""
    return os.fdopen(_open_checked(path, directory=False), "rb")


@contextmanager
def open_beneath(root: Path, parts: Sequence[str]) -> Iterator[BinaryIO]:
    """Open one regular member through confined directory descriptors."""
    if not parts:
        raise SourceOpenError("package member path is empty")
    directories: list[int] = []
    try:
        parent = _open_checked(root, directory=True)
        directories.append(parent)
        for part in parts[:-1]:
            parent = _open_checked(part, directory=True, dir_fd=parent)
            directories.append(parent)
        member = _open_checked(parts[-1], directory=False, dir_fd=parent)
        with os.fdopen(member, "rb") as source:
            yield source
    finally:
        for descriptor in reversed(directories):
            os.close(descriptor)

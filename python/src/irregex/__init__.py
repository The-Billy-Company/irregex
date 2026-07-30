"""Python integration for the native irregex engine."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

__all__ = ["ExecutableNotFound", "executable", "records", "run"]
__version__ = "0.1.0"


class ExecutableNotFound(FileNotFoundError):
    """Raised when the native irregex executable cannot be located."""


def executable() -> str:
    """Return the configured native irregex executable."""
    if configured := os.environ.get("IRREGEX_BIN"):
        path = Path(configured).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
        raise ExecutableNotFound(f"IRREGEX_BIN is not executable: {path}")

    if found := shutil.which("irregex"):
        return found
    raise ExecutableNotFound(
        "irregex is not installed; build the native engine or set IRREGEX_BIN"
    )


def run(
    *arguments: str,
    check: bool = True,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Run the native irregex CLI with text-mode I/O."""
    return subprocess.run(
        [executable(), *arguments],
        check=check,
        capture_output=capture_output,
        text=True,
    )


def records(*arguments: str) -> list[dict[str, Any]]:
    """Run an irregex verb in JSON mode and decode its NDJSON records."""
    result = run(*arguments, "--json")
    return [json.loads(line) for line in result.stdout.splitlines() if line]

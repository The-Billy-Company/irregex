"""Test fixtures, and the one piece of setup the suite needs.

Running from a source checkout, the package has no bundled library yet - that
is placed by the build hook when a wheel is made. So point ``IRGX_LIB`` at
the engine's own build, using exactly the override a user would. Running against
an installed wheel, the bundled library is present and nothing here fires, which
is what makes the same suite valid in both places.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

_TESTS = Path(__file__).resolve().parent
_PACKAGE = _TESTS.parent / "irgx"
_ENGINE = _TESTS.parents[2]

_NAMES = ("libirgx.dylib", "libirgx.so", "irgx.dll")


def _point_at_the_engine_build() -> None:
    if os.environ.get("IRGX_LIB"):
        return
    if any((_PACKAGE / "lib" / name).is_file() for name in _NAMES):
        return
    for folder in ("lib", "bin"):
        for name in _NAMES:
            candidate = _ENGINE / "zig-out" / folder / name
            if candidate.is_file():
                os.environ["IRGX_LIB"] = str(candidate)
                return


_point_at_the_engine_build()


@pytest.fixture(scope="session")
def gist_spans():
    """Spans that ``gist --json`` reports for a pattern over one line of text.

    The header names ``gist --json`` as the authority for what a match sequence
    is, so where the tool is available the suite checks against it rather than
    only against its own expectations.

    gist's unit is a line *including* its newline, where this binding's unit is
    exactly the buffer it was handed. So the caller passes the line without a
    newline and this appends one, which is the same bytes gist matched over.
    """
    if shutil.which("gist") is None:
        pytest.skip("gist is not on PATH")

    def spans(pattern: str, line: str, *extra: str) -> list[tuple[int, int]]:
        with_newline = line + "\n"
        directory = Path(os.environ["PYTEST_GIST_DIR"])
        subject = directory / "subject.txt"
        subject.write_text(with_newline, encoding="utf-8")
        done = subprocess.run(
            ["gist", "--json", *extra, "--", pattern, str(subject)],
            capture_output=True,
            text=True,
            check=False,
        )
        if done.returncode not in (0, 1):
            pytest.skip(f"gist refused this query: {done.stderr.strip()}")
        found: list[tuple[int, int]] = []
        for line_out in done.stdout.splitlines():
            record = json.loads(line_out)
            if record.get("type") != "match":
                continue
            for sub in record["data"]["submatches"]:
                found.append((sub["start"], sub["end"]))
        return found

    return spans


@pytest.fixture(scope="session", autouse=True)
def _gist_scratch(tmp_path_factory):
    os.environ["PYTEST_GIST_DIR"] = str(tmp_path_factory.mktemp("gist"))

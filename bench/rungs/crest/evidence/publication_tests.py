#!/usr/bin/env python3
"""Run every corpus-independent CREST publication gate."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
PYTHON = sys.executable
GATES = (
    (
        "oracle-fixture",
        (PYTHON, "research/crest/oracle/export_zig.py", "--check"),
        None,
    ),
    (
        "oracle",
        (
            "uv",
            "run",
            "--project",
            "bindings/python",
            "--python",
            "3.13",
            "--only-group",
            "dev",
            "python",
            "-m",
            "pytest",
            "research/crest/oracle/tests",
            "-q",
        ),
        None,
    ),
    (
        "training",
        (
            PYTHON,
            "-m",
            "unittest",
            "discover",
            "-s",
            "research/crest/training/tests",
            "-p",
            "test_*.py",
        ),
        {"PYTHONPATH": "research/crest/training"},
    ),
    (
        "publication",
        (
            PYTHON,
            "-m",
            "unittest",
            "discover",
            "-s",
            "research/crest/evidence",
            "-p",
            "test_*.py",
        ),
        None,
    ),
    (
        "benchmark-evidence",
        (
            PYTHON,
            "-m",
            "unittest",
            "discover",
            "-s",
            "bench/rungs/crest/evidence",
            "-p",
            "test_*.py",
        ),
        None,
    ),
    (
        "mutation-harness",
        (
            PYTHON,
            "-m",
            "unittest",
            "discover",
            "-s",
            "research/crest/mutation",
            "-p",
            "test_*.py",
        ),
        None,
    ),
    ("zig", ("mise", "exec", "--", "zig", "build", "test", "--summary", "all"), None),
    ("mutants", (PYTHON, "research/crest/mutation/mutate.py"), None),
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--list", action="store_true", help="print the frozen gate slate"
    )
    arguments = parser.parse_args()
    if arguments.list:
        for name, command, _ in GATES:
            print(f"{name}: {' '.join(command)}")
        return 0

    for name, command, additions in GATES:
        print(f"\n== {name}: {' '.join(command)}", flush=True)
        environment = os.environ.copy()
        if additions:
            environment.update(additions)
        try:
            result = subprocess.run(command, cwd=ROOT, env=environment, check=False)
        except OSError as error:
            print(f"{name} could not start: {error}", file=sys.stderr)
            return 127
        if result.returncode:
            print(f"{name} failed with exit {result.returncode}", file=sys.stderr)
            return result.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

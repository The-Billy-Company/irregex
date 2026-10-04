"""Reuse a release export under its producer's target and current version contract."""

import runpy
from pathlib import Path

ENGINE = Path(__file__).resolve().parent.parent


def reuse_archive(root: Path, triple: str, cpu: str, destination: Path) -> None:
    """Copy a matching export into private staging; missing or stale is a failure.

    Load the existing authorities only on this explicit input path. The wheel
    producer also loads vendor scripts to find binutils; importing its CLI at
    module load would turn that direction into a cycle.
    """
    producer = runpy.run_path(str(ENGINE / "bindings/python/scripts/build_wheels.py"))
    matches = [target for target in producer["MATRIX"] if (target.zig, target.cpu) == (triple, cpu)]
    if len(matches) != 1:
        raise ValueError(f"no unique release archive producer for {triple} ({cpu})")
    source = root / matches[0].name / "libirgx.a"
    blob = source.read_bytes()  # No missing-input fallback to a local build.
    parity = runpy.run_path(str(ENGINE / "quality/parity/check.py"))
    version = parity["declared_version"]()
    if not version or version not in parity["stamped"](blob):
        raise ValueError(f"{source} does not carry this tree's engine version {version}")
    # Validate the bytes we write, not a source that could change between reads.
    # The caller still proves the C floor and consumer link before publishing it.
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(blob)

"""What the published package has to carry, beyond being importable."""

from __future__ import annotations

import sys
from pathlib import Path

PACKAGE = "irgx"

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from build_wheels import accel_shortfall, native_target  # noqa: E402


def test_the_package_declares_its_annotations_to_consumers():
    """Every function in this package is annotated, and PEP 561 says a consumer's
    type checker must ignore all of it unless the package ships this marker. So the
    failure mode is silent in both directions: nothing here breaks, and everyone
    downstream quietly gets `Any` for the whole API."""
    package = Path(__file__).resolve().parents[1] / PACKAGE
    assert (package / "py.typed").is_file(), (
        f"{PACKAGE} annotates its public API and then hides it: no py.typed marker"
    )


def _wheels(*names: str) -> list[Path]:
    return [Path(f"dist/irregex-9.9.9-{name}.whl") for name in names]


PORTABLE = ("py3-none-macosx_11_0_arm64", "py3-none-manylinux_2_17_x86_64")
ACCELERATED = "cp312-abi3-macosx_11_0_arm64"


def test_a_portable_only_matrix_is_refused():
    """2.0.0 and 2.1.x shipped with no accelerated wheel, so every `pip install`
    silently got ctypes: same answers, no error, and ~11x slower than stdlib `re`
    on a real consumer's per-row loop. The release script exits 0 on that matrix
    unless something refuses it, and the two ways in are both quiet - a host
    outside the matrix never attempts the accelerated build, and a host inside it
    can fail that one build while its portable twin succeeds."""
    assert accel_shortfall(_wheels(*PORTABLE), native_target(), None) is not None
    # And the refusal has to say which of the two happened, since the fix differs:
    # publish from a listed host, or repair the compiler on this one.
    outside = accel_shortfall(_wheels(*PORTABLE), None, None)
    assert outside and "not in" in outside


def test_an_accelerated_matrix_and_a_narrow_build_are_both_fine():
    """One accelerated wheel is the whole requirement - pip prefers it where it
    fits and falls back to the portable ones elsewhere, which is what makes the
    accelerator an optimization rather than a narrowing of who can install.

    A deliberately narrow `--only` is not a release, so it is left alone; so is
    an empty matrix, which is a build that produced nothing and has already
    failed louder than this."""
    here = native_target()
    assert accel_shortfall(_wheels(*PORTABLE, ACCELERATED), here, None) is None
    assert accel_shortfall(_wheels(*PORTABLE), here, ["linux-x86_64"]) is None
    assert accel_shortfall([], here, None) is None

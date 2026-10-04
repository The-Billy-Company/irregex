"""What the published package has to carry, beyond being importable."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

PACKAGE = "irgx"

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "scripts"))
sys.path.insert(0, str(PROJECT))

from build_wheels import accel_shortfall, native_target  # noqa: E402

from hatch_build import IrregexBuildHook, toolchain  # noqa: E402


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


@pytest.mark.parametrize(
    ("tag", "target"),
    [
        ("macosx_11_0_arm64", "aarch64-macos.11.0"),
        ("macosx_12_3_arm64", "aarch64-macos.12.3"),
        ("macosx_10_15_x86_64", "x86_64-macos.10.15"),
        ("macosx_15_6_x86_64", "x86_64-macos.15.6"),
        ("manylinux_2_17_x86_64", None),
        ("win_arm64", None),
    ],
)
def test_the_macos_floor_comes_from_the_tag_not_the_build_host(tag, target):
    assert toolchain.macos_target(tag) == target


@pytest.mark.parametrize("tag", ["macosx_11_0_universal2", "macosx_bad_0_arm64"])
def test_an_unbuildable_macos_tag_is_refused(tag):
    # A single-slice Zig build cannot promise the interpreter's universal tag.
    with pytest.raises(RuntimeError, match="unsupported macOS wheel platform"):
        toolchain.macos_target(tag)


@pytest.mark.parametrize(
    ("arch", "target"),
    [("arm64", "aarch64-macos.11.0"), ("x86_64", "x86_64-macos.10.9")],
)
def test_a_bare_source_build_binds_its_corrected_interpreter_tag(monkeypatch, arch, target):
    monkeypatch.delenv("IRGX_WHEEL_PLATFORM", raising=False)
    monkeypatch.setattr(toolchain.sysconfig, "get_platform", lambda: "macosx-10.9-universal2")
    monkeypatch.setattr(toolchain.platform, "machine", lambda: arch)
    assert toolchain.macos_target(IrregexBuildHook._platform_tag()) == target


@pytest.mark.parametrize(
    ("tag", "target"),
    [
        ("macosx_11_0_arm64", "aarch64-linux-gnu.2.17"),
        ("manylinux_2_17_x86_64", "x86_64-macos.11.0"),
    ],
)
def test_a_macos_target_cannot_wear_another_platforms_tag(monkeypatch, tmp_path, tag, target):
    monkeypatch.setenv("IRGX_WHEEL_PLATFORM", tag)
    monkeypatch.setenv("IRGX_ZIG_TARGET", target)
    hook = IrregexBuildHook(str(PROJECT), {}, None, None, str(tmp_path), "wheel")
    with pytest.raises(RuntimeError, match="does not fit wheel platform"):
        hook.initialize("standard", {})

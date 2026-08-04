"""`irgx.runtime.shell` binary resolution — env override, dev checkout, bundled wheel, PATH.

Each rung is proved by making exactly one of them findable and asserting
`_resolve` returns THAT one, not a plausible-looking neighbour. `_resolve` is
`functools.cache`d, so every test names a binary that no other test (and
nothing on this machine) would otherwise resolve, and clears the cache after
itself rather than sharing state through import order.
"""

from __future__ import annotations

import os
import stat
import sys

import pytest
from irgx.runtime import shell
from irgx.runtime.errors import GistNotFoundError


@pytest.fixture(autouse=True)
def _clear_resolve_cache():
    shell._resolve.cache_clear()
    yield
    shell._resolve.cache_clear()


@pytest.fixture
def no_checkout(monkeypatch: pytest.MonkeyPatch) -> None:
    """Nothing under `zig-out`, no sibling `build.zig` — every test here is
    proving the rungs BELOW the dev-checkout one, so that rung has to be shut
    off deliberately rather than accidentally winning on this machine."""
    monkeypatch.setattr(shell, "_locate_root", lambda name: None)


def _fake_binary(tmp_path, pkg_name: str, bin_name: str):
    """A minimal installed package on `sys.path`: `<pkg>/bin/<bin_name>`, mode +x."""
    pkg = tmp_path / pkg_name
    (pkg / "bin").mkdir(parents=True)
    binary = pkg / "bin" / bin_name
    binary.write_text("#!/bin/sh\necho fake\n")
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
    (pkg / "__init__.py").write_text("")
    return pkg, binary


def test_bundled_is_none_for_a_package_that_does_not_exist():
    assert shell._bundled("no-such-package-anywhere-xyz") is None


def test_bundled_is_none_when_the_package_has_no_bin_dir(tmp_path, monkeypatch):
    pkg = tmp_path / "bareimport"
    pkg.mkdir()
    (pkg / "__init__.py").write_text("")
    monkeypatch.syspath_prepend(str(tmp_path))
    assert shell._bundled("bareimport") is None


def test_bundled_finds_the_binary_the_wheel_would_have_placed(tmp_path, monkeypatch):
    # Package name == binary name, same as the real `gist`/`relate`/`blast`
    # distributions — `_bundled` has no other way to connect the two.
    pkg_name = "fakegistcli"
    exe_name = f"{pkg_name}.exe" if sys.platform == "win32" else pkg_name
    _, binary = _fake_binary(tmp_path, pkg_name, exe_name)
    monkeypatch.syspath_prepend(str(tmp_path))
    found = shell._bundled(pkg_name)
    assert found is not None
    assert found.resolve() == binary.resolve()


def test_resolve_prefers_bundled_over_path(tmp_path, monkeypatch, no_checkout):
    binary_name = "irgx-test-prefers-bundled"
    exe_name = f"{binary_name}.exe" if sys.platform == "win32" else binary_name
    _fake_binary(tmp_path, binary_name, exe_name)
    monkeypatch.syspath_prepend(str(tmp_path))

    # A DIFFERENT binary that would win if PATH were consulted first — proves
    # this is testing precedence, not merely "bundled resolves at all".
    on_path_dir = tmp_path / "on-path"
    on_path_dir.mkdir()
    decoy = on_path_dir / (exe_name if sys.platform != "win32" else exe_name)
    decoy.write_text("#!/bin/sh\necho decoy\n")
    decoy.chmod(decoy.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("PATH", f"{on_path_dir}{os.pathsep}{os.environ.get('PATH', '')}")

    got = shell._resolve(binary_name, "IRGX_TEST_UNUSED_ENV")
    assert got == str((tmp_path / binary_name / "bin" / exe_name).resolve())


def test_resolve_env_override_wins_over_bundled(tmp_path, monkeypatch, no_checkout):
    binary_name = "irgx-test-env-wins"
    exe_name = binary_name
    _fake_binary(tmp_path, binary_name, exe_name)
    monkeypatch.syspath_prepend(str(tmp_path))

    override = tmp_path / "explicit-override"
    override.write_text("#!/bin/sh\necho override\n")
    override.chmod(override.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("IRGX_TEST_ENV_WINS", str(override))

    assert shell._resolve(binary_name, "IRGX_TEST_ENV_WINS") == str(override)


def test_resolve_falls_through_to_path_with_nothing_bundled(monkeypatch, tmp_path, no_checkout):
    binary_name = "irgx-test-path-fallback"
    on_path_dir = tmp_path / "on-path"
    on_path_dir.mkdir()
    real = on_path_dir / binary_name
    real.write_text("#!/bin/sh\necho on-path\n")
    real.chmod(real.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("PATH", f"{on_path_dir}{os.pathsep}{os.environ.get('PATH', '')}")

    assert shell._resolve(binary_name, "IRGX_TEST_UNUSED_ENV_2") == str(real)


def test_resolve_fails_closed_when_nothing_resolves(monkeypatch, no_checkout):
    monkeypatch.delenv("PATH", raising=False)
    monkeypatch.setenv("PATH", "")
    with pytest.raises(GistNotFoundError):
        shell._resolve("irgx-test-nothing-anywhere", "IRGX_TEST_UNUSED_ENV_3")

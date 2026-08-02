"""The published package has to declare that its annotations are real."""

from __future__ import annotations

from pathlib import Path

PACKAGE = "irgx"
def test_the_package_declares_its_annotations_to_consumers():
    """Every function in this package is annotated, and PEP 561 says a consumer's
    type checker must ignore all of it unless the package ships this marker. So the
    failure mode is silent in both directions: nothing here breaks, and everyone
    downstream quietly gets `Any` for the whole API."""
    package = Path(__file__).resolve().parents[1] / PACKAGE
    assert (package / "py.typed").is_file(), (
        f"{PACKAGE} annotates its public API and then hides it: no py.typed marker"
    )

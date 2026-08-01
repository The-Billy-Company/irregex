"""The contract mirror in `irregex.contract` must not drift from the canonical
contracts, nor from the driven binary.

The canonical files are split by who authors what they describe: this repo's own
`contract/engine.toml` (request surface, match kinds, exit codes, version axes)
and `contract/analytic.toml` (wire schema, row plane, ABI vocabulary), plus
`gist/contract/surface.toml` (transports, tool boundary, published package
names), `relate/contract/kinship.toml` (the compression plane) and
`blast/contract/compose.toml` (the composed verbs). The ones we do not author
are reached in the sibling that does — see `contract_path`.

Reading them **fails closed**. It used to skip, on the reasoning that an
installed wheel legitimately ships without the repo file — true, but a test run
happens in a checkout, and when the locator silently resolved to a path that no
longer existed after the repo split, every assertion below stopped running and
the mirror drifted for months behind a green suite. A missing contract in a
checkout is now an error that names the file.
"""

from __future__ import annotations

import functools
import shutil

import pytest
import tomllib

from irregex.contract import abi as contract
from irregex.contract import table
from irregex.request import SearchRequest
from irregex.runtime import analytic as analytic_runtime
from irregex.runtime import shell as engine
from irregex.runtime.errors import GistNotFoundError


def _binary_available() -> bool:
    if shutil.which("gist") is not None:
        return True
    try:
        engine.binary()
    except GistNotFoundError:
        return False
    return True


_HAVE_BINARY = _binary_available()


@functools.cache
def _toml(name: str) -> dict:
    path = contract.contract_path(name)
    if not path.is_file():
        raise AssertionError(
            f"contract {name}.toml not found at {path}. The parity gate cannot run "
            f"without it; in a checkout, run `python3 tools/sync_contract.py` from "
            f"the repo root to restore the vendored copies."
        )
    with path.open("rb") as f:
        return tomllib.load(f)


def test_every_contract_is_readable() -> None:
    """The gate's own precondition, asserted once and by name.

    Without this, a contract going missing would surface as an unrelated-looking
    failure in whichever test happened to read it first.
    """
    for name in contract.CONTRACTS:
        assert _toml(name), f"{name}.toml parsed empty"


def test_meta_mirror_matches_toml() -> None:
    meta = _toml("engine")["meta"]
    assert meta["abi_version"] == contract.ABI_VERSION
    assert meta["engine_version"] == contract.ENGINE_VERSION


def test_package_names_mirror_toml() -> None:
    """The published artifact names are this repo's to declare, so they live in
    its own contract rather than the kernel's."""
    package = _toml("surface")["package"]
    assert package["dist"] == contract.PACKAGE_DIST
    assert package["import"] == contract.PACKAGE_IMPORT


def test_request_options_mirror_matches_toml() -> None:
    assert frozenset(_toml("engine")["request_options"]) == contract.REQUEST_OPTIONS


def test_request_options_match_dataclass_fields() -> None:
    """Every contract option is a real `SearchRequest` field, and every request
    field (bar the escape hatch) is a contract option.
    """
    fields = set(SearchRequest.__dataclass_fields__) - {"extra_flags"}
    assert fields == contract.REQUEST_OPTIONS


def test_match_kinds_and_exit_codes_mirror_toml() -> None:
    engine = _toml("engine")
    assert frozenset(engine["match_kinds"]) == contract.MATCH_KINDS
    codes = engine["exit_codes"]
    assert codes["matched"]["code"] == contract.EXIT_MATCHED
    assert codes["no_match"]["code"] == contract.EXIT_NO_MATCH
    assert codes["error"]["code"] == contract.EXIT_ERROR


def test_tool_boundary_mirror_matches_toml() -> None:
    """The agent / code-place seam (aliases + routing keys) must not drift."""
    boundary = _toml("surface")["tool_boundary"]
    assert boundary["aliases"] == contract.ALIASES
    assert frozenset(boundary["routing_keys"]) == contract.ROUTING_KEYS
    # Every alias target is a real request option; routing keys are not options.
    assert set(contract.ALIASES.values()) <= contract.REQUEST_OPTIONS
    assert contract.ROUTING_KEYS.isdisjoint(contract.REQUEST_OPTIONS)


def test_every_verb_routes_to_the_producer_the_contract_names() -> None:
    """The entry symbol a verb dispatches to is the one `[analytic.producers]` declares.

    Three libraries answer these seventeen verbs and the op numbers stayed
    ecosystem-wide, so nothing in a request says which. Mis-routing would not
    fail loudly: the wrong library returns IRREGEX_INVALID for an op it does not
    know, which the ladder reads as a declinature and answers cold — correct rows
    at subprocess cost, invisible forever.
    """
    analytic = _toml("analytic")["analytic"]
    producers = analytic["producers"]
    for verb, spec in analytic["verbs"].items():
        want = producers[spec["producer"]]["entry"]
        assert analytic_runtime._run_symbol(verb) == want, f"{verb} routes to the wrong library"
        assert table.VERBS[verb][4] == want, f"{verb}'s generated entry drifted from the contract"


def test_gists_own_producer_is_a_symbol_its_header_declares() -> None:
    """`gist_run` is spelled the same in the contract and in `include/gist.h`.

    Contract-versus-generated-table parity cannot catch a misspelling, because
    both sides are lowered from the same string: a typo'd `gist_runn` agrees with
    itself and then resolves to nothing at run time, silently demoting the verb to
    the subprocess tier forever. Only a second, independent spelling can catch it,
    and the header is one. The sibling producers' headers live in their own repos,
    where their own gates hold them; the process check below covers them here.
    """
    producers = _toml("analytic")["analytic"]["producers"]
    header = (
        contract.contract_path("surface").parent.parent / "include" / producers["gist"]["header"]
    )
    if not header.is_file():
        raise AssertionError(
            f"{header} not found; the gate cannot check the entry symbol's spelling"
        )
    declared = header.read_text(encoding="utf-8")
    assert f"{producers['gist']['entry']}(" in declared, (
        f"the contract routes verbs to {producers['gist']['entry']}, which {header.name} does not declare"
    )


@pytest.mark.skipif(not analytic_runtime.available(), reason="no analytic plane loaded")
def test_every_declared_producer_resolves_in_the_loaded_process() -> None:
    """Each entry symbol the contract names is really exported where it can be asked.

    A symbol that resolves to nothing is not an error at any layer — the ladder
    reads it as a declinature and answers cold — so nothing but an assertion
    notices. Absent producers are legitimate (a host may link only libgist), so
    this asserts about the ones the process HAS: whatever loaded must export every
    symbol the contract says it does.
    """
    _ffi, lib = analytic_runtime._plane()
    analytic = _toml("analytic")["analytic"]
    gist_entry = analytic["producers"]["gist"]["entry"]
    # libgist is not optional the way the siblings are: it is what this binding
    # opens, so a loaded plane that cannot resolve gist's own entry is a broken
    # library, not a thin install. (The engine handle every producer takes comes
    # from irregex_engine_open, down in the substrate.)
    assert hasattr(lib, gist_entry), f"the loaded plane exports no {gist_entry}"
    for verb, spec in analytic["verbs"].items():
        if spec["producer"] != "gist":
            continue
        assert hasattr(lib, analytic_runtime._run_symbol(verb)), f"{verb} routes nowhere"


@pytest.mark.skipif(not _HAVE_BINARY, reason="no gist binary available")
def test_engine_version_matches_contract() -> None:
    assert engine.version() == contract.ENGINE_VERSION

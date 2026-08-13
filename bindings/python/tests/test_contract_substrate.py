"""The contract mirror in `irgx.contract` must not drift from the canonical
contracts, nor from the driven binary.

The canonical files are split by who authors what they describe, and this suite
asserts about the ones this engine is answerable for: `contract/engine.toml` (the
request surface, match kinds, exit codes, version axes) and
`contract/analytic.toml` (the wire schema, row plane, and ABI vocabulary), both
authored here, plus the kinship package's `contract/kinship.toml`, whose grade
and channel vocabulary the row decoder must know and which is vendored beside
them under a drift gate in that package's CI.

A product's own contract is gated in that product's repo — `surface.toml` in the
exact face's own contract suite. Mirroring a consumer's contract here meant the
engine could not test itself without checking that consumer out.

Reading them **fails closed**. It used to skip, on the reasoning that an
installed wheel legitimately ships without the repo file — true, but a test run
happens in a checkout, and when the locator silently resolved to a path that no
longer existed after the repo split, every assertion below stopped running and
the mirror drifted for months behind a green suite. A missing contract in a
checkout is now an error that names the file.
"""

from __future__ import annotations

import functools
import tomllib

from irgx.contract import abi as contract
from irgx.contract import table
from irgx.request import SearchRequest
from irgx.runtime import analytic as analytic_runtime


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


def test_every_verb_routes_to_the_producer_the_contract_names() -> None:
    """The entry symbol a verb dispatches to is the one `[analytic.producers]` declares.

    Three libraries answer these seventeen verbs and the op numbers stayed
    ecosystem-wide, so nothing in a request says which. Mis-routing would not
    fail loudly: the wrong library returns IRGX_INVALID for an op it does not
    know, which the ladder reads as a declinature and answers cold — correct rows
    at subprocess cost, invisible forever.
    """
    analytic = _toml("analytic")["analytic"]
    producers = analytic["producers"]
    for verb, spec in analytic["verbs"].items():
        want = producers[spec["producer"]]["entry"]
        assert analytic_runtime._run_symbol(verb) == want, f"{verb} routes to the wrong library"
        assert table.VERBS[verb][4] == want, f"{verb}'s generated entry drifted from the contract"

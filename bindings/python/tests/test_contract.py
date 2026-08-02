"""The in-process vocabulary, checked against every artifact that spells it.

``contract/engine.toml`` declares the status codes, the fault taxonomy, the
coordinate spaces and the decline reasons once, and four artifacts restate them:
the ``Status`` and ``AtSpace`` enums in ``src/surface/ffi/contract.zig``, the
``IRGX_*`` defines in ``include/irgx.h``, the error sets in
``src/fault.zig``, and the module constants in ``irgx._abi`` that this
binding switches on. The contract
says the point of declaring them in one place is that a single gate can then
cover all of it -- this is that gate, and before it existed the table was
declared and nothing compared anything to it.

Every expectation is DERIVED from the pair being compared, never listed here.
The key-to-macro mapping is the contract's own ``c`` field, which is why
``out_of_memory`` may answer to ``IRGX_OOM`` without this file knowing that
as a fact of its own; a table row that renamed its macro moves the assertion
with it. Same for the fault domains: the Zig error set a domain is checked
against is the domain key capitalized, per the contract's own rule.

It fails CLOSED. An artifact that cannot be found or read is a failure, not a
skip, because a gate that skips when its subject moves is the exact shape of the
drift it exists to catch -- one of these parity tests was already silently
skipping on an unresolvable path for a whole release.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import tomllib
from irgx import _abi


def _root() -> Path:
    """The engine checkout, found by climbing to the contract.

    Works from the standalone checkout (``irregex/``) and from a copy nested
    somewhere inside a monorepo, without being told which it is in.
    """
    for base in Path(__file__).resolve().parents:
        if (base / "contract" / "engine.toml").is_file():
            return base
    pytest.fail(f"no contract/engine.toml above {__file__} -- cannot gate the contract")


ROOT = _root()


def _read(rel: str) -> str:
    path = ROOT / rel
    if not path.is_file():
        pytest.fail(f"{rel} is missing from {ROOT} -- the gate cannot verify what it cannot read")
    return path.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def contract() -> dict:
    return tomllib.loads(_read("contract/engine.toml"))


def _zig_enum(source: str, name: str) -> dict[str, int]:
    """The `name = int,` members of a Zig `enum(iN)`, up to its first method."""
    body = re.search(rf"pub const {name} = enum\(i\d+\) \{{(.*?)\n\n", source, re.S)
    assert body, f"no `pub const {name} = enum(iN)` in the Zig source"
    return {m[1]: int(m[2]) for m in re.finditer(r"(\w+) = (-?\d+),", body[1])}


def _zig_error_set(source: str, name: str) -> list[str]:
    decl = re.search(rf"pub const {name} = error\{{([^}}]*)\}}", source)
    assert decl, f"no `pub const {name} = error{{...}}` in the Zig source"
    return [m for m in (part.strip() for part in decl[1].split(",")) if m]


def _c_defines(header: str) -> dict[str, int]:
    """`#define IRGX_X 0` / `#define IRGX_X (-1)` -> {name: value}.

    A trailing `/* ... */` on the same line is the header's own house style for a
    short gloss, so it is skipped rather than being a reason to miss the row.
    """
    pattern = r"^#define (IRGX_\w+) \(?(-?\d+)\)?u?(?:\s*/\*.*)?$"
    return {m[1]: int(m[2]) for m in re.finditer(pattern, header, re.M)}


def test_the_zig_status_enum_is_the_contract_table(contract: dict) -> None:
    declared = {name: row["code"] for name, row in contract["status_codes"].items()}
    assert _zig_enum(_read("src/surface/ffi/contract.zig"), "Status") == declared


def test_the_c_header_defines_every_declared_status(contract: dict) -> None:
    defines = _c_defines(_read("include/irgx.h"))
    # The contract names the macro per row, so a renamed macro moves this with it.
    for name, row in contract["status_codes"].items():
        macro = row["c"]
        assert macro in defines, f"{name} declares {macro}, absent from the C header"
        assert defines[macro] == row["code"], f"{macro}: C {defines[macro]}, contract {row['code']}"


def test_no_status_macro_exists_that_the_contract_does_not_declare(contract: dict) -> None:
    """The reverse direction: a code minted in C only would pass every test above.

    Scoped by the header's OWN section banner rather than by guessing from names,
    because the flag, value-tag and ordinal macros share the prefix and are
    different vocabularies -- a name rule would either miss them or sweep them in.
    """
    header = _read("include/irgx.h")
    section = re.search(r"── the shared status vocabulary ─.*?\*/(.*?)/\* ──", header, re.S)
    assert section, "include/irgx.h no longer has a status-vocabulary section to scope to"
    assert set(_c_defines(section[1])) == {row["c"] for row in contract["status_codes"].values()}


def test_the_zig_at_space_enum_is_the_contract_table(contract: dict) -> None:
    declared = {name: row["code"] for name, row in contract["coordinate_spaces"].items()}
    assert _zig_enum(_read("src/surface/ffi/contract.zig"), "AtSpace") == declared


def test_the_c_header_defines_exactly_the_declared_coordinate_spaces(contract: dict) -> None:
    """Both directions at once, scoped to the header's own fault-detail section.

    A space minted in C only is as wrong as one missing: `at_space` is read by a
    switch, so an undeclared value is a prong nobody wrote.
    """
    header = _read("include/irgx.h")
    section = re.search(r"── the fault detail ─.*?\*/(.*?)/\* ──", header, re.S)
    assert section, "include/irgx.h no longer has a fault-detail section to scope to"
    defines = _c_defines(section[1])
    declared = {row["c"]: row["code"] for row in contract["coordinate_spaces"].values()}
    assert defines == declared


def test_this_binding_mirrors_the_declared_coordinate_spaces(contract: dict) -> None:
    """The binding reads `at_space` by comparison, so a value it has no name for
    is a prong nobody wrote - and a name whose number drifted is worse than one
    that is missing. Derived from the contract's own `c` field, as above."""
    for row in contract["coordinate_spaces"].values():
        constant = row["c"].removeprefix("IRGX_")
        assert hasattr(_abi, constant), f"{row['c']} has no name in irgx._abi"
        assert getattr(_abi, constant) == row["code"]


def test_the_abi_version_this_binding_speaks_is_the_declared_one(contract: dict) -> None:
    """The refusal at load is only as good as the number it refuses against."""
    assert contract["meta"]["abi_version"] == _abi.ABI_VERSION


@pytest.mark.parametrize("domain", ["corpus", "persist", "pattern", "resource", "wire"])
def test_each_fault_domain_is_its_zig_error_set(contract: dict, domain: str) -> None:
    """`corpus` is `fault.Corpus` -- the contract states that rule, so it is applied."""
    declared = contract["fault_domains"][domain]["members"]
    assert _zig_error_set(_read("src/fault.zig"), domain.capitalize()) == declared


def test_the_domains_cover_every_fault_the_kernel_can_produce(contract: dict) -> None:
    """`fault.Fault` is the union, so the taxonomy must exhaust it."""
    source = _read("src/fault.zig")
    union = re.search(r"pub const Fault = ([\w\s|]+);", source)
    assert union, "no `pub const Fault = ... || ...;` union in src/fault.zig"
    sets = [part.strip() for part in union[1].split("||")]
    from_zig = {member for name in sets for member in _zig_error_set(source, name)}
    from_contract = {m for d in contract["fault_domains"].values() for m in d["members"]}
    assert from_zig == from_contract


def test_the_decline_reasons_are_the_zig_decline_enum(contract: dict) -> None:
    body = re.search(r"pub const Decline = enum \{(.*?)\n\s*pub fn", _read("src/fault.zig"), re.S)
    assert body, "no `pub const Decline = enum {` in src/fault.zig"
    assert set(re.findall(r"^\s{4}(\w+),$", body[1], re.M)) == set(contract["decline_reasons"])


def test_every_fault_status_names_a_domain_that_exists(contract: dict) -> None:
    """`domains` is required on every fault row, and a domain with no home fails."""
    homes: dict[str, str] = {}
    for name, row in contract["status_codes"].items():
        if row["disposition"] != "fault":
            assert "domains" not in row, f"{name} is not a fault but claims domains"
            continue
        for domain in row["domains"]:
            assert domain in contract["fault_domains"], f"{name} names unknown domain {domain}"
            assert domain not in homes, f"{domain} is claimed by both {homes[domain]} and {name}"
            homes[domain] = name
    assert set(homes) == set(contract["fault_domains"]), "a domain has no status to cross as"

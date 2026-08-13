"""Validated projection of irregex's frozen CREST byte-oracle contract."""

from __future__ import annotations

import hashlib
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType

import tomllib

if __package__:
    from .syntax import OracleError
else:  # Direct execution through oracle.py.
    from syntax import OracleError


CONTRACT_PATH = Path(__file__).with_name("contract.toml")
CONTRACT_REPOSITORY_PATH = "research/crest/oracle/contract.toml"
SUPPORTED_SCHEMA_VERSION = 1
SUPPORTED_RANKS = (1, 2, 4)
SUPPORTED_BUDGETS = (1, 2, 4, 8)
EXPECTED_CLASS_ORDER = (
    "digit",
    "hex",
    "upper",
    "lower",
    "alpha",
    "word",
    "space",
    "punct",
    "literal_space",
    "dot",
    "quote",
    "lparen",
    "slash",
    "underscore",
    "assign_sep",
)
EXPECTED_SOURCE_SYMBOLS = ("Class", "classify", "supported_ranks", "supported_budgets")
EXPECTED_TRANSITIONS = "maximal-byte-run; reset=nonmember; increment=member; epsilon=hold"
EXPECTED_RANGE_SPECS = {
    "digit": ("30-39",),
    "hex": ("30-39", "41-46", "61-66"),
    "upper": ("41-5a",),
    "lower": ("61-7a",),
    "alpha": ("41-5a", "61-7a"),
    "word": ("30-39", "41-5a", "5f", "61-7a"),
    "space": ("09-0d", "20"),
    "punct": ("21-2f", "3a-40", "5b-5e", "60", "7b-7e"),
    "literal_space": ("20",),
    "dot": ("2e",),
    "quote": ("22", "27"),
    "lparen": ("28",),
    "slash": ("2f", "5c"),
    "underscore": ("5f",),
    "assign_sep": ("3a", "3d"),
}
_RANGE = re.compile(r"([0-9A-Fa-f]{2})(?:-([0-9A-Fa-f]{2}))?\Z")


class ContractError(OracleError):
    """The oracle cannot prove its predicate projection matches its contract."""

    code = "oracle.contract_invalid"


@dataclass(frozen=True, slots=True)
class Predicate:
    id: str
    label: str
    bytes: frozenset[int]
    source: str


@dataclass(frozen=True, slots=True)
class CrestContract:
    name: str
    schema_version: int
    sha256: str
    source_module: str
    source_symbols: tuple[str, ...]
    class_order: tuple[str, ...]
    default_rank: int
    supported_ranks: tuple[int, ...]
    default_budget: int
    supported_budgets: tuple[int, ...]
    oracle_assertions: str
    transition_semantics: str
    predicates: Mapping[str, Predicate]


def locate_contract() -> Path:
    """Return the contract colocated with the oracle, independent of caller cwd."""
    if CONTRACT_PATH.is_file():
        return CONTRACT_PATH
    raise ContractError(
        f"cannot locate {CONTRACT_REPOSITORY_PATH}",
        construct="contract path",
    )


def load_contract(path: Path | None = None) -> CrestContract:
    """Load and validate every frozen field on which the byte oracle relies."""
    contract_path = path or locate_contract()
    try:
        raw = contract_path.read_bytes()
        document = tomllib.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise ContractError(
            f"cannot parse CREST oracle contract: {error}",
            construct="contract document",
        ) from error

    meta = _table(document, "meta")
    projection = _table(document, "projection")
    crest = _table(document, "crest")
    dictionary = _table(crest, "dictionary")

    name = _string(meta, "name")
    schema_version = _integer(meta, "schema_version")
    if name != "irregex-crest-exact-oracle":
        _invalid(f"unexpected contract name {name!r}", "meta.name")
    if schema_version != SUPPORTED_SCHEMA_VERSION:
        _invalid(
            f"schema version {schema_version} is not supported; "
            f"expected {SUPPORTED_SCHEMA_VERSION}",
            "meta.schema_version",
        )
    if _string(meta, "artifact_kind") != "crest-exact-byte-oracle":
        _invalid("unexpected artifact kind", "meta.artifact_kind")

    source_module = _string(projection, "source_module")
    if source_module != "src/kernel/math/crest.zig":
        _invalid("production source module changed", "projection.source_module")
    source_symbols = _string_tuple(projection, "source_symbols")
    if source_symbols != EXPECTED_SOURCE_SYMBOLS:
        _invalid("production source symbols changed", "projection.source_symbols")
    class_order = _string_tuple(projection, "class_order")
    if class_order != EXPECTED_CLASS_ORDER:
        _invalid("CREST Class order changed", "projection.class_order")

    ranks = _integer_tuple(crest, "supported_ranks")
    if ranks != SUPPORTED_RANKS:
        _invalid(
            f"supported ranks changed from the checked projection {SUPPORTED_RANKS!r}",
            "crest.supported_ranks",
        )
    default_rank = _integer(crest, "default_rank")
    if default_rank not in ranks:
        _invalid("default rank is outside supported_ranks", "crest.default_rank")

    budgets = _integer_tuple(crest, "supported_budgets")
    if budgets != SUPPORTED_BUDGETS:
        _invalid(
            f"supported budgets changed from the checked projection {SUPPORTED_BUDGETS!r}",
            "crest.supported_budgets",
        )
    default_budget = _integer(crest, "default_budget")
    if default_budget not in budgets:
        _invalid("default budget is outside supported_budgets", "crest.default_budget")
    assertions = _string(crest, "oracle_assertions")
    if assertions != "refuse":
        _invalid("assertion policy must remain exactly 'refuse'", "crest.oracle_assertions")
    transitions = _string(crest, "transition_semantics")
    if transitions != EXPECTED_TRANSITIONS:
        _invalid(
            "transition semantics changed from the exact-oracle projection",
            "crest.transition_semantics",
        )
    if _string(dictionary, "alphabet") != "byte":
        _invalid("oracle alphabet must remain exactly 'byte'", "crest.dictionary.alphabet")

    raw_predicates = dictionary.get("byte_predicate")
    if not isinstance(raw_predicates, list) or not raw_predicates:
        _invalid("byte_predicate must be a non-empty table array", "byte_predicate")
    predicates: dict[str, Predicate] = {}
    for index, raw_predicate in enumerate(raw_predicates):
        if not isinstance(raw_predicate, dict):
            _invalid("predicate row must be a table", f"byte_predicate[{index}]")
        predicate_id = _string(raw_predicate, "id")
        if predicate_id in predicates:
            _invalid(f"duplicate predicate id {predicate_id!r}", "byte_predicate.id")
        raw_ranges = raw_predicate.get("ranges")
        if (
            predicate_id not in EXPECTED_RANGE_SPECS
            or not isinstance(raw_ranges, list)
            or tuple(raw_ranges) != EXPECTED_RANGE_SPECS[predicate_id]
        ):
            _invalid(
                f"predicate {predicate_id!r} ranges changed from the frozen projection",
                "byte_predicate.ranges",
            )
        predicate = Predicate(
            id=predicate_id,
            label=_string(raw_predicate, "label"),
            bytes=_contract_ranges(raw_ranges, predicate_id),
            source=_string(raw_predicate, "source"),
        )
        if not predicate.bytes:
            _invalid(f"predicate {predicate_id!r} is empty", "byte_predicate.ranges")
        if predicate.source != f"Class.{predicate_id}":
            _invalid(
                f"predicate {predicate_id!r} is not bound to Class.{predicate_id}",
                "byte_predicate.source",
            )
        predicates[predicate_id] = predicate
    if tuple(predicates) != class_order:
        _invalid("predicate rows do not match Class order", "byte_predicate.id")

    return CrestContract(
        name=name,
        schema_version=schema_version,
        sha256=hashlib.sha256(raw).hexdigest(),
        source_module=source_module,
        source_symbols=source_symbols,
        class_order=class_order,
        default_rank=default_rank,
        supported_ranks=ranks,
        default_budget=default_budget,
        supported_budgets=budgets,
        oracle_assertions=assertions,
        transition_semantics=transitions,
        predicates=MappingProxyType(predicates),
    )


def _contract_ranges(raw_ranges: object, predicate_id: str) -> frozenset[int]:
    if not isinstance(raw_ranges, list) or not raw_ranges:
        _invalid(f"predicate {predicate_id!r} has no ranges", "byte_predicate.ranges")
    values: set[int] = set()
    for raw_range in raw_ranges:
        if not isinstance(raw_range, str):
            _invalid("predicate range must be a string", "byte_predicate.ranges")
        match = _RANGE.fullmatch(raw_range)
        if match is None:
            _invalid(
                f"predicate {predicate_id!r} has invalid range {raw_range!r}",
                "byte_predicate.ranges",
            )
        low = int(match.group(1), 16)
        high = int(match.group(2), 16) if match.group(2) else low
        if low > high:
            _invalid(
                f"predicate {predicate_id!r} has descending range {raw_range!r}",
                "byte_predicate.ranges",
            )
        values.update(range(low, high + 1))
    return frozenset(values)


def _table(parent: Mapping[str, object], key: str) -> dict[str, object]:
    value = parent.get(key)
    if not isinstance(value, dict):
        _invalid(f"{key!r} must be a table", key)
    return value


def _string(parent: Mapping[str, object], key: str) -> str:
    value = parent.get(key)
    if not isinstance(value, str) or not value:
        _invalid(f"{key!r} must be a non-empty string", key)
    return value


def _integer(parent: Mapping[str, object], key: str) -> int:
    value = parent.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        _invalid(f"{key!r} must be a positive integer", key)
    return value


def _integer_tuple(parent: Mapping[str, object], key: str) -> tuple[int, ...]:
    value = parent.get(key)
    if not isinstance(value, list) or not value:
        _invalid(f"{key!r} must be a non-empty integer array", key)
    result = tuple(value)
    if any(not isinstance(item, int) or isinstance(item, bool) or item < 1 for item in result):
        _invalid(f"{key!r} must contain positive integers", key)
    if len(result) != len(set(result)):
        _invalid(f"{key!r} contains duplicates", key)
    return result


def _string_tuple(parent: Mapping[str, object], key: str) -> tuple[str, ...]:
    value = parent.get(key)
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        _invalid(f"{key!r} must be a string array", key)
    return tuple(value)


def _invalid(message: str, construct: str) -> None:
    raise ContractError(message, construct=construct)

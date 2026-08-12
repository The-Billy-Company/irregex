#!/usr/bin/env python3
"""Exact ranked CREST automata oracle and deterministic JSON CLI."""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Iterable, Sequence

if __package__:
    from .contract import (
        CONTRACT_REPOSITORY_PATH,
        ContractError,
        CrestContract,
        Predicate,
        load_contract,
    )
    from .nfa import ExactResult, compile_nfa, exact_forced_run
    from .syntax import (
        EmptyLanguage,
        OracleError,
        PatternRefusal,
        PatternSyntaxError,
        ResourceLimitExceeded,
        parse,
    )
else:  # Direct `python3 research/crest/oracle/oracle.py ...` execution.
    from nfa import ExactResult, compile_nfa, exact_forced_run
    from syntax import (
        EmptyLanguage,
        OracleError,
        PatternRefusal,
        PatternSyntaxError,
        ResourceLimitExceeded,
        parse,
    )

    from contract import (
        CONTRACT_REPOSITORY_PATH,
        ContractError,
        CrestContract,
        Predicate,
        load_contract,
    )


class CLIUsageError(OracleError):
    code = "oracle.cli_usage"


try:
    CONTRACT: CrestContract | None = load_contract()
    CONTRACT_LOAD_ERROR: ContractError | None = None
except ContractError as error:
    CONTRACT = None
    CONTRACT_LOAD_ERROR = error

NAMED_PREDICATES: dict[str, frozenset[int]] = (
    {name: predicate.bytes for name, predicate in CONTRACT.predicates.items()} if CONTRACT else {}
)


def analyze(pattern: str, predicate: Iterable[int], rank: int | None = None) -> ExactResult:
    """Compute exact g_rank(R,C), independently of irregex's CREST calculus."""
    contract = _contract_or_raise()
    selected_rank = contract.default_rank if rank is None else rank
    if selected_rank not in contract.supported_ranks:
        choices = ", ".join(map(str, contract.supported_ranks))
        raise CLIUsageError(f"rank must be one of the contract-supported values: {choices}")
    return analyze_order_statistic(pattern, predicate, selected_rank)


def analyze_order_statistic(
    pattern: str,
    predicate: Iterable[int],
    rank: int,
) -> ExactResult:
    """Compute one statistic represented inside the largest supported top-q."""
    contract = _contract_or_raise()
    if not 1 <= rank <= max(contract.supported_ranks):
        raise CLIUsageError(f"order statistic must be in 1..{max(contract.supported_ranks)}")
    byte_set = frozenset(predicate)
    invalid = [value for value in byte_set if not isinstance(value, int) or not 0 <= value <= 255]
    if invalid:
        rendered = ", ".join(sorted(map(repr, invalid))[:3])
        raise CLIUsageError(f"predicate contains non-byte values: {rendered}")
    return exact_forced_run(compile_nfa(parse(pattern)), byte_set, rank)


def parse_ranges(specification: str) -> frozenset[int]:
    """Parse comma-separated decimal/0x-prefixed singleton bytes and ranges."""
    values: set[int] = set()
    fields = [field.strip() for field in specification.split(",")]
    if not fields or any(not field for field in fields):
        raise CLIUsageError("ranges must be a non-empty comma-separated list")
    for field in fields:
        bounds = field.split("-")
        if len(bounds) > 2:
            raise CLIUsageError(f"invalid byte range: {field!r}")
        low = _parse_byte(bounds[0])
        high = low if len(bounds) == 1 else _parse_byte(bounds[1])
        if low > high:
            raise CLIUsageError(f"descending byte range: {field!r}")
        values.update(range(low, high + 1))
    return frozenset(values)


def _parse_byte(text: str) -> int:
    try:
        value = int(text, 0)
    except ValueError as error:
        raise CLIUsageError(f"byte {text!r} must be decimal or 0x-prefixed hexadecimal") from error
    if not 0 <= value <= 255:
        raise CLIUsageError(f"byte {text!r} is outside 0..255")
    return value


def _ranges(predicate: frozenset[int]) -> list[str]:
    if not predicate:
        return []
    ordered = sorted(predicate)
    out: list[str] = []
    start = previous = ordered[0]
    for value in ordered[1:]:
        if value == previous + 1:
            previous = value
            continue
        out.append(_format_range(start, previous))
        start = previous = value
    out.append(_format_range(start, previous))
    return out


def _format_range(low: int, high: int) -> str:
    return f"0x{low:02x}" if low == high else f"0x{low:02x}-0x{high:02x}"


class _JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise CLIUsageError(message)


def _parser(contract: CrestContract) -> argparse.ArgumentParser:
    parser = _JSONArgumentParser(
        description="Compute an exact CREST forced run-order-statistic threshold."
    )
    parser.add_argument("pattern", help="consuming irregex byte-regex pattern")
    selector = parser.add_mutually_exclusive_group(required=True)
    selector.add_argument(
        "--predicate",
        choices=sorted(contract.predicates),
        help=f"predicate id loaded from {CONTRACT_REPOSITORY_PATH}",
    )
    selector.add_argument(
        "--ranges",
        help="custom comma-separated bytes/ranges, e.g. 0x30-0x39,0x41",
    )
    parser.add_argument("--pretty", action="store_true", help="indent JSON output")
    parser.add_argument(
        "--rank",
        type=int,
        default=contract.default_rank,
        help=f"run order statistic, one of {contract.supported_ranks}",
    )
    return parser


def _predicate_payload(
    predicate: frozenset[int],
    *,
    predicate_id: str | None,
    label: str,
    source: str,
) -> dict[str, object]:
    return {
        "id": predicate_id,
        "label": label,
        "ranges": _ranges(predicate),
        "size": len(predicate),
        "source": source,
    }


def _contract_payload(contract: CrestContract) -> dict[str, object]:
    return {
        "class_count": len(contract.class_order),
        "default_budget": contract.default_budget,
        "name": contract.name,
        "path": CONTRACT_REPOSITORY_PATH,
        "schema_version": contract.schema_version,
        "sha256": contract.sha256,
        "source_module": contract.source_module,
        "supported_budgets": list(contract.supported_budgets),
        "supported_ranks": list(contract.supported_ranks),
    }


def _success(
    contract: CrestContract,
    pattern: str,
    predicate: dict[str, object],
    rank: int,
    result: ExactResult,
) -> dict[str, object]:
    return {
        "algorithm": "thompson-epsilon-nfa_x_capped-ranked-run-monitor",
        "budget": contract.default_budget,
        "contract": _contract_payload(contract),
        "emptiness_checks": result.emptiness_checks,
        "exact": True,
        "forced_longest_run": result.threshold if rank == 1 else None,
        "forced_run_threshold": result.threshold,
        "max_product_states_visited": result.max_product_states_visited,
        "nfa_states": result.nfa_states,
        "pattern": pattern,
        "predicate": predicate,
        "rank": rank,
        "refusal_reason": None,
        "schema_version": 1,
        "shortest_witness_length": result.shortest_witness_length,
        "status": "ok",
        "threshold": result.threshold,
    }


def _failure(
    error: OracleError,
    *,
    contract: CrestContract | None,
    pattern: str | None,
    predicate: dict[str, object] | None,
    rank: int | None,
) -> dict[str, object]:
    refused = isinstance(
        error,
        (EmptyLanguage, PatternRefusal, PatternSyntaxError, ResourceLimitExceeded),
    )
    return {
        "budget": contract.default_budget if contract else None,
        "contract": _contract_payload(contract) if contract else None,
        "error": error.as_dict(),
        "exact": False,
        "pattern": pattern,
        "predicate": predicate,
        "rank": rank,
        "refusal_reason": str(error),
        "schema_version": 1,
        "status": "refused" if refused else "error",
        "threshold": None,
    }


def _contract_or_raise() -> CrestContract:
    if CONTRACT_LOAD_ERROR is not None:
        raise CONTRACT_LOAD_ERROR
    if CONTRACT is None:
        raise ContractError("CREST oracle contract did not load", construct="contract document")
    return CONTRACT


def main(argv: Sequence[str] | None = None) -> int:
    pretty = False
    pattern: str | None = None
    rank: int | None = None
    predicate_payload: dict[str, object] | None = None
    contract = CONTRACT
    try:
        contract = _contract_or_raise()
        arguments = _parser(contract).parse_args(argv)
        pretty = arguments.pretty
        pattern = arguments.pattern
        rank = arguments.rank
        if arguments.predicate:
            definition: Predicate = contract.predicates[arguments.predicate]
            predicate = definition.bytes
            predicate_payload = _predicate_payload(
                predicate,
                predicate_id=definition.id,
                label=definition.label,
                source=f"contract:{definition.source}",
            )
        else:
            predicate = parse_ranges(arguments.ranges)
            predicate_payload = _predicate_payload(
                predicate,
                predicate_id=None,
                label="custom-byte-ranges",
                source=f"custom:{arguments.ranges}",
            )
        payload = _success(
            contract,
            pattern,
            predicate_payload,
            rank,
            analyze(pattern, predicate, rank),
        )
        exit_code = 0
    except OracleError as error:
        payload = _failure(
            error,
            contract=contract,
            pattern=pattern,
            predicate=predicate_payload,
            rank=rank,
        )
        exit_code = 2
    json.dump(
        payload,
        sys.stdout,
        indent=2 if pretty else None,
        separators=None if pretty else (",", ":"),
        sort_keys=True,
    )
    sys.stdout.write("\n")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

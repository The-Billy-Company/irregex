#!/usr/bin/env python3
"""Deterministically export the finite exact-oracle fixture to Zig."""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import tempfile
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

if __package__:
    from .contract import CrestContract, load_contract
    from .fixtures import A, finite_asts, render
    from .oracle import analyze, analyze_order_statistic
else:  # Direct `python3 research/crest/oracle/export_zig.py ...` execution.
    from fixtures import A, finite_asts, render

    from contract import CrestContract, load_contract
    from oracle import analyze, analyze_order_statistic


REPOSITORY = Path(__file__).resolve().parents[3]
TARGET = REPOSITORY / "src/kernel/regex/analysis/oracle_cases.gen.zig"
SOURCE_PATHS = (
    Path(__file__),
    Path(__file__).with_name("contract.py"),
    Path(__file__).with_name("fixtures.py"),
    Path(__file__).with_name("nfa.py"),
    Path(__file__).with_name("oracle.py"),
    Path(__file__).with_name("syntax.py"),
    Path(__file__).with_name("contract.toml"),
)
ORDER_STATISTICS = (1, 2, 3, 4)
SELECTION_POLICY = (
    ("q2-positive", 1),
    ("q1=3", 2),
    ("q1=2", 10),
    ("q1=1", 9),
    ("q1=0", 10),
)


@dataclass(frozen=True, slots=True)
class Case:
    pattern: str
    oracle: tuple[int, ...]
    exact_subset: bool


@dataclass(frozen=True, slots=True)
class Projection:
    predicate: str
    member: int
    nonmember: int


def selected_cases() -> tuple[Case, ...]:
    """Select the frozen sample and independently evaluate order statistics 1..4."""
    partitions: dict[str, list[tuple[tuple, tuple[int, ...]]]] = {
        label: [] for label, _ in SELECTION_POLICY
    }
    for node in finite_asts():
        pattern = render(node)
        thresholds = (
            analyze(pattern, {A}, 1).threshold,
            analyze(pattern, {A}, 2).threshold,
            analyze_order_statistic(pattern, {A}, 3).threshold,
            analyze(pattern, {A}, 4).threshold,
        )
        partitions[_partition(thresholds)].append((node, thresholds))

    cases: list[Case] = []
    for label, count in SELECTION_POLICY:
        partition = sorted(partitions[label], key=lambda item: _node_key(item[0]))
        if len(partition) < count:
            raise ValueError(
                f"fixture partition {label!r} has {len(partition)} nodes; need {count}"
            )
        cases.extend(
            Case(render(node), thresholds, _is_exact_subset(node))
            for node, thresholds in partition[:count]
        )
    return tuple(cases)


def generate() -> bytes:
    """Return the canonical Zig fixture bytes."""
    contract = load_contract()
    if tuple(range(1, max(contract.supported_ranks) + 1)) != ORDER_STATISTICS:
        raise ValueError("order statistics must exactly fill the largest production rank")
    nodes = finite_asts()
    cases = selected_cases()
    projections = _projections(contract)
    source_hash = _source_digest(SOURCE_PATHS)
    family_hash = _digest("".join(map(repr, nodes)).encode())
    supported_ranks = ", ".join(map(str, contract.supported_ranks))
    order_statistics = ", ".join(map(str, ORDER_STATISTICS))

    lines = [
        "// Generated from the independent Python automata oracle; DO NOT EDIT.",
        "// Sources: research/crest/oracle/{contract,export_zig,fixtures,nfa,oracle,syntax}.py",
        '//          and contract.toml (assertions = "refuse").',
        f"// Determinism: partition all {len(nodes)} nodes by exact (q2,q1) thresholds, take",
        "// 1 q2-positive + 2 q1=3 + 10 q1=2 + 9 q1=1 + 10 q1=0 nodes, each ordered",
        "// by (sha256(repr(node)), repr(node)), then evaluate order statistics 1..4 for {a}.",
        f"// All {len(projections)} contract projections map a to the least member and b to the least nonmember.",
        "// The consuming family contains no assertion, and none is generated here.",
        f'pub const source_sha256 = "{source_hash}";',
        f'pub const family_sha256 = "{family_hash}";',
        f'pub const contract_sha256 = "{contract.sha256}";',
        f"pub const family_count: usize = {len(nodes)};",
        f"pub const selected_count: usize = {len(cases)};",
        "pub const fixture_count: usize = selected_count * projections.len;",
        f"pub const supported_production_ranks = [_]u8{{ {supported_ranks} }};",
        f"pub const order_statistics = [_]u8{{ {order_statistics} }};",
        "",
        "pub const Predicate = enum { " + ", ".join(contract.class_order) + " };",
        "pub const Projection = struct { predicate: Predicate, member: u8, nonmember: u8 };",
        "pub const projections = [_]Projection{",
        *(
            "    .{ .predicate = ."
            f"{projection.predicate}, .member = {_zig_byte(projection.member)}, "
            f".nonmember = {_zig_byte(projection.nonmember)}"
            " },"
            for projection in projections
        ),
        "};",
        "",
        "pub const Case = struct {",
        "    pattern: []const u8,",
        "    oracle: [order_statistics.len]u16,",
        "    exact_subset: bool,",
        "};",
        "",
        "pub const cases = [_]Case{",
        *(_zig_case(case) for case in cases),
        "};",
        "",
    ]
    return "\n".join(lines).encode()


def main(argv: Sequence[str] | None = None, *, target: Path = TARGET) -> int:
    """Check the repository fixture by default, or atomically rewrite it."""
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", dest="mode", action="store_const", const="check")
    mode.add_argument("--write", dest="mode", action="store_const", const="write")
    parser.set_defaults(mode="check")
    arguments = parser.parse_args(argv)
    generated = generate()

    if arguments.mode == "write":
        _write_atomic(target, generated)
        print(f"wrote {_display_path(target)}")
        return 0

    try:
        current = target.read_bytes()
    except OSError as error:
        print(f"drift: cannot read {_display_path(target)}: {error}", file=sys.stderr)
        return 1
    if current != generated:
        print(
            f"drift: {_display_path(target)}; regenerate with "
            "python3 research/crest/oracle/export_zig.py --write",
            file=sys.stderr,
        )
        return 1
    print(f"ok: {_display_path(target)}")
    return 0


def _partition(thresholds: tuple[int, ...]) -> str:
    q1, q2, _, _ = thresholds
    if q2 > 0:
        return "q2-positive"
    if q1 in (0, 1, 2, 3):
        return f"q1={q1}"
    raise ValueError(f"fixture thresholds outside selection policy: q1={q1}, q2={q2}")


def _node_key(node: tuple) -> tuple[str, str]:
    representation = repr(node)
    return _digest(representation.encode()), representation


def _is_exact_subset(node: tuple) -> bool:
    kind, *fields = node
    if kind == "eps":
        return True
    if kind == "atom":
        return len(fields[0]) == 1
    if kind in ("cat", "alt"):
        return _is_exact_subset(fields[0]) and _is_exact_subset(fields[1])
    if kind == "rep":
        return _is_exact_subset(fields[0])
    raise ValueError(f"unknown fixture AST {kind}")


def _projections(contract: CrestContract) -> tuple[Projection, ...]:
    projections = []
    universe = range(256)
    for predicate_id in contract.class_order:
        members = contract.predicates[predicate_id].bytes
        member = min(members)
        nonmember = next((byte for byte in universe if byte not in members), None)
        if nonmember is None:
            raise ValueError(f"predicate {predicate_id!r} has no nonmember byte")
        if member not in members or nonmember in members:
            raise ValueError(f"projection {predicate_id!r} failed contract membership")
        projections.append(Projection(predicate_id, member, nonmember))
    return tuple(projections)


def _zig_case(case: Case) -> str:
    oracle = ", ".join(map(str, case.oracle))
    exact = str(case.exact_subset).lower()
    return (
        f'    .{{ .pattern = "{_zig_string(case.pattern)}", '
        f".oracle = .{{ {oracle} }}, .exact_subset = {exact} }},"
    )


def _zig_string(value: str) -> str:
    return "".join(_zig_escape(ord(character), quote='"') for character in value)


def _zig_byte(value: int) -> str:
    return "'" + _zig_escape(value, quote="'") + "'"


def _zig_escape(value: int, *, quote: str) -> str:
    if value == ord("\\"):
        return "\\\\"
    if value == ord(quote):
        return f"\\{quote}"
    if 0x21 <= value <= 0x7E:
        return chr(value)
    return f"\\x{value:02x}"


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _source_digest(paths: Sequence[Path]) -> str:
    digest = hashlib.sha256()
    for path in paths:
        name = path.relative_to(REPOSITORY).as_posix().encode()
        data = path.read_bytes()
        digest.update(len(name).to_bytes(4, "big"))
        digest.update(name)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def _display_path(target: Path) -> Path:
    try:
        return target.relative_to(REPOSITORY)
    except ValueError:
        return target


def _write_atomic(target: Path, data: bytes) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{target.name}.",
        suffix=".tmp",
        dir=target.parent,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        mode = target.stat().st_mode & 0o777 if target.exists() else 0o644
        temporary.chmod(mode)
        os.replace(temporary, target)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    raise SystemExit(main())

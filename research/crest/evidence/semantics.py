"""Semantic verification for the corpus-dependent CREST publication artifacts."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import sys
from collections.abc import Mapping
from dataclasses import asdict
from functools import cache
from pathlib import Path, PurePosixPath
from threading import Lock
from types import ModuleType

CORPUS_SCHEMA = "irregex-crest-corpus-publication-artifact-v1"
CORPUS_REPORTS = {
    "q1-report.json": ("crest-q1-corpus-report", "q1-b8"),
    "q4-report.json": ("crest-q4-corpus-report", "q4-b8"),
    "fixed-dictionary-report.json": (
        "crest-fixed-dictionary-report",
        "fixed-dictionary",
    ),
    "adaptive-dictionary-report.json": (
        "crest-adaptive-dictionary-report",
        "adaptive-dictionary",
    ),
    "mutation-report.json": ("crest-mutation-report", "mutation"),
}
CORPUS_REQUIRED = frozenset({"corpus-manifest.tsv", *CORPUS_REPORTS})
MAX_ARTIFACT_BYTES = 8 << 20
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_MUTATION_IMPORT_LOCK = Lock()


def _safe_name(name: str) -> bool:
    path = PurePosixPath(name)
    return (
        bool(name)
        and "\\" not in name
        and "\0" not in name
        and not path.is_absolute()
        and ".." not in path.parts
        and path.as_posix() == name
    )


def _is_count(value: object, *, positive: bool = False) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= int(positive)


def _corpus_manifest(raw: bytes, problems: list[str]) -> tuple[int, int, str] | None:
    try:
        text = raw.decode("utf-8")
    except UnicodeError as error:
        problems.append(f"corpus-manifest.tsv is unreadable: {error}")
        return None
    if len(raw) > MAX_ARTIFACT_BYTES:
        problems.append("corpus-manifest.tsv exceeds semantic verification limit")
        return None
    lines = text.splitlines()
    if not lines or lines[0] != "path\tsize_bytes\tsha256":
        problems.append("corpus-manifest.tsv schema header is invalid")
        return None
    names: set[str] = set()
    folded: set[str] = set()
    total_bytes = 0
    for line_number, line in enumerate(lines[1:], 2):
        fields = line.split("\t")
        if len(fields) != 3:
            problems.append(f"corpus-manifest.tsv line {line_number} is malformed")
            continue
        name, size_raw, digest = fields
        lowered = name.casefold()
        if (
            not _safe_name(name)
            or name in names
            or lowered in folded
            or not size_raw.isdecimal()
            or str(int(size_raw)) != size_raw
            or not SHA256.fullmatch(digest)
        ):
            problems.append(f"corpus-manifest.tsv line {line_number} is invalid")
            continue
        names.add(name)
        folded.add(lowered)
        total_bytes += int(size_raw)
    if not names:
        problems.append("corpus-manifest.tsv has no valid corpus members")
        return None
    return len(names), total_bytes, hashlib.sha256(raw).hexdigest()


def _json_artifact(raw: bytes, name: str, problems: list[str]) -> dict[str, object] | None:
    try:
        if len(raw) > MAX_ARTIFACT_BYTES:
            problems.append(f"{name} exceeds semantic verification limit")
            return None
        document = json.loads(raw)
    except (UnicodeError, json.JSONDecodeError) as error:
        problems.append(f"{name} is invalid JSON: {error}")
        return None
    if not isinstance(document, dict):
        problems.append(f"{name} root must be an object")
        return None
    return document


def _common_problems(
    name: str,
    report: dict[str, object],
    *,
    kind: str,
    profile: str,
    source_commit: str,
    dataset_fingerprint: str,
) -> list[str]:
    expected = {
        "schema": CORPUS_SCHEMA,
        "artifact_kind": kind,
        "source_commit": source_commit,
        "dataset_fingerprint": dataset_fingerprint,
        "profile": profile,
    }
    return [
        f"{name} {field} mismatch"
        for field, value in expected.items()
        if report.get(field) != value
    ]


def _load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"{path.name} cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(name, None)
        raise
    return module


@cache
def _mutation_runtime() -> tuple[ModuleType, ModuleType]:
    root = Path(__file__).resolve().parents[1] / "mutation"
    with _MUTATION_IMPORT_LOCK:
        contract = _load_module(
            "_irregex_crest_mutation_contract_v3",
            root / "contract.py",
        )
        previous = sys.modules.get("contract")
        sys.modules["contract"] = contract
        try:
            verifier = _load_module(
                "_irregex_crest_mutation_verifier_v3",
                root / "mutate.py",
            )
        finally:
            if previous is None:
                sys.modules.pop("contract", None)
            else:
                sys.modules["contract"] = previous
    return contract, verifier


def _native_mutation_problems(
    report: dict[str, object],
    source_commit: str,
) -> list[str]:
    label = "mutation-report.json"
    contract, verifier = _mutation_runtime()
    provenance = report.get("provenance")
    provenance_fields = {
        "commit",
        "dirty_tree_sha256",
        "git_tree",
        "mutation_catalog_sha256",
        "source_snapshot_sha256",
        "toolchain",
        "working_tree",
    }
    if not isinstance(provenance, dict) or set(provenance) != provenance_fields:
        return [f"{label} provenance shape is invalid"]
    problems: list[str] = []
    if provenance.get("commit") != source_commit:
        problems.append(f"{label} provenance commit mismatch")
    git_tree = provenance.get("git_tree")
    if not isinstance(git_tree, str) or not re.fullmatch(r"[0-9a-f]{40,64}", git_tree):
        problems.append(f"{label} provenance git tree is invalid")
    snapshot = provenance.get("source_snapshot_sha256")
    if not isinstance(snapshot, str) or not SHA256.fullmatch(snapshot):
        problems.append(f"{label} source snapshot is invalid")
    working_tree, dirty = (
        provenance.get("working_tree"),
        provenance.get("dirty_tree_sha256"),
    )
    if working_tree not in {"clean", "dirty"} or (
        dirty is not None
        if working_tree == "clean"
        else not isinstance(dirty, str) or not SHA256.fullmatch(dirty)
    ):
        problems.append(f"{label} working-tree provenance is invalid")
    expected_catalog = contract.catalog_digest(asdict(mutation) for mutation in contract.MUTATIONS)
    if provenance.get("mutation_catalog_sha256") != expected_catalog:
        problems.append(f"{label} mutation catalog digest mismatch")
    toolchain = provenance.get("toolchain")
    if (
        not isinstance(toolchain, dict)
        or set(toolchain) != {"executable_sha256", "target", "zig_version"}
        or not isinstance(toolchain.get("executable_sha256"), str)
        or not SHA256.fullmatch(toolchain["executable_sha256"])
        or not isinstance(toolchain.get("target"), str)
        or not toolchain["target"]
        or not isinstance(toolchain.get("zig_version"), str)
        or not toolchain["zig_version"]
    ):
        problems.append(f"{label} toolchain provenance is invalid")
    if problems:
        return problems
    identity = contract.SourceIdentity(
        commit=provenance["commit"],
        git_tree=provenance["git_tree"],
        working_tree=provenance["working_tree"],
        dirty_tree_sha256=provenance["dirty_tree_sha256"],
        source_snapshot_sha256=provenance["source_snapshot_sha256"],
        mutation_catalog_sha256=provenance["mutation_catalog_sha256"],
        toolchain=contract.ToolchainIdentity(
            zig_version=toolchain["zig_version"],
            target=toolchain["target"],
            executable_sha256=toolchain["executable_sha256"],
        ),
    )
    try:
        verifier.verify_report(report, identity)
    except contract.ReportDrift as error:
        return [f"{label} native v3 verification failed: {error}"]
    expected = len(contract.MUTATIONS)
    if report.get("summary") != {
        "eligible": expected,
        "invalid": 0,
        "killed": expected,
        "survived": 0,
        "total": expected,
    }:
        problems.append(f"{label} is not all killed with zero invalid outcomes")
    return problems


def corpus_status(
    artifacts: Mapping[str, bytes],
    *,
    source_commit: str,
    dataset_fingerprint: str,
) -> tuple[list[str], list[str]]:
    missing = sorted(name for name in CORPUS_REQUIRED if name not in artifacts)
    problems: list[str] = []
    manifest = (
        _corpus_manifest(artifacts["corpus-manifest.tsv"], problems)
        if "corpus-manifest.tsv" not in missing
        else None
    )
    reports: dict[str, dict[str, object]] = {}
    for name, (kind, profile) in CORPUS_REPORTS.items():
        if name in missing:
            continue
        report = _json_artifact(artifacts[name], name, problems)
        if report is None:
            continue
        reports[name] = report
        if name != "mutation-report.json":
            problems.extend(
                _common_problems(
                    name,
                    report,
                    kind=kind,
                    profile=profile,
                    source_commit=source_commit,
                    dataset_fingerprint=dataset_fingerprint,
                )
            )
    corpus_reports = {
        name: report for name, report in reports.items() if name != "mutation-report.json"
    }
    expected_profile = {
        "q1-report.json": (1, None),
        "q4-report.json": (4, None),
        "fixed-dictionary-report.json": (None, "fixed"),
        "adaptive-dictionary-report.json": (None, "adaptive"),
    }
    for name, report in corpus_reports.items():
        rank, dictionary_mode = expected_profile[name]
        false_negatives, violations = (
            report.get("false_negatives"),
            report.get("violations"),
        )
        if not (
            _is_count(false_negatives)
            and false_negatives == 0
            and _is_count(violations)
            and violations == 0
            and report.get("passed") is True
        ):
            problems.append(f"{name} does not prove zero false negatives and violations")
        if rank is not None:
            observed_rank, budget = report.get("rank"), report.get("budget")
            if not (
                _is_count(observed_rank, positive=True)
                and observed_rank == rank
                and _is_count(budget, positive=True)
                and budget == 8
            ):
                problems.append(f"{name} rank/budget mismatch")
        if dictionary_mode is not None and report.get("dictionary_mode") != dictionary_mode:
            problems.append(f"{name} dictionary mode mismatch")
    if manifest is not None:
        file_count, total_bytes, manifest_sha256 = manifest
        shared = {
            "corpus_manifest_sha256": manifest_sha256,
            "corpus_file_count": file_count,
            "corpus_total_bytes": total_bytes,
        }
        workload: object | None = None
        query_count: object | None = None
        for name, report in corpus_reports.items():
            for field, value in shared.items():
                observed = report.get(field)
                if observed != value or (
                    field != "corpus_manifest_sha256"
                    and not _is_count(observed, positive=field == "corpus_file_count")
                ):
                    problems.append(f"{name} {field} mismatch")
            current_workload, current_count = (
                report.get("query_workload_sha256"),
                report.get("query_count"),
            )
            if not isinstance(current_workload, str) or not SHA256.fullmatch(current_workload):
                problems.append(f"{name} query workload fingerprint is invalid")
            elif workload is None:
                workload = current_workload
            elif current_workload != workload:
                problems.append(f"{name} query workload differs across reports")
            if not _is_count(current_count, positive=True):
                problems.append(f"{name} query count is invalid")
            elif query_count is None:
                query_count = current_count
            elif current_count != query_count:
                problems.append(f"{name} query count differs across reports")
    if mutation := reports.get("mutation-report.json"):
        problems.extend(_native_mutation_problems(mutation, source_commit))
    return missing, problems

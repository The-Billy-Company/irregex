"""Deterministic CREST predicate proposals with a mandatory corpus-evidence gate."""

from __future__ import annotations

import json
from collections import Counter

from .package import (
    DataPackage,
    IntegrityError,
    SchemaError,
    is_strict_int,
    sha256_bytes,
)
from .predicates import (
    Extraction,
    byte_ranges,
    byte_set_digest,
    decode_byte_set,
    encode_byte_set,
    load_manifest,
    load_trace,
    trace_extractions,
)

PROPOSAL_KIND = "crest-byte-predicate-research-proposal"
VALIDATION_KIND = "crest-byte-predicate-held-out-report"
OBJECTIVE = "weighted_query_atom_branch_coverage_proposal"
ALGORITHM_VERSION = 1
TIE_BREAKING = (
    "marginal_objective_gain_desc",
    "predicate_cardinality_asc",
    "candidate_sha256_lexicographic",
)
VALIDATION_TIE_BREAKING = (
    "covered_validation_atom_units_desc",
    "predicate_k_asc",
    "setting_name_lexicographic",
)
PROMOTION_GATE = {
    "status": "corpus_evidence_required",
    "q4_promotion_eligible": False,
    "adaptive_dictionary_promotion_eligible": False,
    "required_evidence": [
        "immutable_document_corpus_fingerprint",
        "independent_query_workload_fingerprint",
        "production_matcher_and_compiler_revision",
        "held_out_soundness_zero_false_negatives",
        "q1_vs_q4_pruning_touched_bytes_latency_and_storage",
        "adaptive_vs_fixed_dictionary_pruning_touched_bytes_latency_and_storage",
    ],
}


def _promotion_gate() -> dict[str, object]:
    return {
        **PROMOTION_GATE,
        "required_evidence": list(PROMOTION_GATE["required_evidence"]),
    }


def canonical_json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()


def artifact_sha256(value: object) -> str:
    return sha256_bytes(canonical_json_bytes(value))


def _units(extractions: list[Extraction]) -> list[frozenset[int]]:
    return [atom.byte_set for extraction in extractions for atom in extraction.atoms]


def _extraction_counts(extractions: list[Extraction]) -> dict[str, object]:
    reasons = Counter(
        candidate.reason for extraction in extractions for candidate in extraction.non_byte
    )
    return {
        "top_level_branches": sum(item.branch_count for item in extractions),
        "exact_byte_atom_units": sum(len(item.atoms) for item in extractions),
        "explicit_non_byte_candidates": sum(len(item.non_byte) for item in extractions),
        "non_byte_reasons": dict(sorted(reasons.items())),
    }


def candidate_universe(extractions: list[Extraction]) -> list[frozenset[int]]:
    return sorted(
        {atom.byte_set for item in extractions for atom in item.atoms},
        key=lambda value: (len(value), byte_set_digest(value)),
    )


def greedy_select(
    universe: list[frozenset[int]],
    units: list[frozenset[int]],
    k: int,
) -> list[tuple[frozenset[int], int, int]]:
    """Maximize trace-atom coverage with a frozen deterministic ordering."""
    coverage = {
        byte_set_digest(candidate): {index for index, atom in enumerate(units) if atom <= candidate}
        for candidate in universe
    }
    selected: list[tuple[frozenset[int], int, int]] = []
    covered: set[int] = set()
    remaining = set(universe)
    while remaining and len(selected) < k:
        winner = min(
            remaining,
            key=lambda candidate: (
                -len(coverage[byte_set_digest(candidate)] - covered),
                len(candidate),
                byte_set_digest(candidate),
            ),
        )
        newly_covered = coverage[byte_set_digest(winner)] - covered
        if not newly_covered:
            break
        covered.update(newly_covered)
        selected.append((winner, len(newly_covered), len(covered)))
        remaining.remove(winner)
    return selected


def _selected_records(
    selections: list[tuple[frozenset[int], int, int]],
    extractions: list[Extraction],
) -> list[dict[str, object]]:
    exact_spellings = {
        candidate: Counter(
            atom.spelling
            for extraction in extractions
            for atom in extraction.atoms
            if atom.byte_set == candidate
        )
        for candidate, _, _ in selections
    }
    records: list[dict[str, object]] = []
    for rank, (candidate, marginal, cumulative) in enumerate(selections, 1):
        spellings = sorted(exact_spellings[candidate].items(), key=lambda item: (-item[1], item[0]))
        records.append(
            {
                "research_rank": rank,
                "candidate_sha256": byte_set_digest(candidate),
                "byte_set_256_little_bit_hex": encode_byte_set(candidate),
                "byte_ranges_hex": byte_ranges(candidate),
                "cardinality": len(candidate),
                "marginal_objective_gain": marginal,
                "cumulative_objective": cumulative,
                "exact_source_occurrences": sum(exact_spellings[candidate].values()),
                "source_spellings": [
                    {"spelling": spelling, "occurrences": count}
                    for spelling, count in spellings[:16]
                ],
            }
        )
    return records


def _split_guard(
    training_rows: list[dict[str, object]],
    validation_rows: list[dict[str, object]],
    manifest: object,
) -> dict[str, object]:
    overlaps: dict[str, int] = {}
    for key in ("call_key", "session_key"):
        train = {row[key] for row in training_rows}
        held_out = {row[key] for row in validation_rows}
        overlaps[key] = len(train & held_out)
    if any(overlaps.values()):
        names = ", ".join(key for key, count in overlaps.items() if count)
        raise IntegrityError(f"training and held-out validation overlap on {names}")
    return {
        "schema": "crest-held-out-split-guard-v1",
        "dataset_fingerprint": manifest.dataset_fingerprint,
        "training_split_sha256": manifest.partition_sha256("train"),
        "validation_split_sha256": manifest.partition_sha256("validation"),
        "call_key_overlap": overlaps["call_key"],
        "session_key_overlap": overlaps["session_key"],
        "validation_opened_after_dictionary_frozen": True,
        "test_partition_opened": False,
        "excluded_partition_opened": False,
    }


def build_proposal(package: DataPackage, k: int) -> dict[str, object]:
    if not is_strict_int(k) or k <= 0:
        raise SchemaError("K must be a positive integer")
    manifest = load_manifest(package)
    rows = load_trace(package, "train", manifest)
    extractions = trace_extractions(rows)
    units = _units(extractions)
    selections = greedy_select(candidate_universe(extractions), units, k)
    counts = manifest.partition("train").counts
    return {
        "schema_version": 1,
        "artifact_kind": PROPOSAL_KIND,
        "promotion_gate": _promotion_gate(),
        "algorithm": {
            "name": "deterministic-greedy-byte-predicate-research-proposal",
            "version": ALGORITHM_VERSION,
            "tie_breaking": list(TIE_BREAKING),
            "downstream_subset_proof_required": True,
        },
        "objective": {
            "name": OBJECTIVE,
            "status": "trace_coverage_only",
            "requested_k": k,
            "proposed_k": len(selections),
            "total_weight": len(units),
            "achieved_weight": selections[-1][2] if selections else 0,
        },
        "provenance": {
            "trace_schema": manifest.document["schema"],
            "trace_manifest_sha256": manifest.sha256,
            "dataset_fingerprint": manifest.dataset_fingerprint,
            "training_split_sha256": manifest.partition_sha256("train"),
            "training_partition": "train.jsonl",
            **package.receipt().as_dict(),
        },
        "training_counts": {
            "calls": len(rows),
            "sessions": len({row["session_key"] for row in rows}),
            "distinct_patterns": len({row["pattern"] for row in rows}),
            "manifest_calls": counts.calls,
            "manifest_sessions": counts.sessions,
            "manifest_distinct_patterns": counts.distinct_patterns,
            "candidate_universe": len(candidate_universe(extractions)),
            **_extraction_counts(extractions),
        },
        "proposed_predicates": _selected_records(selections, extractions),
        "limitations": [
            "This artifact is research evidence and cannot configure production.",
            "Trace-atom coverage is not document pruning, touched bytes, latency, or storage.",
            "q=4 and adaptive dictionaries remain ineligible without held-out corpus evidence.",
        ],
    }


def validate_settings(document: object) -> list[dict[str, object]]:
    if not isinstance(document, dict) or document.get("schema") != "crest-validation-settings-v1":
        raise SchemaError("settings schema must be crest-validation-settings-v1")
    settings = document.get("settings")
    if not isinstance(settings, list) or not settings:
        raise SchemaError("settings requires a nonempty list")
    names: set[str] = set()
    result: list[dict[str, object]] = []
    for setting in settings:
        if (
            not isinstance(setting, dict)
            or set(setting) != {"name", "predicate_k"}
            or not isinstance(setting["name"], str)
            or not setting["name"]
            or not is_strict_int(setting["predicate_k"])
            or setting["predicate_k"] <= 0
            or setting["name"] in names
        ):
            raise SchemaError("each setting requires unique name and positive predicate_k")
        names.add(setting["name"])
        result.append(setting)
    return result


def _validated_candidates(proposal: object, manifest: object) -> list[frozenset[int]]:
    if not isinstance(proposal, dict) or proposal.get("artifact_kind") != PROPOSAL_KIND:
        raise SchemaError("proposal artifact kind mismatch")
    if proposal.get("promotion_gate") != PROMOTION_GATE:
        raise IntegrityError("proposal promotion gate is absent or weakened")
    provenance = proposal.get("provenance")
    if (
        not isinstance(provenance, dict)
        or provenance.get("dataset_fingerprint") != manifest.dataset_fingerprint
        or provenance.get("training_split_sha256") != manifest.partition_sha256("train")
    ):
        raise IntegrityError("proposal dataset or training provenance mismatch")
    records = proposal.get("proposed_predicates")
    if not isinstance(records, list):
        raise SchemaError("proposal predicates must be an array")
    decoded: list[frozenset[int]] = []
    for expected_rank, record in enumerate(records, 1):
        if not isinstance(record, dict) or record.get("research_rank") != expected_rank:
            raise SchemaError("proposal research ranks must be contiguous")
        byte_set = decode_byte_set(record.get("byte_set_256_little_bit_hex"))
        if (
            record.get("candidate_sha256") != byte_set_digest(byte_set)
            or record.get("cardinality") != len(byte_set)
            or record.get("byte_ranges_hex") != byte_ranges(byte_set)
        ):
            raise IntegrityError("proposal predicate receipt mismatch")
        decoded.append(byte_set)
    if len(set(decoded)) != len(decoded):
        raise SchemaError("proposal contains duplicate predicates")
    return decoded


def build_validation_report(
    package: DataPackage,
    proposal: dict[str, object],
    settings_document: dict[str, object],
) -> dict[str, object]:
    requested_k = proposal.get("objective", {}).get("requested_k")
    if not is_strict_int(requested_k) or requested_k <= 0:
        raise SchemaError("proposal has no valid requested K")
    if proposal != build_proposal(package, requested_k):
        raise IntegrityError("proposal differs from deterministic training reproduction")
    manifest = load_manifest(package)
    candidates = _validated_candidates(proposal, manifest)
    settings = validate_settings(settings_document)
    if any(setting["predicate_k"] > len(candidates) for setting in settings):
        raise SchemaError("a validation setting requests more predicates than proposed")
    training_rows = load_trace(package, "train", manifest)
    validation_rows = load_trace(package, "validation", manifest)
    guard = _split_guard(training_rows, validation_rows, manifest)
    units = _units(trace_extractions(validation_rows))
    scores = [
        {
            **setting,
            "covered_validation_atom_units": sum(
                any(atom <= predicate for predicate in candidates[: setting["predicate_k"]])
                for atom in units
            ),
            "total_validation_atom_units": len(units),
        }
        for setting in settings
    ]
    best = min(
        scores,
        key=lambda item: (
            -item["covered_validation_atom_units"],
            item["predicate_k"],
            item["name"],
        ),
    )
    return {
        "schema_version": 1,
        "artifact_kind": VALIDATION_KIND,
        "promotion_gate": _promotion_gate(),
        "dataset_fingerprint": manifest.dataset_fingerprint,
        "proposal_sha256": artifact_sha256(proposal),
        "settings_sha256": artifact_sha256(settings_document),
        "split_guard": guard,
        "candidate_dictionary_frozen_before_validation": True,
        "settings": scores,
        "best_trace_coverage_prefix": {
            "name": best["name"],
            "predicate_k": best["predicate_k"],
        },
        "limitations": [
            "Held-out trace coverage cannot promote q=4.",
            "Held-out trace coverage cannot promote an adaptive dictionary.",
            "No test-set metric is produced.",
        ],
    }

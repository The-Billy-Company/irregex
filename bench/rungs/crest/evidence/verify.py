#!/usr/bin/env python3
"""Fail-closed verification for a CREST release-evidence package."""

from __future__ import annotations

import csv
import hashlib
import json
import math
import os
import re
import subprocess
import tarfile
import tempfile
from datetime import date, datetime, time
from pathlib import Path

import monograph
import tomllib

SHA256 = re.compile(r"[0-9a-f]{64}")
COMMIT = re.compile(r"[0-9a-f]{40,64}")
PROFILE = re.compile(r"q(?:1|2|4)-b(?:1|2|4|8)")
MANIFEST = "evidence-manifest.json"
DETACHED = "EVIDENCE-MANIFEST.sha256"
CSV_FIELDS = [
    "rank",
    "budget",
    "query",
    "pattern",
    "caseless",
    "unicode",
    "alternatives",
    "files",
    "run_survivors",
    "fold_survivors",
    "cnt_survivors",
    "run_prune_pct",
    "fold_prune_pct",
    "cnt_prune_pct",
    "hits",
    "full_ms",
    "sieve_ms",
    "speedup",
]

type _JsonValue = (
    None | bool | int | float | str | list[_JsonValue] | dict[str, _JsonValue]
)
type _JsonObject = dict[str, _JsonValue]
type _TomlValue = (
    bool
    | int
    | float
    | str
    | date
    | datetime
    | time
    | list[_TomlValue]
    | dict[str, _TomlValue]
)
type _TomlTable = dict[str, _TomlValue]


def _strict_int(value: object, minimum: int = 0) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_contract(path: Path) -> _TomlTable:
    with path.open("rb") as source:
        return tomllib.load(source)


def _json(path: Path, problems: list[str]) -> _JsonObject:
    try:
        value = json.loads(path.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        problems.append(f"{path.name}: invalid JSON: {error}")
        return {}
    if not isinstance(value, dict):
        problems.append(f"{path.name}: root must be an object")
        return {}
    return value


def _verify_envelope(
    package: Path, contract: _TomlTable, problems: list[str]
) -> _JsonObject:
    expected = set(contract["artifacts"]["payload_required"])
    expected.update(contract["artifacts"]["envelope_required"])
    observed = {path.name for path in package.iterdir() if path.is_file()}
    if observed != expected:
        missing, extra = sorted(expected - observed), sorted(observed - expected)
        if missing:
            problems.append(f"missing required files: {', '.join(missing)}")
        if extra:
            problems.append(f"unexpected package files: {', '.join(extra)}")
    manifest_path, detached = package / MANIFEST, package / DETACHED
    if not manifest_path.is_file() or not detached.is_file():
        return {}
    parts = detached.read_text().strip().split()
    if parts != [sha256_file(manifest_path), MANIFEST]:
        problems.append("detached evidence-manifest SHA-256 mismatch")
    manifest = _json(manifest_path, problems)
    hashes = manifest.get("files")
    if not isinstance(hashes, dict) or set(hashes) != set(
        contract["artifacts"]["payload_required"]
    ):
        problems.append("evidence manifest file set differs from contract payload")
        return manifest
    for name, expected_hash in hashes.items():
        path = package / name
        if not isinstance(expected_hash, str) or not SHA256.fullmatch(expected_hash):
            problems.append(f"manifest hash is invalid for {name}")
        elif path.is_file() and sha256_file(path) != expected_hash:
            problems.append(f"payload SHA-256 mismatch: {name}")
    return manifest


def _verify_revision(
    package: Path,
    manifest: _JsonObject,
    contract: _TomlTable,
    repo: Path,
    problems: list[str],
) -> None:
    commit = manifest.get("source_commit")
    if not isinstance(commit, str) or not COMMIT.fullmatch(commit):
        problems.append("manifest source_commit is not a full object id")
        return
    source_commit = package / "source-commit.txt"
    if source_commit.is_file() and source_commit.read_text() != f"{commit}\n":
        problems.append("source-commit.txt differs from evidence manifest")
    archive = package / "source.tar"
    if not archive.is_file():
        return
    if manifest.get("source_archive_sha256") != sha256_file(archive):
        problems.append("source archive hash differs from evidence manifest")
    try:
        with tarfile.open(archive, "r:") as source:
            archived_commit = source.pax_headers.get("comment")
            monograph_text = (package / monograph.MONOGRAPH).read_text()
            for path in contract["paths"]["monograph_sources"]:
                member = f"crest-source/{path}"
                try:
                    source_file = source.extractfile(member)
                except KeyError:
                    source_file = None
                if source_file is None:
                    problems.append(f"source archive lacks monograph source: {path}")
                    continue
                text = source_file.read().decode("utf-8")
                block = (
                    f"<!-- begin git show {commit}:{path} -->\n"
                    f"{text.rstrip()}\n"
                    f"<!-- end git show {commit}:{path} -->"
                )
                if block not in monograph_text:
                    problems.append(
                        f"monograph source block differs from archive: {path}"
                    )
    except (OSError, tarfile.TarError) as error:
        problems.append(f"source.tar is not a readable Git archive: {error}")
        return
    if archived_commit != commit:
        problems.append(
            f"source archive revision {archived_commit!r} differs from source_commit {commit}"
        )
    _verify_git_archive(
        archive, repo, commit, contract["paths"]["source_archive_paths"], problems
    )


def _verify_git_archive(
    archive: Path,
    repo: Path,
    commit: str,
    paths: list[str],
    problems: list[str],
) -> None:
    """Rebuild the claimed archive from Git and require exact tar identity."""
    with tempfile.NamedTemporaryFile(prefix="crest-source-", suffix=".tar") as expected:
        completed = subprocess.run(
            [
                "git",
                "-C",
                str(repo),
                "archive",
                "--format=tar",
                "--prefix=crest-source/",
                f"--output={expected.name}",
                commit,
                "--",
                *paths,
            ],
            capture_output=True,
            check=False,
        )
        if completed.returncode:
            detail = completed.stderr.decode(errors="replace").strip()
            problems.append(
                f"claimed Git object is unavailable or unarchivable: {detail}"
            )
            return
        if sha256_file(archive) != sha256_file(Path(expected.name)):
            problems.append(
                "source archive differs from claimed Git object "
                "(path, bytes, mode, or revision mismatch)"
            )


def _verify_corpus(path: Path, run: _JsonObject, problems: list[str]) -> None:
    if not path.is_file():
        return
    try:
        with path.open(newline="") as source:
            reader = csv.DictReader(source, delimiter="\t")
            rows = list(reader)
    except (OSError, csv.Error) as error:
        problems.append(f"corpus manifest is invalid TSV: {error}")
        return
    if reader.fieldnames != ["path", "size_bytes", "sha256"]:
        problems.append("corpus manifest header must be path, size_bytes, sha256")
        return
    paths: list[str] = []
    total = 0
    for line, row in enumerate(rows, 2):
        name, size, digest = row["path"], row["size_bytes"], row["sha256"]
        if (
            not isinstance(name, str)
            or not isinstance(size, str)
            or not isinstance(digest, str)
        ):
            problems.append(f"corpus manifest line {line}: malformed row")
            continue
        paths.append(name)
        try:
            total += int(size)
            if int(size) < 0:
                raise ValueError
        except ValueError:
            problems.append(f"corpus manifest line {line}: invalid size")
        if not SHA256.fullmatch(digest):
            problems.append(f"corpus manifest line {line}: invalid SHA-256")
    if paths != sorted(paths, key=os.fsencode) or len(paths) != len(set(paths)):
        problems.append("corpus manifest paths are not unique and byte-sorted")
    if not rows:
        problems.append("corpus manifest is empty")
    corpus = run.get("corpus", {})
    if not isinstance(corpus, dict):
        problems.append("crest-run corpus must be an object")
        return
    file_count, total_bytes = corpus.get("file_count"), corpus.get("total_bytes")
    if (
        not _strict_int(file_count)
        or not _strict_int(total_bytes)
        or file_count != len(rows)
        or total_bytes != total
    ):
        problems.append("run corpus counts differ from corpus manifest")
    if corpus.get("manifest_sha256") != sha256_file(path):
        problems.append("run corpus manifest SHA-256 mismatch")


def _verify_fixed(run: _JsonObject, contract: _TomlTable, problems: list[str]) -> None:
    actual = run.get("fixed_regression")
    expected = contract["fixed_regression"]
    if not isinstance(actual, list) or len(actual) != len(expected):
        problems.append("fixed matcher regression set differs from contract")
        return
    for index, (got, want) in enumerate(zip(actual, expected, strict=True)):
        fields = ("pattern", "document", "matched", "pruned", "digit_threshold")
        if not isinstance(got, dict) or any(
            got.get(field) != want[field] for field in fields
        ):
            problems.append(f"fixed matcher regression {index} differs from contract")
        elif not all(
            _strict_int(got.get(field), 1)
            for field in (
                "expected_branches",
                "branches",
                "expected_digit_threshold",
                "digit_threshold",
            )
        ):
            problems.append(f"fixed matcher regression {index} has invalid counts")
        if not got.get("passed") or (got.get("matched") and got.get("pruned")):
            problems.append(f"fixed matcher regression {index} did not pass soundly")


def _verify_queries(
    run: _JsonObject,
    expected_runs: object,
    problems: list[str],
) -> list[_JsonObject]:
    raw = run.get("queries")
    if not isinstance(raw, list) or not raw:
        problems.append("crest-run queries must be a non-empty array")
        return []
    queries: list[_JsonObject] = []
    for index, query in enumerate(raw):
        if not isinstance(query, dict):
            problems.append(f"crest-run query {index} must be an object")
            continue
        queries.append(query)
        label = query.get("pattern", index)
        diff = query.get("differential")
        integer_fields = (
            "matched",
            "sieve_hits",
            "survivors",
            "pruned_files",
            "matched_and_pruned",
        )
        query_fields = (
            "files",
            "hits",
            "run_survivors",
            "fold_survivors",
            "cnt_survivors",
            "full_ns",
            "sieve_ns",
        )
        ghat = query.get("ghat")
        if (
            not isinstance(diff, dict)
            or any(not _strict_int(diff.get(field)) for field in integer_fields)
            or any(not _strict_int(query.get(field)) for field in query_fields)
            or not isinstance(ghat, list)
            or any(
                not isinstance(requirement, list)
                or any(not _strict_int(count) for count in requirement)
                for requirement in ghat
            )
        ):
            problems.append(f"{label}: invalid matcher differential")
        elif (
            diff["matched_and_pruned"] != 0
            or diff["matched"] != diff["sieve_hits"]
            or query["hits"] != diff["matched"]
            or query["run_survivors"] != diff["survivors"]
            or diff["survivors"] + diff["pruned_files"] != query["files"]
        ):
            problems.append(
                f"{label}: benchmark pruned a matched document or counts disagree"
            )
        for field in ("full_samples_ns", "sieve_samples_ns"):
            samples = query.get(field)
            if (
                not _strict_int(expected_runs, 1)
                or not isinstance(samples, list)
                or len(samples) != expected_runs
                or any(not _strict_int(sample) for sample in samples)
            ):
                problems.append(f"{label}: invalid {field}")
            elif (
                query.get(field.removesuffix("_samples_ns") + "_ns")
                != sorted(samples)[len(samples) // 2]
            ):
                problems.append(f"{label}: aggregate differs from {field}")
    return queries


def _verify_csv(
    path: Path,
    run: _JsonObject,
    problems: list[str],
) -> None:
    try:
        all_lines = path.read_text().splitlines()
        lines = [line for line in all_lines if not line.startswith("#")]
        reader = csv.DictReader(lines, delimiter="\t")
        rows = list(reader)
    except (OSError, csv.Error) as error:
        problems.append(f"{path.name} is invalid: {error}")
        return
    config = run.get("config")
    if not isinstance(config, dict):
        problems.append("crest-run config must be an object")
        return
    expected_profile = (
        "# profile\trank\tbudget",
        f"# {config.get('profile')}\t{config.get('rank')}\t{config.get('budget')}",
    )
    comments = [line for line in all_lines if line.startswith("#")]
    if tuple(comments[:2]) != expected_profile:
        problems.append(f"{path.name} profile metadata differs from crest-run")
    if reader.fieldnames != CSV_FIELDS:
        problems.append(f"{path.name} header differs from the CREST aggregate schema")
        return
    queries = run.get("queries", [])
    if not isinstance(queries, list):
        problems.append("crest-run queries must be an array")
        return
    if len(rows) != len(queries):
        problems.append(f"{path.name} row count differs from crest-run queries")
        return
    for row, query in zip(rows, queries, strict=True):
        if not isinstance(query, dict):
            continue
        diff = query.get("differential")
        if not isinstance(diff, dict):
            continue
        pattern = query.get("pattern", "<invalid>")
        try:
            alternatives = len(query["ghat"])
            files = query["files"]
            exact = {
                "rank": str(config["rank"]),
                "budget": str(config["budget"]),
                "query": query["label"],
                "pattern": query["pattern"],
                "caseless": str(query["caseless"]).lower(),
                "unicode": str(query["unicode"]).lower(),
                "alternatives": str(alternatives),
                "files": str(files),
                "run_survivors": str(query["run_survivors"]),
                "fold_survivors": str(query["fold_survivors"]),
                "cnt_survivors": str(query["cnt_survivors"]),
                "hits": str(query["hits"]),
            }
            expected = {
                "run_prune_pct": (1 - diff["survivors"] / max(files, 1)) * 100,
                "fold_prune_pct": (1 - query["fold_survivors"] / max(files, 1)) * 100,
                "cnt_prune_pct": (1 - query["cnt_survivors"] / max(files, 1)) * 100,
                "full_ms": query["full_ns"] / 1_000_000,
                "sieve_ms": query["sieve_ns"] / 1_000_000,
                "speedup": query["full_ns"] / query["sieve_ns"]
                if query["sieve_ns"]
                else 0,
            }
        except (KeyError, TypeError):
            problems.append(f"{path.name} cannot be reconciled with query {pattern}")
            continue
        if any(row.get(key) != value for key, value in exact.items()):
            problems.append(f"{path.name} aggregate identity differs for {pattern}")
            continue
        for key, value in expected.items():
            try:
                observed = float(row[key])
            except (KeyError, TypeError, ValueError):
                problems.append(f"{path.name} {key} is invalid for {pattern}")
                continue
            # CSV rounds to 2/3 decimals; include the exact half-unit boundary.
            tolerance = 0.00501 if key.endswith("_pct") else 0.000501
            if not math.isfinite(observed) or abs(observed - value) > tolerance:
                problems.append(f"{path.name} {key} differs for {pattern}")


def _verify_production(
    run: _JsonObject,
    expected: dict[str, object],
    problems: list[str],
) -> None:
    production = run.get("production")
    config = run.get("config")
    if not isinstance(production, dict) or not isinstance(config, dict):
        problems.append("crest-run production metadata must be an object")
        return
    for key in (
        "sidecar_format_version",
        "sidecar_q",
        "builder",
        "runtime",
        "uncalibrated_policy",
    ):
        if production.get(key) != expected.get(key):
            problems.append(f"crest-run production {key} differs from contract")
    sidecar_q = production.get("sidecar_q")
    query_rank = production.get("query_rank")
    if (
        not _strict_int(sidecar_q, 1)
        or sidecar_q != 4
        or sidecar_q != expected.get("sidecar_q")
    ):
        problems.append(
            "crest-run production sidecar_q must be the q4 persisted layout"
        )
    if (
        not _strict_int(query_rank, 1)
        or query_rank != config.get("rank")
        or not _strict_int(sidecar_q, 1)
        or query_rank > sidecar_q
    ):
        problems.append(
            "crest-run production query_rank differs from config or sidecar"
        )
    if "q" in production:
        problems.append("crest-run production uses ambiguous legacy q metadata")
    if production.get("validated") is not True:
        problems.append("crest-run production sidecar validation failed")
    for key in ("encoded_bytes", "overflow_entries"):
        value = production.get(key)
        if not _strict_int(value, 1 if key == "encoded_bytes" else 0):
            problems.append(f"crest-run production {key} is invalid")
    calibration = production.get("planner_calibration")
    if calibration not in {"absent", "environment"}:
        problems.append("crest-run planner calibration state is invalid")
    coefficients = production.get("planner_coefficients")
    if calibration == "absent" and coefficients is not None:
        problems.append("crest-run absent planner calibration carries coefficients")
    if calibration == "environment" and (
        not isinstance(coefficients, dict)
        or set(coefficients) != {"fixed", "column_document", "verify_document"}
        or any(not _strict_int(value) for value in coefficients.values())
    ):
        problems.append("crest-run planner coefficients are invalid")
    queries = run.get("queries")
    if not isinstance(queries, list):
        return
    for query in queries:
        if not isinstance(query, dict):
            continue
        planner = query.get("planner")
        label = query.get("pattern", "<invalid>")
        if (
            not isinstance(planner, dict)
            or planner.get("calibrated") is not (calibration == "environment")
            or not isinstance(planner.get("decision_available"), bool)
            or not isinstance(planner.get("ran"), bool)
            or not isinstance(planner.get("reason"), str)
            or not planner["reason"]
        ):
            problems.append(f"{label}: planner observation is inconsistent")
            continue
        numeric = (
            "touched_columns",
            "candidate_docs",
            "scanned_docs",
            "expected_candidates",
            "expected_rejected",
            "direct_cost",
            "crest_cost",
            "estimated_savings",
            "required_savings",
        )
        if any(not _strict_int(planner.get(key)) for key in numeric):
            problems.append(f"{label}: planner decision state is invalid")
            continue
        if planner["decision_available"]:
            document_count = query.get("files")
            corpus = run.get("corpus")
            if (
                not _strict_int(document_count)
                or not isinstance(corpus, dict)
                or not _strict_int(corpus.get("file_count"))
                or document_count != corpus["file_count"]
                or planner["candidate_docs"] > document_count
                or planner["expected_candidates"] > planner["candidate_docs"]
                or planner["expected_rejected"]
                != planner["candidate_docs"] - planner["expected_candidates"]
            ):
                problems.append(f"{label}: planner decision counts differ from query")
            else:
                expected_scanned = (
                    planner["candidate_docs"]
                    if planner["candidate_docs"] <= document_count // 4
                    else document_count
                )
                if planner["scanned_docs"] != expected_scanned:
                    problems.append(
                        f"{label}: planner scanned_docs differs from sparse/dense boundary"
                    )
        if calibration == "absent" and (
            planner["decision_available"]
            or (
                planner["reason"] == "uncalibrated-always-sieve"
                and planner["ran"] is not True
            )
        ):
            problems.append(f"{label}: uncalibrated planner behavior is inconsistent")
        if calibration == "environment" and (
            planner["reason"] != "inactive" and not planner["decision_available"]
        ):
            problems.append(f"{label}: calibrated planner decision is unavailable")


def verify_benchmark_artifacts(
    run_path: Path,
    csv_path: Path,
    corpus_path: Path,
    *,
    schema_version: object,
    artifact_kind: object,
    expected_config: dict[str, object],
    expected_artifacts: dict[str, str],
    expected_production: dict[str, object],
) -> tuple[_JsonObject, list[str]]:
    """Cross-check one benchmark JSON/CSV/manifest triplet without trusting filenames."""
    problems: list[str] = []
    run = _json(run_path, problems)
    if run.get("schema_version") != schema_version:
        problems.append("crest-run schema version differs from contract")
    if run.get("artifact_kind") != artifact_kind:
        problems.append("crest-run artifact kind differs from contract")
    config = run.get("config")
    if not isinstance(config, dict):
        problems.append("crest-run config must be an object")
    else:
        for key, value in expected_config.items():
            observed = config.get(key)
            if key in {"rank", "budget", "runs", "warmup"} and not _strict_int(
                observed, 0 if key == "warmup" else 1
            ):
                problems.append(f"crest-run config {key} must be a non-Boolean integer")
            elif observed != value:
                problems.append(
                    f"crest-run config {key} differs from requested benchmark"
                )
    if run.get("artifacts") != expected_artifacts:
        problems.append("crest-run artifact names differ from requested benchmark")
    _verify_queries(run, expected_config.get("runs"), problems)
    _verify_production(run, expected_production, problems)
    if (
        not _strict_int(run.get("violations"))
        or run.get("violations") != 0
        or run.get("passed") is not True
    ):
        problems.append("crest production proof did not pass with zero violations")
    _verify_corpus(corpus_path, run, problems)
    _verify_csv(csv_path, run, problems)
    return run, problems


def _profile_set(
    table: object,
    key: str,
    label: str,
    problems: list[str],
) -> set[str] | None:
    value = table.get(key) if isinstance(table, dict) else None
    if (
        not isinstance(value, list)
        or any(
            not isinstance(item, str) or PROFILE.fullmatch(item) is None
            for item in value
        )
        or len(value) != len(set(value))
    ):
        problems.append(f"{label} must be a unique string array")
        return None
    return set(value)


def _verify_promotion(bench: _TomlTable, profile: object, problems: list[str]) -> None:
    comparable = _profile_set(
        bench.get("capability"),
        "comparable_profiles",
        "benchmark capability comparable_profiles",
        problems,
    )
    promotion = bench.get("promotion")
    authorized = _profile_set(
        promotion,
        "authorized_profiles",
        "benchmark promotion authorized_profiles",
        problems,
    )
    blocked = _profile_set(
        promotion,
        "blocked_profiles",
        "benchmark promotion blocked_profiles",
        problems,
    )
    if comparable is None or authorized is None or blocked is None:
        problems.append("benchmark promotion profile sets are invalid")
        return
    if authorized & blocked:
        problems.append("benchmark promotion authorized and blocked profiles overlap")
    if authorized | blocked != comparable:
        problems.append("benchmark promotion sets must partition comparable profiles")
    rank, budget = bench.get("rank"), bench.get("budget")
    if profile != f"q{rank}-b{budget}":
        problems.append("crest-run profile differs from its rank/budget")
    if profile not in authorized:
        problems.append("crest-run profile is not authorized for promotion")
    if profile in blocked:
        problems.append("crest-run profile is blocked from promotion")


def _verify_run(
    package: Path, contract: _TomlTable, problems: list[str]
) -> _JsonObject:
    bench = contract["benchmark"]
    expected_artifacts = {
        "aggregate_csv": Path(contract["paths"]["aggregate_csv"]).name,
        "run_json": Path(contract["paths"]["run_json"]).name,
        "corpus_manifest": Path(contract["paths"]["corpus_manifest"]).name,
    }
    run, common = verify_benchmark_artifacts(
        package / "crest-run.json",
        package / "crest.csv",
        package / "corpus-manifest.tsv",
        schema_version=contract["meta"]["schema_version"],
        artifact_kind=contract["meta"]["artifact_kind"],
        expected_config={
            key: bench[key]
            for key in (
                "runs",
                "warmup",
                "rank",
                "budget",
                "profile",
                "timing_clock",
                "aggregation",
            )
        },
        expected_artifacts=expected_artifacts,
        expected_production=bench["production"],
    )
    problems.extend(
        problem.replace("requested benchmark", "contract") for problem in common
    )
    config = run.get("config")
    profile = config.get("profile") if isinstance(config, dict) else None
    _verify_promotion(bench, profile, problems)
    seeds = run.get("seeds", {})
    if seeds != {
        "ascii": bench["ascii_seed"],
        "unicode": bench["unicode_seed"],
        "caseless_mask": bench["caseless_seed_mask"],
    }:
        problems.append("crest-run seeds differ from contract")
    _verify_fixed(run, contract, problems)

    queries = run.get("queries")
    if not isinstance(queries, list):
        return run
    identities = [
        {
            "label": query.get("label"),
            "pattern": query.get("pattern"),
            "caseless": query.get("caseless"),
            "unicode": query.get("unicode"),
        }
        for query in queries
        if isinstance(query, dict)
    ]
    if identities != bench["query"]:
        problems.append("crest-run query order differs from contract")

    random = run.get("randomized_soundness", {})
    if not isinstance(random, dict):
        problems.append("crest-run randomized_soundness must be an object")
        return run
    expected_checks = (
        bench["random_patterns_per_mode"] * bench["random_files_per_pattern"]
    )
    mask = bench["caseless_seed_mask"]
    for mode, unicode, caseless, seed in (
        ("ascii", False, False, bench["ascii_seed"]),
        ("unicode", True, False, bench["unicode_seed"]),
        ("caseless_ascii", False, True, bench["ascii_seed"] ^ mask),
        ("caseless_unicode", True, True, bench["unicode_seed"] ^ mask),
    ):
        result = random.get(mode, {})
        counts = ("patterns", "checks", "matches", "pruned", "violations")
        if (
            not isinstance(result, dict)
            or not _strict_int(result.get("seed"))
            or any(not _strict_int(result.get(field)) for field in counts)
            or result.get("seed") != seed
            or result.get("unicode") is not unicode
            or result.get("caseless") is not caseless
            or result.get("patterns") != bench["random_patterns_per_mode"]
            or result.get("checks") != expected_checks
            or result.get("violations") != 0
        ):
            problems.append(f"{mode} randomized matcher result differs from contract")
    return run


def _verify_receipts(
    package: Path, contract: _TomlTable, manifest: _JsonObject, problems: list[str]
) -> None:
    test = _json(package / "test-artifact.json", problems)
    if test.get("source_commit") != manifest.get("source_commit"):
        problems.append("test artifact revision differs from source revision")
    if test.get("exit_code") != 0:
        problems.append("test artifact records a failed test command")
    if (
        test.get("argv") != contract["commands"]["test"]
        or test.get("cwd") != contract["commands"]["cwd"]
    ):
        problems.append("test artifact command differs from contract")
    if test.get("transcript_sha256") != sha256_file(package / "test-transcript.txt"):
        problems.append("test transcript hash differs from test artifact")
    if manifest.get("test_artifact_sha256") != sha256_file(
        package / "test-artifact.json"
    ):
        problems.append("test artifact hash differs from evidence manifest")
    if manifest.get("benchmark_artifact_sha256") != sha256_file(
        package / "crest-run.json"
    ):
        problems.append("benchmark artifact hash differs from evidence manifest")

    log = _json(package / "command-log.json", problems)
    commands = log.get("commands")
    if not isinstance(commands, list):
        problems.append("command log has no command receipts")
        return
    by_label = {
        item.get("label"): item
        for item in commands
        if isinstance(item, dict) and item.get("label")
    }
    for label in ("benchmark", "test", "source_archive"):
        if label not in by_label or by_label[label].get("exit_code") != 0:
            problems.append(f"command log lacks successful {label} receipt")
    for label, transcript in (
        ("benchmark", "benchmark-transcript.txt"),
        ("test", "test-transcript.txt"),
    ):
        receipt = by_label.get(label, {})
        if receipt.get("transcript") != transcript or receipt.get(
            "transcript_sha256"
        ) != sha256_file(package / transcript):
            problems.append(f"{label} command receipt has a bad transcript hash")
    benchmark = [
        part.format(
            rank=contract["benchmark"]["rank"],
            budget=contract["benchmark"]["budget"],
            runs=contract["benchmark"]["runs"],
            warmup=contract["benchmark"]["warmup"],
        )
        for part in contract["commands"]["benchmark"]
    ]
    if (
        by_label.get("benchmark", {}).get("argv") != benchmark
        or by_label.get("benchmark", {}).get("cwd") != contract["commands"]["cwd"]
    ):
        problems.append("benchmark command differs from contract")
    expected_test = contract["commands"]["test"]
    if (
        by_label.get("test", {}).get("argv") != expected_test
        or by_label.get("test", {}).get("cwd") != contract["commands"]["cwd"]
    ):
        problems.append("test command differs from contract")
    archive_argv = by_label.get("source_archive", {}).get("argv")
    if not isinstance(archive_argv, list):
        problems.append("source archive command receipt has no argv")
    else:
        try:
            separator = archive_argv.index("--")
        except ValueError:
            separator = -1
        if (
            "archive" not in archive_argv
            or "--format=tar" not in archive_argv
            or "--prefix=crest-source/" not in archive_argv
            or manifest.get("source_commit") not in archive_argv
            or not any(str(arg).startswith("--output=") for arg in archive_argv)
            or separator < 0
            or archive_argv[separator + 1 :]
            != contract["paths"]["source_archive_paths"]
        ):
            problems.append("source archive command differs from contract")


def _verify_machine(
    package: Path, contract: _TomlTable, problems: list[str]
) -> _JsonObject:
    machine = _json(package / "machine.json", problems)
    for key in contract["machine"]["required_keys"]:
        if key not in machine:
            problems.append(f"machine metadata missing key: {key}")
    for key in contract["machine"]["nullable_with_note"]:
        if machine.get(key) is None and not machine.get(f"{key}_note"):
            problems.append(f"machine metadata null {key} lacks an explanatory note")
    toolchain = machine.get("toolchain")
    if (
        not isinstance(toolchain, dict)
        or set(toolchain) != {"python", "git", "zig"}
        or any(not isinstance(value, str) or not value for value in toolchain.values())
    ):
        problems.append("machine metadata lacks bound Python/Git/Zig toolchain")
    return machine


def _verify_environment(
    package: Path,
    manifest: _JsonObject,
    machine: _JsonObject,
    problems: list[str],
) -> None:
    for field, artifact in (
        ("machine_artifact_sha256", "machine.json"),
        ("command_log_sha256", "command-log.json"),
    ):
        digest = manifest.get(field)
        if not isinstance(digest, str) or not SHA256.fullmatch(digest):
            problems.append(f"evidence manifest {field} is not SHA-256")
        elif digest != sha256_file(package / artifact):
            problems.append(f"evidence manifest {field} differs from payload")
    environment = {
        "toolchain": machine.get("toolchain"),
        "platform": {
            key: machine.get(key)
            for key in (
                "hostname",
                "os",
                "kernel",
                "architecture",
                "cpu_model",
                "logical_cpu_count",
                "memory_bytes",
                "filesystem",
                "storage",
                "power",
                "cache_condition",
            )
        },
    }
    if manifest.get("environment") != environment:
        problems.append("evidence manifest environment differs from machine payload")
    expected_hash = hashlib.sha256(
        json.dumps(
            environment,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
        ).encode()
    ).hexdigest()
    if manifest.get("environment_sha256") != expected_hash:
        problems.append("evidence manifest environment SHA-256 mismatch")


def verify_package(
    package: Path, contract_path: Path, repo: Path | None = None
) -> list[str]:
    problems: list[str] = []
    if not package.is_dir():
        return [f"package directory does not exist: {package}"]
    contract = load_contract(contract_path)
    if repo is None:
        try:
            repo = Path(
                subprocess.check_output(
                    [
                        "git",
                        "-C",
                        str(contract_path.parent),
                        "rev-parse",
                        "--show-toplevel",
                    ],
                    text=True,
                    stderr=subprocess.PIPE,
                ).strip()
            )
        except (OSError, subprocess.CalledProcessError) as error:
            detail = getattr(error, "stderr", "").strip()
            return [
                f"cannot locate Git object database for source verification: {detail}"
            ]
    manifest = _verify_envelope(package, contract, problems)
    if not manifest:
        return problems
    required = (
        contract["artifacts"]["payload_required"]
        + contract["artifacts"]["envelope_required"]
    )
    if any(not (package / name).is_file() for name in required):
        return problems
    if manifest.get("schema_version") != contract["meta"]["schema_version"]:
        problems.append("evidence manifest schema version differs from contract")
    if manifest.get("artifact_kind") != contract["meta"]["artifact_kind"]:
        problems.append("evidence manifest artifact kind differs from contract")
    _verify_revision(package, manifest, contract, repo, problems)
    run = _verify_run(package, contract, problems)
    if manifest.get("corpus_manifest_sha256") != sha256_file(
        package / "corpus-manifest.tsv"
    ):
        problems.append("corpus manifest hash differs from evidence manifest")
    matcher = manifest.get("matcher_results")
    if matcher != {
        "fixed_regression": run.get("fixed_regression"),
        "randomized_soundness": run.get("randomized_soundness"),
        "violations": run.get("violations"),
        "passed": run.get("passed"),
    }:
        problems.append("evidence manifest matcher results differ from crest-run")
    _verify_receipts(package, contract, manifest, problems)
    machine = _verify_machine(package, contract, problems)
    _verify_environment(package, manifest, machine, problems)
    problems.extend(monograph.verify(package))
    commit = manifest.get("source_commit", "")
    monograph_text = (package / monograph.MONOGRAPH).read_text()
    if monograph.measured_table(run) not in monograph_text:
        problems.append("monograph measured table differs from crest-run")
    for field, value in (
        ("Source commit", commit),
        ("Source archive SHA-256", manifest.get("source_archive_sha256", "")),
        ("Benchmark artifact SHA-256", manifest.get("benchmark_artifact_sha256", "")),
        ("Test artifact SHA-256", manifest.get("test_artifact_sha256", "")),
    ):
        if f"- {field}: `{value}`" not in monograph_text:
            problems.append(f"monograph {field.lower()} differs from evidence manifest")
    return problems

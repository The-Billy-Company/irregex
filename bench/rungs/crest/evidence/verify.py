#!/usr/bin/env python3
"""Fail-closed verification for a CREST release-evidence package."""

from __future__ import annotations

import csv
from datetime import date, datetime, time
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import tomllib

import monograph


SHA256 = re.compile(r"[0-9a-f]{64}")
COMMIT = re.compile(r"[0-9a-f]{40,64}")
MANIFEST = "evidence-manifest.json"
DETACHED = "EVIDENCE-MANIFEST.sha256"

type _JsonValue = None | bool | int | float | str | list[_JsonValue] | dict[str, _JsonValue]
type _JsonObject = dict[str, _JsonValue]
type _TomlValue = (
    bool | int | float | str | date | datetime | time | list[_TomlValue] | dict[str, _TomlValue]
)
type _TomlTable = dict[str, _TomlValue]


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
    except (OSError, json.JSONDecodeError) as error:
        problems.append(f"{path.name}: invalid JSON: {error}")
        return {}
    if not isinstance(value, dict):
        problems.append(f"{path.name}: root must be an object")
        return {}
    return value


def _verify_envelope(package: Path, contract: _TomlTable, problems: list[str]) -> _JsonObject:
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
                    problems.append(f"monograph source block differs from archive: {path}")
    except (OSError, tarfile.TarError) as error:
        problems.append(f"source.tar is not a readable Git archive: {error}")
        return
    if archived_commit != commit:
        problems.append(
            f"source archive revision {archived_commit!r} differs from source_commit {commit}"
        )
    _verify_git_archive(archive, repo, commit, contract["paths"]["source_archive_paths"], problems)


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
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode:
            detail = completed.stderr.decode(errors="replace").strip()
            problems.append(f"claimed Git object is unavailable or unarchivable: {detail}")
            return
        if sha256_file(archive) != sha256_file(Path(expected.name)):
            problems.append(
                "source archive differs from claimed Git object "
                "(path, bytes, mode, or revision mismatch)"
            )


def _verify_corpus(package: Path, run: _JsonObject, problems: list[str]) -> None:
    path = package / "corpus-manifest.tsv"
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
    if corpus.get("file_count") != len(rows) or corpus.get("total_bytes") != total:
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
        if not isinstance(got, dict) or any(got.get(field) != want[field] for field in fields):
            problems.append(f"fixed matcher regression {index} differs from contract")
        if not got.get("passed") or (got.get("matched") and got.get("pruned")):
            problems.append(f"fixed matcher regression {index} did not pass soundly")


def _verify_csv(package: Path, run: _JsonObject, problems: list[str]) -> None:
    try:
        lines = [
            line
            for line in (package / "crest.csv").read_text().splitlines()
            if not line.startswith("#")
        ]
        rows = list(csv.DictReader(lines, delimiter="\t"))
    except (OSError, csv.Error) as error:
        problems.append(f"crest.csv is invalid: {error}")
        return
    queries = run.get("queries", [])
    if len(rows) != len(queries):
        problems.append("crest.csv row count differs from crest-run queries")
        return
    for row, query in zip(rows, queries, strict=True):
        diff = query["differential"]
        exact = {
            "query": query["label"],
            "pattern": query["pattern"],
            "caseless": str(query["caseless"]).lower(),
            "unicode": str(query["unicode"]).lower(),
            "files": str(query["files"]),
            "run_survivors": str(query["run_survivors"]),
            "cnt_survivors": str(query["cnt_survivors"]),
            "hits": str(query["hits"]),
        }
        if any(row.get(key) != value for key, value in exact.items()):
            problems.append(f"crest.csv aggregate identity differs for {query['pattern']}")
            continue
        files = max(query["files"], 1)
        expected = {
            "run_prune_pct": (1 - diff["survivors"] / files) * 100,
            "cnt_prune_pct": (1 - query["cnt_survivors"] / files) * 100,
            "full_ms": query["full_ns"] / 1_000_000,
            "sieve_ms": query["sieve_ns"] / 1_000_000,
            "speedup": query["full_ns"] / query["sieve_ns"] if query["sieve_ns"] else 0,
        }
        for key, value in expected.items():
            try:
                observed = float(row[key])
            except (KeyError, ValueError):
                problems.append(f"crest.csv {key} is invalid for {query['pattern']}")
                continue
            # CSV rounds to 2/3 decimals; include the exact half-unit boundary.
            tolerance = 0.00501 if key.endswith("_pct") else 0.000501
            if abs(observed - value) > tolerance:
                problems.append(f"crest.csv {key} differs for {query['pattern']}")


def _verify_run(package: Path, contract: _TomlTable, problems: list[str]) -> _JsonObject:
    run = _json(package / "crest-run.json", problems)
    bench = contract["benchmark"]
    if run.get("schema_version") != contract["meta"]["schema_version"]:
        problems.append("crest-run schema version differs from contract")
    if run.get("artifact_kind") != contract["meta"]["artifact_kind"]:
        problems.append("crest-run artifact kind differs from contract")
    config = run.get("config", {})
    for key in ("runs", "warmup", "timing_clock", "aggregation"):
        if config.get(key) != bench[key]:
            problems.append(f"crest-run config {key} differs from contract")
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
        problems.append("crest-run queries must be an array")
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
    for query in queries:
        if not isinstance(query, dict):
            problems.append("crest-run query entry must be an object")
            continue
        diff = query.get("differential", {})
        if (
            diff.get("matched_and_pruned") != 0
            or diff.get("matched") != diff.get("sieve_hits")
            or query.get("hits") != diff.get("matched")
            or query.get("run_survivors") != diff.get("survivors")
            or diff.get("survivors", 0) + diff.get("pruned_files", 0) != query.get("files")
        ):
            problems.append(f"matched⇒not-pruned failed for {query.get('pattern')}")
        for field in ("full_samples_ns", "sieve_samples_ns"):
            samples = query.get(field)
            if (
                not isinstance(samples, list)
                or len(samples) != bench["runs"]
                or any(not isinstance(sample, int) or sample < 0 for sample in samples)
            ):
                problems.append(f"{query.get('pattern')}: invalid {field}")
            elif (
                query.get(field.removesuffix("_samples_ns") + "_ns")
                != sorted(samples)[len(samples) // 2]
            ):
                problems.append(f"{query.get('pattern')}: aggregate differs from {field}")

    random = run.get("randomized_soundness", {})
    expected_checks = bench["random_patterns_per_mode"] * bench["random_files_per_pattern"]
    mask = bench["caseless_seed_mask"]
    for mode, unicode, caseless, seed in (
        ("ascii", False, False, bench["ascii_seed"]),
        ("unicode", True, False, bench["unicode_seed"]),
        ("caseless_ascii", False, True, bench["ascii_seed"] ^ mask),
        ("caseless_unicode", True, True, bench["unicode_seed"] ^ mask),
    ):
        result = random.get(mode, {})
        if (
            result.get("seed") != seed
            or result.get("unicode") is not unicode
            or result.get("caseless") is not caseless
            or result.get("patterns") != bench["random_patterns_per_mode"]
            or result.get("checks") != expected_checks
            or result.get("violations") != 0
        ):
            problems.append(f"{mode} randomized matcher result differs from contract")
    if run.get("violations") != 0 or run.get("passed") is not True:
        problems.append("crest production proof did not pass with zero violations")
    _verify_corpus(package, run, problems)
    _verify_csv(package, run, problems)
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
    if manifest.get("test_artifact_sha256") != sha256_file(package / "test-artifact.json"):
        problems.append("test artifact hash differs from evidence manifest")
    if manifest.get("benchmark_artifact_sha256") != sha256_file(package / "crest-run.json"):
        problems.append("benchmark artifact hash differs from evidence manifest")

    log = _json(package / "command-log.json", problems)
    commands = log.get("commands")
    if not isinstance(commands, list):
        problems.append("command log has no command receipts")
        return
    by_label = {
        item.get("label"): item for item in commands if isinstance(item, dict) and item.get("label")
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
            or archive_argv[separator + 1 :] != contract["paths"]["source_archive_paths"]
        ):
            problems.append("source archive command differs from contract")


def _verify_machine(package: Path, contract: _TomlTable, problems: list[str]) -> None:
    machine = _json(package / "machine.json", problems)
    for key in contract["machine"]["required_keys"]:
        if key not in machine:
            problems.append(f"machine metadata missing key: {key}")
    for key in contract["machine"]["nullable_with_note"]:
        if machine.get(key) is None and not machine.get(f"{key}_note"):
            problems.append(f"machine metadata null {key} lacks an explanatory note")


def verify_package(package: Path, contract_path: Path, repo: Path | None = None) -> list[str]:
    problems: list[str] = []
    if not package.is_dir():
        return [f"package directory does not exist: {package}"]
    contract = load_contract(contract_path)
    if repo is None:
        try:
            repo = Path(
                subprocess.check_output(
                    ["git", "-C", str(contract_path.parent), "rev-parse", "--show-toplevel"],
                    text=True,
                    stderr=subprocess.PIPE,
                ).strip()
            )
        except (OSError, subprocess.CalledProcessError) as error:
            detail = getattr(error, "stderr", "").strip()
            return [f"cannot locate Git object database for source verification: {detail}"]
    manifest = _verify_envelope(package, contract, problems)
    if not manifest:
        return problems
    required = (
        contract["artifacts"]["payload_required"] + contract["artifacts"]["envelope_required"]
    )
    if any(not (package / name).is_file() for name in required):
        return problems
    if manifest.get("schema_version") != contract["meta"]["schema_version"]:
        problems.append("evidence manifest schema version differs from contract")
    if manifest.get("artifact_kind") != contract["meta"]["artifact_kind"]:
        problems.append("evidence manifest artifact kind differs from contract")
    _verify_revision(package, manifest, contract, repo, problems)
    run = _verify_run(package, contract, problems)
    if manifest.get("corpus_manifest_sha256") != sha256_file(package / "corpus-manifest.tsv"):
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
    _verify_machine(package, contract, problems)
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

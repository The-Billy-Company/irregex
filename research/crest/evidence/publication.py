"""Seal and verify corpus-independent CREST publication evidence manifests."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath

if __package__:
    from . import semantics as _semantics
    from .snapshot import SnapshotError, capture
else:
    import semantics as _semantics
    from snapshot import SnapshotError, capture


CORPUS_REPORTS = _semantics.CORPUS_REPORTS
CORPUS_REQUIRED = _semantics.CORPUS_REQUIRED
CORPUS_SCHEMA = _semantics.CORPUS_SCHEMA
corpus_status = _semantics.corpus_status
SCHEMA = "irregex-crest-publication-evidence-v1"
MANIFEST = "publication-evidence.json"
DETACHED = "PUBLICATION-EVIDENCE.sha256"
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
PROMOTION_AUTHORIZATION = {
    "q4": False,
    "adaptive_predicate_dictionary": False,
    "reason": "publication evidence is review input, never an automatic promotion signal",
}


class EvidenceError(ValueError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode()


def _probe(*argv: str) -> str | None:
    executable = shutil.which(argv[0])
    if not executable:
        return None
    try:
        return (
            subprocess.check_output(
                [executable, *argv[1:]],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
            or None
        )
    except (OSError, subprocess.CalledProcessError):
        return None


def environment_metadata() -> dict[str, object]:
    """Capture immutable toolchain/platform facts, with nulls kept explicit."""
    return {
        "captured_at_utc": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "toolchain": {
            "python": sys.version.replace("\n", " "),
            "git": _probe("git", "--version"),
            "zig": _probe("zig", "version") or _probe("mise", "exec", "--", "zig", "version"),
        },
        "platform": {
            "hostname": socket.gethostname(),
            "os": platform.platform(),
            "kernel": platform.release(),
            "architecture": platform.machine(),
            "logical_cpu_count": os.cpu_count(),
        },
    }


def _safe_name(name: str) -> bool:
    path = PurePosixPath(name)
    return (
        bool(name)
        and "\\" not in name
        and "\0" not in name
        and not path.is_absolute()
        and ".." not in path.parts
        and path.as_posix() == name
        and name not in {MANIFEST, DETACHED}
    )


@contextmanager
def _snapshot(directory: Path) -> Iterator[Mapping[str, bytes]]:
    try:
        with capture(directory) as snapshot:
            yield snapshot.files
    except SnapshotError as error:
        raise EvidenceError(f"artifact snapshot failed: {error}") from error


def _payload(snapshot: Mapping[str, bytes]) -> dict[str, bytes]:
    payload: dict[str, bytes] = {}
    for name, raw in snapshot.items():
        if name in {MANIFEST, DETACHED}:
            continue
        if not _safe_name(name):
            raise EvidenceError(f"unsafe artifact path: {name}")
        payload[name] = raw
    if not payload:
        raise EvidenceError("publication evidence has no payload artifacts")
    return payload


def artifact_hashes(artifacts: Mapping[str, bytes]) -> dict[str, str]:
    return {name: sha256_bytes(raw) for name, raw in sorted(artifacts.items())}


def build_manifest(
    directory: Path,
    *,
    source_commit: str,
    dataset_fingerprint: str,
    metadata: dict[str, object] | None = None,
) -> dict[str, object]:
    if not re.fullmatch(r"[0-9a-f]{40,64}", source_commit):
        raise EvidenceError("source commit must be a full hexadecimal object id")
    if not SHA256.fullmatch(dataset_fingerprint):
        raise EvidenceError("dataset fingerprint must be lowercase SHA-256")
    with _snapshot(directory) as snapshot:
        payload = _payload(snapshot)
        files = artifact_hashes(payload)
        corpus_missing, corpus_errors = corpus_status(
            payload,
            source_commit=source_commit,
            dataset_fingerprint=dataset_fingerprint,
        )
        status = (
            "corpus_runs_pending"
            if corpus_missing
            else "corpus_runs_error"
            if corpus_errors
            else "complete"
        )
        environment = metadata or environment_metadata()
        return {
            "schema": SCHEMA,
            "source_commit": source_commit,
            "dataset_fingerprint": dataset_fingerprint,
            "evidence_status": status,
            "corpus_runs_pending": corpus_missing,
            "corpus_evidence_errors": corpus_errors,
            "promotion_authorization": dict(PROMOTION_AUTHORIZATION),
            "environment": environment,
            "environment_sha256": sha256_bytes(canonical_bytes(environment)),
            "files": files,
        }


def seal(
    directory: Path,
    *,
    source_commit: str,
    dataset_fingerprint: str,
    metadata: dict[str, object] | None = None,
) -> dict[str, object]:
    manifest_path, detached = directory / MANIFEST, directory / DETACHED
    if manifest_path.exists() or detached.exists():
        raise EvidenceError("refusing to overwrite an existing publication envelope")
    manifest = build_manifest(
        directory,
        source_commit=source_commit,
        dataset_fingerprint=dataset_fingerprint,
        metadata=metadata,
    )
    encoded = canonical_bytes(manifest)
    manifest_path.write_bytes(encoded)
    detached.write_text(f"{sha256_bytes(encoded)}  {MANIFEST}\n")
    return manifest


def verify(directory: Path) -> list[str]:
    with _snapshot(directory) as snapshot:
        return _verify_snapshot(snapshot)


def _verify_snapshot(snapshot: Mapping[str, bytes]) -> list[str]:
    problems: list[str] = []
    if MANIFEST not in snapshot or DETACHED not in snapshot:
        return ["publication manifest or detached hash is missing"]
    manifest_raw, detached_raw = snapshot[MANIFEST], snapshot[DETACHED]
    try:
        detached_fields = detached_raw.decode("utf-8").strip().split()
    except UnicodeError as error:
        return [f"detached publication hash is not UTF-8: {error}"]
    if detached_fields != [sha256_bytes(manifest_raw), MANIFEST]:
        problems.append("detached publication manifest hash mismatch")
    try:
        manifest = json.loads(manifest_raw)
    except (UnicodeError, json.JSONDecodeError) as error:
        return [f"publication manifest is invalid JSON: {error}"]
    expected_fields = {
        "schema",
        "source_commit",
        "dataset_fingerprint",
        "evidence_status",
        "corpus_runs_pending",
        "corpus_evidence_errors",
        "promotion_authorization",
        "environment",
        "environment_sha256",
        "files",
    }
    if not isinstance(manifest, dict) or set(manifest) != expected_fields:
        return [*problems, "publication manifest fields differ from schema"]
    if manifest["schema"] != SCHEMA:
        problems.append("publication manifest schema mismatch")
    source_commit = manifest.get("source_commit")
    if not isinstance(source_commit, str) or not re.fullmatch(r"[0-9a-f]{40,64}", source_commit):
        problems.append("publication source commit is not a full object id")
    dataset_fingerprint = manifest.get("dataset_fingerprint")
    if not isinstance(dataset_fingerprint, str) or not SHA256.fullmatch(dataset_fingerprint):
        problems.append("publication dataset fingerprint is not SHA-256")
    environment = manifest.get("environment")
    if (
        not isinstance(environment, dict)
        or set(environment) != {"captured_at_utc", "toolchain", "platform"}
        or not isinstance(environment.get("toolchain"), dict)
        or set(environment["toolchain"]) != {"python", "git", "zig"}
        or not isinstance(environment.get("platform"), dict)
        or set(environment["platform"])
        != {
            "hostname",
            "os",
            "kernel",
            "architecture",
            "logical_cpu_count",
        }
    ):
        problems.append("publication toolchain/platform metadata shape is invalid")
    if manifest["environment_sha256"] != sha256_bytes(canonical_bytes(manifest["environment"])):
        problems.append("environment metadata hash mismatch")
    files = manifest["files"]
    if not isinstance(files, dict):
        return [*problems, "publication file hashes must be an object"]
    payload = _payload(snapshot)
    observed_hashes = artifact_hashes(payload)
    for name, digest in files.items():
        if not isinstance(name, str):
            problems.append("publication payload path is not a string")
            continue
        if (
            not _safe_name(name)
            or not isinstance(digest, str)
            or not SHA256.fullmatch(digest)
            or observed_hashes.get(name) != digest
        ):
            problems.append(f"publication payload hash mismatch: {name}")
    if set(payload) != set(files):
        problems.append("publication payload file set differs from manifest")
    missing, semantic = corpus_status(
        payload,
        source_commit=source_commit if isinstance(source_commit, str) else "",
        dataset_fingerprint=(dataset_fingerprint if isinstance(dataset_fingerprint, str) else ""),
    )
    expected_status = (
        "corpus_runs_pending" if missing else "corpus_runs_error" if semantic else "complete"
    )
    if (
        manifest["corpus_runs_pending"] != missing
        or manifest["corpus_evidence_errors"] != semantic
        or manifest["evidence_status"] != expected_status
    ):
        problems.append("corpus evidence status differs from semantic payload verification")
    if semantic:
        problems.extend(f"corpus evidence invalid: {problem}" for problem in semantic)
    if manifest["promotion_authorization"] != PROMOTION_AUTHORIZATION:
        problems.append("publication manifest contains an automatic promotion claim")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("seal")
    create.add_argument("directory", type=Path)
    create.add_argument("--source-commit", required=True)
    create.add_argument("--dataset-fingerprint", required=True)
    check = commands.add_parser("verify")
    check.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "seal":
            print(
                seal(
                    args.directory,
                    source_commit=args.source_commit,
                    dataset_fingerprint=args.dataset_fingerprint,
                )["evidence_status"]
            )
            return 0
        problems = verify(args.directory)
        for problem in problems:
            print(problem)
        return bool(problems)
    except (EvidenceError, OSError) as error:
        print(f"CREST publication evidence error: {error}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
